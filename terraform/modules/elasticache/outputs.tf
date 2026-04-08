# =============================================================================
# Outputs
# =============================================================================

output "redis_endpoint" {
  description = "Redis primary endpoint in host:port format, ready for Thanos cache config"
  value       = "${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
}

output "redis_host" {
  description = "Redis primary endpoint hostname"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.redis.port
}

output "security_group_id" {
  description = "ElastiCache security group ID"
  value       = aws_security_group.elasticache.id
}

output "kms_key_arn" {
  description = "KMS key ARN used for ElastiCache at-rest encryption"
  value       = aws_kms_key.elasticache.arn
}
