# Inspector findings delivery

This repository receives Amazon Inspector container scan reports for one customer, on a schedule, without anyone logging into AWS. A GitHub Actions workflow assumes a read-only AWS role, downloads the newest reports from a staging bucket, and commits them here.

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

A new folder appears each time the export runs. If the export and the delivery job ever fall on opposite sides of midnight UTC, a folder can hold a single file and the next folder its pair. `SOURCE.txt` records the report ID and generation time for each file, so the pairing is always recoverable.

## For the team that runs it

Everything below is done once, by whoever manages the AWS account and this repository. The readers never touch it.

### 1. Turn on the delivery role in the lab account

In the lab's `terraform.tfvars`, set `delivery_repo` to this repository in `ORG/REPO` form, then apply:

```hcl
delivery_repo = "my-org/team-a-inspector-findings"
```

If this repository was created on github.com after July 15, 2026, its OIDC subject uses the immutable form. Print the real `sub` with the troubleshooting step in the lab README and set `delivery_subject_override` to match. On GitHub Enterprise Server, also set `delivery_oidc_url` to `https://YOUR-GHES-HOST/_services/token`. The OIDC provider for that URL must already exist in the account.

Read these outputs when the apply finishes:

| Output | Becomes repository variable |
| --- | --- |
| `delivery_role_arn` | `AWS_ROLE_ARN` |
| `aws_region` | `AWS_REGION` |
| `report_bucket` | `REPORT_BUCKET` |
| `scheduled_export_prefix`, the path part after the bucket | `REPORT_PREFIX`, for example `exports/team-a/` |

### 2. Create this repository

Copy the contents of `delivery-repo-template/` from the lab into a new private repository. Keep the paths: `.github/workflows/deliver-report.yml` and `scripts/fetch-latest-report.sh`. Replace this README with one that names the customer.

Do not protect the `main` branch. The workflow pushes to it directly with the run's own `GITHUB_TOKEN`, which `permissions: contents: write` in the workflow allows. No personal access token or deploy key is involved.

### 3. Set the four repository variables

Under **Settings**, **Secrets and variables**, **Actions**, **Variables**, add the four variables from the table above at repository level, not under an environment. None of them is a secret. The bucket name contains the AWS account ID, and the workflow masks it in logs.

### 4. Set the schedule

Edit the `cron` line in `deliver-report.yml`. GitHub cron is UTC. Run it at least an hour after the export schedule in Terraform so Inspector has finished writing both files. A run that finds nothing new makes no commit, so checking more often than the export runs costs nothing.

### 5. Run it once by hand

Open **Actions**, select **Deliver Inspector findings reports**, and choose **Run workflow**. A green run means the role, the variables, and the bucket permissions all line up. The first dated folder appears in the repository within a minute.

If the credentials step fails, the role's trust policy did not match the token. The lab README's troubleshooting section covers the `sub` claim and how to print it.

## What the workflow can and cannot do

The role it assumes can list and read objects under this customer's prefix in the report bucket, and decrypt them with the report key. It cannot read other customers' prefixes, write to the bucket, or call Inspector. If the token or role were ever misused, the worst outcome is a copy of reports the team already receives.

## Changing the customer

The folder name comes from the last segment of `REPORT_PREFIX`. Change the variable and the next run files reports under the new name. Earlier folders stay where they are.
