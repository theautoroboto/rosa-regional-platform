# RHOBS Architecture Diagrams

## High-Level Communication Flow

```mermaid
graph TB
    subgraph "Management Cluster 1 (Fleet)"
        MC1_OTEL[OTEL Collector<br/>Deployment]
        MC1_FB[Fluent Bit<br/>DaemonSet]
        MC1_Prom[Prometheus<br/>Operator]
        MC1_Pods[Application<br/>Pods]
        MC1_Cert[mTLS Client<br/>Certificate]

        MC1_Prom -->|scrape metrics| MC1_OTEL
        MC1_Pods -->|expose /metrics| MC1_Prom
        MC1_FB -->|tail logs| MC1_Pods
        MC1_Cert -.->|authenticates| MC1_OTEL
        MC1_Cert -.->|authenticates| MC1_FB
    end

    subgraph "Management Cluster 2 (Fleet)"
        MC2_OTEL[OTEL Collector<br/>Deployment]
        MC2_FB[Fluent Bit<br/>DaemonSet]
        MC2_Cert[mTLS Client<br/>Certificate]
    end

    subgraph "Internet (Public mTLS)"
        NLB1[NLB for Metrics<br/>Port 19291]
        NLB2[NLB for Logs<br/>Port 3100]
    end

    subgraph "Regional Cluster (Observability Hub)"
        subgraph "Ingestion Layer"
            TR[Thanos Receive<br/>StatefulSet]
            LD[Loki Distributor<br/>Deployment]
        end

        subgraph "Processing Layer"
            TQ[Thanos Query<br/>Deployment]
            TC[Thanos Compactor<br/>Deployment]
            TS[Thanos Store<br/>Deployment]
            LI[Loki Ingester<br/>Deployment]
            LQ[Loki Querier<br/>Deployment]
            LQF[Loki Query Frontend<br/>Deployment]
        end

        subgraph "Frontend Layer"
            Graf[Grafana<br/>Deployment]
            AM[Alertmanager<br/>Deployment]
        end

        subgraph "Certificate Authority"
            CA[cert-manager<br/>CA Issuer]
        end

        NLB1 -->|routes to| TR
        NLB2 -->|routes to| LD
        TR -->|queries| TQ
        LD -->|queries| LQF
        TQ -->|visualize| Graf
        LQF -->|visualize| Graf
        TC -->|compact| TS
        LI -->|store chunks| LQ
        AM -->|alerts| Graf
        CA -.->|signs client certs| MC1_Cert
        CA -.->|signs client certs| MC2_Cert
    end

    subgraph "AWS Services"
        S3M[(S3 Metrics Bucket<br/>90 day retention)]
        S3L[(S3 Logs Bucket<br/>90 day retention)]
        Cache[(ElastiCache<br/>Memcached)]
        IAM_Thanos[IAM Role<br/>Thanos Pod Identity]
        IAM_Loki[IAM Role<br/>Loki Pod Identity]

        IAM_Thanos -.->|grants access| S3M
        IAM_Loki -.->|grants access| S3L
    end

    MC1_OTEL -->|remote-write<br/>HTTPS + mTLS| NLB1
    MC1_FB -->|Loki push API<br/>HTTPS + mTLS| NLB2
    MC2_OTEL -->|remote-write<br/>HTTPS + mTLS| NLB1
    MC2_FB -->|Loki push API<br/>HTTPS + mTLS| NLB2

    TR -->|write blocks| S3M
    LD -->|write chunks| S3L
    TS -->|read blocks| S3M
    LQ -->|read chunks| S3L
    TQ -->|cache results| Cache
    LQF -->|cache results| Cache
    TC -->|downsample| S3M

    style MC1_Cert fill:#ff9999
    style MC2_Cert fill:#ff9999
    style CA fill:#ff9999
    style NLB1 fill:#ffcc99
    style NLB2 fill:#ffcc99
    style S3M fill:#99ccff
    style S3L fill:#99ccff
    style Cache fill:#99ccff
```

## Detailed mTLS Authentication Flow

