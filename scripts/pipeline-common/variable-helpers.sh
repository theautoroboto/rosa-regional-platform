#!/bin/bash
# =============================================================================
# Variable Helper Functions
# =============================================================================
# This script provides utilities for variable manipulation, resolution, and
# transformation commonly needed in pipeline scripts.
#
# Usage:
#   source scripts/pipeline-common/variable-helpers.sh
#   resolved_value=$(resolve_ssm_param "ssm:///my/param" "us-east-1")
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve SSM Parameter
# -----------------------------------------------------------------------------
# Resolves AWS Systems Manager (SSM) Parameter Store values.
#
# If the value starts with "ssm://", fetches the parameter value from SSM.
# Otherwise, returns the value unchanged.
#
# Arguments:
#   $1 - value: The value to resolve (may be "ssm://param-name" or plain value)
#   $2 - region: (Optional) AWS region for SSM lookup (defaults to AWS_REGION env var)
#
# Returns:
#   The resolved parameter value (from SSM or original value)
#
# Examples:
#   # Resolve SSM parameter
#   account_id=$(resolve_ssm_param "ssm:///rosa/regional/account-id" "us-east-1")
#
#   # Pass-through plain value
#   account_id=$(resolve_ssm_param "123456789012" "us-east-1")
#   # Returns: 123456789012
# -----------------------------------------------------------------------------
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION:-}}"

    # Check if value starts with ssm://
    if [[ "$value" == ssm://* ]]; then
        # Extract parameter name (remove ssm:// prefix)
        local param_name="${value#ssm://}"

        # Validate region is set
        if [[ -z "$region" ]]; then
            echo "ERROR: AWS region not specified for SSM parameter resolution" >&2
            echo "  Parameter: $param_name" >&2
            echo "  Provide region as second argument or set AWS_REGION environment variable" >&2
            return 1
        fi

        echo "Resolving SSM parameter: $param_name in region ${region}" >&2

        # Fetch parameter from SSM
        local resolved_value
        resolved_value=$(aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}" 2>&1)

        local status=$?
        if [[ $status -ne 0 ]]; then
            echo "ERROR: Failed to resolve SSM parameter: $param_name" >&2
            echo "  Region: $region" >&2
            echo "  AWS CLI output: $resolved_value" >&2
            return 1
        fi

        echo "$resolved_value"
    else
        # Not an SSM parameter, return value unchanged
        echo "$value"
    fi
}

# -----------------------------------------------------------------------------
# Convert Boolean String to Terraform Format
# -----------------------------------------------------------------------------
# Converts various boolean representations to Terraform's "true"/"false" strings.
#
# Recognizes as true: "true", "1", "yes", "y" (case-insensitive)
# Everything else is treated as false.
#
# Arguments:
#   $1 - value: The value to convert
#   $2 - default: (Optional) Default value if input is empty (defaults to "false")
#
# Returns:
#   "true" or "false" (Terraform boolean string)
#
# Examples:
#   enable_bastion=$(to_terraform_bool "$ENABLE_BASTION" "false")
#   # Input: "1" → Output: "true"
#   # Input: "true" → Output: "true"
#   # Input: "false" → Output: "false"
#   # Input: "" → Output: "false" (default)
# -----------------------------------------------------------------------------
to_terraform_bool() {
    local value="${1:-}"
    local default="${2:-false}"

    # Use default if value is empty
    if [[ -z "$value" ]]; then
        value="$default"
    fi

    # Convert to lowercase for comparison
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

    # Check for truthy values
    if [[ "$value" == "true" ]] || [[ "$value" == "1" ]] || \
       [[ "$value" == "yes" ]] || [[ "$value" == "y" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# -----------------------------------------------------------------------------
# Get Value with Fallback
# -----------------------------------------------------------------------------
# Returns the first non-empty value from a list of arguments.
# Similar to shell parameter expansion ${var:-default} but for multiple fallbacks.
#
# Arguments:
#   $@ - values: List of values to check (in priority order)
#
# Returns:
#   The first non-empty value, or empty string if all are empty
#
# Examples:
#   branch=$(get_value_with_fallback "$REPOSITORY_BRANCH" "$GITHUB_BRANCH" "main")
#   # Returns: REPOSITORY_BRANCH if set, else GITHUB_BRANCH if set, else "main"
# -----------------------------------------------------------------------------
get_value_with_fallback() {
    for value in "$@"; do
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    done
    echo ""
}

# Export functions so they're available to sourcing scripts
export -f resolve_ssm_param
export -f to_terraform_bool
export -f get_value_with_fallback
