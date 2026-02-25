#!/usr/bin/env bash
#
# e2e-test.sh - End-to-End Test Orchestrator
#
# This script orchestrates a full lifecycle test of the ROSA Regional Platform:
# 1. Provision Regional Cluster (RC) infrastructure
# 2. Provision Management Cluster (MC) infrastructure
# 3. Validate basic infrastructure health
# 4. Destroy all resources (always, even on failure)
#
# Designed to be triggered externally for nightly regression testing.
#
# Required environment variables:
#   RC_ACCOUNT_ID - AWS account ID for Regional Cluster
#   MC_ACCOUNT_ID - AWS account ID for Management Cluster
#
# Optional environment variables:
#   TEST_REGION         - AWS region (default: us-east-1)
#   GITHUB_REPOSITORY   - Git repository (default: auto-detected or openshift-online/rosa-regional-platform)
#   GITHUB_BRANCH       - Git branch (default: main)
#
# Exit codes:
#   0 - Full success (provision, validate, cleanup complete)
#   1 - Provisioning failure (RC or MC failed to provision)
#   2 - Validation failure (infrastructure health checks failed)
#   3 - Cleanup failure (resources may be orphaned)

set -euo pipefail

# =============================================================================
# Configuration and Constants
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test identification
readonly TEST_ID="e2e-$(date +%Y%m%d-%H%M%S)-$$"
readonly TEST_REGION="${TEST_REGION:-us-east-1}"

# Git configuration
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
if [ -z "$GITHUB_REPOSITORY" ]; then
    # Try to auto-detect from git remote
    if git remote get-url origin >/dev/null 2>&1; then
        GITHUB_REPOSITORY=$(git remote get-url origin | sed -E 's|.*github.com[:/](.*)\.git|\1|')
    else
        GITHUB_REPOSITORY="openshift-online/rosa-regional-platform"
    fi
fi
readonly GITHUB_REPOSITORY
readonly GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_PROVISION_FAILURE=1
readonly EXIT_VALIDATION_FAILURE=2
readonly EXIT_CLEANUP_FAILURE=3

# State tracking
PROVISION_RC_COMPLETED=false
PROVISION_MC_COMPLETED=false
VALIDATION_COMPLETED=false
CLEANUP_COMPLETED=false

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$TEST_ID] $*"
}

log_phase() {
    echo ""
    echo "=========================================="
    log "$1"
    echo "=========================================="
}

log_success() {
    log "✅ $1"
}

log_error() {
    log "❌ $1" >&2
}

log_info() {
    log "ℹ️  $1"
}

# =============================================================================
# Validation
# =============================================================================

