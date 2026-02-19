#!/bin/bash
set -euo pipefail

# Provision Regional and Management Cluster Pipelines
# This script processes deploy/ directory structure and creates CodePipeline resources

# Global variables
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
TF_STATE_REGION="us-east-1"

echo "Using state bucket: $TF_STATE_BUCKET"
echo "Using lockfile-based state locking"
echo ""

# Validate and sanitize ENVIRONMENT variable
validate_environment() {
    local env="${1:-}"

    if [[ -z "$env" ]]; then
        echo "❌ ERROR: ENVIRONMENT is empty" >&2
        exit 1
    fi

    if [[ "$env" == *"/"* ]] || [[ "$env" == *".."* ]]; then
        echo "❌ ERROR: ENVIRONMENT contains invalid characters: $env" >&2
        exit 1
    fi

    if [[ "$env" =~ [[:space:]] ]]; then
        echo "❌ ERROR: ENVIRONMENT contains whitespace: $env" >&2
        exit 1
    fi

    if [[ ! "$env" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "❌ ERROR: ENVIRONMENT contains invalid characters: $env" >&2
        echo "   Only alphanumeric, dot (.), underscore (_), and hyphen (-) are allowed" >&2
        exit 1
    fi

    if [ ! -d "deploy/${env}" ]; then
        echo "❌ ERROR: Environment directory does not exist: deploy/${env}" >&2
        echo "   Available environments:" >&2
        ls -d deploy/*/ 2>/dev/null | sed 's|deploy/||g; s|/$||g' | sed 's/^/   - /' >&2 || echo "   (none found)" >&2
        exit 1
    fi

    echo "$env"
}

# Extract configuration from JSON file
extract_json_config() {
    local config_file="$1"

    AWS_REGION=$(jq -r '.region // .target_region // "us-east-1"' "$config_file")
    TARGET_ACCOUNT_ID=$(jq -r '.account_id // ""' "$config_file")
    TARGET_ALIAS=$(jq -r '.alias // ""' "$config_file")
    APP_CODE=$(jq -r '.app_code // "infra"' "$config_file")
    SERVICE_PHASE=$(jq -r '.service_phase // "dev"' "$config_file")
    COST_CENTER=$(jq -r '.cost_center // "000"' "$config_file")
}

# Build Terraform variables string
build_terraform_vars() {
    local cluster_id="${1:-}"
    local regional_account_id="${2:-}"

    local vars="-var=github_repo_owner=${GITHUB_REPO_OWNER}"
    vars="$vars -var=github_repo_name=${GITHUB_REPO_NAME}"
    vars="$vars -var=github_branch=${GITHUB_BRANCH}"
    vars="$vars -var=region=${AWS_REGION}"

    [ -n "$GITHUB_CONNECTION_ARN" ] && vars="$vars -var=github_connection_arn=${GITHUB_CONNECTION_ARN}"
    [ -n "$TARGET_ACCOUNT_ID" ] && vars="$vars -var=target_account_id=${TARGET_ACCOUNT_ID}"
    [ -n "$AWS_REGION" ] && vars="$vars -var=target_region=${AWS_REGION}"
    [ -n "$TARGET_ALIAS" ] && vars="$vars -var=target_alias=${TARGET_ALIAS}"
    [ -n "$APP_CODE" ] && vars="$vars -var=app_code=${APP_CODE}"
    [ -n "$SERVICE_PHASE" ] && vars="$vars -var=service_phase=${SERVICE_PHASE}"
    [ -n "$COST_CENTER" ] && vars="$vars -var=cost_center=${COST_CENTER}"
    [ -n "$cluster_id" ] && vars="$vars -var=cluster_id=${cluster_id}"
    [ -n "$regional_account_id" ] && vars="$vars -var=regional_aws_account_id=${regional_account_id}"

    vars="$vars -var=repository_url=https://github.com/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}.git"
    vars="$vars -var=repository_branch=${GITHUB_BRANCH}"

    echo "$vars"
}

# Retry terraform apply with exponential backoff
retry_terraform_apply() {
    local tf_vars="$1"
    local max_attempts=3
    local attempt=1
    local wait_time=30

    while [ $attempt -le $max_attempts ]; do
        echo "📝 Attempt $attempt/$max_attempts: Running terraform apply..."

        if terraform apply -auto-approve $tf_vars; then
            echo "✅ Terraform apply succeeded"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                echo "⚠️  Attempt $attempt failed, waiting ${wait_time}s before retry..."
                sleep $wait_time
                wait_time=$((wait_time * 2))
                attempt=$((attempt + 1))
            else
                echo "❌ All $max_attempts attempts failed"
                return 1
            fi
        fi
    done
}

# Provision Regional Cluster Pipeline
provision_regional_pipeline() {
    local environment="$1"
    local region_alias="$2"
    local config_file="$3"

    echo "Found regional.json for ${environment}-${region_alias}"

    extract_json_config "$config_file"

    echo "  AWS Region: $AWS_REGION"
    [ -n "$TARGET_ACCOUNT_ID" ] && echo "  Target Account ID: $TARGET_ACCOUNT_ID"
    [ -n "$TARGET_ALIAS" ] && echo "  Target Alias: $TARGET_ALIAS"
    echo "  Terraform Vars: app_code=$APP_CODE, service_phase=$SERVICE_PHASE, cost_center=$COST_CENTER"

    echo "Provisioning Regional Cluster Pipeline for ${environment}-${region_alias}..."

    cd terraform/config/pipeline-regional-cluster

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=pipelines/regional-${environment}-${region_alias}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    local tf_vars
    tf_vars=$(build_terraform_vars)

    if retry_terraform_apply "$tf_vars"; then
        cd ../../..
        echo "✅ Regional pipeline created for ${environment}-${region_alias}"
        return 0
    else
        cd ../../..
        echo "❌ Failed to create regional pipeline for ${environment}-${region_alias} after retries"
        return 1
    fi
}

# Provision Management Cluster Pipeline
provision_management_pipeline() {
    local environment="$1"
    local region_alias="$2"
    local cluster_name="$3"
    local config_file="$4"

    echo "Found management cluster config: $cluster_name"

    extract_json_config "$config_file"

    local cluster_id regional_aws_account_id
    cluster_id=$(jq -r '.cluster_id // ""' "$config_file")
    regional_aws_account_id=$(jq -r '.regional_aws_account_id // ""' "$config_file")

    [ -z "$cluster_id" ] && cluster_id="${TARGET_ALIAS}"
    [ -z "$regional_aws_account_id" ] && regional_aws_account_id="${CENTRAL_ACCOUNT_ID}"

    echo "  AWS Region: $AWS_REGION"
    [ -n "$TARGET_ACCOUNT_ID" ] && echo "  Target Account ID: $TARGET_ACCOUNT_ID"
    [ -n "$TARGET_ALIAS" ] && echo "  Target Alias: $TARGET_ALIAS"
    echo "  Terraform Vars: app_code=$APP_CODE, service_phase=$SERVICE_PHASE, cost_center=$COST_CENTER, cluster_id=$cluster_id, regional_aws_account_id=$regional_aws_account_id"

    echo "Provisioning Management Cluster Pipeline for $cluster_name in ${environment}-${region_alias}..."

    cd terraform/config/pipeline-management-cluster

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=pipelines/management-${environment}-${region_alias}-${cluster_name}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    local tf_vars
    tf_vars=$(build_terraform_vars "$cluster_id" "$regional_aws_account_id")

    if retry_terraform_apply "$tf_vars"; then
        cd ../../..
        echo "✅ Management pipeline created for $cluster_name in ${environment}-${region_alias}"
        return 0
    else
        cd ../../..
        echo "❌ Failed to create management pipeline for $cluster_name after retries"
        return 1
    fi
}

# Main provisioning logic
main() {
    local environment
    environment=$(validate_environment "${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}")

    echo "Processing environment: $environment"
    echo ""

    shopt -s nullglob
    local region_dirs=("deploy/${environment}"/*)
    shopt -u nullglob

    if [ ${#region_dirs[@]} -eq 0 ]; then
        echo "❌ ERROR: No region directories found in deploy/${environment}/" >&2
        echo "   Expected at least one directory matching: deploy/${environment}/*/" >&2
        echo "   Ensure config.yaml has shards for environment '${environment}' and run scripts/render.py" >&2
        exit 1
    fi

    echo "Found ${#region_dirs[@]} region(s) in environment '${environment}'"
    echo ""

    for region_dir in "${region_dirs[@]}"; do
        [ -d "$region_dir" ] || continue

        local region_alias
        region_alias=$(basename "$region_dir")

        echo "=========================================="
        echo "Processing: $environment / $region_alias"
        echo "=========================================="

        # Process regional pipeline
        if [ -f "${region_dir}/terraform/regional.json" ]; then
            provision_regional_pipeline "$environment" "$region_alias" "${region_dir}/terraform/regional.json" || \
                echo "⏭️  Continuing with next region..."
        else
            echo "No terraform/regional.json found in $region_dir, skipping regional pipeline..."
        fi

        # Process management cluster pipelines
        if [ -d "${region_dir}/terraform/management" ]; then
            echo "Checking for management cluster configs in ${environment}-${region_alias}..."

            for mc_config in "${region_dir}"/terraform/management/*.json; do
                [ -e "$mc_config" ] || continue

                local cluster_name
                cluster_name=$(basename "$mc_config" .json)

                provision_management_pipeline "$environment" "$region_alias" "$cluster_name" "$mc_config" || \
                    echo "⏭️  Continuing with next management cluster..."
            done
        else
            echo "No terraform/management/ directory in $region_dir, skipping management pipelines..."
        fi

        echo ""
    done

    echo "Pipeline provisioning complete."
    echo "Check AWS Console CodePipeline to see created pipelines."
}

main
