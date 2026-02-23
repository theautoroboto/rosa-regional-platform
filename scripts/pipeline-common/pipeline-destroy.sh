#!/usr/bin/env bash
#
# pipeline-destroy.sh - Execute conditional infrastructure destruction
#
# Usage: ./scripts/pipeline-common/pipeline-destroy.sh <cluster-type>
#   cluster-type: "regional" or "management"
#
# This script:
# 1. Checks if the relevant config file exists and has "delete": true
# 2. Configures Terraform backend state for the cluster
# 3. Sets necessary Terraform variables
# 4. Executes the corresponding Makefile target for cluster destruction
# 5. Configures Terraform backend state for the pipeline
# 6. Executes terraform destroy for the pipeline itself

set -euo pipefail

CLUSTER_TYPE=${1:-}
if [[ -z "$CLUSTER_TYPE" ]]; then
    echo "Usage: $0 <regional|management>"
    exit 1
fi

export ENVIRONMENT="${ENVIRONMENT:-staging}"

# Validate required environment variables
echo "Validating required environment variables..."
MISSING_VARS=()

# Required variables
[[ -z "${TARGET_REGION:-}" ]] && MISSING_VARS+=("TARGET_REGION")
[[ -z "${TARGET_ALIAS:-}" ]] && MISSING_VARS+=("TARGET_ALIAS")
[[ -z "${TARGET_ACCOUNT_ID:-}" ]] && MISSING_VARS+=("TARGET_ACCOUNT_ID")
[[ -z "${APP_CODE:-}" ]] && MISSING_VARS+=("APP_CODE")
[[ -z "${SERVICE_PHASE:-}" ]] && MISSING_VARS+=("SERVICE_PHASE")
[[ -z "${COST_CENTER:-}" ]] && MISSING_VARS+=("COST_CENTER")
[[ -z "${GITHUB_REPO_OWNER:-}" ]] && MISSING_VARS+=("GITHUB_REPO_OWNER")
[[ -z "${GITHUB_REPO_NAME:-}" ]] && MISSING_VARS+=("GITHUB_REPO_NAME")
[[ -z "${GITHUB_BRANCH:-}" ]] && MISSING_VARS+=("GITHUB_BRANCH")

# Cluster-type specific validation (REGIONAL_AWS_ACCOUNT_ID for management)
# will be checked later after CLUSTER_TYPE is determined

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing required environment variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "   - $var"
    done
    exit 1
fi

echo "✓ All required environment variables are set"
echo ""

# Determine paths and targets based on cluster type
if [ "$CLUSTER_TYPE" == "regional" ]; then
    CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
    MAKE_TARGET="pipeline-destroy-regional"
    TF_STATE_KEY="regional-cluster/${TARGET_ALIAS}.tfstate"
elif [ "$CLUSTER_TYPE" == "management" ]; then
    CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management/${TARGET_ALIAS}.json"
    MAKE_TARGET="pipeline-destroy-management"
    TF_STATE_KEY="management-cluster/${TARGET_ALIAS}.tfstate"
else
    echo "❌ Unknown cluster type: $CLUSTER_TYPE. Must be 'regional' or 'management'."
    exit 1
fi

echo "=========================================="
echo "Checking for Destroy Signal ($CLUSTER_TYPE)"
echo "=========================================="
echo "Config file: $CONFIG_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "Skipping destroy."
    exit 0
fi

DELETE_FLAG=$(jq -r '.delete // false' "$CONFIG_FILE")
echo "Delete flag: $DELETE_FLAG"

if [ "$DELETE_FLAG" != "true" ]; then
    echo "Skipping destroy as 'delete' is not set to true."
    exit 0
fi

echo "⚠️  'delete' is set to true. Proceeding with destruction..."
echo ""

# Configure Terraform backend
# Note: CENTRAL_ACCOUNT_ID is exported by setup-apply-preflight.sh (via buildspec env)
if [[ -z "${CENTRAL_ACCOUNT_ID:-}" ]]; then
    echo "❌ Error: CENTRAL_ACCOUNT_ID is not set."
    exit 1
