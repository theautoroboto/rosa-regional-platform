#!/bin/bash
# =============================================================================
# Validation Helper Functions
# =============================================================================
# This script provides common validation functions to ensure required
# environment variables, AWS resources, and configurations are valid before
# proceeding with pipeline operations.
#
# Usage:
#   source scripts/pipeline-common/validation-helpers.sh
#   validate_required_env_vars TARGET_ACCOUNT_ID TARGET_REGION || exit 1
#   validate_aws_account_id "$TARGET_ACCOUNT_ID" "Target Account ID" || exit 1
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Validate AWS Account ID
# -----------------------------------------------------------------------------
# Validates that an AWS account ID is non-empty and has the correct format.
#
# Arguments:
#   $1 - account_id: The AWS account ID to validate
#   $2 - context: (Optional) Description for error messages (default: "Account ID")
#
# Returns:
#   0 if valid, 1 if invalid
#
# Examples:
#   validate_aws_account_id "$TARGET_ACCOUNT_ID" "Target Account ID" || exit 1
#   validate_aws_account_id "123456789012" || exit 1
# -----------------------------------------------------------------------------
validate_aws_account_id() {
    local account_id="$1"
    local context="${2:-Account ID}"

    if [[ -z "$account_id" ]]; then
        echo "❌ ERROR: ${context} is not set or empty" >&2
        return 1
    fi

    if ! [[ "$account_id" =~ ^[0-9]{12}$ ]]; then
        echo "❌ ERROR: ${context} must be a 12-digit number, got: ${account_id}" >&2
        return 1
    fi

    echo "✓ ${context} validated: ${account_id}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate AWS Region
# -----------------------------------------------------------------------------
# Validates that an AWS region is non-empty and has a valid format.
#
# Arguments:
#   $1 - region: The AWS region to validate
#   $2 - context: (Optional) Description for error messages (default: "Region")
#
# Returns:
#   0 if valid, 1 if invalid
#
# Examples:
#   validate_aws_region "$TARGET_REGION" "Target Region" || exit 1
#   validate_aws_region "us-east-1" || exit 1
# -----------------------------------------------------------------------------
validate_aws_region() {
    local region="$1"
    local context="${2:-Region}"

    if [[ -z "$region" ]]; then
        echo "❌ ERROR: ${context} is not set or empty" >&2
        return 1
    fi

    # Basic region format check (e.g., us-east-1, eu-west-2, ap-southeast-1)
    if ! [[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        echo "❌ ERROR: ${context} has invalid format: ${region}" >&2
        echo "   Expected format: <region>-<location>-<number> (e.g., us-east-1)" >&2
        return 1
    fi

    echo "✓ ${context} validated: ${region}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate Required Environment Variables
# -----------------------------------------------------------------------------
# Checks that all specified environment variables are set and non-empty.
#
# Arguments:
#   $@ - var_names: Names of environment variables to validate
#
# Returns:
#   0 if all variables are set, 1 if any are missing
#
# Examples:
#   validate_required_env_vars TARGET_ACCOUNT_ID TARGET_REGION TARGET_ALIAS || exit 1
#   validate_required_env_vars GITHUB_REPOSITORY GITHUB_BRANCH || exit 1
# -----------------------------------------------------------------------------
validate_required_env_vars() {
    local -a missing_vars=()

    for var_name in "$@"; do
        if [[ -z "${!var_name:-}" ]]; then
            missing_vars+=("$var_name")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "❌ ERROR: Required environment variables not set:" >&2
        printf '   - %s\n' "${missing_vars[@]}" >&2
        return 1
    fi

    echo "✓ All required environment variables set (${#@} variables)" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate File Exists
# -----------------------------------------------------------------------------
# Checks that a file exists at the specified path.
#
# Arguments:
#   $1 - file_path: Path to the file to validate
#   $2 - context: (Optional) Description for error messages (default: "File")
#
# Returns:
#   0 if file exists, 1 if missing
#
# Examples:
#   validate_file_exists "$CONFIG_FILE" "Configuration file" || exit 1
#   validate_file_exists "/path/to/file.json" || exit 1
# -----------------------------------------------------------------------------
validate_file_exists() {
    local file_path="$1"
    local context="${2:-File}"

    if [[ ! -f "$file_path" ]]; then
        echo "❌ ERROR: ${context} not found: ${file_path}" >&2
        return 1
    fi

    echo "✓ ${context} found: ${file_path}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate Directory Exists
# -----------------------------------------------------------------------------
# Checks that a directory exists at the specified path.
#
# Arguments:
#   $1 - dir_path: Path to the directory to validate
#   $2 - context: (Optional) Description for error messages (default: "Directory")
#
# Returns:
#   0 if directory exists, 1 if missing
#
# Examples:
#   validate_directory_exists "$DEPLOY_DIR" "Deployment directory" || exit 1
#   validate_directory_exists "/path/to/dir" || exit 1
# -----------------------------------------------------------------------------
validate_directory_exists() {
    local dir_path="$1"
    local context="${2:-Directory}"

    if [[ ! -d "$dir_path" ]]; then
        echo "❌ ERROR: ${context} not found: ${dir_path}" >&2
        return 1
    fi

    echo "✓ ${context} found: ${dir_path}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate Non-Empty Variable
# -----------------------------------------------------------------------------
# Checks that a variable is set and non-empty.
#
# Arguments:
#   $1 - value: The value to check
#   $2 - var_name: Name of the variable for error messages
#
# Returns:
#   0 if non-empty, 1 if empty
#
# Examples:
#   validate_non_empty "$APP_CODE" "APP_CODE" || exit 1
#   validate_non_empty "$CLUSTER_ID" "CLUSTER_ID" || exit 1
# -----------------------------------------------------------------------------
validate_non_empty() {
    local value="$1"
    local var_name="$2"

    if [[ -z "$value" ]]; then
        echo "❌ ERROR: ${var_name} is not set or empty" >&2
        return 1
    fi

    echo "✓ ${var_name} is set: ${value}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate JSON File
# -----------------------------------------------------------------------------
# Validates that a file exists and contains valid JSON.
#
# Arguments:
#   $1 - file_path: Path to the JSON file
#   $2 - context: (Optional) Description for error messages (default: "JSON file")
#
# Returns:
#   0 if valid JSON, 1 if invalid or missing
#
# Examples:
#   validate_json_file "$CONFIG_FILE" "Configuration" || exit 1
#   validate_json_file "/path/to/file.json" || exit 1
# -----------------------------------------------------------------------------
validate_json_file() {
    local file_path="$1"
    local context="${2:-JSON file}"

    # First check if file exists
    if ! validate_file_exists "$file_path" "$context"; then
        return 1
    fi

    # Then validate JSON syntax
    if ! jq empty "$file_path" 2>/dev/null; then
        echo "❌ ERROR: ${context} contains invalid JSON: ${file_path}" >&2
        return 1
    fi

    echo "✓ ${context} is valid JSON: ${file_path}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Validate GitHub Repository Format
# -----------------------------------------------------------------------------
# Validates that a GitHub repository is in "owner/repo" format.
#
# Arguments:
#   $1 - repository: The repository string to validate
#   $2 - context: (Optional) Description for error messages (default: "GitHub repository")
#
# Returns:
#   0 if valid format, 1 if invalid
#
# Examples:
#   validate_github_repository "$GITHUB_REPOSITORY" || exit 1
#   validate_github_repository "owner/repo" "Repository" || exit 1
# -----------------------------------------------------------------------------
validate_github_repository() {
    local repository="$1"
    local context="${2:-GitHub repository}"

    if [[ -z "$repository" ]]; then
        echo "❌ ERROR: ${context} is not set or empty" >&2
        return 1
    fi

    if ! [[ "$repository" =~ ^[^/]+/[^/]+$ ]]; then
        echo "❌ ERROR: ${context} must be in 'owner/name' format" >&2
        echo "   Got: ${repository}" >&2
        echo "   Example: openshift-online/rosa-regional-platform" >&2
        return 1
    fi

    echo "✓ ${context} format valid: ${repository}" >&2
    return 0
}

# Export functions so they're available to sourcing scripts
export -f validate_aws_account_id
export -f validate_aws_region
export -f validate_required_env_vars
export -f validate_file_exists
export -f validate_directory_exists
export -f validate_non_empty
export -f validate_json_file
export -f validate_github_repository
