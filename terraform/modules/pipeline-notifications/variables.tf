variable "slack_webhook_url" {
  type        = string
  description = "Slack webhook URL for pipeline failure notifications"
  sensitive   = true
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names (e.g., 'abc123-' or empty string)"
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS Region for the notification resources"
}
