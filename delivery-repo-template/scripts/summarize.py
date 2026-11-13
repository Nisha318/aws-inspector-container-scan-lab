#!/usr/bin/env python3
"""Turn an Inspector findings report into a ranked, deduplicated SUMMARY.md.

Reads the JSON report in a dated folder, groups findings into one row per
ECR repository and package, ranks the rows into four tiers, compares them
with the previous run, and writes SUMMARY.md beside the raw files.

    python3 scripts/summarize.py <customer>-inspector-scans/2026-11-12

State lives in <customer>-inspector-scans/summary.json: for every row ever
seen, the date it first appeared, the date it was last seen, and how many
reports it has appeared in. That is what makes "New", "Carried (6)" and
"Resolved" possible. Running the script twice on the same folder is safe.

Standard library only. No arguments beyond the folder.
"""

import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from glob import glob

SEVERITY_RANK = {
    "CRITICAL": 5, "HIGH": 4, "MEDIUM": 3, "LOW": 2,
    "INFORMATIONAL": 1, "UNTRIAGED": 0,
}

TIERS = [
    ("P1", "Act now",
     "Known exploit, fix available, critical or high severity."),
    ("P2", "Schedule",
     "Fix available, critical or high severity, no known exploit."),
    ("P3", "Track",
     "Fix available, medium or low severity."),
    ("P4", "Accept or wait",
     "No fix available yet. Accept the risk, add a control, or wait for the vendor."),
]


def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_findings(folder):
    files = sorted(glob(os.path.join(folder, "*.json")))
    if not files:
        die(f"no JSON report in {folder}")
    path = files[-1]
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    findings = data["findings"] if isinstance(data, dict) else data
    return path, [x for x in findings if x.get("status", "ACTIVE") == "ACTIVE"]


def tier_for(row):
    worst = row["worst_severity"]
    high = SEVERITY_RANK[worst] >= SEVERITY_RANK["HIGH"]
    if row["fix"] and row["exploit"] and high:
        return "P1"
    if row["fix"] and high:
        return "P2"
    if row["fix"]:
        return "P3"
    return "P4"


def split_platform_findings(findings):
    """Inspector reports an unsupported base OS as a finding of its own
    (vulnerabilityId IN-DISCONTINUED-*, title 'Platform End Of Life'). It is
    not a package to patch, so it is pulled out and shown as a notice."""
    platform, rest = [], []
    for f in findings:
        vid = (f.get("packageVulnerabilityDetails") or {}).get("vulnerabilityId", "")
        if vid.startswith("IN-") or f.get("title", "").lower().startswith("platform end of life"):
            platform.append(f)
        else:
            rest.append(f)
    return platform, rest


def version_key(v):
    """Natural sort for package versions, good enough to pick the newest."""
    import re
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", v)]


def build_rows(findings):
    """One row per repository and package name."""
    rows = {}
    for f in findings:
        pv = f.get("packageVulnerabilityDetails") or {}
        cve = pv.get("vulnerabilityId") or f.get("title", "unknown")
        refs = pv.get("referenceUrls") or ([pv["sourceUrl"]] if pv.get("sourceUrl") else [])
        score = f.get("inspectorScore")
        epss = (f.get("epss") or {}).get("score")
        severity = f.get("severity", "UNTRIAGED")
        exploit = f.get("exploitAvailable") == "YES"
        fix = f.get("fixAvailable") in ("YES", "PARTIAL")
        first = (f.get("firstObservedAt") or "")[:10]

        for res in f.get("resources") or []:
            img = (res.get("details") or {}).get("awsEcrContainerImage") or {}
            repo = img.get("repositoryName") or res.get("id", "unknown")
            tags = img.get("imageTags") or []
            for pkg in pv.get("vulnerablePackages") or [{"name": "unknown"}]:
                key = f"{repo}|{pkg.get('name', 'unknown')}"
                row = rows.setdefault(key, {
                    "repository": repo, "package": pkg.get("name", "unknown"),
                    "tags": set(), "versions": set(), "fixed_in": set(),
                    "cves": {}, "exploit": False, "fix": False,
                    "worst_severity": "UNTRIAGED", "max_score": 0.0,
                    "max_epss": 0.0, "first_seen_in_report": first or "",
                    "remediation": "",
                })
                row["tags"].update(tags)
                if pkg.get("version"):
                    row["versions"].add(pkg["version"])
                if pkg.get("fixedInVersion") and pkg["fixedInVersion"] != "NotAvailable":
                    row["fixed_in"].add(pkg["fixedInVersion"])
                if pkg.get("remediation") and not row["remediation"]:
                    row["remediation"] = pkg["remediation"]
                row["exploit"] = row["exploit"] or exploit
                row["fix"] = row["fix"] or fix
                if SEVERITY_RANK[severity] > SEVERITY_RANK[row["worst_severity"]]:
                    row["worst_severity"] = severity
                row["max_score"] = max(row["max_score"], score or 0.0)
                row["max_epss"] = max(row["max_epss"], epss or 0.0)
                if first and (not row["first_seen_in_report"] or first < row["first_seen_in_report"]):
                    row["first_seen_in_report"] = first
                prev = row["cves"].get(cve)
                if not prev or (score or 0) > (prev["score"] or 0):
                    row["cves"][cve] = {
                        "severity": severity, "score": score, "epss": epss,
                        "exploit": exploit, "fix": fix, "url": refs[0] if refs else "",
                    }
    for row in rows.values():
        row["tier"] = tier_for(row)
    return rows


