# =============================================================================
# Security Monitoring — FedRAMP SI-04 (System Monitoring)
#
# Provides automated detection of security events required by FedRAMP SI-04:
#   - VPC Flow Logs: full network traffic metadata for forensic analysis
#   - CloudWatch Metric Filters: extract 401/403 and privilege events from
#     EKS audit logs
#   - CloudWatch Alarms: automated alerting via SNS on security events
#   - AWS Security Hub: centralized posture management with NIST 800-53
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# VPC Flow Logs
#
# Captures ALL traffic (ACCEPT and REJECT) flowing through the EKS VPC.
# Required for FedRAMP network monitoring and forensic analysis of incidents.
# Logs are delivered to CloudWatch for correlation with EKS audit events.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc-flow-logs/${var.cluster_id}"
  retention_in_days = var.flow_log_retention_days
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.cluster_id}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.vpc_flow_logs.arn,
          "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  vpc_id               = var.vpc_id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = {
    Name = "${var.cluster_id}-vpc-flow-logs"
  }
}