```mermaid
sequenceDiagram
    participant MC as Management Cluster
    participant CM_MC as cert-manager (MC)
    participant RC_CA as Regional Cluster CA
    participant NLB as Network Load Balancer
    participant Thanos as Thanos Receive
    participant S3 as S3 Metrics Bucket

    Note over MC,RC_CA: Certificate Provisioning (One-time)
    RC_CA->>RC_CA: Generate self-signed CA cert/key
    RC_CA->>MC: Distribute CA public certificate
    MC->>CM_MC: Request client certificate
    CM_MC->>RC_CA: CSR for cluster identity
    RC_CA->>CM_MC: Signed client certificate
    CM_MC->>MC: Store cert in secret (rhobs-client-cert)

    Note over MC,S3: Metrics Push Flow (Continuous)
    MC->>MC: Prometheus scrapes pods
    MC->>MC: OTEL Collector aggregates
    MC->>NLB: POST /api/v1/receive<br/>+ Client Cert + CA
    NLB->>Thanos: Forward TLS connection
    Thanos->>Thanos: Verify client certificate
    Thanos->>Thanos: Extract cluster_id from cert CN
    Thanos->>Thanos: Buffer metrics in TSDB
    Thanos->>S3: Upload blocks (via Pod Identity)
    S3->>Thanos: 200 OK
    Thanos->>NLB: 200 OK
    NLB->>MC: 200 OK
```

## Data Storage and Retention Architecture

```mermaid
graph LR
    subgraph "Management Cluster"
        Metrics[Raw Metrics<br/>15s resolution]
        Logs[Raw Logs<br/>All log lines]
    end

    subgraph "Regional Cluster - Hot Storage"
        TR_Local[Thanos Receive<br/>Local TSDB<br/>2h retention]
        LI_Local[Loki Ingester<br/>Local Chunks<br/>2h retention]
    end

    subgraph "S3 Long-Term Storage"
        subgraph "Metrics Bucket (90 days)"
            Raw[Raw Data<br/>15s resolution<br/>30 days]
            Downsampled_5m[5m downsampled<br/>90 days]
            Downsampled_1h[1h downsampled<br/>365 days]
        end

        subgraph "Logs Bucket (90 days)"
            LogChunks[Log Chunks<br/>Compressed<br/>90 days]
        end
    end

    subgraph "Query Layer"
        TQ[Thanos Query]
        LQ[Loki Query Frontend]
        Cache[(Memcached<br/>Query Cache)]
    end

    Metrics -->|remote-write| TR_Local
    Logs -->|push API| LI_Local
    TR_Local -->|upload blocks| Raw
    LI_Local -->|flush chunks| LogChunks
    Raw -->|compact & downsample| Downsampled_5m
    Downsampled_5m -->|compact & downsample| Downsampled_1h
    TQ -->|query| Raw
    TQ -->|query| Downsampled_5m
    TQ -->|query| Downsampled_1h
    TQ -->|cache| Cache
    LQ -->|query| LogChunks
    LQ -->|cache| Cache

    style Raw fill:#ffcccc
    style Downsampled_5m fill:#ffddaa
    style Downsampled_1h fill:#ffeeaa
    style LogChunks fill:#ccffcc
```

## Component Deployment Architecture

