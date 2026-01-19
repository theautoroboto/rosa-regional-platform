# =============================================================================
# Regional Cluster Infrastructure Configuration
# =============================================================================

# Configure AWS provider
provider "aws" {
  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
    }
  }
}

# Call the EKS cluster module for regional cluster infrastructure
module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type = "regional"

  # Regional cluster sizing
  node_group_min_size     = 1
  node_group_max_size     = 2
  node_group_desired_size = 1
}

# Call the ECS bootstrap module for external bootstrap execution
module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.regional_cluster.vpc_id
  private_subnets              = module.regional_cluster.private_subnets
  eks_cluster_arn              = module.regional_cluster.cluster_arn
  eks_cluster_name             = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.regional_cluster.cluster_security_group_id
  resource_name_base           = module.regional_cluster.resource_name_base

  # ArgoCD bootstrap configuration
  repository_url    = var.repository_url
  repository_path   = var.repository_path
  repository_branch = var.repository_branch
}