# =============================================================================
# Management Cluster Infrastructure Variables
# =============================================================================

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by bastion and ECS bootstrap)"
  type        = string
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

# =============================================================================
# Bastion Configuration Variables
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}

# =============================================================================
# Maestro Configuration Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier for resource naming (e.g., 'mc01' or 'xg4y-mc01' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "sector" {
  description = "Sector name for tagging (e.g., 'integration', 'us-gov')"
  type        = string
}

variable "regional_aws_account_id" {
  description = "AWS account ID where the regional cluster and IoT Core are hosted"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.regional_aws_account_id))
    error_message = "regional_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "maestro_agent_cert_file" {
  description = "Path to JSON file containing Maestro agent certificate material (from IoT Mint outputs)"
  type        = string
}

variable "maestro_agent_config_file" {
  description = "Path to JSON file containing Maestro agent MQTT configuration (from IoT Mint outputs)"
  type        = string
}

# =============================================================================
# Thanos Gateway Configuration Variables
# =============================================================================

variable "enable_thanos_gateway" {
  description = "Enable Thanos Observability Gateway with SigV4 authentication"
  type        = bool
  default     = false
}

variable "thanos_allowed_account_ids" {
  description = "List of AWS account IDs allowed to write metrics via cross-account role assumption"
  type        = list(string)
  default     = []
}

variable "thanos_external_id" {
  description = "External ID required for cross-account role assumption (additional security)"
  type        = string
  default     = "thanos-metrics-writer"
}

variable "thanos_api_domain_name" {
  description = "Custom domain name for the Thanos API (e.g., metrics.us-east-1.example.com)"
  type        = string
  default     = null
}

variable "thanos_hosted_zone_id" {
  description = "Route53 hosted zone ID for the Thanos API custom domain"
  type        = string
  default     = null
}
