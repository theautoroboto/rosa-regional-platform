# =============================================================================
# Common Variables Module - Local Values
# =============================================================================
# Defines computed values and common patterns used across all deployments.
#
# These locals provide:
# - Standardized resource tagging
# - Consistent naming conventions
# - Computed metadata
#
# =============================================================================

locals {
  # =========================================================================
  # Common Resource Tags
  # =========================================================================
  # Standard tags applied to all AWS resources for:
  # - Cost tracking and allocation
  # - Resource organization and filtering
  # - Compliance and auditing
  # - CMDB integration
  #
  # These tags are mandatory for all infrastructure resources.
  # =========================================================================
  common_tags = {
    # Core identification tags
    AppCode      = var.app_code
    ServicePhase = var.service_phase
    CostCenter   = var.cost_center

    # Infrastructure metadata
    Region       = var.region
    TargetAlias  = var.target_alias
    ManagedBy    = "terraform"
    Repository   = var.repository_url
    Branch       = var.repository_branch

    # Operational metadata
    Bastion      = var.enable_bastion ? "enabled" : "disabled"
  }

  # =========================================================================
  # Resource Naming Convention
  # =========================================================================
  # Standard prefix for resource names ensures consistency and clarity.
  #
  # Pattern: {service_phase}-{target_alias}
  # Examples:
  #   - production-us-east-1 → prod-us-east-1-eks-cluster
  #   - staging-us-west-2 → staging-us-west-2-vpc
  #   - development-test → dev-test-rds
  #
  # This prefix can be extended by specific resources for full naming:
  #   "${local.resource_name_prefix}-eks-cluster"
  #   "${local.resource_name_prefix}-vpc"
  # =========================================================================
  resource_name_prefix = "${substr(var.service_phase, 0, 4)}-${var.target_alias}"

  # =========================================================================
  # Environment Classification
  # =========================================================================
  # Boolean flags for environment-specific logic (e.g., feature toggles)
  # =========================================================================
  is_production  = var.service_phase == "production"
  is_staging     = var.service_phase == "staging"
  is_development = var.service_phase == "development"

  # =========================================================================
  # Compliance and Security Metadata
  # =========================================================================
  # Additional metadata for compliance tracking and security posture
  # =========================================================================
  compliance_tags = {
    # Data classification (can be overridden by specific resources)
    DataClassification = local.is_production ? "confidential" : "internal"

    # Backup requirements
    BackupRequired = local.is_production ? "yes" : "no"

    # Monitoring requirements
    MonitoringLevel = local.is_production ? "critical" : local.is_staging ? "standard" : "basic"
  }

  # =========================================================================
  # Combined Tags (for convenience)
  # =========================================================================
  # Merge common tags with compliance tags for complete tag set
  # =========================================================================
  all_tags = merge(local.common_tags, local.compliance_tags)
}