```mermaid
graph TB
    subgraph "Regional Cluster EKS"
        subgraph "observability Namespace"
            subgraph "Metrics Stack"
                TR_Pods[Thanos Receive<br/>3 replicas<br/>StatefulSet]
                TQ_Pods[Thanos Query<br/>2 replicas]
                TS_Pods[Thanos Store<br/>2 replicas]
                TC_Pod[Thanos Compactor<br/>1 replica]
            end

            subgraph "Logs Stack"
                LD_Pods[Loki Distributor<br/>3 replicas]
                LI_Pods[Loki Ingester<br/>3 replicas]
                LQ_Pods[Loki Querier<br/>2 replicas]
                LQF_Pods[Loki Query Frontend<br/>2 replicas]
            end

            subgraph "Frontend"
                Graf_Pods[Grafana<br/>2 replicas]
                AM_Pods[Alertmanager<br/>3 replicas]
            end

            SA_Thanos[ServiceAccount: thanos<br/>+ Pod Identity IAM Role]
            SA_Loki[ServiceAccount: loki<br/>+ Pod Identity IAM Role]

            TR_Pods -.->|uses| SA_Thanos
            TQ_Pods -.->|uses| SA_Thanos
            TS_Pods -.->|uses| SA_Thanos
            TC_Pod -.->|uses| SA_Thanos
            LD_Pods -.->|uses| SA_Loki
            LI_Pods -.->|uses| SA_Loki
            LQ_Pods -.->|uses| SA_Loki
        end

        subgraph "Services"
            SVC_TR[Service: thanos-receive<br/>Type: LoadBalancer<br/>NLB]
            SVC_TQ[Service: thanos-query<br/>Type: ClusterIP]
            SVC_LD[Service: loki-distributor<br/>Type: LoadBalancer<br/>NLB]
            SVC_LQF[Service: loki-query-frontend<br/>Type: ClusterIP]
            SVC_Graf[Service: grafana<br/>Type: ClusterIP]
        end

        TR_Pods -->|exposes| SVC_TR
        TQ_Pods -->|exposes| SVC_TQ
        LD_Pods -->|exposes| SVC_LD
        LQF_Pods -->|exposes| SVC_LQF
        Graf_Pods -->|exposes| SVC_Graf
    end

    subgraph "Management Cluster EKS"
        subgraph "observability Namespace"
            OTEL_Pods[OTEL Collector<br/>2 replicas<br/>Deployment]
            FB_DS[Fluent Bit<br/>DaemonSet<br/>1 pod per node]
            Cert[Certificate: rhobs-client-cert<br/>issued by Regional CA]

            OTEL_Pods -.->|mounts| Cert
            FB_DS -.->|mounts| Cert
        end

        subgraph "monitoring Namespace"
            Prom[Prometheus Operator<br/>managed Prometheus]
        end

        Prom -->|federate| OTEL_Pods
    end

    OTEL_Pods -->|remote-write<br/>mTLS| SVC_TR
    FB_DS -->|push logs<br/>mTLS| SVC_LD
    SVC_TQ -->|datasource| Graf_Pods
    SVC_LQF -->|datasource| Graf_Pods

    style SVC_TR fill:#ffcc99
    style SVC_LD fill:#ffcc99
    style Cert fill:#ff9999
```

## Network and Security Architecture

```mermaid
graph TB
    subgraph "Management Cluster VPC"
        MC_Nodes[EKS Worker Nodes<br/>Private Subnets]
        MC_NAT[NAT Gateway<br/>Public Subnet]
        MC_IGW[Internet Gateway]

        MC_Nodes -->|egress traffic| MC_NAT
        MC_NAT -->|route to| MC_IGW
    end

    subgraph "Internet"
        Internet((Internet))
    end

    subgraph "Regional Cluster VPC"
        RC_IGW[Internet Gateway]
        RC_Public[Public Subnets]
        RC_Private[Private Subnets<br/>EKS Worker Nodes]
        RC_NLB_Metrics[NLB for Metrics<br/>internet-facing]
        RC_NLB_Logs[NLB for Logs<br/>internet-facing]

        RC_IGW -->|routes to| RC_Public
        RC_Public -->|hosts| RC_NLB_Metrics
        RC_Public -->|hosts| RC_NLB_Logs
        RC_NLB_Metrics -->|forwards to| RC_Private
        RC_NLB_Logs -->|forwards to| RC_Private

        subgraph "Security Groups"
            SG_Thanos[Thanos Receive Pod<br/>Allow 19291 from NLB]
            SG_Loki[Loki Distributor Pod<br/>Allow 3100 from NLB]
            SG_Cache[ElastiCache SG<br/>Allow 11211 from EKS]
        end

        RC_Private -->|pods use| SG_Thanos
        RC_Private -->|pods use| SG_Loki
    end

    subgraph "AWS Managed Services"
        Cache[(ElastiCache<br/>Private Subnets)]
        S3[(S3 Buckets<br/>VPC Endpoint)]

        RC_Private -->|queries| Cache
        RC_Private -->|stores| S3
    end

    MC_IGW -->|HTTPS + mTLS| Internet
    Internet -->|HTTPS + mTLS| RC_IGW

    style MC_NAT fill:#99ccff
    style RC_NLB_Metrics fill:#ffcc99
    style RC_NLB_Logs fill:#ffcc99
    style SG_Thanos fill:#ffcccc
    style SG_Loki fill:#ffcccc
    style SG_Cache fill:#ffcccc
```

