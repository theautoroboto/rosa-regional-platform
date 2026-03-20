# =============================================================================
# Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# API Gateway
# -----------------------------------------------------------------------------

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = module.api_gateway.api_gateway_id
}

output "api_gateway_arn" {
  description = "API Gateway REST API ARN"
  value       = module.api_gateway.api_gateway_arn
}

output "invoke_url" {
  description = "API Gateway invoke URL for Thanos Receive remote-write endpoint"
  value       = module.api_gateway.invoke_url
}

output "remote_write_url" {
  description = "Full URL for Prometheus remote_write configuration"
  value       = "${module.api_gateway.invoke_url}/api/v1/receive"
}

output "stage_name" {
  description = "API Gateway stage name"
  value       = module.api_gateway.stage_name
}

# -----------------------------------------------------------------------------
# Target Group (for Helm TargetGroupBinding)
# -----------------------------------------------------------------------------

output "target_group_arn" {
  description = "Target group ARN - use this in the Helm chart's TargetGroupBinding"
  value       = module.api_gateway.target_group_arn
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------

output "metrics_writer_policy_arn" {
  description = "IAM policy ARN that grants permission to invoke the Thanos API"
  value       = aws_iam_policy.metrics_writer.arn
}

output "cross_account_role_arn" {
  description = "Cross-account IAM role ARN for metrics writers in other accounts (null if not configured)"
  value       = length(var.allowed_account_ids) > 0 ? aws_iam_role.cross_account_metrics_writer[0].arn : null
}

# -----------------------------------------------------------------------------
# Custom Domain
# -----------------------------------------------------------------------------

output "api_domain_name" {
  description = "Custom domain name for the Thanos API"
  value       = module.api_gateway.api_domain_name
}

output "custom_remote_write_url" {
  description = "Custom domain URL for Prometheus remote_write (null if no custom domain)"
  value       = module.api_gateway.api_domain_name != null ? "https://${module.api_gateway.api_domain_name}/api/v1/receive" : null
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = module.api_gateway.alb_security_group_id
}

output "vpc_link_security_group_id" {
  description = "VPC Link security group ID"
  value       = module.api_gateway.vpc_link_security_group_id
}

# -----------------------------------------------------------------------------
# Test Commands
# -----------------------------------------------------------------------------

output "test_command" {
  description = "awscurl command to test the Thanos API (check readiness)"
  value       = <<-EOT
    # Test Thanos Receive readiness
    awscurl --service execute-api --region $(aws configure get region) \
      "${module.api_gateway.invoke_url}/-/ready"

    # Send a test metric (requires protobuf payload)
    # Use the Go test script in helm-chart/rhobs-cell/test/
  EOT
}

output "prometheus_remote_write_config" {
  description = "Example Prometheus remote_write configuration snippet"
  value       = <<-EOT
    remote_write:
      - url: "${module.api_gateway.invoke_url}/api/v1/receive"
        sigv4:
          region: $(aws configure get region)
        # Optional: if using cross-account role
        # sigv4:
        #   region: <region>
        #   role_arn: ${length(var.allowed_account_ids) > 0 ? aws_iam_role.cross_account_metrics_writer[0].arn : "<cross-account-role-arn>"}
  EOT
}
