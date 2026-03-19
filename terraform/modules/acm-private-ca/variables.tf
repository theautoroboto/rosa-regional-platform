variable "regional_id" {
  description = "Regional identifier (e.g., 'regional-us-east-1')"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
