#!/bin/bash
set -e

# RHOBS Verification Script
# Automated checks for RHOBS observability deployment

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ERRORS=0

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_pass() {
  echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
  echo -e "${RED}✗${NC} $1"
  ERRORS=$((ERRORS + 1))
}

check_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

# Parse arguments
REGIONAL_CONTEXT=${1:-}
MANAGEMENT_CONTEXT=${2:-}

if [ -z "$REGIONAL_CONTEXT" ]; then
  echo "Usage: $0 <regional-cluster-context> [management-cluster-context]"
  echo ""
  echo "Example:"
  echo "  $0 regional-us-east-1 management-us-east-1-01"
  echo ""
  exit 1
fi

print_header "🔍 RHOBS Verification Script"
echo "Regional Context: $REGIONAL_CONTEXT"
[ -n "$MANAGEMENT_CONTEXT" ] && echo "Management Context: $MANAGEMENT_CONTEXT"

# ============================================================================
# 1. Regional Cluster Checks
# ============================================================================

print_header "1. Regional Cluster - Infrastructure"

# Switch to regional context
kubectl config use-context "$REGIONAL_CONTEXT" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  check_fail "Failed to switch to regional context: $REGIONAL_CONTEXT"
  exit 1
fi
check_pass "Switched to regional cluster context"

# Check namespace exists
if kubectl get namespace observability > /dev/null 2>&1; then
  check_pass "Namespace 'observability' exists"
else
  check_fail "Namespace 'observability' not found"
  exit 1
fi

# ============================================================================
# 2. Pod Status Checks
# ============================================================================

print_header "2. Regional Cluster - Pod Status"

# Check all pods are running
NOT_RUNNING=$(kubectl get pods -n observability --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | wc -l)
if [ "$NOT_RUNNING" -eq 0 ]; then
  TOTAL_PODS=$(kubectl get pods -n observability --no-headers 2>/dev/null | wc -l)
  check_pass "All $TOTAL_PODS pods are running"
else
  check_fail "$NOT_RUNNING pods are not in Running state"
  kubectl get pods -n observability | grep -v Running
fi

# Check specific components
for component in thanos-receive thanos-query thanos-store loki-distributor loki-querier grafana; do
  if kubectl get pods -n observability -l app.kubernetes.io/component=$component --no-headers 2>/dev/null | grep -q Running; then
    check_pass "$component pods are running"
  else
    check_fail "$component pods not found or not running"
  fi
done

# ============================================================================
# 3. Service and Load Balancer Checks
# ============================================================================

print_header "3. Regional Cluster - Services"

