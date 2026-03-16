# RHOBS to EKS Translation Guide

This document provides a reverse-engineered architecture guide for adapting Red Hat Observability Service (RHOBS) to Amazon EKS.

## Overview

RHOBS is a globally distributed, highly available platform for long-term persistence and querying of metrics, logs, and synthetic probes. It uses a regional cell architecture where independent instances are deployed per AWS region to ensure data sovereignty.

---

## Core Architecture (Portable)

These components work identically on EKS:

| RHOBS Component | EKS Equivalent | Notes |
|-----------------|----------------|-------|
| **Thanos** (Query/Receive/Compact/Store) | Thanos | Deploy via Helm chart or Kustomize |
| **Loki** (LokiStack) | Grafana Loki | Use `loki-distributed` Helm chart |
| **OpenTelemetry Collector** | OTEL Collector | CNCF project, works anywhere |
| **Grafana** | Grafana | Same |
| **Alertmanager** | Alertmanager | Same |
| **S3 Storage** | S3 | Same (already AWS native) |
| **ElastiCache (Memcached)** | ElastiCache | Same |

---

## OpenShift to EKS Replacements

| OpenShift Component | EKS Replacement |
|---------------------|-----------------|
| **Hive SelectorSyncSets** | **FluxCD / ArgoCD** with cluster generators |
| **OpenShift Routes** | **AWS ALB/NLB** + Ingress or **Istio Gateway** |
| **Cluster Logging Operator (CLO)** | **Fluent Bit** DaemonSet or **Vector** |
| **Observability Operator (OBO)** | **Prometheus Operator** (kube-prometheus-stack) |
| **OpenShift Templates** | **Helm charts** or **Kustomize** |
| **FleetManager / OCM** | **EKS Anywhere** + **Cluster API** or **Rancher Fleet** |
| **app-interface (GitOps)** | **ArgoCD ApplicationSets** |
| **Red Hat SSO** | **AWS Cognito** or **Keycloak** |
| **PrivateLink (VPC peering)** | **AWS PrivateLink** (same) |

---

## EKS-Adapted Architecture

```
+-------------------------------------------------------------------+
|                    RHOBS Cell (per region)                        |
|                      EKS Cluster                                  |
|  +-------------------------------------------------------------+  |
|  |  Gateway Layer (Observatorium API / nginx + OPA)            |  |
|  |  - mTLS auth for writers                                    |  |
|  |  - Cognito/OIDC for readers                                 |  |
|  +-----------------------------+-------------------------------+  |
|                                |                                  |
|  +-----------------------------v-------------------------------+  |
|  |                    Metrics Stack                            |  |
|  |  Thanos Receive -> S3 -> Thanos Store/Query/Compact         |  |
|  +-------------------------------------------------------------+  |
|  +-------------------------------------------------------------+  |
|  |                    Logs Stack                               |  |
|  |  Loki Distributor -> S3 -> Loki Querier/Ingester            |  |
|  +-------------------------------------------------------------+  |
|  +-------------------------------------------------------------+  |
|  |  Alertmanager -> PagerDuty/Slack                            |  |
|  +-------------------------------------------------------------+  |
+-------------------------------------------------------------------+
           ^                    ^                    ^
           | remote-write       | Loki push          | Probes
           | (mTLS)             | (mTLS)             |
+----------+--------------------+--------------------+--------------+
|                    Fleet EKS Clusters                             |
|  +-----------------+  +-----------------+  +-------------------+  |
|  | OTEL Collector  |  | Fluent Bit /    |  | Blackbox          |  |
|  | -> Prometheus   |  | Vector          |  | Exporter          |  |
|  |   remote-write  |  | -> Loki push    |  |                   |  |
|  +-----------------+  +-----------------+  +-------------------+  |
+-------------------------------------------------------------------+
```

---

## Key Implementation Steps

### 1. Central RHOBS Cell (per region)

Helm releases needed:

```yaml
# Prometheus Operator + Alertmanager
- name: kube-prometheus-stack
  repo: https://prometheus-community.github.io/helm-charts

# Thanos stack
- name: thanos
  repo: https://charts.bitnami.com/bitnami

# Grafana Loki
- name: loki-distributed
  repo: https://grafana.github.io/helm-charts

# Dashboards
- name: grafana
  repo: https://grafana.github.io/helm-charts
```

### 2. Gateway/Auth Layer

Deploy **nginx + OPA** as auth proxy (replaces Observatorium):

