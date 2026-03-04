# =============================================================================
# Common Variables Module Outputs
# =============================================================================
# Exposes all common variables so consuming modules can reference them.
#
# Usage in consuming modules:
#   module "common_vars" {
#     source = "../../modules/common-variables"
#     # ... variable inputs ...
#   }
#
#   resource "aws_eks_cluster" "this" {
#     tags = module.common_vars.common_tags
#   }
#
# =============================================================================

# =============================================================================
# AWS Infrastructure Outputs
# =============================================================================

output "region" {
  description = "AWS Region for infrastructure deployment"
  value       = var.region
}

output "container_image" {
  description = "Public ECR image URI for platform container"
  value       = var.container_image
}

output "target_account_id" {
  description = "Target AWS account ID for cross-account deployment"
  value       = var.target_account_id
}

output "target_alias" {
  description = "Alias for the target deployment"
  value       = var.target_alias
}

# =============================================================================
# Tagging Outputs
# =============================================================================

output "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  value       = var.app_code
}

output "service_phase" {
  description = "Service phase for tagging"
  value       = var.service_phase
}

output "cost_center" {
  description = "Cost center for tagging"
  value       = var.cost_center
}

# =============================================================================
# ArgoCD Configuration Outputs
# =============================================================================

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = var.repository_url
}

output "repository_branch" {
  description = "Git branch to use for cluster configuration"
  value       = var.repository_branch
}

# =============================================================================
# Bastion Configuration Outputs
# =============================================================================

output "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access"
  value       = var.enable_bastion
}

# =============================================================================
# Computed Outputs (from locals)
# =============================================================================

output "common_tags" {
  description = "Standard tags to apply to all resources for consistency"
  value       = local.common_tags
}

output "resource_name_prefix" {
  description = "Standard resource name prefix based on service phase and target alias"
  value       = local.resource_name_prefix
}

output "all_tags" {
  description = "Complete tag set including common tags and compliance tags"
  value       = local.all_tags
}

output "is_production" {
  description = "Boolean flag indicating if this is a production environment"
  value       = local.is_production
}

output "is_staging" {
  description = "Boolean flag indicating if this is a staging environment"
  value       = local.is_staging
}

output "is_development" {
  description = "Boolean flag indicating if this is a development environment"
  value       = local.is_development
}
