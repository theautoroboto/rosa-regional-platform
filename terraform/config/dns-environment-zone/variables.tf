variable "environment_domain" {
  description = "Environment domain name (e.g. int0.rosa.devshift.net)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.environment_domain))
    error_message = "environment_domain must be a valid domain name."
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g. integration, staging, production)"
  type        = string
}
