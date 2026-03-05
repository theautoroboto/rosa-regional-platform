# Pipeline Migration Plan - Dual Repository Configuration

## Overview

This document describes the migration of CodePipeline configurations to support pulling configuration files (`config.yaml`, `deploy/`) from the private `rosa-regional-platform-internal` repository while keeping platform code in the public `rosa-regional-platform-PR` repository.

## Changes Made

### 1. Pipeline Infrastructure Changes

#### Regional Cluster Pipeline (`terraform/config/pipeline-regional-cluster/`)

**Variables (`variables.tf`):**
- Added `github_config_repository` variable with default: `openshift-online/rosa-regional-platform-internal`

**Pipeline (`main.tf`):**
- Split Source stage into two actions:
  - `PublicSource` - pulls from `rosa-regional-platform-PR` (platform code)
  - `ConfigSource` - pulls from `rosa-regional-platform-internal` (config files)
- Updated trigger to only watch `terraform/config/pipeline-regional-cluster/**` paths
- Updated all build stages to use both sources:
  - `Deploy/ApplyInfrastructure`: uses `public_source` + `config_source`
  - `Bootstrap-ArgoCD`: uses `apply_output` + `config_source`

**Buildspecs:**
- `buildspec-provision-infra.yml`:
  - Updated to reference config files from `${CODEBUILD_SRC_DIR_config_source}/deploy/`
  - Enhanced error messages to show available files in config source
- `buildspec-bootstrap-argocd.yml`:
  - Added install phase command to copy `deploy/` from config source to working directory
  - bootstrap-argocd.sh expects `deploy/` in current directory

#### Management Cluster Pipeline (`terraform/config/pipeline-management-cluster/`)

**Variables (`variables.tf`):**
- Added `github_config_repository` variable with default: `openshift-online/rosa-regional-platform-internal`

**Pipeline (`main.tf`):**
- Split Source stage into two actions:
  - `PublicSource` - pulls from `rosa-regional-platform-PR`
  - `ConfigSource` - pulls from `rosa-regional-platform-internal`
- Updated trigger to only watch `terraform/config/pipeline-management-cluster/**` paths
- Updated all build stages:
  - `Mint-IoT`: uses `public_source`
  - `Deploy/ApplyInfrastructure`: uses `public_source` + `config_source`
  - `Bootstrap-ArgoCD`: uses `apply_output` + `config_source`
  - `Register`: uses `public_source` + `config_source`

**Buildspecs:**
- `buildspec-provision-infra.yml`:
  - Updated to reference `${CODEBUILD_SRC_DIR_config_source}/deploy/` for MC configs
- `buildspec-bootstrap-argocd.yml`:
  - Added install phase command to copy `deploy/` from config source
- `buildspec-register.yml`:
  - Updated to reference `${CODEBUILD_SRC_DIR_config_source}/deploy/` for RC config lookup

### 2. How CodeBuild Multiple Sources Work

When CodePipeline provides multiple input artifacts to CodeBuild:

```bash
# Primary source (specified by PrimarySource parameter)
$CODEBUILD_SRC_DIR/          # Contains files from primary artifact

# Secondary sources (named by artifact name)
$CODEBUILD_SRC_DIR_config_source/    # Contains files from config_source artifact
```

**Example:**
```bash
# Reading a config file
RC_CONFIG_FILE="${CODEBUILD_SRC_DIR_config_source}/deploy/integration/us-east-1/terraform/regional.json"

# Copying deploy directory to working directory for scripts
cp -r "${CODEBUILD_SRC_DIR_config_source}/deploy" ./
```

## Migration Steps

### Phase 1: Merge Code Changes ✅

1. **Public Repository** (`rosa-regional-platform-PR`):
   - ✅ Remove `config.yaml`, `scripts/render.py`, `deploy/`
   - ✅ Add `.gitignore` entries to prevent re-adding these files
   - ✅ Update pipeline Terraform configurations
   - ✅ Update buildspec files
   - ✅ Create migration documentation

2. **Private Repository** (`rosa-regional-platform-internal`):
   - ✅ Add `config.yaml`, `scripts/render.py`, `deploy/`
   - Commit and push to main branch

### Phase 2: Update Existing Pipelines

For **each environment and region**, the pipelines need to be updated with the new configuration.

#### Option A: Terraform Re-Apply (Recommended)

```bash
# In pipeline-provisioner or wherever pipelines are managed
cd terraform/modules/pipeline-provisioner
terraform plan
terraform apply
```

This will:
- Update existing pipelines to add the second source action
- Update trigger configurations
- Update CodeBuild projects with correct PrimarySource settings

#### Option B: Manual Update via AWS Console

For each pipeline:

1. **Navigate to CodePipeline in AWS Console**
2. **Select pipeline** (e.g., `rc-pipe-<hash>`)
3. **Click "Edit"**
4. **Update Source Stage:**
   - Rename existing source action to `PublicSource`
   - Add new source action `ConfigSource`:
     - Provider: CodeStar connection
     - Repository: `openshift-online/rosa-regional-platform-internal`
     - Branch: `main`
     - Output artifact: `config_source`
