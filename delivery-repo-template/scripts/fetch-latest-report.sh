#!/usr/bin/env bash
# Downloads the newest Inspector findings reports for one customer from the
# staging bucket and files them under <customer>-inspector-scans/<report date>/.
#
# The lab exports two reports on the same schedule, one CSV and one JSON, so
# this script looks for the newest object of each format separately. Both land
# in the same dated folder, named after the Inspector report ID they came from:
#
#   team-a-inspector-scans/
#   └── 2026-11-10/
#       ├── findings-0f3a9c2e-....csv
#       ├── findings-7b41d8e0-....json
#       └── SOURCE.txt
#
# Delivered object keys are recorded in <customer>-inspector-scans/.delivered.
# A key already listed there is skipped, so a scheduled run with nothing new
# changes no files and the workflow makes no commit.
#
# Required environment variables:
#   REPORT_BUCKET  Bucket that holds the exports (the lab's report_bucket output)
#   REPORT_PREFIX  Customer folder inside the bucket, for example exports/team-a/
#                  The last path segment names the customer.
# Credentials come from the OIDC role the workflow assumed.

set -euo pipefail

: "${REPORT_BUCKET:?Set the REPORT_BUCKET variable}"
: "${REPORT_PREFIX:?Set the REPORT_PREFIX variable}"

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: the AWS CLI is not installed on this runner." >&2
  exit 1
fi

# Normalize the prefix to exactly one trailing slash, then take the last
# segment as the customer name. exports/team-a/ becomes team-a.
PREFIX="${REPORT_PREFIX%/}/"
CUSTOMER="$(basename "${PREFIX%/}")"

if [ -z "$CUSTOMER" ] || [ "$CUSTOMER" = "." ] || [ "$CUSTOMER" = "/" ]; then
  echo "Error: could not read a customer name from REPORT_PREFIX='${REPORT_PREFIX}'." >&2
  exit 1
fi

SCAN_DIR="${CUSTOMER}-inspector-scans"
STATE_FILE="${SCAN_DIR}/.delivered"

mkdir -p "$SCAN_DIR"
touch "$STATE_FILE"

delivered=0

for EXT in csv json; do
  # Newest object with this extension under the prefix. The CLI pages through
  # the listing on its own, and JMESPath filters and sorts the merged result.
  # Output is "KEY<tab>LASTMODIFIED", or "None" when nothing matches.
  RESULT="$(aws s3api list-objects-v2 \
    --bucket "$REPORT_BUCKET" --prefix "$PREFIX" \
    --query "sort_by(Contents[?ends_with(Key, '.${EXT}')], &LastModified)[-1].[Key, LastModified]" \
    --output text 2>/dev/null || true)"

  if [ -z "$RESULT" ] || [ "$RESULT" = "None" ]; then
    echo "No .${EXT} report found under s3://${REPORT_BUCKET}/${PREFIX} yet."
    continue
  fi

  KEY="$(cut -f1 <<<"$RESULT")"
  MODIFIED="$(cut -f2 <<<"$RESULT")"

  if grep -qxF "$KEY" "$STATE_FILE"; then
    echo "Newest .${EXT} report already delivered: $(basename "$KEY")"
    continue
  fi

  # LastModified is ISO 8601 in UTC, so the first ten characters are the date
  # the report was generated. Inspector names the object after the report ID.
  REPORT_DATE="${MODIFIED:0:10}"
  REPORT_ID="$(basename "$KEY" ".${EXT}")"
  DEST_DIR="${SCAN_DIR}/${REPORT_DATE}"
  DEST_FILE="${DEST_DIR}/findings-${REPORT_ID}.${EXT}"

  mkdir -p "$DEST_DIR"
  aws s3 cp "s3://${REPORT_BUCKET}/${KEY}" "$DEST_FILE" --only-show-errors

  {
    echo "File:       $(basename "$DEST_FILE")"
    echo "Report ID:  ${REPORT_ID}"
    echo "Generated:  ${MODIFIED}"
    echo "Source:     s3://${REPORT_BUCKET}/${KEY}"
    echo
  } >> "${DEST_DIR}/SOURCE.txt"

  echo "$KEY" >> "$STATE_FILE"
  delivered=$((delivered + 1))
  echo "Delivered ${DEST_FILE}"
done

if [ "$delivered" -eq 0 ]; then
  echo "Nothing new to deliver."
fi
