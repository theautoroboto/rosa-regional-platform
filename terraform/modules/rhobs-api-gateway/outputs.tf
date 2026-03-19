# =============================================================================
# RHOBS API Gateway Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# API Gateway Endpoints
# -----------------------------------------------------------------------------

output "api_domain_name" {
  description = "RHOBS API Gateway custom domain name"
  value       = module.api_gateway_base.api_domain_name
}

output "api_endpoint_metrics" {
  description = "Thanos Receive metrics ingestion endpoint"
  value       = "https://${module.api_gateway_base.api_domain_name}/metrics"
}

output "api_endpoint_logs" {
  description = "Loki Distributor logs ingestion endpoint"
  value       = "https://${module.api_gateway_base.api_domain_name}/logs"
}

output "invoke_url" {
  description = "API Gateway invoke URL (disabled when mTLS is enabled)"
  value       = module.api_gateway_base.invoke_url
}

# -----------------------------------------------------------------------------
# Target Groups for TargetGroupBinding
# -----------------------------------------------------------------------------

output "thanos_target_group_arn" {
  description = "Thanos Receive target group ARN for TargetGroupBinding"
  value       = module.api_gateway_base.target_group_arn
}

output "loki_target_group_arn" {
  description = "Loki Distributor target group ARN for TargetGroupBinding"
  value       = aws_lb_target_group.loki.arn
}

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = module.api_gateway_base.api_gateway_id
}

output "vpc_link_id" {
  description = "VPC Link ID"
  value       = module.api_gateway_base.vpc_link_id
}

output "alb_arn" {
  description = "Internal ALB ARN"
  value       = module.api_gateway_base.alb_arn
}

output "alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = module.api_gateway_base.alb_dns_name
}

output "alb_listener_arn" {
  description = "ALB listener ARN"
  value       = module.api_gateway_base.alb_listener_arn
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.api_gateway_base.alb_security_group_id
}

output "vpc_link_security_group_id" {
  description = "VPC Link security group ID"
  value       = module.api_gateway_base.vpc_link_security_group_id
}

# -----------------------------------------------------------------------------
# Helper Information
# -----------------------------------------------------------------------------

output "test_commands" {
  description = "Commands to test mTLS endpoints (requires client certificate)"
  value       = <<-EOT
    # Test Thanos Receive health endpoint
    curl -v --cert client.crt --key client.key --cacert ca.crt \
      https://${module.api_gateway_base.api_domain_name}/metrics/-/healthy

    # Test Loki Distributor health endpoint
    curl -v --cert client.crt --key client.key --cacert ca.crt \
      https://${module.api_gateway_base.api_domain_name}/logs/ready
  EOT
}
