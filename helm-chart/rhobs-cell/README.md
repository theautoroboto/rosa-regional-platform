# RHOBS Cell Helm Chart

Regional Observability Cell for EKS - based on Red Hat Observability Service (RHOBS) architecture.

## Overview

This Helm chart deploys a complete observability stack including:

- **Gateway** - Observatorium API for multi-tenant access control
- **Thanos** - Metrics storage and query (Receive, Query, Store, Compact, Ruler)
- **Loki** - Logs storage and query (Distributed mode)
- **Alertmanager** - Alert routing and notification
- **Synthetics** - Uptime monitoring and probes

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+
- AWS EKS cluster
- AWS resources:
  - S3 buckets for metrics and logs
  - ElastiCache (Memcached) for caching
  - IAM roles for IRSA
- External Secrets Operator (for AWS Secrets Manager integration)
- Prometheus Operator / kube-prometheus-stack (for ServiceMonitors)

## Installation

### 1. Add Helm repositories

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 2. Update dependencies

```bash
cd helm-chart/rhobs-cell
helm dependency update
```

### 3. Create values file for your environment

```bash
cp values.yaml values-production.yaml
# Edit values-production.yaml with your configuration
```

### 4. Install the chart

```bash
helm install rhobs-cell . \
  -n rhobs \
  --create-namespace \
  -f values-production.yaml
```

## Configuration

### Global Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.region` | AWS region | `us-east-1` |
| `global.environment` | Environment name | `production` |
| `global.clusterName` | Cluster identifier | `rhobs-us-east-1` |
| `global.domain` | Public domain for gateway | `us-east-1.rhobs.example.com` |
| `global.aws.accountId` | AWS account ID for IRSA | `""` |

### Gateway

| Parameter | Description | Default |
|-----------|-------------|---------|
| `gateway.enabled` | Enable gateway | `true` |
| `gateway.replicaCount` | Number of replicas | `2` |
| `gateway.auth.type` | Auth type (oidc, mtls, both) | `mtls` |
| `gateway.ingress.enabled` | Enable ingress | `true` |
| `gateway.ingress.className` | Ingress class | `alb` |

### Thanos

| Parameter | Description | Default |
|-----------|-------------|---------|
| `thanos.enabled` | Enable Thanos | `true` |
| `thanos.receive.replicaCount` | Receive replicas | `3` |
| `thanos.receive.replicationFactor` | Replication factor | `2` |
| `thanos.query.replicaCount` | Query replicas | `2` |
| `thanos.compactor.retentionResolution1h` | 1h downsampled retention | `90d` |

### Loki

| Parameter | Description | Default |
|-----------|-------------|---------|
| `loki.enabled` | Enable Loki | `true` |
| `loki.loki.limits_config.retention_period` | Log retention | `2160h` (90 days) |
| `loki.distributor.replicas` | Distributor replicas | `3` |
| `loki.ingester.replicas` | Ingester replicas | `3` |

### Alertmanager

| Parameter | Description | Default |
|-----------|-------------|---------|
| `alertmanager.enabled` | Enable Alertmanager | `true` |
| `alertmanager.replicaCount` | Number of replicas | `3` |
| `alertmanager.config` | Alertmanager config | See values.yaml |

## AWS Resources Required

### S3 Buckets

Create buckets for metrics and logs storage:

```bash
aws s3 mb s3://rhobs-metrics-us-east-1 --region us-east-1
aws s3 mb s3://rhobs-logs-us-east-1 --region us-east-1
```

### IAM Roles (IRSA)

Create IAM roles for Thanos and Loki with S3 access:

```hcl
# Thanos role
resource "aws_iam_role" "rhobs_thanos" {
  name = "rhobs-thanos-us-east-1"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/CLUSTER_ID"
      }
    }]
  })
}

resource "aws_iam_role_policy" "rhobs_thanos_s3" {
  name = "s3-access"
  role = aws_iam_role.rhobs_thanos.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:*"]
      Resource = [
        "arn:aws:s3:::rhobs-metrics-us-east-1",
        "arn:aws:s3:::rhobs-metrics-us-east-1/*"
      ]
    }]
  })
}
```

### Secrets Manager

Create secrets for sensitive configuration:

```bash
aws secretsmanager create-secret \
  --name rhobs/alertmanager/pagerduty \
  --secret-string '{"routing-key":"YOUR_KEY"}'

aws secretsmanager create-secret \
  --name rhobs/alertmanager/slack \
  --secret-string '{"webhook-url":"YOUR_URL"}'
```

## Architecture

```
                     ┌─────────────────────────────────────────┐
                     │           RHOBS Cell (EKS)              │
                     │                                         │
    Fleet ──────────►│  ┌─────────────────────────────────┐   │
    Clusters         │  │     Gateway (Observatorium)      │   │
    (mTLS)           │  │  - mTLS auth for writers         │   │
                     │  │  - OIDC auth for readers         │   │
                     │  │  - Tenant RBAC                   │   │
                     │  └───────────────┬─────────────────┘   │
                     │                  │                      │
                     │    ┌─────────────┴─────────────┐       │
                     │    │                           │       │
                     │    ▼                           ▼       │
                     │  ┌───────────┐           ┌─────────┐   │
                     │  │  Thanos   │           │  Loki   │   │
                     │  │ (metrics) │           │ (logs)  │   │
                     │  └─────┬─────┘           └────┬────┘   │
                     │        │                      │        │
                     │        ▼                      ▼        │
                     │  ┌─────────────────────────────────┐   │
                     │  │           AWS S3                 │   │
                     │  │  (Regional, 90-day retention)    │   │
                     │  └─────────────────────────────────┘   │
                     └─────────────────────────────────────────┘
```

## Upgrading

```bash
helm upgrade rhobs-cell . \
  -n rhobs \
  -f values-production.yaml
```

## Uninstalling

```bash
helm uninstall rhobs-cell -n rhobs
```

## Troubleshooting

### Check pod status

```bash
kubectl get pods -n rhobs
```

### Check gateway logs

```bash
kubectl logs -l app.kubernetes.io/component=gateway -n rhobs
```

### Verify Thanos components

```bash
kubectl get pods -n rhobs | grep thanos
```

### Test metrics ingestion

```bash
curl -X POST https://rhobs.us-east-1.example.com/api/v1/receive \
  --cert client.crt --key client.key \
  -d 'test_metric{job="test"} 1'
```

## Contributing

1. Clone `rhobs/configuration` to see original RHOBS configs
2. Make changes to templates
3. Test with `helm template . | kubectl apply --dry-run=client -f -`
4. Submit PR
