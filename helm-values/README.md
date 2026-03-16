# RHOBS on EKS - Helm Values

This directory contains Helm values files for deploying a RHOBS-equivalent observability stack on Amazon EKS.

## Architecture Overview

```
+------------------------------------------------------------------+
|                      RHOBS Cell (EKS)                            |
|  +------------------------------------------------------------+  |
|  |  Gateway (nginx + OPA) - mTLS for writers, OIDC for readers|  |
|  +------------------------------------------------------------+  |
|  |  Thanos (Receive/Query/Store/Compact) -> S3               |  |
|  +------------------------------------------------------------+  |
|  |  Loki (Distributor/Ingester/Querier) -> S3                |  |
|  +------------------------------------------------------------+  |
|  |  Alertmanager -> PagerDuty/Slack                          |  |
|  +------------------------------------------------------------+  |
|  |  Grafana (OIDC auth, regional datasources)                |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
         ^                    ^                    ^
         | Prometheus         | Loki               |
         | remote-write       | push               |
+--------+---------+----------+---------+----------+---------+
|  Fleet EKS Clusters                                        |
|  +------------------+  +------------------+                |
|  | OTEL Collector   |  | Fluent Bit       |                |
|  | (metrics)        |  | (logs)           |                |
|  +------------------+  +------------------+                |
+------------------------------------------------------------+
```

## Components

| File | Chart | Purpose |
|------|-------|---------|
| `thanos-values.yaml` | bitnami/thanos | Metrics backend with S3 storage |
| `loki-values.yaml` | grafana/loki-distributed | Logs backend with S3 storage |
| `kube-prometheus-stack-values.yaml` | prometheus-community/kube-prometheus-stack | Prometheus Operator + Alertmanager |
| `grafana-values.yaml` | grafana/grafana | Dashboards with OIDC auth |
| `otel-collector-values.yaml` | open-telemetry/opentelemetry-collector | Metrics collection for fleet |
| `fluent-bit-values.yaml` | fluent/fluent-bit | Log collection for fleet |
| `external-secrets-values.yaml` | external-secrets/external-secrets | Secret sync from AWS Secrets Manager |
| `cert-manager-values.yaml` | jetstack/cert-manager | mTLS certificate management |

## Prerequisites

1. **EKS Cluster** for RHOBS cell (regional)
2. **AWS Resources**:
   - S3 buckets: `rhobs-metrics-${REGION}`, `rhobs-logs-${REGION}`
   - ElastiCache Memcached: `rhobs-cache.${REGION}.cache.amazonaws.com`
   - Secrets Manager secrets for credentials
   - IAM roles for IRSA
3. **DNS**: Zone for `${DNS_ZONE}` with Route53
4. **OIDC Provider**: AWS Cognito or Okta for user authentication

## Environment Variables

Replace these placeholders in the values files:

| Variable | Description | Example |
|----------|-------------|---------|
| `${REGION}` | AWS region | `us-east-1` |
| `${ENVIRONMENT}` | Environment name | `prod`, `staging` |
| `${AWS_ACCOUNT_ID}` | AWS account ID | `123456789012` |
| `${CLUSTER_ID}` | Unique cluster identifier | `abc123` |
| `${CLUSTER_NAME}` | Human-readable cluster name | `prod-us-east-1-001` |
| `${ORGANIZATION}` | Organization name for certs | `my-org` |
| `${DNS_ZONE}` | DNS zone | `example.com` |
| `${ACME_EMAIL}` | Email for Let's Encrypt | `admin@example.com` |
| `${OAUTH_CLIENT_ID}` | OIDC client ID | - |
| `${OAUTH_CLIENT_SECRET}` | OIDC client secret | - |
| `${OAUTH_DOMAIN}` | OIDC provider domain | `auth.example.com` |

## Installation Order

### 1. RHOBS Cell (Central Observability Cluster)

