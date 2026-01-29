variable "aws_region" {
  description = "AWS region where the CodePipeline will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "test"
}

variable "target_account_1_id" {
  description = "AWS Account ID for the first target account"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_1_id))
    error_message = "Target Account 1 ID must be a 12-digit AWS account ID."
  }
}

variable "target_account_2_id" {
  description = "AWS Account ID for the second target account"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_2_id))
    error_message = "Target Account 2 ID must be a 12-digit AWS account ID."
  }
}

variable "target_role_name" {
  description = "Name of the IAM role to assume in target accounts"
  type        = string
  default     = "CodePipelineCrossAccountRole"
}
