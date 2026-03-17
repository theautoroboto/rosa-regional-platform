# RHOBS Verification Guide

Complete guide to verify your RHOBS observability deployment is working correctly.

## Quick Verification

Run the automated verification script:

```bash
./scripts/verify-rhobs.sh <regional-cluster-context> [management-cluster-context]
```

**Example:**

```bash
./scripts/verify-rhobs.sh regional-us-east-1 management-us-east-1-01
```

The script will check:
- ✅ All pods running
- ✅ Services and load balancers provisioned
- ✅ Internal health endpoints
- ✅ S3 buckets accessible
- ✅ Pod Identity configured
- ✅ Management cluster agents running
- ✅ mTLS certificates ready

---

## Manual Verification Steps

If you prefer manual verification or need to troubleshoot specific components:

### 1. Regional Cluster Verification

#### 1.1 Check All Pods Running

```bash
# Switch to regional cluster context
kubectl config use-context <regional-cluster-context>

# Check observability namespace
kubectl get pods -n observability
```

**Expected:** All pods should be `Running` with `1/1` READY

#### 1.2 Check Services and Load Balancers

```bash
kubectl get svc -n observability
```

**Verify:**
- `thanos-receive` has `LoadBalancer` type with EXTERNAL-IP
- `loki-distributor` has `LoadBalancer` type with EXTERNAL-IP

#### 1.3 Get Public Endpoints

```bash
# Save these for testing
export THANOS_ENDPOINT=$(kubectl get svc thanos-receive -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export LOKI_ENDPOINT=$(kubectl get svc loki-distributor -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Thanos Receive: https://$THANOS_ENDPOINT:19291"
echo "Loki Distributor: https://$LOKI_ENDPOINT:3100"
```

#### 1.4 Test Internal Health Endpoints

```bash
# Test Thanos Receive
kubectl run test --image=curlimages/curl --rm -i --restart=Never -- \
  curl -s http://thanos-receive.observability.svc.cluster.local:10902/-/healthy

# Test Loki Distributor
kubectl run test --image=curlimages/curl --rm -i --restart=Never -- \
  curl -s http://loki-distributor.observability.svc.cluster.local:3100/ready

# Test Grafana
kubectl run test --image=curlimages/curl --rm -i --restart=Never -- \
  curl -s http://grafana.observability.svc.cluster.local:3000/api/health
```

**Expected:** All should return success responses

---

### 2. Management Cluster Verification

#### 2.1 Check Agent Pods

```bash
# Switch to management cluster context
kubectl config use-context <management-cluster-context>

# Check pods
kubectl get pods -n observability
```

**Expected:**
- OTEL Collector: 2 replicas running
- Fluent Bit: DaemonSet with pods on all nodes

#### 2.2 Verify mTLS Client Certificate

```bash
# Check certificate status
kubectl get certificate -n observability

# Verify certificate is ready
kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

**Expected:** Should return `True`

#### 2.3 Check Agent Logs for Errors

```bash
# Check OTEL Collector logs
kubectl logs -n observability -l app.kubernetes.io/component=otel-collector --tail=50 | grep -i error

# Check Fluent Bit logs
kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit --tail=50 | grep -i error
```

**Expected:** No critical errors

---

### 3. End-to-End Metrics Verification

#### 3.1 Port-Forward to Grafana

```bash
# On regional cluster
kubectl port-forward -n observability svc/grafana 3000:3000
```

Open browser: http://localhost:3000

**Login:**
- Username: `admin`
- Password: (from your Kubernetes secret)

#### 3.2 Check Data Sources

Navigate to: **Configuration** → **Data Sources**

**Verify:**
- ✅ Thanos datasource exists
- ✅ Loki datasource exists
- ✅ Both show green "Data source is working"

#### 3.3 Query Metrics

**Explore** → **Thanos**

Try these queries:

```promql
# Check metrics from all clusters
up

# Filter by cluster
up{cluster_id="<management-cluster-name>"}

# Check OTEL Collector metrics
otelcol_receiver_accepted_metric_points
```

**Expected:** Should return metrics from your management clusters

#### 3.4 Query Logs

**Explore** → **Loki**

Try these queries:

```logql
# All logs from observability namespace
{namespace="observability"}

# Logs from specific cluster
{cluster="<management-cluster-name>"}

# Logs from OTEL Collector
{pod=~"otel-collector.*"}
```

**Expected:** Should return logs from your management clusters

---

### 4. S3 Storage Verification

#### 4.1 Check Metrics in S3

```bash
# Get bucket name from Terraform
cd terraform/config/regional-cluster
METRICS_BUCKET=$(terraform output -json | jq -r '.rhobs_infrastructure.value[0].metrics_bucket_name')

# List objects (will be empty initially, populated after ~2 hours)
aws s3 ls s3://$METRICS_BUCKET/ --recursive | head -20
```

**Expected:** After 2+ hours, should see Thanos block directories

#### 4.2 Check Logs in S3

```bash
# Get bucket name
LOGS_BUCKET=$(terraform output -json | jq -r '.rhobs_infrastructure.value[0].logs_bucket_name')

