#!/bin/bash
set -euo pipefail

# Shared script for conditional destroy logic
# Usage: ./conditional-destroy.sh <cluster-type> <pipeline-type>
#   cluster-type: "regional-cluster" or "management-cluster"
#   pipeline-type: "pipeline-regional-cluster" or "pipeline-management-cluster"

CLUSTER_TYPE="${1:-}"
PIPELINE_TYPE="${2:-}"

if [ -z "$CLUSTER_TYPE" ] || [ -z "$PIPELINE_TYPE" ]; then
    echo "Usage: $0 <cluster-type> <pipeline-type>"
    echo "  cluster-type: regional-cluster or management-cluster"
    echo "  pipeline-type: pipeline-regional-cluster or pipeline-management-cluster"
    exit 1
fi

echo "=========================================="
echo "Checking delete flag..."
echo "=========================================="

# Determine config file path based on cluster type
ENVIRONMENT="${ENVIRONMENT:-staging}"
if [ "$CLUSTER_TYPE" = "regional-cluster" ]; then
    CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
elif [ "$CLUSTER_TYPE" = "management-cluster" ]; then
    CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management/${TARGET_ALIAS}.json"
else
    echo "❌ ERROR: Unknown cluster type: $CLUSTER_TYPE"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ ERROR: Config file not found: $CONFIG_FILE"
    echo "   Cannot determine delete flag. Exiting."
    exit 1
fi

# Check if delete flag is set to true
DELETE_FLAG=$(jq -r '.delete // false' "$CONFIG_FILE")
echo "Delete flag value: $DELETE_FLAG"

if [ "$DELETE_FLAG" != "true" ]; then
    echo "ℹ️  Delete flag is not true - skipping destroy."
    echo "   To destroy infrastructure, set 'delete': true in $CONFIG_FILE"
    exit 0
fi

echo "⚠️  DELETE FLAG IS TRUE - Will proceed with destroy..."
echo ""

# Return success - caller should proceed with destroy
exit 0
