variable "account_ids" {
  description = "List of AWS Account IDs to populate in the pool"
  type        = list(string)
  default     = ["109342711269", "114594328247", "095279701323", "507041536644"]
}
