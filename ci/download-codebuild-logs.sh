#!/bin/bash
# Download CloudWatch logs for all CodeBuild projects matching a CI prefix.
# Usage: ./ci/download-codebuild-logs.sh <ci-prefix> [region]
# Example: ./ci/download-codebuild-logs.sh ci-202982

set -euo pipefail

CI_PREFIX="${1:?Usage: $0 <ci-prefix> [region]}"
REGION="${2:-us-east-1}"
OUT_DIR="codebuild-logs-${CI_PREFIX}"

mkdir -p "$OUT_DIR"

# Portable in-place sed: macOS requires -i '', GNU sed requires -i
sed_inplace() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

echo "Searching for log groups matching /aws/codebuild/${CI_PREFIX}-* in ${REGION}..."

LOG_GROUPS=$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/codebuild/${CI_PREFIX}-" \
  --region "$REGION" \
  --query 'logGroups[].logGroupName' \
  --output text)

if [[ -z "$LOG_GROUPS" ]]; then
  echo "No log groups found."
  exit 0
fi

for LOG_GROUP in $LOG_GROUPS; do
  PROJECT_NAME="${LOG_GROUP##*/}"
  echo "Downloading ${LOG_GROUP}..."

  STREAMS_JSON=$(aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP" \
    --region "$REGION" \
    --order-by LastEventTime \
    --descending \
    --query 'logStreams[].{name:logStreamName, ts:firstEventTimestamp}' \
    --output json)

  TOTAL=$(echo "$STREAMS_JSON" | jq 'length')
  if [[ "$TOTAL" -eq 0 ]]; then
    echo "  (no log streams)"
    continue
  fi

  # Iterate in reverse (oldest first) for chronological filenames.
  for (( i = TOTAL - 1; i >= 0; i-- )); do
    STREAM=$(echo "$STREAMS_JSON" | jq -r ".[$i].name")
    TS_MS=$(echo "$STREAMS_JSON" | jq -r ".[$i].ts // empty")

    if [[ -n "$TS_MS" ]]; then
      # Convert epoch millis to human-readable timestamp
      TS_SEC=$(( TS_MS / 1000 ))
      TS_LABEL=$(date -u -r "$TS_SEC" '+%Y%m%d-%H%M%S' 2>/dev/null \
        || date -u -d "@$TS_SEC" '+%Y%m%d-%H%M%S' 2>/dev/null \
        || echo "unknown")
    else
      TS_LABEL="unknown"
    fi

    SAFE_NAME="${PROJECT_NAME}.${TS_LABEL}.log"

    echo "  ${STREAM} -> ${OUT_DIR}/${SAFE_NAME}"

    aws logs get-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name "$STREAM" \
      --region "$REGION" \
      --start-from-head \
      --query 'events[].message' \
      --output text > "${OUT_DIR}/${SAFE_NAME}"

    # Strip ANSI color codes
    sed_inplace 's/\x1b\[[0-9;]*m//g' "${OUT_DIR}/${SAFE_NAME}"

    LINES=$(wc -l < "${OUT_DIR}/${SAFE_NAME}")
    echo "    ${LINES} lines"
  done
done

echo ""
echo "Logs saved to ${OUT_DIR}/"
ls -la "${OUT_DIR}/"
