# =============================================================================
# Thanos Observability Gateway
#
# Creates an API Gateway with AWS_IAM (SigV4) authentication for secure
# metrics ingestion to Thanos Receive. Uses the api-gateway module internally.
#
# Architecture:
#   Client (SigV4) -> API Gateway -> VPC Link -> ALB -> Thanos Receive
# =============================================================================

module "api_gateway" {
  source = "../api-gateway"

  vpc_id                 = var.vpc_id
  private_subnet_ids     = var.private_subnet_ids
  regional_id            = "${var.regional_id}-thanos"
  node_security_group_id = var.node_security_group_id
  cluster_name           = var.cluster_name

  # Thanos Receive configuration
  target_port           = 19291 # Thanos Receive remote-write port
  health_check_path     = "/-/ready"
  health_check_interval = 30
  health_check_timeout  = 5

  # API Gateway configuration
  stage_name      = var.stage_name
  api_description = "Thanos Receive metrics ingestion endpoint with SigV4 authentication"

  # Optional custom domain
  api_domain_name        = var.api_domain_name
  regional_hosted_zone_id = var.regional_hosted_zone_id
}

# =============================================================================
# IAM Policy for Metrics Writers
#
# This policy allows clients to invoke the Thanos API Gateway.
# Attach this policy to IAM roles used by Prometheus/metrics writers.
# =============================================================================

resource "aws_iam_policy" "metrics_writer" {
  name        = "${var.regional_id}-thanos-metrics-writer"
  description = "Allows invoking Thanos Receive API Gateway for metrics ingestion"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeThanosAPI"
        Effect = "Allow"
        Action = [
          "execute-api:Invoke"
        ]
        Resource = [
          "${module.api_gateway.api_gateway_arn}/*"
        ]
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-thanos-metrics-writer"
  }
}

# =============================================================================
# Cross-Account Access (Optional)
#
# If metrics writers are in different AWS accounts, create an IAM role
# that those accounts can assume.
# =============================================================================

resource "aws_iam_role" "cross_account_metrics_writer" {
  count = length(var.allowed_account_ids) > 0 ? 1 : 0

  name        = "${var.regional_id}-thanos-cross-account-writer"
  description = "Cross-account role for metrics ingestion to Thanos"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountAssume"
        Effect = "Allow"
        Principal = {
          AWS = [for account_id in var.allowed_account_ids : "arn:${local.partition}:iam::${account_id}:root"]
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.regional_id}-thanos-cross-account-writer"
  }
}

resource "aws_iam_role_policy_attachment" "cross_account_metrics_writer" {
  count = length(var.allowed_account_ids) > 0 ? 1 : 0

  role       = aws_iam_role.cross_account_metrics_writer[0].name
  policy_arn = aws_iam_policy.metrics_writer.arn
}

# =============================================================================
# Locals
# =============================================================================

locals {
  partition = data.aws_partition.current.partition
}

data "aws_partition" "current" {}
