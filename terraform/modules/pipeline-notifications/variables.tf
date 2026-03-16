variable "pipeline_name" {
  description = "Name of the CodePipeline to monitor"
  type        = string
}

variable "slack_webhook_secret" {
  description = "AWS Secrets Manager secret name containing the Slack webhook URL"
  type        = string
  default     = "pipeline-notifications/slack-webhook"
}

variable "notification_channels" {
  description = "List of Slack channels to notify (for display purposes only)"
  type        = list(string)
  default     = ["#pipeline-alerts"]
}

variable "notify_on_failed" {
  description = "Send notifications when pipeline fails"
  type        = bool
  default     = true
}

variable "notify_on_stopped" {
  description = "Send notifications when pipeline is stopped"
  type        = bool
  default     = true
}

variable "notify_on_superseded" {
  description = "Send notifications when pipeline is superseded by a newer execution"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Number of days to retain Lambda CloudWatch logs"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
