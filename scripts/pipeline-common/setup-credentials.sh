#!/usr/bin/env bash
#
# setup-credentials.sh - Shared credential setup for CodeBuild pipelines
#
# This script handles the common pre_build logic for both regional and management cluster
# bootstrap pipelines:
# - Validates required environment variables
# - Detects central account and S3 state bucket region
# - Saves central account credentials for Terraform backend access
# - Assumes role in target account (if cross-account)
# - Builds platform image in target account
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID - The target AWS account ID
#   TARGET_REGION     - The target AWS region
#   TARGET_ALIAS      - The target cluster alias
#
# Exports:
#   CENTRAL_ACCOUNT_ID           - Central account ID (for S3 state bucket)
#   TF_STATE_REGION              - Region where S3 state bucket is located
#   SAVE_AWS_ACCESS_KEY_ID       - Saved central account credentials
#   SAVE_AWS_SECRET_ACCESS_KEY   - Saved central account credentials
#   SAVE_AWS_SESSION_TOKEN       - Saved central account credentials
#   TARGET_AWS_ACCESS_KEY_ID     - Target account credentials (for ECR/ECS/EKS)
#   TARGET_AWS_SECRET_ACCESS_KEY - Target account credentials
#   TARGET_AWS_SESSION_TOKEN     - Target account credentials
#   TF_VAR_target_account_id     - Terraform variable for target account
#   TF_VAR_target_alias          - Terraform variable for target alias

set -euo pipefail

echo "=========================================="
echo "Pre-flight Setup"
echo "=========================================="

# Validate required environment variables
if [[ -z "${TARGET_ACCOUNT_ID:-}" || -z "${TARGET_REGION:-}" || -z "${TARGET_ALIAS:-}" ]]; then
    echo "❌ ERROR: Required environment variables not set"
    echo "   TARGET_ACCOUNT_ID: ${TARGET_ACCOUNT_ID:-not set}"
    echo "   TARGET_REGION: ${TARGET_REGION:-not set}"
    echo "   TARGET_ALIAS: ${TARGET_ALIAS:-not set}"
    exit 1
fi

# Get central account ID BEFORE assuming role
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CENTRAL_ACCOUNT_ID

# Detect S3 state bucket region BEFORE assuming role (bucket is in central account)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text)
if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
    BUCKET_REGION="us-east-1"
fi
export TF_STATE_REGION=$BUCKET_REGION

echo "Configuration:"
echo "  Central Account: $CENTRAL_ACCOUNT_ID"
echo "  Target Account: $TARGET_ACCOUNT_ID"
echo "  Target Region: $TARGET_REGION"
echo "  Target Alias: $TARGET_ALIAS"
echo "  State Bucket Region: $TF_STATE_REGION"
echo ""

# Save central account credentials before assuming role
# These will be restored later for Terraform backend access
export SAVE_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export SAVE_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export SAVE_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Prepare target account credentials for target-specific operations (ECR, ECS, EKS)
# NOTE: We assume role only for target account operations, then restore central creds for Terraform
if [ "$TARGET_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
    ROLE_ARN="arn:aws:iam::${TARGET_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    echo "Assuming role for target account operations: $ROLE_ARN"

    if ! TEMP_CREDS=$(aws sts assume-role \
        --role-arn "$ROLE_ARN" \
        --role-session-name "pipeline-bootstrap-${TARGET_ALIAS}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text 2>&1); then
        echo "❌ ERROR: Failed to assume role $ROLE_ARN"
        echo "Error: $TEMP_CREDS"
        exit 1
    fi

    # Store assumed credentials for use in build phase (target account operations)
    export TARGET_AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | awk '{print $1}')
    export TARGET_AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | awk '{print $2}')
    export TARGET_AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | awk '{print $3}')

    # Verify the assumed role credentials work
    ASSUMED_ACCOUNT=$(AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
                      AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
                      AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
                      aws sts get-caller-identity --query Account --output text)
    if [ "$ASSUMED_ACCOUNT" != "$TARGET_ACCOUNT_ID" ]; then
        echo "❌ ERROR: Assumed wrong account. Expected $TARGET_ACCOUNT_ID, got $ASSUMED_ACCOUNT"
        exit 1
    fi

    echo "✅ Assumed role in account $TARGET_ACCOUNT_ID (credentials saved for target operations)"
else
    echo "✅ Target account same as central - using current credentials for both operations"
    # For same-account deployments, use current credentials for both
    export TARGET_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    export TARGET_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    export TARGET_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
fi
echo ""

# Pass target account to Terraform for consistency
export TF_VAR_target_account_id="${TARGET_ACCOUNT_ID}"
export TF_VAR_target_alias="${TARGET_ALIAS}"

# Build platform image (uses target account credentials to push to target ECR)
echo "Building platform image (if needed)..."
AWS_ACCESS_KEY_ID="$TARGET_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$TARGET_AWS_SECRET_ACCESS_KEY" \
AWS_SESSION_TOKEN="$TARGET_AWS_SESSION_TOKEN" \
make build-platform-image
echo ""

echo "✅ Pre-flight setup complete"
