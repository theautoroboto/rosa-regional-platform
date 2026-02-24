#!/usr/bin/env bash
#
# e2e-cleanup-iot.sh - Non-interactive IoT Resources Cleanup
#
# This script removes AWS IoT resources (certificates, things, policies)
# for e2e test management clusters. Based on scripts/cleanup-maestro-agent-iot.sh
# but modified for non-interactive automation.
#
# Required environment variables:
#   CLUSTER_ID - Management cluster ID
#
# Optional:
#   TEST_REGION - AWS region (default: us-east-1)
#
# Exit codes:
#   0 - Success
#   1 - Failure

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

readonly CLUSTER_ID="${CLUSTER_ID:?CLUSTER_ID environment variable is required}"
readonly AWS_REGION="${TEST_REGION:-us-east-1}"

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    echo "ℹ️  $1"
}

log_success() {
    echo "✅ $1"
}

log_warning() {
    echo "⚠️  $1"
}

log_error() {
    echo "❌ $1" >&2
}

# =============================================================================
# Validation
# =============================================================================

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

# =============================================================================
# IoT Resource Discovery
# =============================================================================

discover_iot_resources() {
    log_info "Discovering IoT resources for cluster: $CLUSTER_ID"

    # Policy name
    POLICY_NAME="${CLUSTER_ID}-maestro-agent-policy"

    # Find certificates attached to the policy
    log_info "Searching for certificates attached to policy: $POLICY_NAME"

    CERT_ARNS=$(aws iot list-targets-for-policy \
        --policy-name "$POLICY_NAME" \
        --region "$AWS_REGION" \
        --query 'targets[]' \
        --output text 2>/dev/null || echo "")

    if [ -z "$CERT_ARNS" ]; then
        log_warning "No certificates found attached to policy $POLICY_NAME"
        return 0
    fi

    log_info "Found $(echo "$CERT_ARNS" | wc -w) certificate(s)"
}

# =============================================================================
# Certificate Cleanup
# =============================================================================

cleanup_certificates() {
    if [ -z "${CERT_ARNS:-}" ]; then
        log_info "No certificates to clean up"
        return 0
    fi

    log_info "Cleaning up certificates..."

    for cert_arn in $CERT_ARNS; do
        log_info "Processing certificate: $cert_arn"

        # Extract certificate ID from ARN
        CERT_ID=$(echo "$cert_arn" | grep -oP 'cert/\K[a-f0-9]+' || echo "")
        if [ -z "$CERT_ID" ]; then
            log_warning "Could not extract certificate ID from: $cert_arn"
            continue
        fi

        # Detach policy from certificate
        log_info "Detaching policy from certificate..."
        aws iot detach-policy \
            --policy-name "$POLICY_NAME" \
            --target "$cert_arn" \
            --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to detach policy (may already be detached)"

        # Deactivate certificate
        log_info "Deactivating certificate..."
        aws iot update-certificate \
            --certificate-id "$CERT_ID" \
            --new-status INACTIVE \
            --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to deactivate certificate"

        # Delete certificate
        log_info "Deleting certificate..."
        aws iot delete-certificate \
            --certificate-id "$CERT_ID" \
            --force-delete \
            --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete certificate"

        log_success "Certificate $CERT_ID cleaned up"
    done
}

# =============================================================================
# Policy Cleanup
# =============================================================================

cleanup_policy() {
    log_info "Cleaning up IoT policy: $POLICY_NAME"

    # Check if policy exists
    if ! aws iot get-policy \
        --policy-name "$POLICY_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Policy $POLICY_NAME not found (already deleted or never existed)"
        return 0
    fi

    # List all policy versions
    POLICY_VERSIONS=$(aws iot list-policy-versions \
        --policy-name "$POLICY_NAME" \
        --region "$AWS_REGION" \
        --query 'policyVersions[].versionId' \
        --output text 2>/dev/null || echo "")

    # Delete non-default versions first
    for version in $POLICY_VERSIONS; do
        IS_DEFAULT=$(aws iot list-policy-versions \
            --policy-name "$POLICY_NAME" \
            --region "$AWS_REGION" \
            --query "policyVersions[?versionId=='$version'].isDefaultVersion" \
            --output text 2>/dev/null || echo "false")

        if [ "$IS_DEFAULT" != "true" ] && [ "$IS_DEFAULT" != "True" ]; then
            log_info "Deleting non-default policy version: $version"
            aws iot delete-policy-version \
                --policy-name "$POLICY_NAME" \
                --policy-version-id "$version" \
                --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete policy version $version"
        fi
    done

    # Delete the policy
    log_info "Deleting policy..."
    aws iot delete-policy \
        --policy-name "$POLICY_NAME" \
        --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete policy"

    log_success "Policy $POLICY_NAME cleaned up"
}

# =============================================================================
# Thing Cleanup
# =============================================================================

cleanup_thing() {
    local thing_name="${CLUSTER_ID}-maestro-agent"

    log_info "Cleaning up IoT thing: $thing_name"

    # Check if thing exists
    if ! aws iot describe-thing \
        --thing-name "$thing_name" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_info "Thing $thing_name not found (already deleted or never existed)"
        return 0
    fi

    # Detach all principals from thing
    log_info "Detaching principals from thing..."
    PRINCIPALS=$(aws iot list-thing-principals \
        --thing-name "$thing_name" \
        --region "$AWS_REGION" \
        --query 'principals[]' \
        --output text 2>/dev/null || echo "")

    for principal in $PRINCIPALS; do
        log_info "Detaching principal: $principal"
        aws iot detach-thing-principal \
            --thing-name "$thing_name" \
            --principal "$principal" \
            --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to detach principal"
    done

    # Delete thing
    log_info "Deleting thing..."
    aws iot delete-thing \
        --thing-name "$thing_name" \
        --region "$AWS_REGION" 2>/dev/null || log_warning "Failed to delete thing"

    log_success "Thing $thing_name cleaned up"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    log_info "Starting IoT cleanup for cluster: $CLUSTER_ID"
    log_info "Region: $AWS_REGION"

    # Set error handling to continue on failure
    set +e

    # Discover resources
    discover_iot_resources

    # Clean up in proper order
    cleanup_certificates
    cleanup_thing
    cleanup_policy

    # Re-enable error handling
    set -e

    log_success "IoT cleanup complete for cluster: $CLUSTER_ID"
    exit 0
}

main "$@"