# List objects (will be empty initially, populated after ~1 hour)
aws s3 ls s3://$LOGS_BUCKET/ --recursive | head -20
```

**Expected:** After 1+ hour, should see Loki chunk files

---

### 5. mTLS Authentication Verification

#### 5.1 Test Without Certificate (Should Fail)

```bash
# This should be rejected
curl -k https://$THANOS_ENDPOINT:19291/api/v1/receive
```

**Expected:** Connection error or TLS handshake failure (this is good - means mTLS is enforced)

#### 5.2 Test With Certificate (Should Succeed)

```bash
# Extract certificates from management cluster
kubectl get secret rhobs-client-cert -n observability -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/client.crt
kubectl get secret rhobs-client-cert -n observability -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/client.key
kubectl get secret rhobs-client-cert -n observability -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt

# Test with certificate
curl --cert /tmp/client.crt --key /tmp/client.key --cacert /tmp/ca.crt \
  https://$THANOS_ENDPOINT:19291/-/healthy
```

**Expected:** `Thanos is Healthy.` or similar success message

#### 5.3 Verify Certificate CN

```bash
# Check certificate common name matches cluster
openssl x509 -in /tmp/client.crt -noout -subject
```

**Expected:** `subject=CN=<management-cluster-name>`

---

### 6. Performance Checks

#### 6.1 Check Resource Usage

```bash
# Regional cluster pod resources
kubectl top pods -n observability

# Management cluster pod resources
kubectl top pods -n observability
```

**Verify:** Pods are within their resource limits

#### 6.2 Check Cache Hit Rate

```bash
# Check Thanos cache metrics
kubectl exec -n observability deploy/thanos-query -- \
  curl -s localhost:9090/metrics | grep thanos_cache_hits
```

**Expected:** Cache hits > 0 (after running some queries)

---

## Troubleshooting Common Issues

### Issue: Pods Not Running

**Diagnosis:**

```bash
# Check pod status
kubectl describe pod <pod-name> -n observability

# Check pod logs
kubectl logs <pod-name> -n observability

# Check previous pod logs if restarting
kubectl logs <pod-name> -n observability --previous
```

**Common Causes:**
- Image pull errors → Check ECR permissions
- Volume mount errors → Check PVC status
- OOM killed → Increase memory limits in values.yaml
- CrashLoopBackOff → Check application logs

**Fix:**

```bash
# Restart deployment
kubectl rollout restart deployment/<deployment-name> -n observability

# Or delete pod to force recreation
kubectl delete pod <pod-name> -n observability
```

---

### Issue: No Metrics Flowing

**Diagnosis:**

```bash
# Check OTEL Collector logs
kubectl logs -n observability -l app.kubernetes.io/component=otel-collector | grep -i error

# Check if Prometheus is being scraped
kubectl logs -n observability -l app.kubernetes.io/component=otel-collector | grep "prometheus"

# Check remote write errors
kubectl logs -n observability -l app.kubernetes.io/component=otel-collector | grep "remote.write"
```

**Common Causes:**
- Wrong Thanos endpoint URL in values
- Certificate not mounted properly
- Network connectivity issues
- Prometheus not running in cluster

**Fix:**

```bash
# Verify configuration
kubectl get configmap -n observability <otel-configmap> -o yaml

# Check certificate secret exists
kubectl get secret rhobs-client-cert -n observability

# Restart OTEL Collector
kubectl rollout restart deployment/otel-collector -n observability
```

---

### Issue: No Logs Flowing

**Diagnosis:**

```bash
# Check Fluent Bit logs
kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit --tail=100 | grep -E "error|fail"

# Check if logs are being tailed
kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit | grep "inotify"

# Check Loki connection
kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit | grep "loki"
```

**Common Causes:**
- Log path not accessible (`/var/log/containers/`)
- Certificate issues
- Loki endpoint unreachable
- Parser configuration errors

**Fix:**

```bash
# Verify Fluent Bit can access logs
kubectl exec -n observability <fluent-bit-pod> -- ls -la /var/log/containers/

# Check Fluent Bit configuration
kubectl get configmap fluent-bit-config -n observability -o yaml

# Restart Fluent Bit
kubectl rollout restart daemonset/fluent-bit -n observability
```

---

### Issue: S3 Upload Failures

**Diagnosis:**

```bash
# Check Thanos logs for S3 errors
kubectl logs -n observability thanos-receive-0 | grep -i s3

# Check Loki logs for S3 errors
kubectl logs -n observability -l app.kubernetes.io/component=loki-ingester | grep -i s3

# Test S3 access from pod
kubectl exec -it -n observability thanos-receive-0 -- \
  aws s3 ls s3://<metrics-bucket>/
```

**Common Causes:**
- Pod Identity not configured
- IAM role missing permissions
- S3 bucket doesn't exist
- Wrong AWS region

**Fix:**

```bash
# Verify ServiceAccount annotations
kubectl get sa thanos -n observability -o yaml | grep eks.amazonaws.com/role-arn

# Check IAM role trust policy
aws iam get-role --role-name <rhobs-thanos-role-name>

