#!/usr/bin/env bash
#
# e2e-destroy.sh - Automated E2E Environment Cleanup
#
# This script performs non-interactive teardown of e2e test environments.
# Destroys resources in the correct order:
# 1. IoT resources (certificates, things, policies)
# 2. Maestro secrets (MC account)
# 3. Management Cluster infrastructure
# 4. Regional Cluster secrets (RC account)
# 5. Regional Cluster infrastructure
# 6. Terraform state files
# 7. kubectl contexts
#
# Required environment variables:
#   MC_CLUSTER_ID       - Management cluster ID
#   TEST_REGION         - AWS region
#   RC_ACCOUNT_ID       - RC AWS account ID
#   MC_ACCOUNT_ID       - MC AWS account ID
#   CENTRAL_ACCOUNT_ID  - Central account ID
#   TF_STATE_BUCKET     - Terraform state bucket
#   TF_STATE_REGION     - State bucket region
#   TF_STATE_KEY_RC     - RC state key
#   TF_STATE_KEY_MC     - MC state key
#   RC_CLUSTER_NAME     - Regional cluster name
#   MC_CLUSTER_NAME     - Management cluster name
#
# Exit codes:
#   0 - All cleanup successful
#   3 - One or more cleanup steps failed

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Required variables (always needed)
readonly TEST_REGION="${TEST_REGION:?TEST_REGION is required}"
readonly RC_ACCOUNT_ID="${RC_ACCOUNT_ID:?RC_ACCOUNT_ID is required}"
readonly MC_ACCOUNT_ID="${MC_ACCOUNT_ID:?MC_ACCOUNT_ID is required}"
readonly CENTRAL_ACCOUNT_ID="${CENTRAL_ACCOUNT_ID:?CENTRAL_ACCOUNT_ID is required}"
readonly TF_STATE_BUCKET="${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
readonly TF_STATE_REGION="${TF_STATE_REGION:?TF_STATE_REGION is required}"
readonly TF_STATE_KEY_RC="${TF_STATE_KEY_RC:?TF_STATE_KEY_RC is required}"

# Optional variables (may not be set if provisioning failed early)
readonly MC_CLUSTER_ID="${MC_CLUSTER_ID:-}"
readonly TF_STATE_KEY_MC="${TF_STATE_KEY_MC:-}"
readonly RC_CLUSTER_NAME="${RC_CLUSTER_NAME:-}"
readonly MC_CLUSTER_NAME="${MC_CLUSTER_NAME:-}"

CLEANUP_FAILURES=0
CLEANUP_ERRORS=()

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [CLEANUP] $*"
}

log_success() {
    echo "✅ $1"
}

log_error() {
    echo "❌ $1" >&2
}

log_info() {
    echo "ℹ️  $1"
}

log_phase() {
    echo ""
    echo "=========================================="
    log "$1"
    echo "=========================================="
}

# =============================================================================
# Helper Functions
# =============================================================================

record_failure() {
    ((CLEANUP_FAILURES++)) || true
    CLEANUP_ERRORS+=("$1")
    log_error "$1"
}

retry_command() {
    local max_attempts="$1"
    shift
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi

        log_info "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 10
    done

    return 1
}

# =============================================================================
# IoT Cleanup
# =============================================================================

cleanup_iot_resources() {
    log_phase "Cleaning up IoT Resources"

    # Skip if MC was never configured
    if [ -z "$MC_CLUSTER_ID" ]; then
        log_info "MC was never provisioned, skipping IoT cleanup"
        return 0
    fi

    # Export cluster ID for cleanup script
    export CLUSTER_ID="$MC_CLUSTER_ID"

    # Run IoT cleanup script
    if [ -x "$SCRIPT_DIR/e2e-cleanup-iot.sh" ]; then
        log_info "Running IoT cleanup script..."
        if "$SCRIPT_DIR/e2e-cleanup-iot.sh"; then
            log_success "IoT resources cleaned up"
        else
            record_failure "IoT cleanup script failed (non-fatal, continuing)"
        fi
    else
        log_info "IoT cleanup script not found, skipping"
    fi

    # Clean up local certificate files
    if [ -d "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}" ]; then
        log_info "Removing local certificate files..."
        rm -rf "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}"
        log_success "Local certificate files removed"
    fi

    # Clean up IoT Terraform state
    if [ -d "$REPO_ROOT/terraform/config/maestro-agent-iot-provisioning/.terraform" ]; then
        log_info "Cleaning up IoT provisioning Terraform state..."
        rm -rf "$REPO_ROOT/terraform/config/maestro-agent-iot-provisioning/.terraform"
        rm -f "$REPO_ROOT/terraform/config/maestro-agent-iot-provisioning/terraform.tfstate"*
        log_success "IoT Terraform state cleaned up"
    fi
}

# =============================================================================
# Regional Cluster Secrets Cleanup
# =============================================================================