def load_state(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {"rows": {}, "reports": []}


def update_state(state, rows, report_date):
    """Mark rows New / Carried / Resolved and record this report. Idempotent."""
    seen_before = report_date in state["reports"]
    prev_dates = [d for d in state["reports"] if d < report_date]
    prev_date = max(prev_dates) if prev_dates else None

    status = {}
    for key in rows:
        rec = state["rows"].get(key)
        if rec is None:
            state["rows"][key] = {"first_seen": report_date, "last_seen": report_date, "reports": 1}
            status[key] = ("New", 1)
        else:
            if not seen_before and rec["last_seen"] != report_date:
                rec["reports"] += 1
                rec["last_seen"] = report_date
            label = "New" if rec["first_seen"] == report_date else "Carried"
            status[key] = (label, rec["reports"])

    resolved = []
    for key, rec in list(state["rows"].items()):
        if key not in rows and prev_date and rec["last_seen"] == prev_date:
            resolved.append((key, rec))
            del state["rows"][key]

    if not seen_before:
        state["reports"].append(report_date)
        state["reports"].sort()
    return status, resolved, prev_date


def fmt_score(x):
    return f"{x:.1f}" if x else "-"


def fmt_epss(x):
    return f"{x:.3f}" if x else "-"


def cve_link(cve, url):
    return f"[{cve}]({url})" if url else cve


def write_summary(folder, report_path, rows, status, resolved, prev_date, report_date, customer, findings, platform):
    sev_counts = defaultdict(int)
    for f in findings:
        sev_counts[f.get("severity", "UNTRIAGED")] += 1
    by_tier = defaultdict(list)
    for key, row in rows.items():
        by_tier[row["tier"]].append((key, row))
    for t in by_tier:
        by_tier[t].sort(key=lambda kr: (-kr[1]["max_score"], -kr[1]["max_epss"], kr[1]["repository"], kr[1]["package"]))

    new_n = sum(1 for s in status.values() if s[0] == "New")
    carried_n = len(status) - new_n

    out = []
    out.append(f"# Inspector findings summary: {customer}, {report_date}\n")
    out.append(f"Source report: `{os.path.basename(report_path)}`  ")
    sev_line = ", ".join(f"{sev_counts[s]} {s.lower()}" for s in ["CRITICAL", "HIGH", "MEDIUM", "LOW"] if sev_counts[s])
    out.append(f"Active findings: **{len(findings)}** ({sev_line}), grouped into **{len(rows)} rows** by repository and package.  ")
    if prev_date:
        out.append(f"Since {prev_date}: **{new_n} new**, {carried_n} carried, **{len(resolved)} resolved**.\n")
    else:
        out.append("First report for this customer. Every row is new.\n")

    if platform:
        images = sorted({
            f"{(r.get('details') or {}).get('awsEcrContainerImage', {}).get('repositoryName', '?').split('/')[-1]}"
            f":{','.join((r.get('details') or {}).get('awsEcrContainerImage', {}).get('imageTags') or ['?'])}"
            f" ({(r.get('details') or {}).get('awsEcrContainerImage', {}).get('platform', '?')})"
            for f in platform for r in f.get("resources") or []})
        url = ((platform[0].get("packageVulnerabilityDetails") or {}).get("referenceUrls") or [""])[0]
        out.append(f"> **Base image end of life.** Inspector reports the operating system of "
                   f"{', '.join(images)} as no longer supported ([details]({url})). Vendor patches have stopped, "
                   f"so the rows below cannot all be closed by updating packages. The fix is to rebuild on a supported base image.\n")

    p1 = len(by_tier["P1"])
    if p1:
        out.append(f"> **{p1} row{'s' if p1 != 1 else ''} need attention now**: known exploit, fix available, critical or high.\n")

    out.append("| Tier | Rows | Meaning |\n| --- | ---: | --- |")
    for code, name, meaning in TIERS:
        out.append(f"| {code} | {len(by_tier[code])} | {name}. {meaning} |")
    out.append("")

    for code, name, meaning in TIERS:
        items = by_tier[code]
        out.append(f"## {code}: {name} ({len(items)} row{'s' if len(items) != 1 else ''})\n")
        if not items:
            out.append("None.\n")
            continue
        out.append("| Repository | Tags | Package | Current | Fixed in | CVEs | Worst | Score | EPSS | Exploit | First seen | Status |")
        out.append("| --- | --- | --- | --- | --- | ---: | --- | ---: | ---: | :---: | --- | --- |")
        for key, row in items:
            worst_cve = max(row["cves"].items(), key=lambda kv: ((kv[1]["score"] or 0), kv[1]["exploit"]))
            label, n = status[key]
            st = "New" if label == "New" else f"Carried ({n})"
            out.append("| {repo} | {tags} | {pkg} | {cur} | {fix} | {n} | {worst} | {score} | {epss} | {exp} | {first} | {st} |".format(
                repo=row["repository"].split("/")[-1],
                tags=", ".join(sorted(row["tags"])) or "-",
                pkg=f"`{row['package']}`",
                cur=", ".join(sorted(row["versions"])) or "-",
                fix=(max(row["fixed_in"], key=version_key) if row["fixed_in"] else "-"),
                n=len(row["cves"]),
                worst=cve_link(worst_cve[0], worst_cve[1]["url"]),
                score=fmt_score(row["max_score"]),
                epss=fmt_epss(row["max_epss"]),
                exp="yes" if row["exploit"] else "no",
                first=row["first_seen_in_report"] or "-",
                st=st,
            ))
        out.append("")
        out.append("<details><summary>Every CVE in these rows</summary>\n")
        for key, row in items:
            out.append(f"**{row['repository'].split('/')[-1]} / {row['package']}** ({len(row['cves'])}): " + ", ".join(
                cve_link(c, d["url"]) + f" {d['severity'].lower()} {fmt_score(d['score'] or 0)}"
                for c, d in sorted(row["cves"].items(), key=lambda kv: -(kv[1]["score"] or 0))
            ) + "  ")
        out.append("\n</details>\n")

    out.append(f"## Resolved since {prev_date or 'last report'} ({len(resolved)})\n")
    if resolved:
        out.append("| Repository | Package | First seen | Reports |\n| --- | --- | --- | ---: |")
        for key, rec in sorted(resolved):
            repo, pkg = key.split("|", 1)
            out.append(f"| {repo.split('/')[-1]} | `{pkg}` | {rec['first_seen']} | {rec['reports']} |")
    else:
        out.append("None.")
    out.append("")

    out.append("---\n")
    out.append("**How to read this.** One row is one package in one repository, across all of its tags. "
               "Updating that package, usually by rebuilding on a newer base image, closes every CVE in the row. "
               "Score is the highest Inspector score in the row. EPSS is the highest estimated probability of exploitation in the next 30 days. "
               "*Carried (n)* means the row has appeared in n consecutive reports. "
               "Findings come from registry scans: Inspector does not know whether an image is deployed or exposed. "
               "Suppressed findings are not in the report.")
    out.append(f"\nGenerated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by `scripts/summarize.py`.")

    path = os.path.join(folder, "SUMMARY.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return path, p1, new_n, len(resolved)


def main():
    if len(sys.argv) != 2:
        die("usage: summarize.py <customer>-inspector-scans/<YYYY-MM-DD>")
    folder = os.path.abspath(sys.argv[1].rstrip("/"))
    if not os.path.isdir(folder):
        die(f"{folder} is not a directory")
    scan_dir = os.path.dirname(folder)
    report_date = os.path.basename(folder)
    customer = os.path.basename(scan_dir).removesuffix("-inspector-scans")

    report_path, findings = load_findings(folder)
    platform, findings = split_platform_findings(findings)
    rows = build_rows(findings)
    state_path = os.path.join(scan_dir, "summary.json")
    state = load_state(state_path)
    status, resolved, prev_date = update_state(state, rows, report_date)
    summary_path, p1, new_n, resolved_n = write_summary(
        folder, report_path, rows, status, resolved, prev_date, report_date, customer, findings, platform)

    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)
        f.write("\n")

    print(f"Wrote {summary_path}: {len(findings)} findings, {len(rows)} rows, "
          f"{p1} P1, {new_n} new, {resolved_n} resolved")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write(f"summary_path={summary_path}\n")
            f.write(f"p1={p1}\nnew={new_n}\nresolved={resolved_n}\nrows={len(rows)}\n")


if __name__ == "__main__":
    main()