- mTLS termination for cluster writers
- OIDC integration with Cognito for human readers
- RBAC ConfigMap defining `{tenant}-metrics-read/write` roles

Example gateway RBAC configuration:

```yaml
# rbac-config.yaml
roleBindings:
  - name: {service-account-uuid}
    roles:
      - eks-metrics-read
      - eks-metrics-write
      - eks-logs-read
      - eks-logs-write
      - eks-probes-read
      - eks-probes-write
    subjects:
      - kind: user
        name: {service-account-uuid}
```

### 3. Fleet Config Distribution (replaces SelectorSyncSets)

Use ArgoCD ApplicationSet for fleet-wide configuration:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: rhobs-fleet-config
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            region: us-east-1
  template:
    metadata:
      name: '{{name}}-observability'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/fleet-observability
        targetRevision: main
        path: charts/observability-agent
        helm:
          values: |
            clusterName: "{{name}}"
            region: "{{metadata.labels.region}}"
            remoteWrite:
              url: https://rhobs.us-east-1.internal/api/v1/receive
            auth:
              type: mtls
              certSecret: rhobs-client-cert
      destination:
        server: '{{server}}'
        namespace: observability
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### 4. Credential Delivery (replaces dynatrace-token-provider)

Use **External Secrets Operator** to sync from AWS Secrets Manager:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: rhobs-credentials
  namespace: observability
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: rhobs-client-credentials
    creationPolicy: Owner
  data:
    - secretKey: client-id
      remoteRef:
        key: rhobs/prod/us-east-1/metrics-write
        property: client-id
    - secretKey: client-secret
      remoteRef:
        key: rhobs/prod/us-east-1/metrics-write
        property: client-secret
```

Generate per-cluster mTLS certs via **cert-manager**:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rhobs-client-cert
  namespace: observability
spec:
  secretName: rhobs-client-cert
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days
  subject:
    organizations:
      - your-org
  commonName: ${CLUSTER_NAME}
  dnsNames:
    - ${CLUSTER_NAME}.eks.internal
  issuerRef:
    name: rhobs-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

### 5. Log Collection (replaces CLO/ClusterLogForwarder)

Fluent Bit configuration for Loki push:

```ini
[SERVICE]
    Flush         5
    Log_Level     info
    Parsers_File  parsers.conf

