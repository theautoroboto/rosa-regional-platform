# Random suffix for resource naming
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  # Generate resource name based on cluster type with random suffix
  resource_name_base = "${var.cluster_type}-${random_string.suffix.result}"

  # Availability zone selection
  # Use provided AZs if given, otherwise auto-detect the first 3 available AZs
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)
}