5. **Update Deploy Stage:**
   - Edit `ApplyInfrastructure` action
   - Add `config_source` to input artifacts
   - Set `PrimarySource` = `public_source`
6. **Update Bootstrap Stage:**
   - Edit `BootstrapArgoCD` action
   - Add `config_source` to input artifacts
   - Set `PrimarySource` = `apply_output`
7. **Save pipeline changes**

### Phase 3: Testing

#### Test Regional Cluster Pipeline

1. Make a change in `terraform/config/pipeline-regional-cluster/`
2. Push to trigger pipeline
3. Verify:
   - ✅ Both sources are checked out
   - ✅ Config files are found at `${CODEBUILD_SRC_DIR_config_source}/deploy/`
   - ✅ Infrastructure deploys successfully
   - ✅ ArgoCD bootstrap completes

#### Test Management Cluster Pipeline

1. Make a change in `terraform/config/pipeline-management-cluster/`
2. Push to trigger pipeline
3. Verify:
   - ✅ Both sources are checked out
   - ✅ Config files are found correctly
   - ✅ IoT minting succeeds
   - ✅ Infrastructure deploys successfully
   - ✅ ArgoCD bootstrap completes
   - ✅ MC registration with RC succeeds

#### Test Config Changes

1. Make a change in the **private repository**:
   ```bash
   cd rosa-regional-platform-internal
   vim config.yaml
   ./scripts/render.py
   git add config.yaml deploy/
   git commit -m "test: update config"
   git push
   ```

2. Manually trigger pipeline (config changes don't auto-trigger)
3. Verify pipelines pick up new config

### Phase 4: Update Documentation

Update documentation references to reflect the new dual-repository model:

- ✅ [MIGRATION-CONFIG-FILES.md](../MIGRATION-CONFIG-FILES.md) - Created
- [ ] [docs/full-region-provisioning.md](full-region-provisioning.md)
- [ ] [docs/central-pipeline-provisioning.md](central-pipeline-provisioning.md)
- [ ] [docs/design/pipeline-based-lifecycle.md](design/pipeline-based-lifecycle.md)
- [ ] [README.md](../README.md)

## Rollback Plan

If issues arise, rollback steps:

1. **Revert Terraform changes:**
   ```bash
   git revert <commit-sha>
   terraform apply
   ```

2. **Restore files to public repo temporarily:**
   ```bash
   # Copy from private repo
   cp -r ../rosa-regional-platform-internal/config.yaml .
   cp -r ../rosa-regional-platform-internal/scripts/render.py scripts/
   cp -r ../rosa-regional-platform-internal/deploy .
   git add config.yaml scripts/render.py deploy/
   git commit -m "rollback: temporarily restore config files"
   ```

3. **Revert pipeline configurations** via AWS Console or Terraform

## Troubleshooting

### Issue: Config files not found

**Symptoms:**
```
ERROR: Regional cluster config not found: ${CODEBUILD_SRC_DIR_config_source}/deploy/.../regional.json
```

**Checks:**
1. Verify `config_source` artifact is listed in pipeline stage inputs
2. Check CodeBuild logs for source checkout:
   ```
   [Container] 2024/03/05 Phase is DOWNLOAD_SOURCE
   [Container] Downloading source 1: public_source
   [Container] Downloading source 2: config_source
   ```
3. List available files:
   ```bash
   ls -la ${CODEBUILD_SRC_DIR_config_source}/
   ```

### Issue: Pipeline not triggering on platform code changes

**Symptoms:** Push to public repo doesn't trigger pipeline

**Fix:** Check trigger configuration includes the right paths:
```hcl
file_paths {
  includes = ["terraform/config/pipeline-regional-cluster/**"]
}
```

### Issue: Wrong source is primary

**Symptoms:** Scripts fail because they're running in the wrong directory context

**Fix:** Ensure `PrimarySource` is set correctly in pipeline configuration:
- For Apply stages: `PrimarySource = "public_source"`
- For Bootstrap stages: `PrimarySource = "apply_output"` or `"public_source"`

## Security Considerations

1. **Private Repository Access:**
   - CodeStar connection must have access to the private repository
   - Verify IAM roles have permissions to read from both repositories

2. **Config Files Security:**
   - Config files remain in private repository only
   - Pipelines read them at runtime but don't persist in public artifacts
   - Ensure CodeBuild logs don't expose sensitive values

3. **Branch Protection:**
   - Keep branch protection on `main` in both repositories
   - Require PR reviews for config changes
   - Consider separate approval workflows for sensitive config changes

## Next Steps

1. ✅ Complete Phase 1 (code changes)
2. ⏳ Complete Phase 2 (update pipelines)
3. ⏳ Complete Phase 3 (testing)
4. ⏳ Complete Phase 4 (documentation updates)
5. ⏳ Monitor production pipelines for 1 week
6. ⏳ Update runbooks and operational procedures

## Questions?

Contact the platform team or file an issue in the public repository.
