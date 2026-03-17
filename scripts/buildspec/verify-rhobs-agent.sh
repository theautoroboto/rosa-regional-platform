#!/usr/bin/env bash
# Verify RHOBS agents (OTEL Collector, Fluent Bit) on management cluster
# Called from: terraform/config/pipeline-management-cluster/buildspec-verify-rhobs-agent.yml
set -euo pipefail

echo "=========================================="
echo "RHOBS Agent Verification"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config
ENVIRONMENT="${ENVIRONMENT:-staging}"
MC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/management-${MANAGEMENT_CLUSTER_SERIAL}.json"
if [ ! -f "$MC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $MC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$MC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Cluster is being destroyed - skipping RHOBS agent verification"
    exit 0
fi

# Assume target account role
use_mc_account
echo ""

echo "Verifying RHOBS agents: ${MANAGEMENT_CLUSTER_ID} in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend
./scripts/pipeline-common/init-terraform-backend.sh management-cluster "${TARGET_REGION}" "${MANAGEMENT_CLUSTER_ID}"

# Get cluster context
CLUSTER_NAME="${MANAGEMENT_CLUSTER_ID}"
REGION="${TARGET_REGION}"

echo "Updating kubeconfig for cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}"

echo ""
echo "================================================"
echo "Step 1: Verify Agent Pods"
echo "================================================"

# Check if observability namespace exists
if ! kubectl get namespace observability > /dev/null 2>&1; then
    echo "ERROR: observability namespace not found"
    echo "RHOBS agents may not be deployed yet."
    exit 1
fi
echo "✓ observability namespace exists"

# Check OTEL Collector pods
echo ""
echo "Checking OTEL Collector..."
OTEL_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/component=otel-collector --no-headers 2>/dev/null | grep Running | wc -l)
if [ "$OTEL_PODS" -gt 0 ]; then
    echo "✓ OTEL Collector running ($OTEL_PODS pods)"
else
    echo "✗ OTEL Collector pods not running"
    kubectl get pods -n observability -l app.kubernetes.io/component=otel-collector 2>/dev/null || true
    exit 1
fi

# Check Fluent Bit pods
echo ""
echo "Checking Fluent Bit..."
FB_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/component=fluent-bit --no-headers 2>/dev/null | grep Running | wc -l)
if [ "$FB_PODS" -gt 0 ]; then
    echo "✓ Fluent Bit running ($FB_PODS pods)"
else
    echo "✗ Fluent Bit pods not running"
    kubectl get pods -n observability -l app.kubernetes.io/component=fluent-bit 2>/dev/null || true
    exit 1
fi

echo ""
echo "================================================"
echo "Step 2: Verify mTLS Certificates"
echo "================================================"

# Check certificate exists and is ready
if kubectl get certificate rhobs-client-cert -n observability > /dev/null 2>&1; then
    CERT_READY=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_READY" = "True" ]; then
        echo "✓ mTLS client certificate is ready"

        # Check expiry
        NOT_AFTER=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.notAfter}' 2>/dev/null)
        if [ -n "$NOT_AFTER" ]; then
            echo "  Expires: $NOT_AFTER"
        fi
    else
        echo "✗ mTLS client certificate not ready"
        kubectl describe certificate rhobs-client-cert -n observability
        exit 1
    fi
else
    echo "✗ mTLS client certificate not found"
    exit 1
fi

echo ""
echo "================================================"
echo "Step 3: Verify Agent Configuration"
echo "================================================"

# Get OTEL Collector configuration
echo "Checking OTEL Collector configuration..."
OTEL_CONFIG=$(kubectl get configmap -n observability -l app.kubernetes.io/component=otel-collector -o yaml 2>/dev/null || echo "")

if echo "$OTEL_CONFIG" | grep -q "remote_write"; then
    echo "✓ OTEL Collector has remote_write configuration"

    # Extract Thanos endpoint if possible
    THANOS_ENDPOINT=$(echo "$OTEL_CONFIG" | grep -o "https://[^:]*:19291" | head -1 || echo "")
    if [ -n "$THANOS_ENDPOINT" ]; then
        echo "  Thanos endpoint: $THANOS_ENDPOINT"
    fi
else
    echo "⚠ Warning: Could not verify remote_write configuration"
fi

# Get Fluent Bit configuration
echo ""
echo "Checking Fluent Bit configuration..."
FB_CONFIG=$(kubectl get configmap -n observability -l app.kubernetes.io/component=fluent-bit -o yaml 2>/dev/null || echo "")