# Check Thanos Receive NLB
THANOS_LB=$(kubectl get svc thanos-receive -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$THANOS_LB" ]; then
  check_pass "Thanos Receive NLB: $THANOS_LB"
  echo "   Endpoint: https://$THANOS_LB:19291"
else
  check_fail "Thanos Receive LoadBalancer not provisioned"
fi

# Check Loki Distributor NLB
LOKI_LB=$(kubectl get svc loki-distributor -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$LOKI_LB" ]; then
  check_pass "Loki Distributor NLB: $LOKI_LB"
  echo "   Endpoint: https://$LOKI_LB:3100"
else
  check_fail "Loki Distributor LoadBalancer not provisioned"
fi

# Check internal services
for svc in thanos-query loki-query-frontend grafana; do
  if kubectl get svc $svc -n observability > /dev/null 2>&1; then
    check_pass "Service '$svc' exists"
  else
    check_fail "Service '$svc' not found"
  fi
done

# ============================================================================
# 4. Internal Health Checks
# ============================================================================

print_header "4. Regional Cluster - Health Checks"

# Test Thanos Receive health
echo -n "Testing Thanos Receive health... "
if kubectl run verify-thanos --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://thanos-receive.observability.svc.cluster.local:10902/-/healthy > /dev/null 2>&1; then
  check_pass "Thanos Receive is healthy"
else
  check_fail "Thanos Receive health check failed"
fi

# Test Loki Distributor health
echo -n "Testing Loki Distributor health... "
if kubectl run verify-loki --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://loki-distributor.observability.svc.cluster.local:3100/ready > /dev/null 2>&1; then
  check_pass "Loki Distributor is healthy"
else
  check_fail "Loki Distributor health check failed"
fi

# Test Grafana health
echo -n "Testing Grafana health... "
if kubectl run verify-grafana --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://grafana.observability.svc.cluster.local:3000/api/health > /dev/null 2>&1; then
  check_pass "Grafana is healthy"
else
  check_fail "Grafana health check failed"
fi

# ============================================================================
# 5. S3 Bucket Checks
# ============================================================================

print_header "5. Storage - S3 Buckets"

# Try to get bucket names from Terraform
if [ -f "terraform/config/regional-cluster/terraform.tfstate" ]; then
  METRICS_BUCKET=$(cd terraform/config/regional-cluster && terraform output -json 2>/dev/null | jq -r '.rhobs_infrastructure.value[0].metrics_bucket_name' 2>/dev/null)
  LOGS_BUCKET=$(cd terraform/config/regional-cluster && terraform output -json 2>/dev/null | jq -r '.rhobs_infrastructure.value[0].logs_bucket_name' 2>/dev/null)

  if [ -n "$METRICS_BUCKET" ] && [ "$METRICS_BUCKET" != "null" ]; then
    if aws s3 ls s3://$METRICS_BUCKET > /dev/null 2>&1; then
      check_pass "Metrics bucket accessible: $METRICS_BUCKET"
    else
      check_fail "Cannot access metrics bucket: $METRICS_BUCKET"
    fi
  else
    check_warn "Metrics bucket name not found in Terraform state"
  fi

  if [ -n "$LOGS_BUCKET" ] && [ "$LOGS_BUCKET" != "null" ]; then
    if aws s3 ls s3://$LOGS_BUCKET > /dev/null 2>&1; then
      check_pass "Logs bucket accessible: $LOGS_BUCKET"
    else
      check_fail "Cannot access logs bucket: $LOGS_BUCKET"
    fi
  else
    check_warn "Logs bucket name not found in Terraform state"
  fi
else
  check_warn "Terraform state not found - skipping S3 checks"
fi

# ============================================================================
# 6. Pod Identity Checks
# ============================================================================

print_header "6. IAM - Pod Identity"

# Check ServiceAccount annotations
THANOS_SA_ROLE=$(kubectl get sa thanos -n observability -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
if [ -n "$THANOS_SA_ROLE" ]; then
  check_pass "Thanos ServiceAccount has IAM role: $THANOS_SA_ROLE"
else
  check_fail "Thanos ServiceAccount missing IAM role annotation"
fi

LOKI_SA_ROLE=$(kubectl get sa loki -n observability -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
if [ -n "$LOKI_SA_ROLE" ]; then
  check_pass "Loki ServiceAccount has IAM role: $LOKI_SA_ROLE"
else
  check_fail "Loki ServiceAccount missing IAM role annotation"
fi

# ============================================================================
# 7. Management Cluster Checks (if context provided)
# ============================================================================

if [ -n "$MANAGEMENT_CONTEXT" ]; then
  print_header "7. Management Cluster - Agent Status"

  kubectl config use-context "$MANAGEMENT_CONTEXT" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    check_fail "Failed to switch to management context: $MANAGEMENT_CONTEXT"
  else
    check_pass "Switched to management cluster context"

    # Check namespace
    if kubectl get namespace observability > /dev/null 2>&1; then
      check_pass "Namespace 'observability' exists"
    else
      check_fail "Namespace 'observability' not found"
    fi

    # Check OTEL Collector
    OTEL_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/component=otel-collector --no-headers 2>/dev/null | grep Running | wc -l)
    if [ "$OTEL_PODS" -gt 0 ]; then
      check_pass "OTEL Collector running ($OTEL_PODS pods)"
    else
      check_fail "OTEL Collector pods not running"
    fi

    # Check Fluent Bit
    FB_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/component=fluent-bit --no-headers 2>/dev/null | grep Running | wc -l)
    if [ "$FB_PODS" -gt 0 ]; then
      check_pass "Fluent Bit running ($FB_PODS pods)"
    else
      check_fail "Fluent Bit pods not running"
    fi

    # Check mTLS certificate
    if kubectl get certificate rhobs-client-cert -n observability > /dev/null 2>&1; then
      CERT_READY=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$CERT_READY" = "True" ]; then
        check_pass "mTLS client certificate is ready"

        # Check expiry
        NOT_AFTER=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.notAfter}' 2>/dev/null)
        if [ -n "$NOT_AFTER" ]; then
          echo "   Expires: $NOT_AFTER"
        fi
      else
        check_fail "mTLS client certificate not ready"
      fi
    else
      check_fail "mTLS client certificate not found"
    fi
  fi
fi

# ============================================================================
# Summary
# ============================================================================

print_header "Summary"

if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed!${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Access Grafana: kubectl port-forward -n observability svc/grafana 3000:3000"
  echo "  2. Test queries in Grafana Explore"
  echo "  3. Verify metrics/logs flowing from management clusters"
  exit 0
else
  echo -e "${RED}✗ $ERRORS check(s) failed${NC}"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Check pod logs: kubectl logs -n observability <pod-name>"
  echo "  2. Check events: kubectl get events -n observability"
  echo "  3. Review setup guide: docs/RHOBS-SETUP.md"
  exit 1
fi
