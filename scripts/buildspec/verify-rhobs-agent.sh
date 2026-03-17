#!/usr/bin/env bash
# Verify RHOBS agents (OTEL Collector, Fluent Bit) on management cluster
# Called from: terraform/config/pipeline-management-cluster/buildspec-verify-rhobs-agent.yml
set -euo pipefail

echo "=========================================="
echo "RHOBS Agent Verification"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config
ENVIRONMENT="${ENVIRONMENT:-staging}"

# Extract serial from management cluster ID (e.g., management-us-east-1-01 -> 01)
MANAGEMENT_CLUSTER_SERIAL=$(echo "${MANAGEMENT_CLUSTER_ID}" | grep -oE '[0-9]+$')

MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management-${MANAGEMENT_CLUSTER_SERIAL}.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$MC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Cluster is being destroyed - skipping RHOBS agent verification"
    exit 0
fi

# Assume target account role
use_mc_account
echo ""

echo "Verifying RHOBS agents: ${MANAGEMENT_CLUSTER_ID} in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend
./scripts/pipeline-common/init-terraform-backend.sh management-cluster "${TARGET_REGION}" "${MANAGEMENT_CLUSTER_ID}"

# Set environment variables for the verification wrapper
export ENVIRONMENT="${ENVIRONMENT}"
export TARGET_REGION="${TARGET_REGION}"
export MANAGEMENT_CLUSTER_ID="${MANAGEMENT_CLUSTER_ID}"

# Run verification via ECS Fargate task (cluster is fully private)
./scripts/verify-rhobs-agent-wrapper.sh
