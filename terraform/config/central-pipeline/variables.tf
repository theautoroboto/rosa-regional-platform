variable "github_repo_url" {
  description = "The URL of the GitHub repository (deprecated - used for reference only)"
  type        = string
  default     = "https://github.com/theautoroboto/rosa-regional-platform"
}

variable "github_repo_full_name" {
  description = "The full repository name in format 'owner/repo' (e.g., 'theautoroboto/rosa-regional-platform')"
  type        = string
  default     = "theautoroboto/rosa-regional-platform"
}

variable "github_repo_branch" {
  description = "The branch of the GitHub repository to use"
  type        = string
  default     = "main"
}

variable "github_connection_name" {
  description = "Name for the CodeStar Connection to GitHub"
  type        = string
  default     = "github-rosa-pipeline"
}

variable "target_account_ids" {
  description = "List of AWS Account IDs that the CodeBuild role is allowed to assume roles in"
  type        = list(string)
  default     = ["109342711269", "114594328247"]
}

variable "target_role_name" {
  description = "Name of the IAM role to assume in target accounts"
  type        = string
  default     = "OrganizationAccountAccessRole"
}