validate_prerequisites() {
    log_phase "Validating Prerequisites"

    # Check required environment variables
    if [[ -z "${RC_ACCOUNT_ID:-}" ]]; then
        log_error "RC_ACCOUNT_ID environment variable is required"
        exit 1
    fi

    if [[ -z "${MC_ACCOUNT_ID:-}" ]]; then
        log_error "MC_ACCOUNT_ID environment variable is required"
        exit 1
    fi

    # Check required tools
    local required_tools=("aws" "terraform" "jq" "git" "kubectl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is required but not installed"
            exit 1
        fi
    done

    log_success "Prerequisites validated"
    log_info "RC Account: ${RC_ACCOUNT_ID}"
    log_info "MC Account: ${MC_ACCOUNT_ID}"
    log_info "Test Region: ${TEST_REGION}"
    log_info "Repository: ${GITHUB_REPOSITORY}"
    log_info "Branch: ${GITHUB_BRANCH}"
}

# =============================================================================
# State and Account Detection
# =============================================================================

detect_central_account() {
    log_phase "Detecting Central Account and State Configuration"

    # Source the existing detection script
    source "$REPO_ROOT/scripts/pipeline-common/detect-central-state.sh"

    export TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"
    export TF_STATE_KEY_RC="e2e-tests/regional-${TEST_ID}.tfstate"
    export TF_STATE_KEY_MC="e2e-tests/management-${TEST_ID}.tfstate"

    log_success "State configuration detected"
    log_info "Central Account: ${CENTRAL_ACCOUNT_ID}"
    log_info "State Bucket: ${TF_STATE_BUCKET}"
    log_info "State Region: ${TF_STATE_REGION}"
    log_info "RC State Key: ${TF_STATE_KEY_RC}"
    log_info "MC State Key: ${TF_STATE_KEY_MC}"
}

# =============================================================================
# Environment Configuration
# =============================================================================

configure_rc_environment() {
    log_phase "Configuring Regional Cluster Environment Variables"

    # Terraform state configuration (exported for make targets)
    export TF_STATE_BUCKET
    export TF_STATE_REGION
    export TF_STATE_KEY="${TF_STATE_KEY_RC}"

    # Terraform variables for RC
    export TF_VAR_region="${TEST_REGION}"
    export TF_VAR_target_account_id="${RC_ACCOUNT_ID}"
    export TF_VAR_target_alias="e2e-rc-${TEST_ID}"
    export TF_VAR_app_code="e2e"
    export TF_VAR_service_phase="test"
    export TF_VAR_cost_center="000"
    export TF_VAR_repository_url="https://github.com/${GITHUB_REPOSITORY}.git"
    export TF_VAR_repository_branch="${GITHUB_BRANCH}"
    export TF_VAR_enable_bastion="false"
    export TF_VAR_api_additional_allowed_accounts="${MC_ACCOUNT_ID}"

    # Database optimizations for test (smallest/cheapest instances)
    export TF_VAR_maestro_db_instance_class="db.t4g.micro"
    export TF_VAR_maestro_db_multi_az="false"
    export TF_VAR_maestro_db_deletion_protection="false"
    export TF_VAR_maestro_db_skip_final_snapshot="true"
    export TF_VAR_hyperfleet_db_instance_class="db.t4g.micro"
    export TF_VAR_hyperfleet_db_multi_az="false"
    export TF_VAR_hyperfleet_db_deletion_protection="false"
    export TF_VAR_hyperfleet_db_skip_final_snapshot="true"
    export TF_VAR_hyperfleet_mq_instance_type="mq.t3.micro"
    export TF_VAR_hyperfleet_mq_deployment_mode="SINGLE_INSTANCE"
    export TF_VAR_authz_deletion_protection="false"

    # Store cluster name for later use
    export RC_CLUSTER_NAME="e2e-rc-${TEST_ID}"

    log_success "RC environment configured"
}

configure_mc_environment() {
    log_phase "Configuring Management Cluster Environment Variables"

    # Terraform state configuration
    export TF_STATE_KEY="${TF_STATE_KEY_MC}"

    # Terraform variables for MC
    export TF_VAR_region="${TEST_REGION}"
    export TF_VAR_target_account_id="${MC_ACCOUNT_ID}"
    export TF_VAR_target_alias="e2e-mc-${TEST_ID}"
    export TF_VAR_app_code="e2e"
    export TF_VAR_service_phase="test"
    export TF_VAR_cost_center="000"
    export TF_VAR_repository_url="https://github.com/${GITHUB_REPOSITORY}.git"
    export TF_VAR_repository_branch="${GITHUB_BRANCH}"
    export TF_VAR_enable_bastion="false"

    # MC-specific configuration
    export TF_VAR_cluster_id="e2e-mc-${TEST_ID}"
    export TF_VAR_regional_aws_account_id="${RC_ACCOUNT_ID}"

    # Store cluster name for later use
    export MC_CLUSTER_NAME="e2e-mc-${TEST_ID}"
    export MC_CLUSTER_ID="e2e-mc-${TEST_ID}"

    log_success "MC environment configured"
}

# =============================================================================
# Pre-Flight Cleanup
# =============================================================================

cleanup_orphaned_secrets() {
    log_phase "Cleaning Up Orphaned Secrets from Previous Runs"

    # List of secrets that might be left over from failed runs
    local secrets=(
        "maestro/server-cert"
        "maestro/server-config"
        "maestro/db-credentials"
        "hyperfleet/db-credentials"
        "hyperfleet/mq-credentials"
        "maestro/agent-cert"
        "maestro/agent-config"
    )

    for secret in "${secrets[@]}"; do
        log_info "Checking for orphaned secret: $secret"

        # Get secret status
        local secret_info=$(aws secretsmanager describe-secret --secret-id "$secret" --region "$TEST_REGION" 2>&1 || echo "NOT_FOUND")

        if echo "$secret_info" | grep -q "ResourceNotFoundException"; then
            log_info "Secret $secret does not exist (clean)"
            continue
        fi

        # Check if secret is scheduled for deletion
        if echo "$secret_info" | grep -q "DeletedDate"; then
            log_warning "Secret $secret is scheduled for deletion - canceling deletion and re-deleting..."
            # Restore the secret first
            aws secretsmanager restore-secret --secret-id "$secret" --region "$TEST_REGION" 2>/dev/null || true
            sleep 2
        fi

        # Now force delete
        log_warning "Deleting orphaned secret: $secret"
        aws secretsmanager delete-secret \
            --secret-id "$secret" \
            --region "$TEST_REGION" \
            --force-delete-without-recovery \
            2>/dev/null || log_warning "Failed to delete $secret"
    done

    log_success "Orphaned secrets cleanup complete"
}

cleanup_orphaned_eips() {
    log_phase "Cleaning Up Orphaned Elastic IPs from Previous Runs"

    # Find all unattached EIPs with e2e tags
    log_info "Searching for unattached EIPs with e2e tags..."

    local eip_allocations=$(aws ec2 describe-addresses \
        --region "$TEST_REGION" \
        --filters "Name=tag:app_code,Values=e2e" \
        --query 'Addresses[?AssociationId==null].AllocationId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$eip_allocations" ]; then
        log_info "No orphaned EIPs found (clean)"
        log_success "Orphaned EIPs cleanup complete"
        return 0
    fi

    local eip_count=$(echo "$eip_allocations" | wc -w)
    log_warning "Found $eip_count orphaned EIP(s)"

    for allocation_id in $eip_allocations; do
        log_warning "Releasing orphaned EIP: $allocation_id"
        if aws ec2 release-address \
            --allocation-id "$allocation_id" \
            --region "$TEST_REGION" 2>/dev/null; then
            log_success "Released EIP: $allocation_id"
        else
            log_warning "Failed to release EIP: $allocation_id (may be in use)"
        fi
    done

    log_success "Orphaned EIPs cleanup complete"
}

# =============================================================================
# Provisioning Functions
# =============================================================================

provision_regional_cluster() {
    log_phase "Provisioning Regional Cluster"

    configure_rc_environment

    # Set environment variables for ArgoCD validation and bootstrap
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="e2e"
    export AWS_REGION="${TEST_REGION}"
    export CLUSTER_TYPE="regional-cluster"

    # Provision infrastructure using pipeline target (same as CI/CD)
    log_info "Running pipeline provisioning for Regional Cluster..."
    make pipeline-provision-regional || {
        log_error "Pipeline provision failed for RC"
        return 1
    }

    log_success "Regional Cluster infrastructure provisioned"
    PROVISION_RC_COMPLETED=true

    # Build platform image
    log_info "Building platform image..."
    make build-platform-image || {
        log_error "Platform image build failed"
        return 1
    }

    # Bootstrap ArgoCD
    log_info "Bootstrapping ArgoCD for Regional Cluster..."

    # Set role assumption if cross-account
    if [ "$RC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        export ASSUME_ROLE_ARN="arn:aws:iam::${RC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    fi

    "$REPO_ROOT/scripts/bootstrap-argocd.sh" regional-cluster || {
        log_error "ArgoCD bootstrap failed for RC"
        return 1
    }

    log_success "Regional Cluster fully provisioned and bootstrapped"
}

provision_management_cluster() {
    log_phase "Provisioning Management Cluster"

    configure_mc_environment

    # Set environment variables for ArgoCD validation and bootstrap
    export ENVIRONMENT="e2e"
    export REGION_ALIAS="e2e"
    export AWS_REGION="${TEST_REGION}"
    export CLUSTER_TYPE="management-cluster"

    # Provision IoT resources in regional account first
    log_info "Provisioning IoT resources in regional account..."
    provision_iot_resources || {
        log_error "IoT provisioning failed"
        return 1
    }

    # Create Maestro secrets in management account
    log_info "Creating Maestro secrets in management account..."
    create_maestro_secrets || {
        log_error "Maestro secret creation failed"
        return 1
    }

    # Provision infrastructure using pipeline target (same as CI/CD)
    log_info "Running pipeline provisioning for Management Cluster..."
    make pipeline-provision-management || {
        log_error "Pipeline provision failed for MC"
        return 1
    }

    log_success "Management Cluster infrastructure provisioned"
    PROVISION_MC_COMPLETED=true

    # Bootstrap ArgoCD
    log_info "Bootstrapping ArgoCD for Management Cluster..."

    # Set role assumption if cross-account
    if [ "$MC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        export ASSUME_ROLE_ARN="arn:aws:iam::${MC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
    fi

    "$REPO_ROOT/scripts/bootstrap-argocd.sh" management-cluster || {
        log_error "ArgoCD bootstrap failed for MC"
        return 1
    }

    log_success "Management Cluster fully provisioned and bootstrapped"
}

provision_iot_resources() {
    log_info "Provisioning AWS IoT resources for cluster ${MC_CLUSTER_ID}..."

    # Save current credentials
    local SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    local SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    local SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    # Assume role in regional account if needed
    if [ "$RC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        local role_arn="arn:aws:iam::${RC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
        log_info "Assuming role in regional account: $role_arn"

        local creds=$(aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "e2e-iot-provision" \
            --output json)

        export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
        export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
        export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
    fi

    # Provision IoT thing and certificate
    cd "$REPO_ROOT/terraform/config/maestro-agent-iot-provisioning"

    terraform init -backend=false

    terraform apply -auto-approve \
        -var="cluster_id=${MC_CLUSTER_ID}" \
        -var="region=${TEST_REGION}" || {
        # Restore credentials
        export AWS_ACCESS_KEY_ID="$SAVED_AWS_ACCESS_KEY_ID"
        export AWS_SECRET_ACCESS_KEY="$SAVED_AWS_SECRET_ACCESS_KEY"
        export AWS_SESSION_TOKEN="$SAVED_AWS_SESSION_TOKEN"
        return 1
    }

    # Save outputs for secret creation
    local iot_endpoint=$(terraform output -raw iot_endpoint)
    local certificate_pem=$(terraform output -raw certificate_pem)
    local private_key=$(terraform output -raw private_key)
    local ca_cert=$(terraform output -raw ca_certificate)

    # Store in temp file for secret creation
    mkdir -p "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}"
    cat > "$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}/certificate_data.json" <<EOF
{
  "iot_endpoint": "$iot_endpoint",
  "certificate_pem": "$certificate_pem",
  "private_key": "$private_key",
  "ca_certificate": "$ca_cert"
}
EOF

    cd "$REPO_ROOT"

    # Restore credentials
    export AWS_ACCESS_KEY_ID="$SAVED_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$SAVED_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$SAVED_AWS_SESSION_TOKEN"

    log_success "IoT resources provisioned"
}

create_maestro_secrets() {
    log_info "Creating Maestro secrets in management account..."

    # Assume role in management account if needed
    if [ "$MC_ACCOUNT_ID" != "$CENTRAL_ACCOUNT_ID" ]; then
        local role_arn="arn:aws:iam::${MC_ACCOUNT_ID}:role/OrganizationAccountAccessRole"
        log_info "Assuming role in management account: $role_arn"

        local creds=$(aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "e2e-maestro-secrets" \
            --output json)

        export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
        export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
        export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
    fi

    # Read certificate data
    local cert_file="$REPO_ROOT/.maestro-certs/${MC_CLUSTER_ID}/certificate_data.json"
    if [ ! -f "$cert_file" ]; then
        log_error "Certificate data not found: $cert_file"
        return 1
    fi

    local iot_endpoint=$(jq -r '.iot_endpoint' "$cert_file")
    local certificate_pem=$(jq -r '.certificate_pem' "$cert_file")
    local private_key=$(jq -r '.private_key' "$cert_file")
    local ca_cert=$(jq -r '.ca_certificate' "$cert_file")

    # Create secrets
    aws secretsmanager create-secret \
        --name "maestro/agent-cert" \
        --secret-string "{\"certificate\":\"$certificate_pem\",\"private_key\":\"$private_key\",\"ca_certificate\":\"$ca_cert\"}" \
        --region "${TEST_REGION}" || true

    aws secretsmanager create-secret \
        --name "maestro/agent-config" \
        --secret-string "{\"endpoint\":\"$iot_endpoint\"}" \
        --region "${TEST_REGION}" || true

    log_success "Maestro secrets created"
}

# =============================================================================
# Validation
# =============================================================================

run_validation() {
    log_phase "Running Validation Tests"

    # Export cluster names for validation script
    export RC_CLUSTER_NAME
    export MC_CLUSTER_NAME
    export MC_CLUSTER_ID
    export TEST_REGION
    export RC_ACCOUNT_ID
    export MC_ACCOUNT_ID
    export CENTRAL_ACCOUNT_ID

    "$SCRIPT_DIR/e2e-validate.sh" || {
        log_error "Validation failed"
        return 1
    }

    log_success "Validation complete"
    VALIDATION_COMPLETED=true
}

# =============================================================================
# Cleanup
# =============================================================================

run_cleanup() {
    log_phase "Running Cleanup"

    # Export necessary variables for cleanup script
    export MC_CLUSTER_ID
    export TEST_REGION
    export RC_ACCOUNT_ID
    export MC_ACCOUNT_ID
    export CENTRAL_ACCOUNT_ID
    export TF_STATE_BUCKET
    export TF_STATE_REGION
    export TF_STATE_KEY_RC
    export TF_STATE_KEY_MC
    export RC_CLUSTER_NAME
    export MC_CLUSTER_NAME

    "$SCRIPT_DIR/e2e-destroy.sh" || {
        log_error "Cleanup failed - resources may be orphaned"
        CLEANUP_COMPLETED=false
        return 1
    }

    log_success "Cleanup complete"
    CLEANUP_COMPLETED=true
}

# =============================================================================
# Trap Handler
# =============================================================================

cleanup_on_exit() {
    local exit_code=$?

    echo ""
    log_phase "Test Execution Complete"

    if [ $exit_code -ne 0 ]; then
        log_error "Test failed with exit code $exit_code"
    else
        log_success "Test passed"
    fi

    # Always run cleanup
    log_info "Running cleanup (always runs regardless of test result)..."
    if run_cleanup; then
        log_success "Cleanup successful"
    else
        log_error "Cleanup failed - manual intervention may be required"
        exit_code=$EXIT_CLEANUP_FAILURE
    fi

    # Summary
    echo ""
    log_phase "Test Summary"
    log_info "Test ID: $TEST_ID"
    log_info "RC Provisioned: $PROVISION_RC_COMPLETED"
    log_info "MC Provisioned: $PROVISION_MC_COMPLETED"
    log_info "Validation: $VALIDATION_COMPLETED"
    log_info "Cleanup: $CLEANUP_COMPLETED"

    if [ $exit_code -eq 0 ] && [ "$CLEANUP_COMPLETED" = "true" ]; then
        log_success "E2E Test PASSED - All resources cleaned up"
    else
        log_error "E2E Test FAILED - Exit code: $exit_code"
    fi

    exit $exit_code
}

trap cleanup_on_exit EXIT INT TERM

# =============================================================================
# Main Execution
# =============================================================================

main() {
    log_phase "Starting End-to-End Test"
    log_info "Test ID: $TEST_ID"

    # Validate prerequisites
    validate_prerequisites

    # Detect central account and configure state
    detect_central_account

    # Clean up any orphaned resources from previous failed runs
    cleanup_orphaned_secrets
    cleanup_orphaned_eips

    # Provision Regional Cluster
    if ! provision_regional_cluster; then
        log_error "Regional Cluster provisioning failed"
        exit $EXIT_PROVISION_FAILURE
    fi

    # Provision Management Cluster
    if ! provision_management_cluster; then
        log_error "Management Cluster provisioning failed"
        exit $EXIT_PROVISION_FAILURE
    fi

    # Run validation tests
    if ! run_validation; then
        log_error "Validation failed"
        exit $EXIT_VALIDATION_FAILURE
    fi

    log_success "All tests passed"
    exit $EXIT_SUCCESS
}

# Run main function
main "$@"
