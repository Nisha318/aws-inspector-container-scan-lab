#!/usr/bin/env bash
# Downloads the newest Inspector findings report for this customer from S3 and
# files it under reports/<report date>/. Skips quietly when the newest report
# has already been delivered, so scheduled runs never create duplicate commits.
#
# Required environment variables:
#   REPORT_BUCKET  Bucket that holds the exports (the lab's report_bucket output)
#   REPORT_PREFIX  Customer folder inside the bucket, for example exports/team-a/
# Credentials come from the OIDC role the workflow assumed.

set -euo pipefail

: "${REPORT_BUCKET:?Set the REPORT_BUCKET variable}"
: "${REPORT_PREFIX:?Set the REPORT_PREFIX variable}"

PREFIX="${REPORT_PREFIX%/}/"
STATE_FILE="reports/.last-source-key"

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: the AWS CLI is not installed on this runner." >&2
  exit 1
fi

# Newest object under the prefix. A null result means no report exists yet.
KEY="$(aws s3api list-objects-v2 \
  --bucket "$REPORT_BUCKET" --prefix "$PREFIX" \
  --query 'sort_by(Contents, &LastModified)[-1].Key' --output text 2>/dev/null || true)"

if [ -z "$KEY" ] || [ "$KEY" = "None" ]; then
  echo "No reports found under s3://${REPORT_BUCKET}/${PREFIX} yet. Nothing to deliver."
  exit 0
fi

mkdir -p reports

if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$KEY" ]; then
  echo "The newest report has already been delivered. Nothing to do."
  exit 0
fi

MODIFIED="$(aws s3api head-object --bucket "$REPORT_BUCKET" --key "$KEY" \
  --query LastModified --output text)"
REPORT_DATE="${MODIFIED:0:10}"
EXTENSION="${KEY##*.}"
DEST_DIR="reports/${REPORT_DATE}"

mkdir -p "$DEST_DIR"
aws s3 cp "s3://${REPORT_BUCKET}/${KEY}" "${DEST_DIR}/findings.${EXTENSION}" --only-show-errors

{
  echo "Report file:  $(basename "$KEY")"
  echo "Generated:    ${MODIFIED}"
} > "${DEST_DIR}/SOURCE.txt"

echo "$KEY" > "$STATE_FILE"
echo "Delivered ${DEST_DIR}/findings.${EXTENSION}"
