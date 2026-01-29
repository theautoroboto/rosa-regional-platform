# CodePipeline Cross-Account Testing Module
# This module creates a CodePipeline in a central account that can assume roles
# in two different target AWS accounts to test cross-account access patterns

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# S3 bucket for pipeline artifacts
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "codepipeline-cross-account-test-"

  tags = {
    Name        = "CodePipeline Cross-Account Test Artifacts"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access to artifacts bucket
resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for CodePipeline service
resource "aws_iam_role" "codepipeline_role" {
  name_prefix = "codepipeline-cross-account-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "CodePipeline Cross-Account Test Role"
    Environment = var.environment
  }
}

# Policy for CodePipeline to interact with S3 and CodeBuild
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline-cross-account-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.pipeline_artifacts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = [
          aws_codebuild_project.account1_test.arn,
          aws_codebuild_project.account2_test.arn
        ]
      }
    ]
  })
}

# IAM role for CodeBuild projects
resource "aws_iam_role" "codebuild_role" {
  name_prefix = "codebuild-cross-account-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "CodeBuild Cross-Account Test Role"
    Environment = var.environment
  }
}

# Policy for CodeBuild to write logs and access S3
resource "aws_iam_role_policy" "codebuild_base_policy" {
  name = "codebuild-base-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.pipeline_artifacts.arn
      }
    ]
  })
}

# Policy for CodeBuild to assume roles in target accounts
resource "aws_iam_role_policy" "codebuild_assume_role_policy" {
  name = "codebuild-assume-role-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sts:AssumeRole"
        ]
        Resource = [
          "arn:aws:iam::${var.target_account_1_id}:role/${var.target_role_name}",
          "arn:aws:iam::${var.target_account_2_id}:role/${var.target_role_name}"
        ]
      }
    ]
  })
}

# CodeBuild project for Account 1 test
resource "aws_codebuild_project" "account1_test" {
  name          = "cross-account-test-account1"
  description   = "Test STS GetCallerIdentity in Account 1"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 10

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_1_id
    }

    environment_variable {
      name  = "TARGET_ROLE_NAME"
      value = var.target_role_name
    }

    environment_variable {
      name  = "ACCOUNT_NAME"
      value = "Account-1"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/test-caller-identity.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/cross-account-test"
      stream_name = "account1"
    }
  }

  tags = {
    Name        = "Cross-Account Test - Account 1"
    Environment = var.environment
  }
}

# CodeBuild project for Account 2 test
resource "aws_codebuild_project" "account2_test" {
  name          = "cross-account-test-account2"
  description   = "Test STS GetCallerIdentity in Account 2"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 10

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TARGET_ACCOUNT_ID"
      value = var.target_account_2_id
    }

    environment_variable {
      name  = "TARGET_ROLE_NAME"
      value = var.target_role_name
    }

    environment_variable {
      name  = "ACCOUNT_NAME"
      value = "Account-2"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/test-caller-identity.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/cross-account-test"
      stream_name = "account2"
    }
  }

  tags = {
    Name        = "Cross-Account Test - Account 2"
    Environment = var.environment
  }
}

# CodePipeline
resource "aws_codepipeline" "cross_account_test" {
  name     = "cross-account-test-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  # Source stage - manual trigger
  stage {
    name = "Source"

    action {
      name             = "ManualTrigger"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        S3Bucket             = aws_s3_bucket.pipeline_artifacts.bucket
        S3ObjectKey          = "trigger/dummy.zip"
        PollForSourceChanges = false
      }
    }
  }

  # Test Account 1
  stage {
    name = "TestAccount1"

    action {
      name             = "GetCallerIdentity-Account1"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["account1_output"]

      configuration = {
        ProjectName = aws_codebuild_project.account1_test.name
      }
    }
  }

  # Test Account 2
  stage {
    name = "TestAccount2"

    action {
      name             = "GetCallerIdentity-Account2"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["account2_output"]

      configuration = {
        ProjectName = aws_codebuild_project.account2_test.name
      }
    }
  }

  tags = {
    Name        = "Cross-Account Test Pipeline"
    Environment = var.environment
  }
}

# CloudWatch Log Group for CodeBuild
resource "aws_cloudwatch_log_group" "codebuild_logs" {
  name              = "/aws/codebuild/cross-account-test"
  retention_in_days = 7

  tags = {
    Name        = "CodeBuild Cross-Account Test Logs"
    Environment = var.environment
  }
}

# Data source for current account
data "aws_caller_identity" "current" {}
