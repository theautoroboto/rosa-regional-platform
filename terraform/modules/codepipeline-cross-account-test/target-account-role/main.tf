# Target Account IAM Role Module
# Deploy this in each target account to allow the central CodeBuild role to assume it

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# IAM role that allows assumption from central account CodeBuild
resource "aws_iam_role" "cross_account_role" {
  name        = var.role_name
  description = "Role assumable by CodePipeline in central account ${var.central_account_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.central_codebuild_role_arn
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

  # Optional: Add maximum session duration
  max_session_duration = 3600

  tags = {
    Name            = "CodePipeline Cross-Account Role"
    CentralAccount  = var.central_account_id
    ManagedBy       = "Terraform"
    Purpose         = "Cross-account access for CodePipeline testing"
  }
}

# Minimal policy for testing - only allows STS GetCallerIdentity
resource "aws_iam_role_policy" "minimal_test_policy" {
  name = "minimal-test-policy"
  role = aws_iam_role.cross_account_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

# Optional: Add additional policies for actual workloads
resource "aws_iam_role_policy" "additional_permissions" {
  count = var.additional_policy_json != null ? 1 : 0
  name  = "additional-permissions"
  role  = aws_iam_role.cross_account_role.id

  policy = var.additional_policy_json
}

# Data source to get current account
data "aws_caller_identity" "current" {}
