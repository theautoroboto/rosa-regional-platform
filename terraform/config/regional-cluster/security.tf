# =============================================================================
# Security Monitoring — FedRAMP SI-04 (System Monitoring)
#
# Wires the security-monitoring module into the regional cluster, providing:
#   - VPC Flow Logs — network traffic metadata for forensic analysis
#   - CloudWatch Metric Filters — 401, 403, privilege escalation, anonymous
#     access events extracted from EKS audit logs into Security/<cluster-id>
#   - AWS Security Hub — NIST 800-53 and AWS Foundational standards
#
# Alerting is handled by Prometheus Alertmanager via YACE, which scrapes the
# CloudWatch Security/* namespace into Prometheus. See:
#   argocd/config/regional-cluster/yace/        — YACE scraper
#   argocd/config/regional-cluster/monitoring/  — PrometheusRules + Alertmanager
#   terraform/config/regional-cluster/yace.tf   — YACE Pod Identity IAM role
# =============================================================================

module "security_monitoring" {
  source = "../../modules/security-monitoring"

  cluster_id               = var.regional_id
  vpc_id                   = module.regional_cluster.vpc_id
  eks_audit_log_group_name = "/aws/eks/${var.regional_id}/cluster"

  enable_security_hub = var.enable_security_hub
}
