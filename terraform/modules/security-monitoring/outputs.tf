# =============================================================================
# Security Monitoring Outputs
# =============================================================================

output "vpc_flow_log_group_name" {
  description = "CloudWatch log group name for VPC Flow Logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.name
}

output "vpc_flow_log_id" {
  description = "ID of the VPC Flow Log resource"
  value       = aws_flow_log.main.id
}

output "security_metric_namespace" {
  description = "CloudWatch namespace where security metric filters publish counts (scraped by YACE into Prometheus)"
  value       = "Security/${var.cluster_id}"
}
