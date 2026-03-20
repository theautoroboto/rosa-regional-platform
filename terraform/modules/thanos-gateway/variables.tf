# =============================================================================
# Required Variables
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the ALB and VPC Link will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ALB and VPC Link placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming (e.g., 'us-east-1-prod')"
  type        = string
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - required for tagging target group with eks:eks-cluster-name tag"
  type        = string
}

# =============================================================================
# API Gateway Configuration
# =============================================================================

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.stage_name))
    error_message = "Stage name can only contain alphanumeric characters, hyphens, and underscores."
  }
}

# =============================================================================
# Custom Domain Configuration (Optional)
# =============================================================================

variable "api_domain_name" {
  description = "Custom domain name for the Thanos API (e.g., metrics.us-east-1.example.com). When null, no custom domain is created."
  type        = string
  default     = null
}

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for ACM DNS validation and API alias record. Required when api_domain_name is set."
  type        = string
  default     = null
}

# =============================================================================
# Cross-Account Access (Optional)
# =============================================================================

variable "allowed_account_ids" {
  description = "List of AWS account IDs allowed to assume the cross-account metrics writer role. Leave empty to disable cross-account access."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "All account IDs must be 12-digit numbers."
  }
}

variable "external_id" {
  description = "External ID required when assuming the cross-account role (for additional security)"
  type        = string
  default     = "thanos-metrics-writer"
}