```bash
# Add Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install in order
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  -f cert-manager-values.yaml

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  -f external-secrets-values.yaml

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --create-namespace \
  -f kube-prometheus-stack-values.yaml

helm upgrade --install thanos bitnami/thanos \
  -n observability \
  -f thanos-values.yaml

helm upgrade --install loki grafana/loki-distributed \
  -n observability \
  -f loki-values.yaml

helm upgrade --install grafana grafana/grafana \
  -n observability \
  -f grafana-values.yaml
```

### 2. Fleet Clusters (Workload Clusters)

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# Install cert-manager first for mTLS certs
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  -f cert-manager-values.yaml

# Create cluster-info ConfigMap
kubectl create configmap cluster-info \
  -n observability \
  --from-literal=cluster-id=${CLUSTER_ID} \
  --from-literal=cluster-name=${CLUSTER_NAME} \
  --from-literal=region=${REGION} \
  --from-literal=environment=${ENVIRONMENT}

# Install collectors
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n observability --create-namespace \
  -f otel-collector-values.yaml

helm upgrade --install fluent-bit fluent/fluent-bit \
  -n observability \
  -f fluent-bit-values.yaml
```

## IAM Roles for Service Accounts (IRSA)

Create these IAM roles with appropriate policies:

### Thanos Role
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::rhobs-metrics-${REGION}",
        "arn:aws:s3:::rhobs-metrics-${REGION}/*"
      ]
    }
  ]
}
```

### Loki Role
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::rhobs-logs-${REGION}",
        "arn:aws:s3:::rhobs-logs-${REGION}/*"
      ]
    }
  ]
}
```

### External Secrets Role
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:${REGION}:${AWS_ACCOUNT_ID}:secret:rhobs/*",
        "arn:aws:secretsmanager:${REGION}:${AWS_ACCOUNT_ID}:secret:grafana/*",
        "arn:aws:secretsmanager:${REGION}:${AWS_ACCOUNT_ID}:secret:alertmanager/*"
      ]
    }
  ]
}
```

## Secrets Structure in AWS Secrets Manager

```
rhobs/
  prod/
    us-east-1/
      metrics-write    # { "client-id": "...", "client-secret": "..." }
      logs-write       # { "client-id": "...", "client-secret": "..." }
  staging/
    ...

grafana/
  prod/
    oauth             # { "client-id": "...", "client-secret": "...", "domain": "..." }
    admin             # { "username": "admin", "password": "..." }

alertmanager/
  prod/
    us-east-1/
      pagerduty       # { "routing-key": "..." }
    slack             # { "webhook-url": "..." }
    deadmanssnitch    # { "url": "..." }
```

## Validation

```bash
# Check RHOBS cell components
kubectl get pods -n observability

# Verify Thanos
kubectl port-forward svc/thanos-query-frontend 9090:9090 -n observability
# Open http://localhost:9090

# Verify Loki
kubectl port-forward svc/loki-gateway 3100:80 -n observability
curl http://localhost:3100/ready

# Verify Grafana
kubectl port-forward svc/grafana 3000:80 -n observability
# Open http://localhost:3000

# Check metrics ingestion (from fleet cluster)
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n observability

# Check logs ingestion (from fleet cluster)
kubectl logs -l app.kubernetes.io/name=fluent-bit -n observability
```

## Troubleshooting

### Metrics not appearing in Thanos
1. Check OTEL Collector logs for remote-write errors
2. Verify mTLS certificates are valid and not expired
3. Check Thanos Receive logs for ingestion errors
4. Verify S3 bucket permissions

### Logs not appearing in Loki
1. Check Fluent Bit logs for Loki push errors
2. Verify mTLS certificates
3. Check Loki Distributor logs
4. Verify tenant ID matches (`eks`)

### Certificate issues
1. Check cert-manager logs
2. Verify ClusterIssuer is ready: `kubectl get clusterissuer`
3. Check certificate status: `kubectl get certificate -A`

### Authentication failures
1. Verify OIDC configuration in Grafana
2. Check External Secrets sync status
3. Verify AWS Secrets Manager values
