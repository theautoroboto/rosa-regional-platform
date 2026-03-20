# =============================================================================
# Infrastructure Outputs for Bootstrap Configuration
# =============================================================================

# Cluster identification
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.management_cluster.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.management_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.management_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for kubectl"
  value       = module.management_cluster.cluster_certificate_authority_data
  sensitive   = true
}

# Networking
output "vpc_id" {
  description = "VPC ID where cluster is deployed"
  value       = module.management_cluster.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs where worker nodes are deployed"
  value       = module.management_cluster.private_subnets
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.management_cluster.cluster_security_group_id
}

# =============================================================================
# ECS Bootstrap Outputs for External Script Usage
# =============================================================================

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name for bootstrap tasks"
  value       = module.ecs_bootstrap.ecs_cluster_name
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN for bootstrap execution"
  value       = module.ecs_bootstrap.task_definition_arn
}

output "bootstrap_log_group_name" {
  description = "CloudWatch log group name for bootstrap operations"
  value       = module.ecs_bootstrap.log_group_name
}

output "bootstrap_security_group_id" {
  description = "Security group ID for bootstrap ECS tasks"
  value       = module.ecs_bootstrap.bootstrap_security_group_id
}

# =============================================================================
# ArgoCD Bootstrap Configuration Outputs
# =============================================================================

output "repository_url" {
  description = "Git repository URL for cluster configuration"
  value       = module.ecs_bootstrap.repository_url
}

output "repository_branch" {
  description = "Git branch for cluster configuration"
  value       = module.ecs_bootstrap.repository_branch
}

# =============================================================================
# Bastion Outputs (only available when enable_bastion = true)
# =============================================================================

output "bastion_ecs_cluster_name" {
  description = "ECS cluster name for bastion tasks"
  value       = var.enable_bastion ? module.bastion[0].ecs_cluster_name : null
}

output "bastion_log_group_name" {
  description = "CloudWatch log group name for bastion logs"
  value       = var.enable_bastion ? module.bastion[0].log_group_name : null
}

output "bastion_run_task_command" {
  description = "AWS CLI command to start a bastion task"
  value       = var.enable_bastion ? module.bastion[0].run_task_command : null
}

output "bastion_exec_command_template" {
  description = "AWS CLI command template to connect to a running bastion (replace <TASK_ID>)"
  value       = var.enable_bastion ? module.bastion[0].exec_command_template : null
}

output "bastion_ssm_port_forward_template" {
  description = "AWS CLI command template for SSM port forwarding (replace <TASK_ID> and <RUNTIME_ID>)"
  value       = var.enable_bastion ? module.bastion[0].ssm_port_forward_template : null
}

output "maestro_agent_cert_secret_name" {
  description = "Secret name for Maestro Agent MQTT certificate"
  value       = module.maestro_agent.maestro_agent_cert_secret_name
}

output "maestro_agent_config_secret_name" {
  description = "Secret name for Maestro Agent MQTT configuration"
  value       = module.maestro_agent.maestro_agent_config_secret_name
}

output "maestro_agent_role_arn" {
  description = "IAM role ARN for Maestro Agent"
  value       = module.maestro_agent.maestro_agent_role_arn
}

# =============================================================================
# HyperShift OIDC Outputs
# =============================================================================

output "hypershift_operator_role_arn" {
  description = "IAM role ARN for HyperShift operator"
  value       = module.hypershift_oidc.role_arn
}

output "oidc_bucket_name" {
  description = "S3 bucket name for OIDC discovery documents"
  value       = module.hypershift_oidc.oidc_bucket_name
}

output "oidc_cloudfront_domain" {
  description = "CloudFront domain for OIDC issuer URL (prefix with https://)"
  value       = module.hypershift_oidc.cloudfront_domain_name
}

# =============================================================================
# Thanos Gateway Outputs (only available when enable_thanos_gateway = true)
# =============================================================================

output "thanos_api_gateway_invoke_url" {
  description = "API Gateway invoke URL for Thanos Receive"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].invoke_url : null
}

output "thanos_remote_write_url" {
  description = "Full URL for Prometheus remote_write configuration"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].remote_write_url : null
}

output "thanos_target_group_arn" {
  description = "Target group ARN for Helm TargetGroupBinding"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].target_group_arn : null
}

output "thanos_alb_security_group_id" {
  description = "ALB security group ID for Helm TargetGroupBinding"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].alb_security_group_id : null
}

output "thanos_metrics_writer_policy_arn" {
  description = "IAM policy ARN to attach to metrics writers"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].metrics_writer_policy_arn : null
}

output "thanos_cross_account_role_arn" {
  description = "Cross-account IAM role ARN for external metrics writers"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].cross_account_role_arn : null
}

output "thanos_test_command" {
  description = "awscurl command to test the Thanos API"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].test_command : null
}

output "thanos_prometheus_config" {
  description = "Example Prometheus remote_write configuration"
  value       = var.enable_thanos_gateway ? module.thanos_gateway[0].prometheus_remote_write_config : null
}
