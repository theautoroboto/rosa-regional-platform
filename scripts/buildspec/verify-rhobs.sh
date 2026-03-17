#!/usr/bin/env bash
# Verify RHOBS metrics and logs flow from management clusters
# Called from: terraform/config/pipeline-regional-cluster/buildspec-verify-rhobs.yml
set -euo pipefail

echo "=========================================="
echo "RHOBS Verification"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config
ENVIRONMENT="${ENVIRONMENT:-staging}"
RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $RC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$RC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Cluster is being destroyed - skipping RHOBS verification"
    exit 0
fi

# Assume target account role
use_mc_account
echo ""

echo "Verifying RHOBS deployment: ${REGIONAL_ID} in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend to get outputs
./scripts/pipeline-common/init-terraform-backend.sh regional-cluster "${TARGET_REGION}" "${REGIONAL_ID}"

# Set environment variables for the verification wrapper
export ENVIRONMENT="${ENVIRONMENT}"
export TARGET_REGION="${TARGET_REGION}"
export REGIONAL_ID="${REGIONAL_ID}"

# Run verification via ECS Fargate task (cluster is fully private)
./scripts/verify-rhobs-wrapper.sh
