#!/usr/bin/env bash
# Verify RHOBS metrics and logs flow from management clusters
# Called from: terraform/config/pipeline-regional-cluster/buildspec-verify-rhobs.yml
set -euo pipefail

echo "=========================================="
echo "RHOBS Verification"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Pre-flight setup (validates env vars, inits account helpers)
source scripts/pipeline-common/setup-apply-preflight.sh

# Read delete flag from config
ENVIRONMENT="${ENVIRONMENT:-staging}"
RC_CONFIG_FILE="deploy/${ENVIRONMENT}/${TARGET_REGION}/terraform/regional.json"
if [ ! -f "$RC_CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $RC_CONFIG_FILE" >&2
    exit 1
fi
DELETE_FLAG=$(jq -r '.delete // false' "$RC_CONFIG_FILE")
[ "${IS_DESTROY:-false}" == "true" ] && DELETE_FLAG="true"

if [ "${DELETE_FLAG}" == "true" ]; then
    echo "Cluster is being destroyed - skipping RHOBS verification"
    exit 0
fi

# Assume target account role
use_mc_account
echo ""

echo "Verifying RHOBS deployment: ${REGIONAL_ID} in ${TARGET_REGION}"
echo ""

# Initialize Terraform backend to get outputs
./scripts/pipeline-common/init-terraform-backend.sh regional-cluster "${TARGET_REGION}" "${REGIONAL_ID}"

# Get cluster context
CLUSTER_NAME="${REGIONAL_ID}"
REGION="${TARGET_REGION}"

echo "Updating kubeconfig for cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}"

# Verification parameters
MAX_RETRIES=30  # 5 minutes with 10-second intervals
RETRY_INTERVAL=10
METRICS_FOUND=false
LOGS_FOUND=false

echo ""
echo "================================================"
echo "Step 1: Verify RHOBS Infrastructure"
echo "================================================"

# Check if observability namespace exists
if ! kubectl get namespace observability > /dev/null 2>&1; then
    echo "ERROR: observability namespace not found"
    echo "RHOBS may not be deployed yet. Deploy RHOBS stack first."
    exit 1
fi
echo "✓ observability namespace exists"

# Check if key pods are running
echo ""
echo "Checking RHOBS component pods..."
REQUIRED_COMPONENTS=(
    "thanos-receive"
    "thanos-query"
    "loki-distributor"
    "loki-querier"
    "grafana"
)

for component in "${REQUIRED_COMPONENTS[@]}"; do
    if kubectl get pods -n observability -l "app.kubernetes.io/component=${component}" --no-headers 2>/dev/null | grep -q Running; then
        echo "✓ ${component} pods are running"
    else
        echo "✗ ${component} pods not found or not running"
        kubectl get pods -n observability -l "app.kubernetes.io/component=${component}" 2>/dev/null || true
        exit 1
    fi
done

echo ""
echo "================================================"
echo "Step 2: Wait for Metrics Flow"
echo "================================================"

# Port-forward to Thanos Query
echo "Setting up port-forward to Thanos Query..."
kubectl port-forward -n observability svc/thanos-query 9090:9090 > /dev/null 2>&1 &
PF_PID=$!
sleep 5

# Verify port-forward is active
if ! kill -0 $PF_PID 2>/dev/null; then
    echo "ERROR: Failed to establish port-forward to Thanos Query"
    exit 1
fi

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up port-forwards..."
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Querying Thanos for metrics from management clusters..."
echo "This may take a few minutes for metrics to start flowing..."
echo ""

for i in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $i/$MAX_RETRIES: Querying for 'up' metric..."

    # Query Thanos for any 'up' metric with cluster_id label
    RESPONSE=$(curl -s "http://localhost:9090/api/v1/query?query=up{cluster_id=~\".+\"}" || echo "")

    if [ -z "$RESPONSE" ]; then
        echo "  ⚠ No response from Thanos API"
    else
        # Check if we got actual metric data
        RESULT_TYPE=$(echo "$RESPONSE" | jq -r '.data.resultType // "none"' 2>/dev/null || echo "none")
        RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [ "$RESULT_TYPE" = "vector" ] && [ "$RESULT_COUNT" -gt 0 ]; then
            echo "  ✓ Found metrics from management clusters!"
            echo ""
            echo "Metric details:"
            echo "$RESPONSE" | jq -r '.data.result[] | "  - cluster_id: \(.metric.cluster_id // "unknown"), job: \(.metric.job // "unknown"), value: \(.value[1])"' 2>/dev/null | head -10
            METRICS_FOUND=true
            break
        else
            echo "  ⚠ No metrics found yet (resultType=$RESULT_TYPE, count=$RESULT_COUNT)"
        fi
    fi

    if [ $i -lt $MAX_RETRIES ]; then
        echo "  Waiting ${RETRY_INTERVAL}s before retry..."
        sleep $RETRY_INTERVAL
    fi
done

echo ""
if [ "$METRICS_FOUND" = false ]; then
    echo "✗ FAILED: No metrics received from management clusters after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check OTEL Collector logs on management clusters:"
    echo "     kubectl logs -n observability -l app.kubernetes.io/component=otel-collector"
    echo "  2. Verify mTLS certificates are ready:"
    echo "     kubectl get certificate -n observability"
    echo "  3. Check Thanos Receive logs:"
    echo "     kubectl logs -n observability -l app.kubernetes.io/component=thanos-receive"
    exit 1
fi

echo ""
echo "================================================"
echo "Step 3: Wait for Logs Flow"
echo "================================================"

# Kill existing port-forward and create new one for Loki
kill $PF_PID 2>/dev/null || true
sleep 2

echo "Setting up port-forward to Loki Query Frontend..."
kubectl port-forward -n observability svc/loki-query-frontend 3100:3100 > /dev/null 2>&1 &
PF_PID=$!
sleep 5

if ! kill -0 $PF_PID 2>/dev/null; then
    echo "ERROR: Failed to establish port-forward to Loki Query Frontend"
    exit 1
fi

echo "Querying Loki for logs from management clusters..."
echo ""

# Calculate time range (last 5 minutes)
END_TIME=$(date +%s)000000000  # nanoseconds
START_TIME=$((END_TIME - 300000000000))  # 5 minutes ago

for i in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $i/$MAX_RETRIES: Querying for logs with cluster label..."

    # Query Loki for any logs with cluster label
    QUERY='{cluster=~".+"}'
    ENCODED_QUERY=$(printf '%s' "$QUERY" | jq -sRr @uri)

    RESPONSE=$(curl -s "http://localhost:3100/loki/api/v1/query_range?query=${ENCODED_QUERY}&start=${START_TIME}&end=${END_TIME}&limit=100" || echo "")

    if [ -z "$RESPONSE" ]; then
        echo "  ⚠ No response from Loki API"
    else
        # Check if we got actual log data
        RESULT_TYPE=$(echo "$RESPONSE" | jq -r '.data.resultType // "none"' 2>/dev/null || echo "none")
        RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [ "$RESULT_TYPE" = "streams" ] && [ "$RESULT_COUNT" -gt 0 ]; then
            echo "  ✓ Found logs from management clusters!"
            echo ""
            echo "Log stream details:"
            echo "$RESPONSE" | jq -r '.data.result[] | "  - cluster: \(.stream.cluster // "unknown"), namespace: \(.stream.namespace // "unknown"), pod: \(.stream.pod // "unknown")"' 2>/dev/null | head -10
            LOGS_FOUND=true
            break
        else
            echo "  ⚠ No logs found yet (resultType=$RESULT_TYPE, count=$RESULT_COUNT)"
        fi
    fi

    if [ $i -lt $MAX_RETRIES ]; then
        echo "  Waiting ${RETRY_INTERVAL}s before retry..."
        sleep $RETRY_INTERVAL
    fi
done

echo ""
if [ "$LOGS_FOUND" = false ]; then
    echo "✗ FAILED: No logs received from management clusters after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check Fluent Bit logs on management clusters:"
    echo "     kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit"
    echo "  2. Verify mTLS certificates are ready:"
    echo "     kubectl get certificate -n observability"
    echo "  3. Check Loki Distributor logs:"
    echo "     kubectl logs -n observability -l app.kubernetes.io/component=loki-distributor"
    exit 1
fi

echo ""
echo "================================================"
echo "RHOBS Verification Summary"
echo "================================================"
echo "✓ Metrics flowing from management clusters"
echo "✓ Logs flowing from management clusters"
echo "✓ RHOBS stack is operational"
echo ""
echo "Next steps:"
echo "  - Access Grafana: kubectl port-forward -n observability svc/grafana 3000:3000"
echo "  - Create dashboards for your applications"
echo "  - Set up alerting rules"
echo ""
echo "RHOBS verification completed successfully!"
