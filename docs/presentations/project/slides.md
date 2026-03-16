---
theme: default
title: The ROSA Regional Platform
info: |
  ## ROSA Regional Platform - Project Overview
  Building the next generation of ROSA HCP
class: text-center
highlighter: shiki
drawings:
  persist: false
transition: slide-left
mdc: true
---

<!-- markdownlint-disable MD003 -->

# The ROSA Regional Platform

Building the next generation of ROSA HCP

<div class="pt-12 text-xs opacity-50">

[Blog Post](https://source.redhat.com/departments/products_and_global_engineering/hybrid_cloud_management/service_delivery_blog/the_rosa_regional_platform_building_the_next_generation_of_rosa_hcp) · [ROSA-659](https://issues.redhat.com/browse/ROSA-659) · [Repository](https://github.com/openshift-online/rosa-regional-platform)

</div>

---

## layout: default

# The New Architecture — Design Principles

<div class="grid grid-cols-2 gap-5 pt-2 text-xs">
<div class="border rounded-lg p-4">

## 🏗️ Architecture

- **AWS native** — all EKS, IAM (SigV4)
- **Simpler** — no ACM, no App-Interface, no legacy dependencies
- **CLM** replaces CS/AMS — single source of truth
- **Clear data flows** — CLM, Maestro, ArgoCD, PKO
- **Pipeline driven regions** — regions lifecycled via pipelines
- **Async**, eventually consistent
- **New APIs, new UX** — navigate by region (like AWS console)

</div>
<div class="flex flex-col gap-5">
<div class="border rounded-lg p-4">

## 🌍 Regional

- **All future clusters** provisioned through the regional architecture
- **All regional APIs** — no global endpoints
- **Regional independence** — failures contained per region
- **Data residency** — data stays in region
- **Rapid region deployment** — on demand
- **FedRAMP Moderate** target for US regions (FIPS-140)

</div>
<div class="border rounded-lg p-4">

## 🔐 Operations

- **Zero operator access** — audited breakglass only
- **Private** EKS Kube APIs (RC & MCs) — no network path between
- **Sectors** — progressive delivery via canary-style rollouts
- **CI** — pre-merge and nightlies provision regions and run e2e tests
- **AI** from the ground up

</div>
</div>
</div>

---

## layout: default

# Architecture

<img src="./images/blog-arch.png" alt="ROSA Regional Platform architecture diagram" class="h-100 mx-auto" />

<div class="text-xs opacity-50 text-center">

[Excalidraw source](https://link.excalidraw.com/readonly/v1TEPnH0bi6uYKTuaApK)

</div>

---

## layout: default

# Team

<div class="pt-4">

**6 engineers and 1 manager** — senior, self-driven, building greenfield infrastructure

<div class="pt-4 text-sm">

- Full ownership from architecture through operations
- Proactive — making decisions quickly, iterating based on learnings
- Leveraging AI for development, debugging, and operations
- Every team member understands HyperShift and Management Cluster architecture
- Carries the pager for every environment from go-live

</div>

</div>

---

## layout: default

# Contributing Teams

<div class="pt-2 text-sm">

| Team                     | Collaboration Area                                                   |
| ------------------------ | -------------------------------------------------------------------- |
| **HyperShift Operator**  | HyperShift on EKS — networking, storage, IAM integration             |
| **HyperShift ROSA**      | Upstream contributions — request serving nodes, SG optimization, ECR |
| **ROSA PKO**             | Content delivery and image management for hosted clusters            |
| **Hyperfleet**           | CLM (Cluster Lifecycle Manager) — new API replacing CS/AMS           |
| **Platform Engineering** | ArgoCD patterns, progressive delivery (ADR-300)                      |
| **RHOBS**                | Observability stack (RHOBS v2) — metrics, logs, dashboards, alerting |
| **GCP**                  | Cross-cloud alignment — shared components and patterns               |

</div>

---

## layout: default

# Main Repositories

<div class="pt-8">

| Repository                                                                                              | Description                                                    |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| [rosa-regional-platform](https://github.com/openshift-online/rosa-regional-platform)                    | Main project repository — infrastructure, ArgoCD configs, docs |
| [rosa-regional-platform-internal](https://github.com/openshift-online/rosa-regional-platform-internal/) | Internal configurations and deployment values                  |
| [rosa-regional-platform-api](https://github.com/openshift-online/rosa-regional-platform-api/)           | Platform API specification and implementation                  |

</div>

<div class="pt-8 text-sm">

## Additional Resources

- **Slack:** `#team-rosa-regional-platform`
- **Design Document:** [ROSA HCP Regionality Design](https://docs.google.com/document/d/1tdoTPIW5eiduGLLhxtjrMEt496Gkh-PpBAJjP4UGyvE/)
- **ADR 300:** [HCM Regional Architecture](https://issues.redhat.com/browse/HCM-ADR-0300)
- **FAQs:** [FAQ.md](https://github.com/openshift-online/rosa-regional-platform/blob/main/FAQ.md)

</div>

---

## layout: default

# CI Strategy

<div style="position: absolute; top: 5rem; right: 2rem; font-size: 0.6rem; border: 1px solid #888; border-radius: 0.5rem; padding: 0.75rem 1rem;">

|               | Source    | Env           |
| ------------- | --------- | ------------- |
| **Pre-merge** | PR branch | Ephemeral     |
| **Nightly**   | main      | Persistent    |
| **Nightly**   | main      | Ephemeral x N |

**Testing suite:** Hosted Cluster lifecycle → workload validation

</div>

<div style="font-size: 0.6rem; max-width: 65%;">

**Pre-merge** (from PR branch)

```mermaid {scale: 0.45}
flowchart LR
    A[Branch] --> B[Fork to temp branch]
    B --> C[Provision]
    C --> D[Testing Suite]
    D --> E{Reconfig}
    E -->|Repeat| D
    E -->|Done| F[Delete and Cleanup]
```

**Nightly: Integration** (always running)

```mermaid {scale: 0.45}
flowchart LR
    A[main] -->|CD| B[Integration env]
    B --> C[Alerts → on-call]
    D[🕐 Nightly] --> E[Testing Suite] --> B
```

**Nightly: Ephemeral** (from main, x N)

```mermaid {scale: 0.45}
flowchart LR
    A[🕐 Nightly] --> B[Fork `main` to temp branch]
    B --> C[Provision]
    C --> D[Testing Suite +<br/>OCP Conformance tests]
    D --> E{Reconfig}
    E -->|Repeat| D
    E -->|Done| F[Teardown]
    A --> G[Latest known good ROSA config<br/>+ OCP nightlies]
    G --> H[Provision]
    H --> I[OCP Blocking tests]
    I --> J[Teardown]
```

</div>

<div style="position: absolute; bottom: 1.5rem; right: 2rem; max-width: 14rem; font-size: 0.5rem; line-height: 1.3; text-align: left; border: 1px solid #888; border-radius: 0.5rem; padding: 0.5rem 0.75rem;">
<p style="margin: 0;">› <b>Temp branches</b> are used to push GitOps commits during testing without affecting source branches.</p>
<p style="margin: 0.3rem 0 0;">› <b>Reconfig</b> includes changes to the underlying regional infrastructure through gitops (config.yaml), as well as HCP Lifecycle through the Platform API</p>
</div>

---

## layout: default

# Roadmap

<div class="text-xs">

[ROSA-659 — Operational Readiness](https://issues.redhat.com/browse/ROSA-659) — end of Q2 2026

</div>

<div class="roadmap-cards">
  <a href="https://issues.redhat.com/browse/ROSA-666" class="roadmap-card roadmap-card--done">
    <div class="roadmap-card__title">1 · Deploy a Region</div>
    <div class="roadmap-card__status">✅ Done</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-667" class="roadmap-card roadmap-card--in-progress">
    <div class="roadmap-card__title">2 · Continuous Validation</div>
    <div class="roadmap-card__status">🔨 In Progress</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-668" class="roadmap-card roadmap-card--in-progress">
    <div class="roadmap-card__title">3 · HCPs on EKS MCs</div>
    <div class="roadmap-card__status">🔨 In Progress</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-669" class="roadmap-card roadmap-card--planned">
    <div class="roadmap-card__title">4 · Observability</div>
    <div class="roadmap-card__status">Planned</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-670" class="roadmap-card roadmap-card--in-progress">
    <div class="roadmap-card__title">5 · CLM Integration</div>
    <div class="roadmap-card__status">🔨 In Progress</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-671" class="roadmap-card roadmap-card--planned">
    <div class="roadmap-card__title">6 · Disaster Recovery</div>
    <div class="roadmap-card__status">Planned</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-672" class="roadmap-card roadmap-card--planned">
    <div class="roadmap-card__title">7 · Zero Operator Access</div>
    <div class="roadmap-card__status">Planned</div>
  </a>
  <a href="https://issues.redhat.com/browse/ROSA-673" class="roadmap-card roadmap-card--planned">
    <div class="roadmap-card__title">8 · Migrate My Cluster</div>
    <div class="roadmap-card__status">Planned</div>
  </a>
</div>

<div style="padding-top: 0.8rem; font-size: 0.6rem;">

**After Q2 — path to GA**

</div>

<div style="display: flex; align-items: center; gap: 0.3rem; font-size: 0.6rem;">
  <div style="display: flex; align-items: center; gap: 0.3rem; border: 1px dashed #888; border-radius: 0.6rem; padding: 0.4rem 0.6rem; position: relative;">
    <span style="position: absolute; top: -0.7rem; left: 0.6rem; font-size: 0.45rem; color: #aaa; letter-spacing: 0.05em;">FEATURE PARITY</span>
    <span style="padding: 0.2rem 0.5rem; border: 1px solid #666; border-radius: 1rem;">Internal Preview</span>
    <span style="opacity: 0.5;">→</span>
    <span style="padding: 0.2rem 0.5rem; border: 1px solid #666; border-radius: 1rem;">Private Preview</span>
    <span style="opacity: 0.5;">→</span>
    <span style="padding: 0.2rem 0.5rem; border: 1px solid #666; border-radius: 1rem;">Public Preview</span>
  </div>
  <span style="opacity: 0.5;">→</span>
  <span style="padding: 0.2rem 0.5rem; border: 1px solid #666; border-radius: 1rem;">GA</span>
</div>
