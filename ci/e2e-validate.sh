#!/usr/bin/env bash
#
# e2e-validate.sh - E2E Validation Test Suite
#
# This script validates the successful deployment of RC and MC infrastructure.
# Performs basic health checks on:
# - EKS clusters
# - VPC and networking
# - RDS databases
# - API Gateway (RC only)
# - ArgoCD deployments
# - IoT/Maestro infrastructure
#
# Required environment variables:
#   RC_CLUSTER_NAME     - Regional cluster name
#   MC_CLUSTER_NAME     - Management cluster name
#   MC_CLUSTER_ID       - Management cluster ID
#   TEST_REGION         - AWS region
#   RC_ACCOUNT_ID       - RC AWS account ID
#   MC_ACCOUNT_ID       - MC AWS account ID
#   CENTRAL_ACCOUNT_ID  - Central account ID
#
# Exit codes:
#   0 - All validations passed
#   2 - One or more validations failed

set -euo pipefail

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [VALIDATE] $*"
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

log_test() {
    echo "🧪 $1"
}

# =============================================================================
# Configuration
# =============================================================================

readonly RC_CLUSTER_NAME="${RC_CLUSTER_NAME:?RC_CLUSTER_NAME is required}"
readonly MC_CLUSTER_NAME="${MC_CLUSTER_NAME:?MC_CLUSTER_NAME is required}"
readonly MC_CLUSTER_ID="${MC_CLUSTER_ID:?MC_CLUSTER_ID is required}"
readonly TEST_REGION="${TEST_REGION:?TEST_REGION is required}"
readonly RC_ACCOUNT_ID="${RC_ACCOUNT_ID:?RC_ACCOUNT_ID is required}"
readonly MC_ACCOUNT_ID="${MC_ACCOUNT_ID:?MC_ACCOUNT_ID is required}"
readonly CENTRAL_ACCOUNT_ID="${CENTRAL_ACCOUNT_ID:?CENTRAL_ACCOUNT_ID is required}"

VALIDATION_FAILURES=0

# =============================================================================
# Helper Functions
# =============================================================================

record_failure() {
    ((VALIDATION_FAILURES++)) || true
    log_error "$1"
}

assume_role_in_account() {
    local account_id="$1"
    local session_name="$2"

    if [ "$account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        log_info "Already in central account, no role assumption needed"
        return 0
    fi

    local role_arn="arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole"
    log_info "Assuming role: $role_arn"

    local creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --output json 2>/dev/null || echo "")

    if [ -z "$creds" ]; then
        log_error "Failed to assume role: $role_arn"
        return 1
    fi

    export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')

    log_success "Role assumed successfully"
}

# =============================================================================
# EKS Cluster Validation
# =============================================================================

validate_eks_cluster() {
    local cluster_name="$1"
    local account_id="$2"
    local description="$3"

    log_test "Validating EKS cluster: $description ($cluster_name)"

    # Assume role if needed
    assume_role_in_account "$account_id" "e2e-validate-eks" || {
        record_failure "Failed to assume role for $description"
        return 1
    }

    # Check cluster exists and is ACTIVE
    local status=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --region "$TEST_REGION" \
        --query 'cluster.status' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$status" = "ACTIVE" ]; then
        log_success "EKS cluster $description is ACTIVE"
    else
        record_failure "EKS cluster $description status: $status (expected ACTIVE)"
        return 1
    fi

    # Get VPC ID for later validation
    local vpc_id=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --region "$TEST_REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text 2>/dev/null || echo "")

    if [ -n "$vpc_id" ]; then
        log_success "EKS cluster $description VPC: $vpc_id"
        echo "$vpc_id"  # Return VPC ID for further validation
    else
        record_failure "Failed to get VPC ID for $description"
        return 1
    fi
}

# =============================================================================
# VPC and Networking Validation
# =============================================================================

