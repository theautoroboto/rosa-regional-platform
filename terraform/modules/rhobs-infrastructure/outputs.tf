# =============================================================================
# RHOBS Infrastructure Module - Outputs
#
# Exports resource identifiers and connection details for use by
# RHOBS ArgoCD Helm charts and fleet cluster configurations
# =============================================================================

# =============================================================================
# S3 Bucket Outputs
# =============================================================================

output "metrics_bucket_name" {
  description = "Name of the S3 bucket for metrics storage (Thanos)"
  value       = aws_s3_bucket.rhobs_metrics.id
}

output "metrics_bucket_arn" {
  description = "ARN of the S3 bucket for metrics storage"
  value       = aws_s3_bucket.rhobs_metrics.arn
}

output "logs_bucket_name" {
  description = "Name of the S3 bucket for logs storage (Loki)"
  value       = aws_s3_bucket.rhobs_logs.id
}

output "logs_bucket_arn" {
  description = "ARN of the S3 bucket for logs storage"
  value       = aws_s3_bucket.rhobs_logs.arn
}

# =============================================================================
# ElastiCache Outputs
# =============================================================================

output "cache_cluster_id" {
  description = "ID of the ElastiCache Memcached cluster"
  value       = aws_elasticache_cluster.rhobs.id
}

output "cache_cluster_address" {
  description = "Configuration endpoint address of the Memcached cluster"
  value       = aws_elasticache_cluster.rhobs.configuration_endpoint
}

output "cache_cluster_port" {
  description = "Port number of the Memcached cluster"
  value       = aws_elasticache_cluster.rhobs.port
}

# =============================================================================
# IAM Role Outputs
# =============================================================================

output "thanos_role_arn" {
  description = "ARN of the IAM role for Thanos components"
  value       = aws_iam_role.thanos.arn
}

output "thanos_role_name" {
  description = "Name of the IAM role for Thanos components"
  value       = aws_iam_role.thanos.name
}

output "loki_role_arn" {
  description = "ARN of the IAM role for Loki components"
  value       = aws_iam_role.loki.arn
}

output "loki_role_name" {
  description = "Name of the IAM role for Loki components"
  value       = aws_iam_role.loki.name
}

# =============================================================================
# Connection Information (for Helm chart values)
# =============================================================================

output "thanos_s3_config" {
  description = "S3 configuration object for Thanos"
  value = {
    bucket = aws_s3_bucket.rhobs_metrics.id
    region = data.aws_region.current.name
  }
}

output "loki_s3_config" {
  description = "S3 configuration object for Loki"
  value = {
    bucket = aws_s3_bucket.rhobs_logs.id
    region = data.aws_region.current.name
  }
}

output "memcached_config" {
  description = "Memcached configuration object for query caching"
  value = {
    address = aws_elasticache_cluster.rhobs.configuration_endpoint
    port    = aws_elasticache_cluster.rhobs.port
  }
}
