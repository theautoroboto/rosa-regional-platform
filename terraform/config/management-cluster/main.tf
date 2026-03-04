# =============================================================================
# Common Variables Module
# =============================================================================
# Centralized variable definitions shared across all cluster types
# =============================================================================

module "common_vars" {
  source = "../../modules/common-variables"

  # AWS Infrastructure
  region            = var.region
  container_image   = var.container_image
  target_account_id = var.target_account_id
  target_alias      = var.target_alias

  # Tagging
  app_code      = var.app_code
  service_phase = var.service_phase
  cost_center   = var.cost_center

  # ArgoCD Configuration
  repository_url    = var.repository_url
  repository_branch = var.repository_branch

  # Bastion Configuration
  enable_bastion = var.enable_bastion
}

# =============================================================================
# AWS Provider Configuration
# =============================================================================

provider "aws" {
  region = module.common_vars.region

  # Conditionally assume role for cross-account deployment (local dev only)
  # When target_account_id is set, assume OrganizationAccountAccessRole in target account
  # In pipelines, target_account_id is empty - ambient creds are already the target account
  dynamic "assume_role" {
    for_each = module.common_vars.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${module.common_vars.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-management-${module.common_vars.target_alias}"
    }
  }

  default_tags {
    tags = module.common_vars.common_tags
  }
}

# Call the EKS cluster module for management cluster infrastructure
module "management_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type          = "management-cluster"
  cluster_name_override = var.cluster_id

  # Management cluster sizing
  node_group_min_size     = 1
  node_group_max_size     = 2
  node_group_desired_size = 1
}

# Call the ECS bootstrap module for external bootstrap execution
module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.management_cluster.vpc_id
  private_subnets               = module.management_cluster.private_subnets
  eks_cluster_arn               = module.management_cluster.cluster_arn
  eks_cluster_name              = module.management_cluster.cluster_name
  eks_cluster_security_group_id = module.management_cluster.cluster_security_group_id
  resource_name_base            = module.management_cluster.resource_name_base
  container_image               = module.common_vars.container_image

  # ArgoCD bootstrap configuration
  repository_url    = module.common_vars.repository_url
  repository_branch = module.common_vars.repository_branch
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = module.common_vars.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  resource_name_base        = module.management_cluster.resource_name_base
  cluster_name              = module.management_cluster.cluster_name
  cluster_endpoint          = module.management_cluster.cluster_endpoint
  cluster_security_group_id = module.management_cluster.cluster_security_group_id
  vpc_id                    = module.management_cluster.vpc_id
  private_subnet_ids        = module.management_cluster.private_subnets
  container_image           = module.common_vars.container_image
}

module "maestro_agent" {
  source = "../../modules/maestro-agent"

  cluster_id              = var.cluster_id
  regional_aws_account_id = var.regional_aws_account_id
  eks_cluster_name        = module.management_cluster.cluster_name

  maestro_agent_cert_json   = file(var.maestro_agent_cert_file)
  maestro_agent_config_json = file(var.maestro_agent_config_file)
}
