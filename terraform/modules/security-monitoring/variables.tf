# =============================================================================
# Security Monitoring Variables — FedRAMP SI-04
# =============================================================================

variable "cluster_id" {
  description = "Cluster identifier used for resource naming and the CloudWatch metric namespace (Security/<cluster_id>)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to enable Flow Logs on"
  type        = string
}

variable "eks_audit_log_group_name" {
  description = "CloudWatch log group name for EKS audit logs (e.g. /aws/eks/<cluster>/cluster)"
  type        = string
}

variable "enable_security_hub" {
  description = "Enable AWS Security Hub with NIST 800-53 and AWS Foundational Security Best Practices standards"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention period in days for VPC Flow Logs in CloudWatch"
  type        = number
  default     = 365
}
