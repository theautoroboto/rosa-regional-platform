#!/bin/bash
# =============================================================================
# Buildspec Common Setup Functions
# =============================================================================
# This script provides common setup functions for CodeBuild buildspecs to
# eliminate duplication across regional-cluster and management-cluster pipelines.
#
# Usage:
#   source scripts/pipeline-common/buildspec-common.sh
#   setup_common_environment
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Setup common Terraform variables
# -----------------------------------------------------------------------------
# Sets TF_VAR_* environment variables that are common across all cluster types:
# - region, app_code, service_phase, cost_center
# - repository_url, repository_branch
#
# These variables are sourced from the environment and should be set by
# provision-pipelines.sh or pipeline configuration.
# -----------------------------------------------------------------------------
setup_common_tf_vars() {
    echo "Setting common Terraform variables..."

    # Core tagging variables
    export TF_VAR_region="${TARGET_REGION}"
    export TF_VAR_app_code="${APP_CODE}"
    export TF_VAR_service_phase="${SERVICE_PHASE}"
    export TF_VAR_cost_center="${COST_CENTER}"

    # Repository URL and branch with proper fallback handling for set -u
    # Note: CODEBUILD_SOURCE_VERSION contains S3 artifact location, not git branch
    # Use REPOSITORY_BRANCH (from CodeBuild env vars) or GITHUB_BRANCH instead
    local repo_branch="${REPOSITORY_BRANCH:-${GITHUB_BRANCH:-main}}"
    export TF_VAR_repository_url="${REPOSITORY_URL:-https://github.com/${GITHUB_REPOSITORY}.git}"
    export TF_VAR_repository_branch="${repo_branch}"

    echo "  Region: $TF_VAR_region"
    echo "  App Code: $TF_VAR_app_code"
    echo "  Service Phase: $TF_VAR_service_phase"
    echo "  Cost Center: $TF_VAR_cost_center"
    echo "  Repository URL: $TF_VAR_repository_url"
    echo "  Repository Branch: $TF_VAR_repository_branch"
}

# -----------------------------------------------------------------------------
# Setup container image variable
# -----------------------------------------------------------------------------
# Sets TF_VAR_container_image from PLATFORM_IMAGE environment variable.
# Fails if PLATFORM_IMAGE is not set, as it's required for ECS tasks.
# -----------------------------------------------------------------------------
setup_container_image() {
    echo "Setting container image variable..."

    if [ -z "${PLATFORM_IMAGE:-}" ]; then
        echo "ERROR: PLATFORM_IMAGE is not set or empty; cannot set TF_VAR_container_image" >&2
        exit 1
    fi

    export TF_VAR_container_image="${PLATFORM_IMAGE}"
    echo "  Container Image: $TF_VAR_container_image"
}

# -----------------------------------------------------------------------------
# Setup enable_bastion variable
# -----------------------------------------------------------------------------
# Converts ENABLE_BASTION environment variable (string "true"/"false" or 1/0)
# to Terraform boolean string ("true" or "false").
# Defaults to "false" if not set.
# -----------------------------------------------------------------------------
setup_enable_bastion() {
    echo "Setting enable_bastion variable..."

    local enable_bastion="${ENABLE_BASTION:-false}"
    if [ "$enable_bastion" == "true" ] || [ "$enable_bastion" == "1" ]; then
        export TF_VAR_enable_bastion="true"
    else
        export TF_VAR_enable_bastion="false"
    fi

    echo "  Enable Bastion: $TF_VAR_enable_bastion"
}

# -----------------------------------------------------------------------------
# Setup common environment (All-in-one)
# -----------------------------------------------------------------------------
# Runs all common setup functions in the correct order:
# 1. Preflight checks (validates env vars, inits account helpers)
# 2. Common Terraform variables
# 3. Container image variable
# 4. Enable bastion variable
#
# This is the main entry point that buildspecs should call.
# -----------------------------------------------------------------------------
setup_common_environment() {
    echo "==========================================="
    echo "Common Environment Setup"
    echo "==========================================="

    # Pre-flight setup (validates env vars, inits account helpers)
    # This script is already sourced in buildspecs before this function is called
    # source scripts/pipeline-common/setup-apply-preflight.sh

    # Setup common variables
    setup_common_tf_vars
    setup_container_image
    setup_enable_bastion

    echo "==========================================="
    echo "Common Environment Setup Complete"
    echo "==========================================="
    echo ""
}

# Export functions so they're available to sourcing scripts
export -f setup_common_tf_vars
export -f setup_container_image
export -f setup_enable_bastion
export -f setup_common_environment