# Verify Pod Identity association
aws eks list-pod-identity-associations --cluster-name <cluster-name>

# Restart pods to pick up new IAM configuration
kubectl rollout restart statefulset/thanos-receive -n observability
```

---

### Issue: Certificate Not Ready

**Diagnosis:**

```bash
# Check certificate status
kubectl describe certificate rhobs-client-cert -n observability

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check if CA issuer exists
kubectl get clusterissuer rhobs-ca-issuer
```

**Common Causes:**
- cert-manager not installed
- CA issuer not created
- CA secret missing
- Certificate request failed

**Fix:**

```bash
# Recreate certificate
kubectl delete certificate rhobs-client-cert -n observability

# cert-manager will automatically recreate it

# Or manually approve certificate request
kubectl get certificaterequest -n observability
kubectl certificate approve <request-name>
```

---

### Issue: Grafana Shows "No Data"

**Diagnosis:**

```bash
# Test Thanos Query directly
kubectl port-forward -n observability svc/thanos-query 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq

# Test Loki Query directly
kubectl port-forward -n observability svc/loki-query-frontend 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/query_range?query={pod="test"}' | jq
```

**Common Causes:**
- No data ingested yet (wait 2-5 minutes)
- Datasource configuration wrong
- Query syntax errors
- Time range too narrow

**Fix:**

```bash
# In Grafana, check datasource settings
# - Thanos: http://thanos-query.observability.svc.cluster.local:9090
# - Loki: http://loki-query-frontend.observability.svc.cluster.local:3100

# Refresh datasources
# Configuration → Data Sources → Test

# Try wider time range (Last 1 hour instead of Last 5 minutes)
```

---

## Quick Reference Commands

### Get All Component Status

```bash
# Regional cluster
kubectl get all -n observability

# Management cluster
kubectl get all -n observability
```

### View All Logs

```bash
# All regional cluster logs
kubectl logs -n observability --all-containers=true --since=10m

# Specific component
kubectl logs -n observability -l app.kubernetes.io/component=thanos-receive --tail=100
```

### Check Events

```bash
# Recent events
kubectl get events -n observability --sort-by='.lastTimestamp'

# Warning events only
kubectl get events -n observability --field-selector type=Warning
```

### Port-Forward All Services

```bash
# Grafana
kubectl port-forward -n observability svc/grafana 3000:3000 &

# Thanos Query
kubectl port-forward -n observability svc/thanos-query 9090:9090 &

# Loki Query Frontend
kubectl port-forward -n observability svc/loki-query-frontend 3100:3100 &
```

---

## Verification Checklist

Use this checklist to track your verification progress:

### Infrastructure

- [ ] S3 metrics bucket exists and accessible
- [ ] S3 logs bucket exists and accessible
- [ ] ElastiCache cluster status is `available`
- [ ] IAM roles created with correct trust policies
- [ ] Pod Identity associations configured

### Regional Cluster

- [ ] All pods in `observability` namespace are `Running`
- [ ] Thanos Receive has LoadBalancer with EXTERNAL-IP
- [ ] Loki Distributor has LoadBalancer with EXTERNAL-IP
- [ ] Internal health checks return OK
- [ ] Grafana is accessible via port-forward

### Management Cluster

- [ ] OTEL Collector deployment has desired replicas running
- [ ] Fluent Bit DaemonSet has pods on all nodes
- [ ] mTLS client certificate status is `Ready`
- [ ] Certificate expires > 30 days in future
- [ ] No errors in OTEL Collector logs
- [ ] No errors in Fluent Bit logs

### Data Flow

- [ ] Metrics queryable in Grafana from management clusters
- [ ] Logs queryable in Grafana from management clusters
- [ ] Cluster labels correctly identify source clusters
- [ ] Metrics data visible in S3 (after ~2 hours)
- [ ] Logs data visible in S3 (after ~1 hour)

### Security

- [ ] mTLS enforced (connections without cert fail)
- [ ] Connections with valid cert succeed
- [ ] Certificate CN matches cluster name
- [ ] Pod Identity grants S3 access (no static credentials)

---

## Next Steps After Successful Verification

1. **Set Up Dashboards**
   - Import community dashboards for Kubernetes
   - Create custom dashboards for your applications
   - Configure dashboard permissions

2. **Configure Alerting**
   - Set up Alertmanager receivers (PagerDuty, Slack)
   - Create alert rules for critical metrics
   - Test alert routing

3. **Enable Production Features**
   - Multi-AZ for RDS (if using)
   - External CA instead of self-signed
   - S3 versioning for compliance
   - Longer retention periods

4. **Monitor Resource Usage**
   - Set up alerts for pod resource limits
   - Configure horizontal pod autoscaling
   - Plan for storage growth

5. **Documentation**
   - Document custom dashboards
   - Create runbooks for common alerts
   - Train team on Grafana usage

---

## Support and Feedback

If you encounter issues not covered in this guide:

1. Check component logs for detailed error messages
2. Review the [RHOBS Setup Guide](RHOBS-SETUP.md)
3. Consult Thanos/Loki documentation for component-specific issues
4. Report issues at: https://github.com/anthropics/claude-code/issues
