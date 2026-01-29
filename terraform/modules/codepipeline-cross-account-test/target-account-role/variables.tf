variable "role_name" {
  description = "Name of the IAM role to create in the target account"
  type        = string
  default     = "CodePipelineCrossAccountRole"
}

variable "central_account_id" {
  description = "AWS Account ID of the central account where CodePipeline runs"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.central_account_id))
    error_message = "Central Account ID must be a 12-digit AWS account ID."
  }
}

variable "central_codebuild_role_arn" {
  description = "ARN of the CodeBuild IAM role in the central account"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.central_codebuild_role_arn))
    error_message = "Must be a valid IAM role ARN."
  }
}

variable "external_id" {
  description = "External ID for additional security when assuming the role (optional but recommended)"
  type        = string
  default     = ""
}

variable "additional_policy_json" {
  description = "Additional IAM policy JSON to attach to the role (for actual workloads beyond testing)"
  type        = string
  default     = null
}
