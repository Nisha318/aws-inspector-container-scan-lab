# Inspector findings delivery

This repository receives Amazon Inspector container scan reports for one customer, on a schedule, without anyone logging into AWS. A GitHub Actions workflow assumes a read-only AWS role, downloads the newest reports from a staging bucket, commits them here, and emails the readers a link.

## For readers

Reports are filed by the date they were generated, in UTC:

```
team-a-inspector-scans/
├── .delivered                      Bookkeeping for the workflow. Ignore it.
├── 2026-11-10/
│   ├── findings-<report id>.csv    Open in a spreadsheet
│   ├── findings-<report id>.json   For scripts and tooling
│   └── SOURCE.txt                  Where each file came from and when
└── 2026-12-10/
    └── ...
```

Each report lists active findings for the customer's container images at the time it was generated. Suppressed findings are left out. Both files in a folder come from the same scan and differ only in format.

When new reports land, subscribers receive an email with a link to the dated folder. No email means nothing new was delivered.

If the export and the delivery job ever fall on opposite sides of midnight UTC, a folder can hold a single file and the next folder its pair. `SOURCE.txt` records the report ID and generation time for each file, so the pairing is always recoverable.

## For the team that runs it

Everything below is done once, by whoever manages the AWS account and this repository. The readers never touch it.

### 1. Create or choose the delivery repository

**New repository.** From the folder that holds your clone of the lab:

```bash
gh repo create OWNER/REPO --private --clone
cp -r aws-inspector-container-scan-lab/delivery-repo-template/. REPO/
cd REPO
ls -a
```

The `/.` on the source copies the hidden `.github` folder too. You should see `.github`, `README.md`, and `scripts`. Then:

```bash
git add -A
git commit -m "Add Inspector findings delivery workflow"
git push -u origin main
```

**Existing repository.** Copy these two paths into it, keeping their names, and commit:

```
.github/workflows/deliver-report.yml
scripts/fetch-latest-report.sh
```

This README is optional. Replace it with one that names the customer, or keep the "For readers" section above.

**Either way,** record the numeric IDs the AWS trust policy needs:

```bash
gh api repos/OWNER/REPO --jq '{owner: .owner.id, repo: .id}'
```

Do not protect the `main` branch. The workflow pushes to it directly with the run's own `GITHUB_TOKEN`, which `permissions: contents: write` in the workflow allows. No personal access token or deploy key is involved.

### 2. Turn on the delivery role in the lab account

In the lab's `terraform.tfvars`, set the repository and its OIDC subject, then apply:

```hcl
delivery_repo             = "OWNER/REPO"
delivery_subject_override = ["repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main"]
```

Use the two IDs from step 1. Repositories created on github.com after July 15, 2026 send this immutable subject form, and the role only trusts an exact match. For an older repository that still sends the plain form, leave `delivery_subject_override` out. If a run fails at the credentials step, the troubleshooting section of the lab README shows how to print the real subject.

On GitHub Enterprise Server, also set `delivery_oidc_url` to `https://YOUR-GHES-HOST/_services/token`. The IAM OIDC provider for that URL must already exist in the account.

To receive emails, add the addresses too:

```hcl
delivery_notify_emails = ["cyber-team@example.com"]   # readers: new reports landed
ops_notify_emails      = ["cloud-team@example.com"]   # operators: export or delivery failed
```

Each address receives a confirmation email from AWS Notifications after the apply. Nothing arrives until the recipient clicks the link in it. Terraform cannot confirm subscriptions on anyone's behalf.

Read these outputs when the apply finishes:

| Output | Becomes repository variable |
| --- | --- |
| `delivery_role_arn` | `AWS_ROLE_ARN` |
| `aws_region` | `AWS_REGION` |
| `report_bucket` | `REPORT_BUCKET` |
| `scheduled_export_prefix`, the path after the bucket | `REPORT_PREFIX`, for example `exports/team-a/` |
| `delivery_topic_arn` | `DELIVERY_TOPIC_ARN` (optional) |
| `ops_topic_arn` | `OPS_TOPIC_ARN` (optional) |

### 3. Set the repository variables

With the `gh` CLI, from any directory:

```bash
gh variable set AWS_ROLE_ARN       --repo OWNER/REPO --body "arn:aws:iam::ACCOUNT:role/inspector-lab-report-delivery"
gh variable set AWS_REGION         --repo OWNER/REPO --body "us-east-1"
gh variable set REPORT_BUCKET      --repo OWNER/REPO --body "inspector-lab-reports-ACCOUNT-us-east-1"
gh variable set REPORT_PREFIX      --repo OWNER/REPO --body "exports/team-a/"
gh variable set DELIVERY_TOPIC_ARN --repo OWNER/REPO --body "arn:aws:sns:us-east-1:ACCOUNT:inspector-lab-report-delivered"
gh variable set OPS_TOPIC_ARN      --repo OWNER/REPO --body "arn:aws:sns:us-east-1:ACCOUNT:inspector-lab-report-pipeline-failures"
gh variable list --repo OWNER/REPO
```

Or in the browser, under **Settings**, **Secrets and variables**, **Actions**, **Variables**, at repository level, not under an environment. None of them is a secret. The bucket name contains the AWS account ID, and the workflow masks it in logs. Leave the two topic variables unset to skip emails.

### 4. Set the schedule

Edit the `cron` line in `deliver-report.yml`. GitHub cron is UTC. Run it at least an hour after the export schedule in Terraform so Inspector has finished writing both files. A run that finds nothing new makes no commit and sends no email, so checking more often than the export runs costs nothing.

GitHub pauses scheduled workflows in a repository with no commits for 60 days. A monthly delivery commits often enough to stay active. For a quarterly cadence, expect to re-enable the workflow from the Actions tab now and then.

### 5. Run it once by hand

Open **Actions**, select **Deliver Inspector findings reports**, and choose **Run workflow**, or:

```bash
gh workflow run deliver-report.yml --repo OWNER/REPO
gh run watch --repo OWNER/REPO
```

A green run means the role, the variables, and the bucket permissions all line up. The first dated folder appears in the repository within a minute, and the delivery email follows if a topic is set.

If the credentials step fails, the role's trust policy did not match the token. The lab README's troubleshooting section covers the `sub` claim and how to print it.

## What the workflow can and cannot do

The role it assumes can list and read objects under this customer's prefix in the report bucket, decrypt them with the report key, and publish to the two notification topics. It cannot read other customers' prefixes, write to the bucket, call Inspector, or publish anywhere else. If the token or role were ever misused, the worst outcome is a copy of reports the team already receives and a spurious email.

## Changing the customer

The folder name comes from the last segment of `REPORT_PREFIX`. Change the variable and the next run files reports under the new name. Earlier folders stay where they are.
