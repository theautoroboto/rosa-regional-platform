#!/bin/bash
set -euo pipefail

# Shared script for destroying pipeline infrastructure
# Usage: ./destroy-pipeline.sh <cluster-type> <pipeline-type>
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
echo "Destroying Pipeline Infrastructure"
echo "=========================================="

# Only destroy pipeline if we actually destroyed infrastructure
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
    echo "Config file not found - skipping pipeline destroy"
    exit 0
fi

DELETE_FLAG=$(jq -r '.delete // false' "$CONFIG_FILE")

if [ "$DELETE_FLAG" != "true" ]; then
    echo "Delete flag was not true - skipping pipeline destroy"
    exit 0
fi

echo "⚠️  Destroying pipeline infrastructure for ${TARGET_ALIAS}..."
echo ""

# Navigate to pipeline terraform directory
cd "terraform/config/${PIPELINE_TYPE}"

# Configure backend for pipeline state
export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
export TF_STATE_KEY="${PIPELINE_TYPE}/${TARGET_ALIAS}.tfstate"

echo "Pipeline Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET"
echo "  Key: $TF_STATE_KEY"
echo "  Region: $TF_STATE_REGION"
echo ""

# Set Terraform variables for pipeline destroy
# Note: github_connection_arn will be read from state during destroy
export TF_VAR_github_repo_owner="${GITHUB_REPO_OWNER}"
export TF_VAR_github_repo_name="${GITHUB_REPO_NAME}"
export TF_VAR_github_branch="${GITHUB_BRANCH}"
export TF_VAR_region="${TF_STATE_REGION}"
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_region="${TARGET_REGION}"
export TF_VAR_target_alias="${TARGET_ALIAS}"
export TF_VAR_target_environment="${ENVIRONMENT}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${REPOSITORY_BRANCH}"

# Get github_connection_arn from AWS
# It should be the only connection, or we can filter by name
GITHUB_CONNECTION_ARN=$(aws codestar-connections list-connections --region ${TF_STATE_REGION} --query 'Connections[?ConnectionStatus==`AVAILABLE`].ConnectionArn | [0]' --output text)
if [ -z "$GITHUB_CONNECTION_ARN" ] || [ "$GITHUB_CONNECTION_ARN" = "None" ]; then
    echo "⚠️  Warning: Could not find GitHub connection. Terraform will use value from state."
    export TF_VAR_github_connection_arn="dummy-value-will-use-state"
else
    echo "Found GitHub connection: $GITHUB_CONNECTION_ARN"
    export TF_VAR_github_connection_arn="$GITHUB_CONNECTION_ARN"
fi

# Initialize Terraform
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="region=${TF_STATE_REGION}" \
  -reconfigure

# Destroy pipeline infrastructure
echo "Running terraform destroy on pipeline infrastructure..."
terraform destroy -auto-approve

echo ""
echo "✅ Pipeline infrastructure destroyed successfully."
echo "   The following resources have been removed:"
echo "   - CodePipeline: ${TARGET_ALIAS}"
echo "   - CodeBuild projects (validate, apply, bootstrap, destroy)"
echo "   - IAM roles and policies"
echo "   - S3 artifact bucket"
