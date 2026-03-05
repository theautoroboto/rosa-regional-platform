# =============================================================================
# Common Variables Module
# =============================================================================
# This module defines variables that are shared across all cluster types
# (regional clusters, management clusters, and their associated pipelines).
#
# By centralizing these definitions, we ensure consistency in:
# - Variable types and validation rules
# - Default values
# - Documentation
# - Tagging standards
#
# Usage:
#   module "common_vars" {
#     source = "../../modules/common-variables"
#
#     region              = var.region
#     app_code            = var.app_code
#     service_phase       = var.service_phase
#     cost_center         = var.cost_center
#     container_image     = var.container_image
#     target_account_id   = var.target_account_id
#     target_alias        = var.target_alias
#     repository_url      = var.repository_url
#     repository_branch   = var.repository_branch
#     enable_bastion      = var.enable_bastion
#   }
#
# =============================================================================

# =============================================================================
# AWS Infrastructure Variables
# =============================================================================

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "region must be a valid AWS region format (e.g., us-east-1, eu-west-2)"
  }
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by bastion and ECS bootstrap)"
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must be a non-empty ECR image URI"
  }
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""

  validation {
    condition     = var.target_account_id == "" || can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be empty or a 12-digit AWS account ID"
  }
}

variable "target_alias" {
  description = "Alias for the target deployment (used for resource naming and role session identification in CloudTrail)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.target_alias))
    error_message = "target_alias must contain only lowercase letters, numbers, and hyphens"
  }
}

# =============================================================================
# Tagging Variables (Required for CMDB/Cost Tracking)
# =============================================================================

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.app_code))
    error_message = "app_code must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string

  validation {
    condition     = contains(["dev", "development", "staging", "production"], var.service_phase)
    error_message = "service_phase must be one of: development, staging, production"
  }
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{3}$", var.cost_center))
    error_message = "cost_center must be a 3-digit number"
  }
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string

  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+\\.git$", var.repository_url))
    error_message = "repository_url must be a valid GitHub HTTPS URL (e.g., https://github.com/owner/repo.git)"
  }
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"

  validation {
    condition     = length(var.repository_branch) > 0
    error_message = "repository_branch must not be empty"
  }
}

# =============================================================================
# Bastion Configuration Variables
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}
