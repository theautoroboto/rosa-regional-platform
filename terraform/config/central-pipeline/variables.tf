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

variable "schedule_expression" {
  description = "EventBridge schedule expression for pipeline triggers (e.g., 'rate(1 hour)', 'cron(0 * * * ? *)')"
  type        = string
  default     = "rate(1 hour)"
}
