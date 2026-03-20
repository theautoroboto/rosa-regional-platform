#!/bin/bash
# Test script for Thanos Receive
# Usage: ./test-thanos-receive.sh [deploy|test|query|cleanup|all]

set -e

NAMESPACE="thanos-test"
RELEASE_NAME="thanos-test"
RECEIVE_PORT=19291
QUERY_PORT=9090
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Install from https://helm.sh/docs/intro/install/"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Install from https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    log_info "Prerequisites OK"
}

deploy() {
    log_info "Deploying Thanos Receive to namespace: $NAMESPACE"

    # Add Bitnami repo
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update

    # Create namespace if not exists
    kubectl create namespace $NAMESPACE 2>/dev/null || true

    # Install Thanos with minimal config (Receive + Query only)
    helm upgrade --install $RELEASE_NAME bitnami/thanos \
        -n $NAMESPACE \
        --set receive.enabled=true \
        --set receive.replicaCount=1 \
        --set receive.persistence.enabled=true \
        --set receive.persistence.size=10Gi \
        --set receive.extraFlags="{--tsdb.retention=2h}" \
        --set query.enabled=true \
        --set query.replicaCount=1 \
        --set query.stores="{dnssrv+_grpc._tcp.$RELEASE_NAME-receive-headless.$NAMESPACE.svc.cluster.local}" \
        --set queryFrontend.enabled=false \
        --set storegateway.enabled=false \
        --set compactor.enabled=false \
        --set ruler.enabled=false \
        --set minio.enabled=false \
        --set objstoreConfig="" \
        --wait \
        --timeout 5m

    log_info "Deployment complete. Waiting for pods..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=receive -n $NAMESPACE --timeout=120s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=query -n $NAMESPACE --timeout=120s

    log_info "All pods ready:"
    kubectl get pods -n $NAMESPACE
}

start_port_forwards() {
    log_info "Starting port-forwards..."

    # Kill any existing port-forwards
    pkill -f "port-forward.*$NAMESPACE" 2>/dev/null || true
    sleep 1

    # Start port-forwards in background
    kubectl port-forward svc/$RELEASE_NAME-receive $RECEIVE_PORT:19291 -n $NAMESPACE &
    PF_RECEIVE_PID=$!

    kubectl port-forward svc/$RELEASE_NAME-query $QUERY_PORT:9090 -n $NAMESPACE &
    PF_QUERY_PID=$!

    # Wait for port-forwards to be ready
    sleep 3

    # Verify they're running
    if ! kill -0 $PF_RECEIVE_PID 2>/dev/null; then
        log_error "Failed to start port-forward for Receive"
        exit 1
    fi

    if ! kill -0 $PF_QUERY_PID 2>/dev/null; then
        log_error "Failed to start port-forward for Query"
        exit 1
    fi

    log_info "Port-forwards active:"
    log_info "  Receive: http://localhost:$RECEIVE_PORT"
    log_info "  Query:   http://localhost:$QUERY_PORT"
}

stop_port_forwards() {
    log_info "Stopping port-forwards..."
    pkill -f "port-forward.*$NAMESPACE" 2>/dev/null || true
}

send_test_metric() {
    log_info "Sending test metric to Thanos Receive..."

    # Check if Go is available
    if command -v go &> /dev/null; then
        cd "$SCRIPT_DIR"
        go run main.go --endpoint "http://localhost:$RECEIVE_PORT/api/v1/receive"
    else
        log_warn "Go not found, using curl fallback..."

        # Create a simple test using curl and the text format
        # Note: Thanos Receive expects protobuf, but we can test connectivity
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "http://localhost:$RECEIVE_PORT/api/v1/receive" \
            -H "Content-Type: application/x-protobuf" \
            -d '' 2>/dev/null || echo "000")

        if [ "$RESPONSE" = "000" ]; then
            log_error "Cannot connect to Thanos Receive at localhost:$RECEIVE_PORT"
            return 1
        elif [ "$RESPONSE" = "400" ]; then
            log_info "Thanos Receive is responding (got 400 - expected without proper protobuf)"
            log_warn "Install Go and run 'go run main.go' for full test"
        else
            log_info "Thanos Receive response code: $RESPONSE"
        fi
    fi
}

query_metric() {
    log_info "Querying test_metric from Thanos Query..."

    RESULT=$(curl -s "http://localhost:$QUERY_PORT/api/v1/query?query=test_metric")

    if echo "$RESULT" | grep -q '"status":"success"'; then
        log_info "Query successful!"
        echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"

        # Check if we got data
        if echo "$RESULT" | grep -q '"result":\[\]'; then
            log_warn "No data found. Make sure you sent a test metric first."
        fi
    else
        log_error "Query failed:"
        echo "$RESULT"
    fi
}

query_all_metrics() {
    log_info "Querying all available metrics..."

    curl -s "http://localhost:$QUERY_PORT/api/v1/label/__name__/values" | jq . 2>/dev/null
}

check_status() {
    log_info "Checking Thanos status..."

    echo ""
    log_info "Pods:"
    kubectl get pods -n $NAMESPACE -o wide

    echo ""
    log_info "Services:"
    kubectl get svc -n $NAMESPACE

    echo ""
    log_info "Receive targets (from Query):"
    curl -s "http://localhost:$QUERY_PORT/api/v1/targets" 2>/dev/null | jq '.data.activeTargets | length' 2>/dev/null || echo "Cannot connect to Query"

    echo ""
    log_info "Store endpoints:"
    curl -s "http://localhost:$QUERY_PORT/api/v1/stores" 2>/dev/null | jq . 2>/dev/null || echo "Cannot connect to Query"
}

cleanup() {
    log_info "Cleaning up..."

    stop_port_forwards

    helm uninstall $RELEASE_NAME -n $NAMESPACE 2>/dev/null || true
    kubectl delete namespace $NAMESPACE 2>/dev/null || true

    log_info "Cleanup complete"
}

run_all() {
    check_prerequisites
    deploy
    start_port_forwards
    sleep 2
    send_test_metric
    sleep 2
    query_metric

    echo ""
    log_info "Test complete! Port-forwards are still running."
    log_info "Press Ctrl+C to stop, or run: $0 cleanup"

    # Keep script running to maintain port-forwards
    wait
}

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy     - Deploy Thanos Receive + Query to Kubernetes"
    echo "  pf         - Start port-forwards (Receive:$RECEIVE_PORT, Query:$QUERY_PORT)"
    echo "  test       - Send a test metric to Thanos Receive"
    echo "  query      - Query test_metric from Thanos Query"
    echo "  metrics    - List all available metrics"
    echo "  status     - Check deployment status"
    echo "  cleanup    - Remove deployment and namespace"
    echo "  all        - Run full test (deploy, test, query)"
    echo ""
    echo "Example:"
    echo "  $0 all      # Full automated test"
    echo "  $0 deploy   # Just deploy"
    echo "  $0 cleanup  # Remove everything"
}

# Main
case "${1:-}" in
    deploy)
        check_prerequisites
        deploy
        ;;
    pf|port-forward)
        start_port_forwards
        wait
        ;;
    test|send)
        send_test_metric
        ;;
    query)
        query_metric
        ;;
    metrics)
        query_all_metrics
        ;;
    status)
        check_status
        ;;
    cleanup|clean)
        cleanup
        ;;
    all)
        run_all
        ;;
    *)
        usage
        exit 1
        ;;
esac
