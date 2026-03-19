# =============================================================================
# Required Variables
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the ALB and VPC Link will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ALB and VPC Link placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - required for tagging target groups"
  type        = string
}

variable "truststore_uri" {
  description = "S3 URI of the truststore PEM file containing ACM Private CA certificate (e.g., s3://bucket/truststore.pem)"
  type        = string

  validation {
    condition     = can(regex("^s3://[a-z0-9][a-z0-9.-]+[a-z0-9]/.*", var.truststore_uri))
    error_message = "truststore_uri must be a valid S3 URI (s3://bucket/key)."
  }
}

variable "truststore_version" {
  description = "S3 object version ID of the truststore. Used to trigger mTLS config updates."
  type        = string
  default     = null
}

variable "api_domain_name" {
  description = "Custom domain name for the RHOBS API Gateway (e.g. rhobs.us-east-1.int0.rosa.devshift.net)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.api_domain_name))
    error_message = "api_domain_name must be a valid domain name."
  }
}

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional delegation zone"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}