fi

export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
# Save cluster state key for potential verification
CLUSTER_STATE_KEY="$TF_STATE_KEY"
export TF_STATE_KEY

echo "Terraform backend:"
echo "  Bucket: $TF_STATE_BUCKET"
echo "  Key: $TF_STATE_KEY"
echo "  Region: ${TF_STATE_REGION:-us-east-1}"
echo ""

# Set common Terraform variables
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"

_REPO_URL="${REPOSITORY_URL:-}"
_REPO_BRANCH="${REPOSITORY_BRANCH:-}"
export TF_VAR_repository_url="${CODEBUILD_SOURCE_REPO_URL:-$_REPO_URL}"
export TF_VAR_repository_branch="${CODEBUILD_SOURCE_VERSION:-$_REPO_BRANCH}"

# Set specific variables and handle pre-destroy setup
if [ "$CLUSTER_TYPE" == "regional" ]; then
    export TF_VAR_api_additional_allowed_accounts="${TARGET_ACCOUNT_ID}"
    
    # Regional pipeline uses Terraform provider assume_role for cross-account access
    # Current credentials (CodeBuild role) are sufficient to access the backend in Central account.
    
elif [ "$CLUSTER_TYPE" == "management" ]; then
    export TF_VAR_cluster_id="${CLUSTER_ID:-mgmt-cluster-01}"
    export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
    
    # Resolve Regional Account ID (SSM check)
    RESOLVED_REGIONAL_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"
    if [[ "$RESOLVED_REGIONAL_ACCOUNT_ID" =~ ^ssm:/ ]]; then
        SSM_PARAM_NAME="${RESOLVED_REGIONAL_ACCOUNT_ID#ssm:}"
        echo "Resolving SSM parameter: $SSM_PARAM_NAME in region ${TARGET_REGION}"

        # Using current credentials (assumed target role)
        RESOLVED_REGIONAL_ACCOUNT_ID=$(aws ssm get-parameter \
            --name "$SSM_PARAM_NAME" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${TARGET_REGION}")
            
        echo "✓ Resolved regional account ID"
    fi
    
    if [[ -z "$RESOLVED_REGIONAL_ACCOUNT_ID" ]]; then
        echo "❌ ERROR: REGIONAL_AWS_ACCOUNT_ID is empty or could not be resolved."
        exit 1
    fi
    export TF_VAR_regional_aws_account_id="${RESOLVED_REGIONAL_ACCOUNT_ID}"
    
    # Restore central account credentials for Terraform backend access
    echo "Restoring central account credentials for Terraform backend access..."
    if [[ -z "${CENTRAL_AWS_ACCESS_KEY_ID:-}" ]]; then
        echo "❌ Error: CENTRAL_AWS_ACCESS_KEY_ID not saved. Cannot restore backend access."
        exit 1
    fi
    
    export AWS_ACCESS_KEY_ID="${CENTRAL_AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${CENTRAL_AWS_SECRET_ACCESS_KEY}"
    export AWS_SESSION_TOKEN="${CENTRAL_AWS_SESSION_TOKEN}"
    
    # Verify restoration
    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    echo "Restored identity account: $CURRENT_ACCOUNT (should be Central: $CENTRAL_ACCOUNT_ID)"
fi

echo "Running make target: $MAKE_TARGET"
echo ""

# Execute the make target to destroy cluster infrastructure
make "$MAKE_TARGET"

echo ""
echo "✅ $CLUSTER_TYPE cluster infrastructure destroyed successfully."
echo ""

# ==============================================================================
# Phase 2: Destroy Pipeline Infrastructure (Self-Destruct)
# ==============================================================================
echo "=========================================="
echo "Initiating Pipeline Self-Destruction"
echo "=========================================="
echo "⚠️  This step will destroy the pipeline resources (CodePipeline, CodeBuild)."
echo "   The build execution will terminate abruptly once resources are deleted."
echo ""

# Determine Pipeline Config Directory and State Key
if [ "$CLUSTER_TYPE" == "regional" ]; then
    PIPELINE_CONFIG_DIR="terraform/config/pipeline-regional-cluster"
    # Note: pipeline-provisioner uses directory name as REGION_ALIAS.
    # We assume directory name matches TARGET_REGION (e.g., us-east-1).
    PIPELINE_STATE_KEY="pipelines/regional-${ENVIRONMENT}-${TARGET_REGION}.tfstate"
    
elif [ "$CLUSTER_TYPE" == "management" ]; then
    PIPELINE_CONFIG_DIR="terraform/config/pipeline-management-cluster"
    # Note: pipeline-provisioner uses management-${ENVIRONMENT}-${REGION_ALIAS}-${CLUSTER_NAME}.tfstate
    # We assume TARGET_ALIAS matches CLUSTER_NAME (from filename).
    PIPELINE_STATE_KEY="pipelines/management-${ENVIRONMENT}-${TARGET_REGION}-${TARGET_ALIAS}.tfstate"
fi

echo "Pipeline Config Dir: $PIPELINE_CONFIG_DIR"
echo "Pipeline State Key: $PIPELINE_STATE_KEY"

if [ ! -d "$PIPELINE_CONFIG_DIR" ]; then
    echo "❌ Error: Pipeline config directory not found: $PIPELINE_CONFIG_DIR"
    exit 1
fi

cd "$PIPELINE_CONFIG_DIR"

# Initialize Terraform for Pipeline State
echo "Initializing Terraform for pipeline destruction..."
# Note: Using -reconfigure because we are switching state from cluster to pipeline
terraform init \
    -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=$PIPELINE_STATE_KEY" \
    -backend-config="region=${TF_STATE_REGION:-us-east-1}" \
    -backend-config="use_lockfile=true"

# Construct TF_VARS for pipeline destroy
# We reuse variables exported earlier, but format them for command line if needed
# Actually, we can export TF_VAR_... environment variables, which Terraform picks up automatically.
# But some variable names in main.tf might differ from env vars.
# Let's map them explicitly or use -var arguments.

# Common variables required by pipeline main.tf:
# github_repo_owner, github_repo_name, github_branch, github_connection_arn
# region (target region)
# target_account_id, target_region, target_alias
# app_code, service_phase, cost_center
# repository_url, repository_branch

# Check for GITHUB_CONNECTION_ARN
if [[ -z "${GITHUB_CONNECTION_ARN:-}" ]]; then
    echo "⚠️  Warning: GITHUB_CONNECTION_ARN is not set. Pipeline destroy might fail if Terraform requires it."
    # We proceed anyway; maybe it's in tfvars or defaults (unlikely for ARN).
fi

# Export variables as TF_VARs where names match
export TF_VAR_github_repo_owner="${GITHUB_REPO_OWNER}"
export TF_VAR_github_repo_name="${GITHUB_REPO_NAME}"
export TF_VAR_github_branch="${GITHUB_BRANCH}"
export TF_VAR_github_connection_arn="${GITHUB_CONNECTION_ARN:-}"
# TF_VAR_region is already set to TARGET_REGION above
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_region="${TARGET_REGION}"
export TF_VAR_target_alias="${TARGET_ALIAS}"
# TF_VAR_app_code, TF_VAR_service_phase, TF_VAR_cost_center already set
export TF_VAR_target_environment="${ENVIRONMENT}"
# TF_VAR_repository_url, TF_VAR_repository_branch already set

# Specific variables
if [ "$CLUSTER_TYPE" == "management" ]; then
    # TF_VAR_cluster_id already set
    # TF_VAR_regional_aws_account_id already set
    :
fi

echo "Running terraform destroy for pipeline infrastructure..."
echo "Variables:"
echo "  Region: $TF_VAR_region"
echo "  State Key: $PIPELINE_STATE_KEY"

# Run destroy
# We use 'exec' to replace the shell process, ensuring no lingering script logic tries to run
# after the container might be destabilized (though CodeBuild is external to the shell).
# Actually, just running it is fine.
terraform destroy -auto-approve

echo "✅ Pipeline infrastructure destroyed (if you see this, the self-destruct was surprisingly graceful)."
