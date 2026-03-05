# Configuration Files Migration

**Date:** March 5, 2026
**Status:** COMPLETED

## Overview

The following files have been moved from this public repository to the private repository at `https://github.com/openshift-online/rosa-regional-platform-internal` to protect sensitive environment and account information:

- `config.yaml` - Environment-specific configurations with AWS account IDs
- `scripts/render.py` - Configuration rendering script
- `deploy/` - All generated deployment manifests and terraform configs

## Why This Move?

These files contain sensitive information including:
- AWS account IDs for multiple environments
- Environment-specific infrastructure configurations
- Generated terraform variable files with account details
- ArgoCD deployment manifests with internal infrastructure references

Moving them to a private repository ensures this sensitive information is not publicly accessible while keeping the core platform code and documentation public.

## Accessing the Moved Files

### Prerequisites

You need access to the private repository. Request access from the platform team if needed.

### Using SSH (Recommended)

```bash
# Clone the private configuration repository
git clone git@github.com:openshift-online/rosa-regional-platform-internal.git

# The files are at:
# - rosa-regional-platform-internal/config.yaml
# - rosa-regional-platform-internal/scripts/render.py
# - rosa-regional-platform-internal/deploy/
```

### Using HTTPS with Personal Access Token

```bash
# Create a Personal Access Token at: https://github.com/settings/tokens
# Then clone using:
git clone https://github.com/openshift-online/rosa-regional-platform-internal.git
```

## Updated Workflow

### Before (Old Workflow)
```bash
# Edit config.yaml in this repository
vim config.yaml

# Run render script
./scripts/render.py

# Commit everything together
git add config.yaml deploy/
git commit -m "Add new region"
```

### After (New Workflow)
```bash
# 1. Work in the PRIVATE repository for configuration
cd /path/to/rosa-regional-platform-internal
vim config.yaml
./scripts/render.py
git add config.yaml deploy/
git commit -m "Add new region"
git push

# 2. Work in the PUBLIC repository for platform code/docs
cd /path/to/rosa-regional-platform-PR
# Edit platform code, ArgoCD configs, terraform modules, docs, etc.
git add <files>
git commit -m "Update platform code"
git push
```

## Impact on Documentation

The documentation in this repository still references `config.yaml`, `scripts/render.py`, and `deploy/` directories. When following these docs:

1. Understand that these files now live in `rosa-regional-platform-internal`
2. Clone both repositories when working on the platform
3. Run `scripts/render.py` from the internal repository
4. Configuration changes go to the internal repository
5. Platform code and infrastructure modules stay in this repository

## Files That Reference the Moved Configuration

The following files in this repository reference the moved files and should be understood to refer to the internal repository:

### Documentation
- `docs/full-region-provisioning.md`
- `docs/central-pipeline-provisioning.md`
- `docs/design/pipeline-based-lifecycle.md`
- `docs/design/gitops-cluster-configuration.md`
- `argocd/README.md`
- `README.md`

### Scripts and Build Files
- `Makefile`
- `scripts/provision-pipelines.sh`
- `scripts/bootstrap-central-account.sh`
- `scripts/bootstrap-argocd.sh`
- `scripts/dev/validate-argocd-config.sh`
- `terraform/config/pipeline-regional-cluster/buildspec-provision-infra.yml`
- `terraform/config/pipeline-management-cluster/buildspec-provision-infra.yml`

## Repository Structure

### Public Repository (rosa-regional-platform-PR)
```
rosa-regional-platform-PR/
├── argocd/                    # ArgoCD configuration templates
├── terraform/                 # Terraform modules
├── scripts/                   # Utility scripts (except render.py)
├── docs/                      # Documentation
└── README.md                  # Main documentation
```

### Private Repository (rosa-regional-platform-internal)
```
rosa-regional-platform-internal/
├── config.yaml                # Environment configurations (SENSITIVE)
├── scripts/
│   └── render.py             # Configuration renderer
└── deploy/                    # Generated deployment files (SENSITIVE)
    ├── integration/
    ├── staging/
    └── ...
```

## Pipeline Configuration Updates

The CodePipeline configurations have been updated to pull from both repositories:

- **Public Repository** (`rosa-regional-platform-PR`): Platform code, terraform modules, scripts
- **Private Repository** (`rosa-regional-platform-internal`): Configuration files, deploy manifests

Each pipeline now has two source actions:
- `PublicSource` - Monitors the public repo for platform code changes
- `ConfigSource` - Pulls config files from the private repo

**Important:** After merging these changes, existing pipelines must be updated to use the new dual-source configuration.

See [docs/PIPELINE-MIGRATION-PLAN.md](docs/PIPELINE-MIGRATION-PLAN.md) for detailed migration steps and troubleshooting.

## Questions?

If you have questions about this migration or need access to the private repository, contact the platform team.
