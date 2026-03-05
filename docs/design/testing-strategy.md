# Testing Strategy

**Last Updated Date**: 2026-03-05

> TODO: This document is a stub. It currently only covers the ephemeral environment test flow. The Testing Suite, long-lived environment details, and broader test strategy still need to be documented.

## Summary

The ROSA Regional Platform testing strategy has two layers: a reusable Testing Suite that validates customer-facing behavior, and infrastructure provisioning that gives the suite an environment to run against. Tests run against either long-lived or ephemeral infrastructure.

## Testing Suite

Acts against an already existing environment. Uses the platform API to create, read, update, and delete HCPs, then runs workloads inside those HCPs. Tests the customer experience.

The Testing Suite is the reusable building block. Both long-lived and ephemeral test runs invoke it.

## Long-lived Environment (Nightlies)

A persistent environment deployed from `main` with a pre-existing pipeline-provisioner (set up once). A nightly job runs the Testing Suite against it.

## Ephemeral Environments

Used by both pre-merge (PR branch) and nightlies (`main`). Each run provisions fresh infrastructure, runs the Testing Suite, and tears everything down. A unique CI prefix (e.g. `ci-a1b2c3`) namespaces all resources to enable parallel runs in the dedicated CI AWS accounts.

Implementation: `ci/ephemerallib/`, entry point: `ci/pre-merge.py`.

```
                    ┌──────────────────────────────────┐
                    │         Source repo/branch        │
                    │  (PR branch or main)              │
                    └────────────────┬─────────────────┘
                                     │ clone
                                     ▼
                    ┌──────────────────────────────────┐
                    │  rosa-regional-platform-ci fork   │
                    │  (CI branch with injected config) │
                    └────────────────┬─────────────────┘
                                     │ push rendered config
                                     ▼
  ┌─ PROVISION ──────────────────────────────────────────────────┐
  │                                                              │
  │  bootstrap-central-account.sh                                │
  │         │                                                    │
  │         ▼                                                    │
  │  Pipeline-provisioner (CodePipeline)                         │
  │         │ creates                                            │
  │         ▼                                                    │
  │  RC pipeline ─────► provisions Regional Cluster              │
  │  MC pipeline ─────► provisions Management Cluster            │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
  ┌─ TEST ───────────────────────────────────────────────────────┐
  │  Run Testing Suite against provisioned environment           │
  └──────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
  ┌─ TEARDOWN ───────────────────────────────────────────────────┐
  │                                                              │
  │  1. Push delete: true        ──► RC/MC pipelines destroy     │
  │                                  infrastructure              │
  │  2. Push delete_pipeline: true ─► Provisioner destroys       │
  │                                   RC/MC pipelines            │
  │  3. terraform destroy        ──► Remove pipeline-provisioner │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```
