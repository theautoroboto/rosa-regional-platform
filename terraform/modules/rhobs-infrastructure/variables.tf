# =============================================================================
# RHOBS Infrastructure Module - Variables
#
# Configuration for RHOBS observability infrastructure including S3 storage,
# ElastiCache, and PrivateLink connectivity for fleet clusters
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where resources will be deployed"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for ElastiCache and NLB deployment"
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity associations"
  type        = string
}

variable "eks_cluster_security_group_id" {
  description = "EKS cluster additional security group ID for ElastiCache access"
  type        = string
}

variable "eks_cluster_primary_security_group_id" {
  description = "EKS cluster primary security group ID for ElastiCache access (used by Auto Mode nodes)"
  type        = string
}

variable "bastion_security_group_id" {
  description = "Optional bastion security group ID for troubleshooting access"
  type        = string
  default     = null
}

# S3 Configuration
variable "metrics_retention_days" {
  description = "Number of days to retain metrics in S3 before deletion"
  type        = number
  default     = 90
}

variable "logs_retention_days" {
  description = "Number of days to retain logs in S3 before deletion"
  type        = number
  default     = 90
}

variable "enable_s3_versioning" {
  description = "Enable versioning on S3 buckets (recommended for production)"
  type        = bool
  default     = false
}

# ElastiCache Configuration
variable "cache_node_type" {
  description = "ElastiCache node type for Memcached cluster"
  type        = string
  default     = "cache.r6g.large"
}

variable "cache_num_nodes" {
  description = "Number of cache nodes in the Memcached cluster"
  type        = number
  default     = 3
}

variable "cache_parameter_group_name" {
  description = "ElastiCache parameter group name"
  type        = string
  default     = "default.memcached1.6"
}

variable "cache_engine_version" {
  description = "Memcached engine version"
  type        = string
  default     = "1.6.17"
}

variable "cache_port" {
  description = "Port for Memcached cluster"
  type        = number
  default     = 11211
}

# Tagging
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
