# =============================================================================
# AWS Security Hub — FedRAMP SI-04
#
# Centralizes security findings from AWS services (GuardDuty, Inspector,
# Macie, Config, IAM Access Analyzer) and provides managed insights for
# detecting unauthorized API calls, over-privileged identities, and
# configuration drift.
#
# Standards enabled:
#   - NIST SP 800-53 Rev 5: primary FedRAMP control framework mapping
#   - AWS Foundational Security Best Practices: broad misconfiguration detection
# =============================================================================

resource "aws_securityhub_account" "main" {
  count = var.enable_security_hub ? 1 : 0

  # Do not auto-enable the CIS and AWS Foundational default standards on
  # enrollment — we manage standard subscriptions explicitly below so that
  # each standard's ARN can be constructed for both standard and GovCloud
  # partitions via data.aws_partition.current.
  enable_default_standards = false
  auto_enable_controls     = true
}

# NIST SP 800-53 Rev 5 — maps directly to FedRAMP control families
resource "aws_securityhub_standards_subscription" "nist_800_53" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.region}::standards/nist-800-53/v/5.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# AWS Foundational Security Best Practices — catches broad misconfigurations
# (public S3, unencrypted EBS, missing MFA, etc.) not in NIST control scope
resource "aws_securityhub_standards_subscription" "aws_foundational" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}
