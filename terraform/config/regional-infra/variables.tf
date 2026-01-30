variable "github_repo_owner" {
  type        = string
  description = "GitHub Repository Owner"
}

variable "github_repo_name" {
  type        = string
  description = "GitHub Repository Name"
}

variable "github_branch" {
  type        = string
  description = "GitHub Branch to track"
  default     = "main"
}

variable "codestar_connection_arn" {
  type        = string
  description = "ARN of the CodeStar Connection to GitHub"
}

variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

variable "assume_role_arn" {
  description = "Role ARN to assume for provisioning resources (Cross-Account)"
  type        = string
  default     = null
}
