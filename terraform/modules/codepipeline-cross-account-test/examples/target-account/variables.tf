variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "role_name" {
  description = "Name of the IAM role to create (must match the name used in central account)"
  type        = string
  default     = "CodePipelineCrossAccountRole"
}

variable "central_account_id" {
  description = "AWS Account ID of the central account where CodePipeline runs"
  type        = string
  # Get this from the central account deployment output
  # Example: "999999999999"
}

variable "central_codebuild_role_arn" {
  description = "ARN of the CodeBuild IAM role in the central account"
  type        = string
  # Get this from the central account deployment output: codebuild_role_arn
  # Example: "arn:aws:iam::999999999999:role/codebuild-cross-account-20240115123456"
}

variable "external_id" {
  description = "External ID for additional security (optional but recommended)"
  type        = string
  default     = ""
  # If you use an external ID, it must match what the central account uses
  # when calling AssumeRole
}
