# =============================================================================
# RHOBS Infrastructure Module - Main Configuration
#
# Creates AWS resources for Red Hat Observability Service (RHOBS) adapted for EKS:
# - S3 buckets for metrics and logs storage (Thanos, Loki backends)
# - ElastiCache Memcached cluster for query caching
# - IAM roles for observability components
#
# Network ingestion is handled via Kubernetes Service type=LoadBalancer with mTLS
# =============================================================================

# =============================================================================
# Data Sources
# =============================================================================

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# Local Variables
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      Module    = "rhobs-infrastructure"
      ManagedBy = "terraform"
    }
  )

  # S3 bucket names
  metrics_bucket_name = "${var.regional_id}-rhobs-metrics"
  logs_bucket_name    = "${var.regional_id}-rhobs-logs"

  # ElastiCache cluster name
  cache_cluster_id = "${var.regional_id}-rhobs-cache"
}
