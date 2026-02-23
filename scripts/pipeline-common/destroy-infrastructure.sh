#!/bin/bash
set -euo pipefail

# Shared script for destroying main infrastructure
# Usage: ./destroy-infrastructure.sh <cluster-type>
#   cluster-type: "regional-cluster" or "management-cluster"

CLUSTER_TYPE="${1:-}"

if [ -z "$CLUSTER_TYPE" ]; then
    echo "Usage: $0 <cluster-type>"
    echo "  cluster-type: regional-cluster or management-cluster"
    exit 1
fi

if [ "$CLUSTER_TYPE" = "regional-cluster" ]; then
    CLUSTER_NAME="Regional Cluster"
elif [ "$CLUSTER_TYPE" = "management-cluster" ]; then
    CLUSTER_NAME="Management Cluster"
else
    echo "❌ ERROR: Unknown cluster type: $CLUSTER_TYPE"
    exit 1
fi

echo "=========================================="
echo "Destroying ${CLUSTER_NAME} Infrastructure"
echo "=========================================="

echo "Destroying infrastructure for: ${TARGET_ALIAS} (${TARGET_ACCOUNT_ID}) in ${TARGET_REGION}"
echo ""

# Configure Terraform backend (same as apply)
export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
export TF_STATE_KEY="${CLUSTER_TYPE}/${TARGET_ALIAS}.tfstate"

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET (central account: $CENTRAL_ACCOUNT_ID)"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Set Terraform variables (same as apply)
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"

_REPO_URL="${REPOSITORY_URL:-}"
_REPO_BRANCH="${REPOSITORY_BRANCH:-}"
export TF_VAR_repository_url="${CODEBUILD_SOURCE_REPO_URL:-$_REPO_URL}"
export TF_VAR_repository_branch="${CODEBUILD_SOURCE_VERSION:-$_REPO_BRANCH}"

# Regional cluster specific variable
if [ "$CLUSTER_TYPE" = "regional-cluster" ]; then
    export TF_VAR_api_additional_allowed_accounts="${TARGET_ACCOUNT_ID}"
fi

# Navigate to terraform directory
cd "terraform/config/${CLUSTER_TYPE}"

# Initialize Terraform with backend configuration
echo "Initializing Terraform..."
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="region=${TF_STATE_REGION}" \
  -reconfigure

# Run terraform destroy
echo ""
echo "Running terraform destroy -auto-approve..."
terraform destroy -auto-approve

echo ""
echo "✅ Infrastructure destroyed successfully."