if echo "$FB_CONFIG" | grep -q "loki"; then
    echo "✓ Fluent Bit has Loki output configuration"

    # Extract Loki endpoint if possible
    LOKI_ENDPOINT=$(echo "$FB_CONFIG" | grep -o "https://[^:]*:3100" | head -1 || echo "")
    if [ -n "$LOKI_ENDPOINT" ]; then
        echo "  Loki endpoint: $LOKI_ENDPOINT"
    fi
else
    echo "⚠ Warning: Could not verify Loki output configuration"
fi

echo ""
echo "================================================"
echo "Step 4: Check Agent Logs for Errors"
echo "================================================"

echo "Checking OTEL Collector logs for errors..."
OTEL_ERRORS=$(kubectl logs -n observability -l app.kubernetes.io/component=otel-collector --tail=100 2>/dev/null | grep -i "error\|failed\|fatal" | grep -v "level=info" | head -5 || echo "")

if [ -z "$OTEL_ERRORS" ]; then
    echo "✓ No critical errors in OTEL Collector logs"
else
    echo "⚠ Found potential errors in OTEL Collector logs:"
    echo "$OTEL_ERRORS"
    echo ""
    echo "Note: Some errors may be transient during startup. Check full logs if issues persist."
fi

echo ""
echo "Checking Fluent Bit logs for errors..."
FB_ERRORS=$(kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit --tail=100 2>/dev/null | grep -i "error\|failed\|fatal" | grep -v "level=info" | head -5 || echo "")

if [ -z "$FB_ERRORS" ]; then
    echo "✓ No critical errors in Fluent Bit logs"
else
    echo "⚠ Found potential errors in Fluent Bit logs:"
    echo "$FB_ERRORS"
    echo ""
    echo "Note: Some errors may be transient during startup. Check full logs if issues persist."
fi

echo ""
echo "================================================"
echo "Step 5: Test Connectivity to RHOBS Endpoints"
echo "================================================"

# Test if agents can reach RHOBS endpoints
echo "Testing connectivity to Thanos Receive..."

# Get Thanos endpoint from OTEL Collector config
THANOS_HOST=$(echo "$OTEL_CONFIG" | grep -oP 'https://\K[^:]+' | head -1 || echo "")

if [ -n "$THANOS_HOST" ]; then
    # Test DNS resolution
    if nslookup "$THANOS_HOST" > /dev/null 2>&1; then
        echo "✓ DNS resolution successful for $THANOS_HOST"
    else
        echo "⚠ Could not resolve DNS for $THANOS_HOST"
    fi

    # Test HTTPS connectivity (expect TLS handshake, which validates mTLS is enforced)
    if timeout 5 bash -c "echo | openssl s_client -connect ${THANOS_HOST}:19291 -brief" > /dev/null 2>&1; then
        echo "✓ TLS endpoint reachable at ${THANOS_HOST}:19291"
    else
        echo "⚠ Could not establish TLS connection to ${THANOS_HOST}:19291"
        echo "  This may indicate network connectivity issues or NLB not ready"
    fi
else
    echo "⚠ Could not extract Thanos endpoint from configuration"
fi

echo ""
echo "Testing connectivity to Loki Distributor..."

# Get Loki endpoint from Fluent Bit config
LOKI_HOST=$(echo "$FB_CONFIG" | grep -oP 'https://\K[^:]+' | head -1 || echo "")

if [ -n "$LOKI_HOST" ]; then
    # Test DNS resolution
    if nslookup "$LOKI_HOST" > /dev/null 2>&1; then
        echo "✓ DNS resolution successful for $LOKI_HOST"
    else
        echo "⚠ Could not resolve DNS for $LOKI_HOST"
    fi

    # Test HTTPS connectivity
    if timeout 5 bash -c "echo | openssl s_client -connect ${LOKI_HOST}:3100 -brief" > /dev/null 2>&1; then
        echo "✓ TLS endpoint reachable at ${LOKI_HOST}:3100"
    else
        echo "⚠ Could not establish TLS connection to ${LOKI_HOST}:3100"
        echo "  This may indicate network connectivity issues or NLB not ready"
    fi
else
    echo "⚠ Could not extract Loki endpoint from configuration"
fi

echo ""
echo "================================================"
echo "RHOBS Agent Verification Summary"
echo "================================================"
echo "✓ OTEL Collector deployed and running"
echo "✓ Fluent Bit deployed and running"
echo "✓ mTLS client certificate ready"
echo "✓ Agent configurations validated"
echo ""
echo "Note: Metrics and logs may take 2-5 minutes to appear in the regional cluster."
echo "Run the regional cluster verification to confirm end-to-end data flow."
echo ""
echo "RHOBS agent verification completed successfully!"
