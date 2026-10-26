#!/usr/bin/env bash
# Exports Inspector findings for the lab's ECR repositories to the S3 bucket
# that Terraform created, then waits for the report to finish.
#
# Requirements: AWS CLI v2 and credentials for the lab account.
# Terraform is not needed. The bucket and key are found by their lab names.
#
# Optional overrides (environment variables):
#   AWS_REGION     Region you deployed to. Default: us-east-1
#   PROJECT_NAME   Must match var.project_name in Terraform. Default: inspector-lab
#   REPORT_FORMAT  CSV or JSON. Default: CSV
#   REPORT_PREFIX  Folder inside the bucket for the report. Default: exports

set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-inspector-lab}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
REPORT_FORMAT="${REPORT_FORMAT:-CSV}"
REPORT_PREFIX="${REPORT_PREFIX:-exports}"

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: the AWS CLI is not installed or not on your PATH." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# In GitHub Actions the log is public on a public repo. Tell the runner to
# mask the account ID so it prints as *** everywhere it appears (bucket name,
# KMS key ARN, registry URL).
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::add-mask::${ACCOUNT_ID}"
fi
BUCKET="${PROJECT_NAME}-reports-${ACCOUNT_ID}-${AWS_REGION}"
KMS_ARN="$(aws kms describe-key --region "$AWS_REGION" \
  --key-id "alias/${PROJECT_NAME}-report" \
  --query KeyMetadata.Arn --output text)"

# Only active findings on the lab's repositories. Without a filter, Inspector
# exports every finding in the account.
FILTER="{\"ecrImageRepositoryName\":[{\"comparison\":\"PREFIX\",\"value\":\"${PROJECT_NAME}/\"}],\"findingStatus\":[{\"comparison\":\"EQUALS\",\"value\":\"ACTIVE\"}]}"

echo "Bucket:  s3://${BUCKET}/${REPORT_PREFIX}/"
echo "Key:     ${KMS_ARN}"
echo "Format:  ${REPORT_FORMAT}"

REPORT_ID="$(aws inspector2 create-findings-report \
  --region "$AWS_REGION" \
  --report-format "$REPORT_FORMAT" \
  --s3-destination "bucketName=${BUCKET},keyPrefix=${REPORT_PREFIX},kmsKeyArn=${KMS_ARN}" \
  --filter-criteria "$FILTER" \
  --query reportId --output text)"

echo "Report requested: ${REPORT_ID}"

# Large reports can take a few minutes. Check every 10 seconds for up to 5 minutes.
for _ in $(seq 1 30); do
  STATUS="$(aws inspector2 get-findings-report-status \
    --region "$AWS_REGION" --report-id "$REPORT_ID" \
    --query status --output text)"

  case "$STATUS" in
    SUCCEEDED)
      echo
      echo "Export complete. The file name starts with ${REPORT_ID}."
      echo "Look in s3://${BUCKET}/${REPORT_PREFIX}/ or run:"
      echo "  aws s3 ls s3://${BUCKET}/${REPORT_PREFIX}/"
      exit 0
      ;;
    FAILED|CANCELLED)
      echo "Export ${STATUS}." >&2
      aws inspector2 get-findings-report-status \
        --region "$AWS_REGION" --report-id "$REPORT_ID" \
        --query errorMessage --output text >&2 || true
      exit 1
      ;;
    *)
      echo "Status: ${STATUS}. Waiting..."
      sleep 10
      ;;
  esac
done

echo "Timed out waiting for report ${REPORT_ID}. Check the Inspector console for its status." >&2
exit 1