cleanup_regional_secrets() {
    log_phase "Cleaning up Regional Cluster Secrets (RC Account)"

    # Save original credentials
    local ORIG_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    local ORIG_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    local ORIG_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    # Assume role in RC account if needed
    if [ "$RC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        local role_arn="arn:aws:iam::${RC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
        log_info "Assuming role in RC account: $role_arn"

        local creds=$(aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "e2e-cleanup-rc-secrets" \
            --output json 2>/dev/null || echo "")

        if [ -n "$creds" ]; then
            export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
            export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
            export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
        else
            log_error "Failed to assume role in RC account"
            record_failure "Cannot cleanup RC secrets"
            return 1
        fi
    fi

    # List of secrets to clean up in RC account
    local secrets=(
        "hyperfleet/db-credentials"
        "maestro/server-cert"
        "maestro/server-key"
        "maestro/ca-cert"
    )

    for secret in "${secrets[@]}"; do
        log_info "Deleting secret: $secret"

        # Check if secret exists and is scheduled for deletion
        local secret_info=$(aws secretsmanager describe-secret \
            --secret-id "$secret" \
            --region "$TEST_REGION" 2>/dev/null || echo "")

        if [ -n "$secret_info" ]; then
            # If scheduled for deletion, restore it first
            if echo "$secret_info" | grep -q "DeletedDate"; then
                log_info "Secret $secret is scheduled for deletion, restoring first..."
                aws secretsmanager restore-secret \
                    --secret-id "$secret" \
                    --region "$TEST_REGION" 2>/dev/null || log_info "Failed to restore $secret"
                sleep 2
            fi

            # Force delete
            aws secretsmanager delete-secret \
                --secret-id "$secret" \
                --region "$TEST_REGION" \
                --force-delete-without-recovery \
                2>/dev/null || log_info "Failed to delete $secret"
        else
            log_info "Secret $secret not found or already deleted"
        fi
    done

    log_success "Regional cluster secrets cleanup complete"

    # Restore original credentials
    export AWS_ACCESS_KEY_ID="$ORIG_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$ORIG_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$ORIG_AWS_SESSION_TOKEN"
}

# =============================================================================
# Maestro Secrets Cleanup
# =============================================================================

cleanup_maestro_secrets() {
    log_phase "Cleaning up Maestro Secrets (MC Account)"

    # Save original credentials
    local ORIG_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    local ORIG_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    local ORIG_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    # Assume role in MC account if needed
    if [ "$MC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        local role_arn="arn:aws:iam::${MC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
        log_info "Assuming role in MC account: $role_arn"

        local creds=$(aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "e2e-cleanup-secrets" \
            --output json 2>/dev/null || echo "")

        if [ -n "$creds" ]; then
            export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
            export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
            export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
        else
            log_error "Failed to assume role in MC account"
            record_failure "Cannot cleanup Maestro secrets"
        fi
    fi

    # Delete Maestro secrets (ignore errors if they don't exist)
    log_info "Deleting Maestro agent certificate secret..."
    aws secretsmanager delete-secret \
        --secret-id "maestro/agent-cert" \
        --region "$TEST_REGION" \
        --force-delete-without-recovery \
        2>/dev/null || log_info "Secret maestro/agent-cert not found or already deleted"

    log_info "Deleting Maestro agent config secret..."
    aws secretsmanager delete-secret \
        --secret-id "maestro/agent-config" \
        --region "$TEST_REGION" \
        --force-delete-without-recovery \
        2>/dev/null || log_info "Secret maestro/agent-config not found or already deleted"

    log_success "Maestro secrets cleanup complete"

    # Restore original credentials
    export AWS_ACCESS_KEY_ID="$ORIG_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$ORIG_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$ORIG_AWS_SESSION_TOKEN"
}

# =============================================================================
# Terraform Destroy
# =============================================================================

destroy_terraform() {
    local cluster_type="$1"
    local state_key="$2"
    local description="$3"

    log_phase "Destroying $description Infrastructure"

    local terraform_dir="$REPO_ROOT/terraform/config/${cluster_type}"

    if [ ! -d "$terraform_dir" ]; then
        log_error "Terraform directory not found: $terraform_dir"
        record_failure "Cannot destroy $description"
        return 1
    fi

    cd "$terraform_dir"

    # Initialize Terraform with correct backend
    log_info "Initializing Terraform for $description..."
    if ! terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${state_key}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=true" 2>/dev/null; then
        log_error "Terraform init failed for $description"
        record_failure "Cannot destroy $description - init failed"
        cd "$REPO_ROOT"
        return 1
    fi

    # Build destroy command with all required variables
    local destroy_cmd="terraform destroy -auto-approve -input=false"

    # Add cluster-type specific variables
    if [ "$cluster_type" = "management-cluster" ] && [ -n "$MC_CLUSTER_ID" ]; then
        destroy_cmd="$destroy_cmd -var cluster_id=${MC_CLUSTER_ID}"
        destroy_cmd="$destroy_cmd -var regional_aws_account_id=${RC_ACCOUNT_ID}"
    fi

    # Retry destroy up to 2 times
    log_info "Running terraform destroy for $description (with retry)..."
    if retry_command 2 bash -c "$destroy_cmd"; then
        log_success "$description infrastructure destroyed"
    else
        log_error "Terraform destroy failed for $description after retries"
        record_failure "$description infrastructure may not be fully destroyed"
    fi

    cd "$REPO_ROOT"
}

# =============================================================================
# State File Cleanup
# =============================================================================

cleanup_state_files() {
    log_phase "Cleaning up Terraform State Files"

    # Delete RC state file
    log_info "Deleting RC state file: s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_RC}"
    if aws s3 rm "s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_RC}" --region "$TF_STATE_REGION" 2>/dev/null; then
        log_success "RC state file deleted"
    else
        log_info "RC state file not found or already deleted"
    fi

    # Delete MC state file (only if MC was provisioned)
    if [ -n "$TF_STATE_KEY_MC" ]; then
        log_info "Deleting MC state file: s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_MC}"
        if aws s3 rm "s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_MC}" --region "$TF_STATE_REGION" 2>/dev/null; then
            log_success "MC state file deleted"
        else
            log_info "MC state file not found or already deleted"
        fi

        # Clean up MC lock file (ignore errors)
        aws s3 rm "s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_MC}.tflock" --region "$TF_STATE_REGION" 2>/dev/null || true
    else
        log_info "Skipping MC state file cleanup (MC was never provisioned)"
    fi

    # Clean up RC lock file (ignore errors)
    aws s3 rm "s3://${TF_STATE_BUCKET}/${TF_STATE_KEY_RC}.tflock" --region "$TF_STATE_REGION" 2>/dev/null || true

    log_success "State file cleanup complete"
}

# =============================================================================
# kubectl Context Cleanup
# =============================================================================

cleanup_kubectl_contexts() {
    log_phase "Cleaning up kubectl Contexts"

    # Remove kubectl contexts for e2e clusters
    kubectl config delete-context "e2e-RC" 2>/dev/null || true
    kubectl config delete-context "e2e-MC" 2>/dev/null || true

    log_success "kubectl contexts cleaned up"
}

# =============================================================================
# Main Cleanup Flow
# =============================================================================

main() {
    log_phase "Starting E2E Environment Cleanup"
    if [ -n "$MC_CLUSTER_ID" ]; then
        log_info "MC Cluster ID: $MC_CLUSTER_ID"
    else
        log_info "MC Cluster ID: (not set - MC was never provisioned)"
    fi
    log_info "Region: $TEST_REGION"
    echo ""

    # Step 1: Clean up IoT resources (must be done before MC destroy)
    cleanup_iot_resources

    # Step 2: Clean up Maestro secrets in MC account (only if MC was provisioned)
    if [ -n "$MC_CLUSTER_ID" ]; then
        cleanup_maestro_secrets
    else
        log_info "Skipping Maestro secrets cleanup (MC was never provisioned)"
    fi

    # Step 3: Destroy Management Cluster (depends on RC, so destroy first)
    # Only destroy if MC was actually configured (MC_CLUSTER_ID is set)
    if [ -n "$MC_CLUSTER_ID" ] && [ -n "$TF_STATE_KEY_MC" ]; then
        destroy_terraform "management-cluster" "$TF_STATE_KEY_MC" "Management Cluster"
    else
        log_info "Skipping MC destroy (MC was never provisioned)"
    fi

    # Step 4: Clean up Regional Cluster secrets (before destroying RC)
    cleanup_regional_secrets

    # Step 5: Destroy Regional Cluster
    destroy_terraform "regional-cluster" "$TF_STATE_KEY_RC" "Regional Cluster"

    # Step 6: Clean up state files
    cleanup_state_files

    # Step 7: Clean up kubectl contexts
    cleanup_kubectl_contexts

    # Summary
    log_phase "Cleanup Summary"

    if [ $CLEANUP_FAILURES -eq 0 ]; then
        log_success "All cleanup operations completed successfully (0 failures)"
        exit 0
    else
        log_error "Cleanup completed with $CLEANUP_FAILURES failure(s)"
        echo ""
        log_error "Errors encountered during cleanup:"
        for error in "${CLEANUP_ERRORS[@]}"; do
            echo "  ❌ $error"
        done
        echo ""
        log_error "Manual intervention may be required to clean up orphaned resources"
        log_info "Check AWS console for resources tagged with cluster names:"
        if [ -n "$RC_CLUSTER_NAME" ]; then
            log_info "  RC: $RC_CLUSTER_NAME"
        fi
        if [ -n "$MC_CLUSTER_NAME" ]; then
            log_info "  MC: $MC_CLUSTER_NAME"
        fi
        exit 3
    fi
}

main "$@"
