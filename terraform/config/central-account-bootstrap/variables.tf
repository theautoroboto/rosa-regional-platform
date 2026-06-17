# =============================================================================
# GitHub Repository Configuration
# =============================================================================

variable "github_repository" {
  type        = string
  description = "GitHub Repository in owner/name format (e.g., 'octocat/hello-world')"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "name_prefix" {
  type        = string
  description = "Optional prefix for resource names (e.g., CI run hash for parallel e2e runs)"
  default     = ""
}

# =============================================================================
# AWS Configuration
# =============================================================================

variable "region" {
  type        = string
  description = "AWS Region for the Pipeline Infrastructure"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment to monitor (e.g., integration, staging, production)"
  default     = "staging"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be a single path segment (lowercase letters, digits, hyphen)."
  }
}

# =============================================================================
# Notifications Configuration
# =============================================================================

variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (only required for staging, production, integration environments)"
  default     = "/rosa-regional/slack/webhook-url"
}

# =============================================================================
# AMI Builder Configuration
# =============================================================================

variable "trusted_principal_arns" {
  description = "IAM ARNs (users or roles) allowed to assume the packer-ami-build role"
  type        = list(string)
  default     = []
}

variable "ami_consumer_account_ids" {
  description = "AWS account IDs that will launch instances from the built AMIs (granted KMS key access)"
  type        = list(string)
  default     = []
}

