# =============================================================================
# YACE (Yet Another CloudWatch Exporter) IAM Role — FedRAMP SI-04
#
# Grants the in-cluster YACE pod read-only access to CloudWatch so it can
# scrape the Security/<cluster-id> custom namespace (populated by the metric
# filters in modules/security-monitoring) and expose those counts as Prometheus
# metrics for Alertmanager to evaluate.
#
# Bound to the "yace" service account in the "yace" namespace via EKS Pod
# Identity (matches serviceAccount.name in argocd/config/regional-cluster/yace/).
# =============================================================================

resource "aws_iam_role" "yace" {
  name = "${var.regional_id}-yace"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-yace"
  }
}

resource "aws_iam_role_policy" "yace_cloudwatch" {
  name = "cloudwatch-security-read"
  role = aws_iam_role.yace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchSecurityMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
        ]
        # Scoped to the Security/* namespace to follow least-privilege.
        # CloudWatch does not support namespace-level resource ARNs for these
        # actions — "*" is required but the Sid documents the intent.
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "yace" {
  cluster_name    = module.regional_cluster.cluster_name
  namespace       = "yace"
  service_account = "yace"
  role_arn        = aws_iam_role.yace.arn

  tags = {
    Name = "${var.regional_id}-yace"
  }
}