[INPUT]
    Name              tail
    Tag               kube.*
    Path              /var/log/containers/*.log
    Parser            docker
    DB                /var/log/flb_kube.db
    Mem_Buf_Limit     50MB
    Skip_Long_Lines   On
    Refresh_Interval  10

[FILTER]
    Name                kubernetes
    Match               kube.*
    Kube_URL            https://kubernetes.default.svc:443
    Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
    Merge_Log           On
    K8S-Logging.Parser  On
    K8S-Logging.Exclude On

[OUTPUT]
    Name          loki
    Match         *
    Host          rhobs.us-east-1.internal
    Port          443
    TLS           On
    TLS.verify    On
    TLS.ca_file   /certs/ca.crt
    TLS.cert_file /certs/client.crt
    TLS.key_file  /certs/client.key
    Labels        cluster=${CLUSTER_ID}, region=${REGION}, env=${ENVIRONMENT}
    Label_keys    $kubernetes['namespace_name'],$kubernetes['pod_name']
    Line_Format   json
```

### 6. Metrics Collection (OTEL Collector)

OpenTelemetry Collector configuration:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: rhobs-metrics
  namespace: observability
spec:
  mode: deployment
  config: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: 'federate'
              honor_labels: true
              metrics_path: '/federate'
              params:
                'match[]':
                  - '{__name__=~"ALERTS|cluster:.*|namespace:.*"}'
              static_configs:
                - targets: ['prometheus-operated.monitoring:9090']
              scheme: https
              tls_config:
                ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1000
      resource:
        attributes:
          - key: cluster_id
            value: ${CLUSTER_ID}
            action: upsert
          - key: region
            value: ${REGION}
            action: upsert

    exporters:
      otlphttp:
        endpoint: https://rhobs.us-east-1.internal/api/v1/receive
        tls:
          cert_file: /certs/client.crt
          key_file: /certs/client.key
          ca_file: /certs/ca.crt

    service:
      pipelines:
        metrics:
          receivers: [prometheus]
          processors: [batch, resource]
          exporters: [otlphttp]
```

---

## Critical Design Decisions

### 1. Data Sovereignty
- One RHOBS cell per AWS region
- S3 buckets in same region as cell
- No cross-region data transfer at rest

### 2. Authentication for Writers (Clusters)
- Use **mTLS** over OIDC tokens
- Resilient to SSO/IdP outages
- Per-cluster certificates signed by central CA
- Subject Alternative Name identifies cluster

### 3. Authentication for Readers (Humans)
- OIDC via AWS Cognito or Okta
- Pass token through Grafana datasource to gateway
- Token validation at gateway layer

### 4. Multi-tenancy Model
- Single tenant per region (tenant path like `/api/eks`)
- Not per-cluster isolation
- Clusters distinguished by labels, not separate tenants

### 5. Cardinality Management
- Recording rules on fleet clusters pre-aggregate metrics
- Ship aggregated metrics, not raw high-cardinality data
- Use `ALERTS` metric for cluster-level alerting

---

## Terraform/Infrastructure Requirements

### S3 Buckets (per region)

```hcl
resource "aws_s3_bucket" "rhobs_metrics" {
  bucket = "rhobs-metrics-${var.region}"

  tags = {
    Purpose = "RHOBS Thanos metrics storage"
    Region  = var.region
  }
}

resource "aws_s3_bucket" "rhobs_logs" {
  bucket = "rhobs-logs-${var.region}"

  tags = {
    Purpose = "RHOBS Loki logs storage"
    Region  = var.region
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rhobs_metrics_lifecycle" {
  bucket = aws_s3_bucket.rhobs_metrics.id

  rule {
    id     = "retention-90-days"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}
```

### ElastiCache for Caching

```hcl
resource "aws_elasticache_cluster" "rhobs_cache" {
  cluster_id           = "rhobs-cache-${var.region}"
  engine               = "memcached"
  node_type            = "cache.r6g.large"
  num_cache_nodes      = 3
  parameter_group_name = "default.memcached1.6"
  port                 = 11211
  subnet_group_name    = aws_elasticache_subnet_group.rhobs.name
  security_group_ids   = [aws_security_group.rhobs_cache.id]
}
```

### PrivateLink for Secure Ingestion

```hcl
resource "aws_vpc_endpoint_service" "rhobs" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.rhobs_nlb.arn]

  tags = {
    Name = "rhobs-endpoint-service-${var.region}"
  }
}

resource "aws_vpc_endpoint" "rhobs_fleet" {
  for_each = var.fleet_vpc_ids

  vpc_id              = each.value
  service_name        = aws_vpc_endpoint_service.rhobs.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.fleet_subnet_ids[each.key]
  security_group_ids  = [aws_security_group.rhobs_endpoint[each.key].id]
  private_dns_enabled = true
}
```

---

## Alerting Pipeline

### PagerDuty Integration

```yaml
# Alertmanager configuration
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: observability
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m

    route:
      receiver: 'null'
      group_by: ['alertname', 'cluster', 'region']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - match:
            severity: critical
          receiver: pagerduty-critical
        - match:
            severity: warning
          receiver: slack-warning

    receivers:
      - name: 'null'
      - name: pagerduty-critical
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/pagerduty-routing-key
            severity: critical
            description: '{{ .CommonAnnotations.summary }}'
            details:
              cluster: '{{ .CommonLabels.cluster }}'
              region: '{{ .CommonLabels.region }}'
      - name: slack-warning
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-webhook-url
            channel: '#eks-alerts'
            title: '{{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
```

---

## Migration Checklist

- [ ] Provision EKS cluster for RHOBS cell in target region
- [ ] Deploy Thanos stack with S3 backend
- [ ] Deploy Loki stack with S3 backend
- [ ] Configure ElastiCache for query caching
- [ ] Set up cert-manager with central CA for mTLS
- [ ] Deploy gateway layer (nginx + OPA)
- [ ] Configure OIDC provider (Cognito/Okta)
- [ ] Set up ArgoCD ApplicationSet for fleet config
- [ ] Deploy External Secrets Operator for credential sync
- [ ] Configure PrivateLink endpoints for fleet clusters
- [ ] Deploy OTEL Collector to fleet clusters
- [ ] Deploy Fluent Bit to fleet clusters
- [ ] Configure Alertmanager with PagerDuty/Slack
- [ ] Set up Grafana with regional datasources
- [ ] Validate metrics ingestion end-to-end
- [ ] Validate logs ingestion end-to-end
- [ ] Run synthetic probes for uptime monitoring