## Query Path Architecture

```mermaid
graph LR
    User[User Browser]

    subgraph "Regional Cluster"
        Graf[Grafana UI]

        subgraph "Metrics Query Path"
            TQ[Thanos Query]
            TS[Thanos Store]
            TR[Thanos Receive]
            Cache1[(Memcached<br/>Results Cache)]
        end

        subgraph "Logs Query Path"
            LQF[Loki Query Frontend]
            LQ[Loki Querier]
            LI[Loki Ingester]
            Cache2[(Memcached<br/>Results Cache)]
        end
    end

    subgraph "Storage"
        S3M[(S3 Metrics<br/>Historical Blocks)]
        S3L[(S3 Logs<br/>Historical Chunks)]
    end

    User -->|PromQL query| Graf
    Graf -->|datasource| TQ
    TQ -->|check cache| Cache1
    TQ -->|query recent| TR
    TQ -->|query historical| TS
    TS -->|read| S3M

    User -->|LogQL query| Graf
    Graf -->|datasource| LQF
    LQF -->|check cache| Cache2
    LQF -->|distribute query| LQ
    LQ -->|query recent| LI
    LQ -->|query historical| S3L

    Cache1 -.->|cache hit| TQ
    Cache2 -.->|cache hit| LQF

    style Cache1 fill:#99ff99
    style Cache2 fill:#99ff99
```

## Certificate Lifecycle

```mermaid
stateDiagram-v2
    [*] --> CA_Created: Deploy Regional Cluster
    CA_Created --> CA_Distributed: Copy CA cert to Secrets Manager
    CA_Distributed --> Fleet_Request: Deploy Management Cluster
    Fleet_Request --> Cert_Issued: cert-manager creates Certificate CR
    Cert_Issued --> Cert_Valid: Certificate stored in Secret

    Cert_Valid --> Cert_Renew: 30 days before expiry
    Cert_Renew --> Cert_Valid: New cert issued

    Cert_Valid --> Connection_Established: OTEL/Fluent Bit connect
    Connection_Established --> Metrics_Flowing: mTLS handshake success

    Metrics_Flowing --> Cert_Renew: Auto-renewal
    Metrics_Flowing --> [*]: Cluster decommissioned

    note right of CA_Created
        Self-signed CA for dev
        External CA for prod
        (AWS Private CA, Vault)
    end note

    note right of Cert_Valid
        Valid for 1 year
        Auto-renew 30 days before
        CN = cluster_name
    end note
```

## Troubleshooting Decision Tree

```mermaid
graph TD
    Start{Metrics/Logs<br/>Missing?}
    Start -->|Yes| Check1{Check Agent Pods}
    Check1 -->|Not Running| Fix1[Check pod events<br/>Fix deployment issues]
    Check1 -->|Running| Check2{Check Logs}

    Check2 -->|Connection Refused| Check3{Verify NLB DNS}
    Check3 -->|Wrong DNS| Fix2[Update values.yaml<br/>with correct endpoint]
    Check3 -->|Correct| Check4{Test Connectivity}

    Check4 -->|Cannot Connect| Fix3[Check NAT Gateway<br/>Check Security Groups]
    Check4 -->|Can Connect| Check5{mTLS Error?}

    Check5 -->|Yes| Check6{Check Certificate}
    Check6 -->|Expired/Invalid| Fix4[Renew certificate<br/>Check cert-manager]
    Check6 -->|Valid| Fix5[Verify CA cert distributed<br/>Check trust chain]

    Check5 -->|No| Check7{Data in S3?}
    Check7 -->|No| Fix6[Check Pod Identity<br/>Verify IAM role]
    Check7 -->|Yes| Check8{Query Works?}

    Check8 -->|No| Fix7[Check Thanos/Loki<br/>query components]
    Check8 -->|Yes| Success[✓ System Working]

    Start -->|No| Success

    style Success fill:#99ff99
    style Fix1 fill:#ffcccc
    style Fix2 fill:#ffcccc
    style Fix3 fill:#ffcccc
    style Fix4 fill:#ffcccc
    style Fix5 fill:#ffcccc
    style Fix6 fill:#ffcccc
    style Fix7 fill:#ffcccc
```
