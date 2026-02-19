#!/bin/bash
set -euo pipefail

# Validate Management Cluster Terraform configuration
# This script:
# 1. Sets up Terraform backend configuration
# 2. Ensures Maestro agent secrets exist in target account
# 3. Runs terraform init, validate, and plan

echo "Validating Management Cluster Configuration..."

# Set Terraform backend config (state bucket is in central account, region detected in pre_build)
export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
export TF_STATE_KEY="management-cluster/${TARGET_ALIAS}.tfstate"

# Export required Terraform variables
export TF_VAR_region="${TARGET_REGION}"
export TF_VAR_app_code="${APP_CODE}"
export TF_VAR_service_phase="${SERVICE_PHASE}"
export TF_VAR_cost_center="${COST_CENTER}"
export TF_VAR_repository_url="${REPOSITORY_URL}"
export TF_VAR_repository_branch="${REPOSITORY_BRANCH}"
export TF_VAR_cluster_id="${CLUSTER_ID:-mgmt-cluster-01}"
export TF_VAR_regional_aws_account_id="${REGIONAL_AWS_ACCOUNT_ID:-${CENTRAL_ACCOUNT_ID}}"
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_alias="${TARGET_ALIAS}"

# Create placeholder Maestro agent secrets in target account
create_maestro_secrets() {
    echo "Ensuring Maestro agent secrets exist in account ${TARGET_ACCOUNT_ID}..."

    for SECRET_NAME in "maestro/agent-cert" "maestro/agent-config"; do
        if ! AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
             AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
             AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
             aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "${TARGET_REGION}" 2>/dev/null; then

            echo "Creating placeholder secret: $SECRET_NAME"
            if ! CREATE_OUTPUT=$(AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
                                 AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
                                 AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
                                 aws secretsmanager create-secret \
                                 --name "$SECRET_NAME" \
                                 --description "Placeholder secret for Maestro agent (created by buildspec)" \
                                 --secret-string '{"placeholder":true}' \
                                 --region "${TARGET_REGION}" 2>&1); then

                if echo "$CREATE_OUTPUT" | grep -q "ResourceExistsException"; then
                    echo "Secret $SECRET_NAME already exists (created concurrently)"
                else
                    echo "❌ Failed to create secret $SECRET_NAME"
                    echo "Error: $CREATE_OUTPUT"
                    exit 1
                fi
            else
                echo "✓ Created secret $SECRET_NAME"
            fi
        else
            echo "Secret $SECRET_NAME already exists"
        fi
    done

    echo "Maestro agent placeholder secrets verified"
    echo ""
}

# Run Terraform validation
run_terraform_validation() {
    echo "Restoring central account credentials for Terraform backend access..."
    export AWS_ACCESS_KEY_ID="${CENTRAL_AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${CENTRAL_AWS_SECRET_ACCESS_KEY}"
    export AWS_SESSION_TOKEN="${CENTRAL_AWS_SESSION_TOKEN}"

    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    echo "Current account: $CURRENT_ACCOUNT (central: $CENTRAL_ACCOUNT_ID)"

    echo "Initializing Terraform..."
    cd terraform/config/management-cluster
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=true"

    echo "Validating Terraform configuration..."
    terraform validate

    echo "Running Terraform plan..."
    if ! terraform plan -out=tfplan; then
        echo "❌ Terraform plan failed"
        cd ../../..
        exit 1
    fi

    terraform show -no-color tfplan > plan-summary.txt
    echo "✓ Plan summary saved to plan-summary.txt"

    cd ../../..
}

# Main execution
create_maestro_secrets
run_terraform_validation

echo "Validation complete."