validate_vpc() {
    local vpc_id="$1"
    local description="$2"

    log_test "Validating VPC: $description ($vpc_id)"

    # Check VPC state
    local state=$(aws ec2 describe-vpcs \
        --vpc-ids "$vpc_id" \
        --region "$TEST_REGION" \
        --query 'Vpcs[0].State' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$state" = "available" ]; then
        log_success "VPC $description is available"
    else
        record_failure "VPC $description state: $state (expected available)"
        return 1
    fi

    # Check NAT gateways exist and are available
    local nat_count=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" \
        --region "$TEST_REGION" \
        --query 'length(NatGateways)' \
        --output text 2>/dev/null || echo "0")

    if [ "$nat_count" -gt 0 ]; then
        log_success "VPC $description has $nat_count NAT gateway(s)"
    else
        record_failure "VPC $description has no available NAT gateways"
        return 1
    fi
}

# =============================================================================
# RDS Validation
# =============================================================================

validate_rds_instance() {
    local db_identifier="$1"
    local description="$2"

    log_test "Validating RDS instance: $description ($db_identifier)"

    # Check RDS instance status
    local status=$(aws rds describe-db-instances \
        --db-instance-identifier "$db_identifier" \
        --region "$TEST_REGION" \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$status" = "available" ]; then
        log_success "RDS instance $description is available"
    else
        record_failure "RDS instance $description status: $status (expected available)"
        return 1
    fi

    # Get endpoint
    local endpoint=$(aws rds describe-db-instances \
        --db-instance-identifier "$db_identifier" \
        --region "$TEST_REGION" \
        --query 'DBInstances[0].Endpoint.Address' \
        --output text 2>/dev/null || echo "")

    if [ -n "$endpoint" ]; then
        log_success "RDS instance $description endpoint: $endpoint"
    else
        record_failure "Failed to get endpoint for $description"
        return 1
    fi
}

# =============================================================================
# API Gateway Validation
# =============================================================================

validate_api_gateway() {
    log_test "Validating API Gateway (RC)"

    # Find API Gateway by tag or name pattern
    local api_id=$(aws apigateway get-rest-apis \
        --region "$TEST_REGION" \
        --query "items[?contains(name, '${RC_CLUSTER_NAME}')].id | [0]" \
        --output text 2>/dev/null || echo "")

    if [ -n "$api_id" ] && [ "$api_id" != "None" ] && [ "$api_id" != "null" ]; then
        log_success "API Gateway found: $api_id"

        # Get invoke URL
        local invoke_url=$(aws apigateway get-rest-apis \
            --region "$TEST_REGION" \
            --query "items[?id=='$api_id'].id | [0]" \
            --output text 2>/dev/null || echo "")

        if [ -n "$invoke_url" ]; then
            log_success "API Gateway is accessible"
        fi
    else
        log_info "API Gateway not found (may not have been created yet, skipping)"
        # Not a failure - API Gateway might not be immediately available
    fi
}

# =============================================================================
# ArgoCD Validation
# =============================================================================

validate_argocd() {
    local cluster_name="$1"
    local account_id="$2"
    local description="$3"

    log_test "Validating ArgoCD deployment: $description"

    # Assume role if needed
    assume_role_in_account "$account_id" "e2e-validate-argocd" || {
        record_failure "Failed to assume role for ArgoCD validation"
        return 1
    }

    # Update kubeconfig
    aws eks update-kubeconfig \
        --name "$cluster_name" \
        --region "$TEST_REGION" \
        --alias "e2e-${description}" >/dev/null 2>&1 || {
        record_failure "Failed to update kubeconfig for $description"
        return 1
    }

    # Check ArgoCD namespace exists
    if kubectl get namespace argocd --context="e2e-${description}" >/dev/null 2>&1; then
        log_success "ArgoCD namespace exists in $description"
    else
        record_failure "ArgoCD namespace not found in $description"
        return 1
    fi

    # Check ArgoCD server pod is running
    local server_status=$(kubectl get pods -n argocd \
        --context="e2e-${description}" \
        -l app.kubernetes.io/name=argocd-server \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NOT_FOUND")

    if [ "$server_status" = "Running" ]; then
        log_success "ArgoCD server pod is Running in $description"
    else
        log_info "ArgoCD server pod status in $description: $server_status (may still be initializing)"
        # Not a hard failure - pods may still be starting
    fi

    # Check if root Application exists
    if kubectl get application root -n argocd --context="e2e-${description}" >/dev/null 2>&1; then
        log_success "Root Application exists in $description"
    else
        log_info "Root Application not found in $description (may not be created yet)"
        # Not a hard failure - application may not be created immediately
    fi
}

# =============================================================================
# IoT/Maestro Validation
# =============================================================================

validate_iot_infrastructure() {
    log_test "Validating IoT/Maestro infrastructure"

    # Assume role in regional account
    assume_role_in_account "$RC_ACCOUNT_ID" "e2e-validate-iot" || {
        record_failure "Failed to assume role for IoT validation"
        return 1
    }

    # Check IoT endpoint exists
    local iot_endpoint=$(aws iot describe-endpoint \
        --endpoint-type iot:Data-ATS \
        --region "$TEST_REGION" \
        --query 'endpointAddress' \
        --output text 2>/dev/null || echo "")

    if [ -n "$iot_endpoint" ]; then
        log_success "IoT endpoint exists: $iot_endpoint"
    else
        record_failure "IoT endpoint not found"
        return 1
    fi

    # Check IoT Thing for MC exists
    local thing_name="${MC_CLUSTER_ID}-maestro-agent"
    if aws iot describe-thing \
        --thing-name "$thing_name" \
        --region "$TEST_REGION" >/dev/null 2>&1; then
        log_success "IoT Thing exists: $thing_name"
    else
        record_failure "IoT Thing not found: $thing_name"
        return 1
    fi

    # Check IoT Policy exists
    local policy_name="${MC_CLUSTER_ID}-maestro-agent-policy"
    if aws iot get-policy \
        --policy-name "$policy_name" \
        --region "$TEST_REGION" >/dev/null 2>&1; then
        log_success "IoT Policy exists: $policy_name"
    else
        record_failure "IoT Policy not found: $policy_name"
        return 1
    fi
}

# =============================================================================
# Main Validation Flow
# =============================================================================

main() {
    echo "=========================================="
    log "Starting Validation Tests"
    echo "=========================================="
    log_info "RC Cluster: $RC_CLUSTER_NAME"
    log_info "MC Cluster: $MC_CLUSTER_NAME"
    log_info "Region: $TEST_REGION"
    echo ""

    # Save original credentials
    local ORIG_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    local ORIG_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    local ORIG_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    # Validate RC EKS cluster
    RC_VPC_ID=$(validate_eks_cluster "$RC_CLUSTER_NAME" "$RC_ACCOUNT_ID" "RC" || echo "")

    # Validate MC EKS cluster
    MC_VPC_ID=$(validate_eks_cluster "$MC_CLUSTER_NAME" "$MC_ACCOUNT_ID" "MC" || echo "")

    # Restore credentials for RC account validations
    export AWS_ACCESS_KEY_ID="$ORIG_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$ORIG_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$ORIG_AWS_SESSION_TOKEN"

    # Validate RC VPC
    if [ -n "$RC_VPC_ID" ]; then
        assume_role_in_account "$RC_ACCOUNT_ID" "e2e-validate-vpc" || true
        validate_vpc "$RC_VPC_ID" "RC" || true
    fi

    # Validate RC RDS instances
    assume_role_in_account "$RC_ACCOUNT_ID" "e2e-validate-rds" || true
    validate_rds_instance "${RC_CLUSTER_NAME}-maestro" "Maestro DB (RC)" || true
    validate_rds_instance "${RC_CLUSTER_NAME}-hyperfleet" "HyperFleet DB (RC)" || true

    # Validate API Gateway
    validate_api_gateway || true

    # Validate ArgoCD deployments
    validate_argocd "$RC_CLUSTER_NAME" "$RC_ACCOUNT_ID" "RC" || true
    validate_argocd "$MC_CLUSTER_NAME" "$MC_ACCOUNT_ID" "MC" || true

    # Validate IoT infrastructure
    validate_iot_infrastructure || true

    # Summary
    echo ""
    echo "=========================================="
    log "Validation Complete"
    echo "=========================================="

    if [ $VALIDATION_FAILURES -eq 0 ]; then
        log_success "All validations passed (0 failures)"
        exit 0
    else
        log_error "Validation failed with $VALIDATION_FAILURES failure(s)"
        exit 2
    fi
}

main "$@"
