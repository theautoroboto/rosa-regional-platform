provider "aws" {
  # Configuration typically inherited from environment variables or profile
}

# -----------------------------------------------------------------------------
# IAM Role for CodeBuild Service
# -----------------------------------------------------------------------------
resource "aws_iam_role" "codebuild_role" {
  name = "cross-account-test-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Policies
# -----------------------------------------------------------------------------

# Policy to allow Assuming Roles in the specified Target Accounts
resource "aws_iam_role_policy" "cross_account_policy" {
  name = "allow-assume-cross-account"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        # Scopes permission to assume the specific role in the specific accounts
        Resource = [for account_id in var.target_account_ids : "arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole"]
      }
    ]
  })
}

# Policy for CloudWatch Logs
resource "aws_iam_role_policy" "logging_policy" {
  name = "allow-logging"
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
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CodeBuild Project
# -----------------------------------------------------------------------------
resource "aws_codebuild_project" "cross_account_test" {
  name          = "cross-account-test"
  description   = "Test cross-account access to target accounts via sts:AssumeRole"
  build_timeout = "10"
  service_role  = aws_iam_role.codebuild_role.arn

  source {
    type            = "CODEPIPELINE"
    git_clone_depth = 0
    
    # Inline buildspec to ensure exact logic execution
    buildspec = <<EOF
version: 0.2

phases:
  install:
    commands:
      - echo "Installing dependencies..."
      - yum install -y jq
  build:
    commands:
      - echo "Starting cross-account test..."
      - echo "Role to assume: $ROLE_NAME"
      
      # Define function for assume role logic
      - |
        assume_role() {
          local account_id=$1
          local role_name=$2
          local role_arn="arn:aws:iam::$${account_id}:role/$${role_name}"
          
          echo "Attempting to assume role: $role_arn"
          
          # Use a subshell to isolate credentials
          (
            creds=$(aws sts assume-role --role-arn "$role_arn" --role-session-name "CodeBuildTest" --output json)
            
            if [ $? -eq 0 ]; then
              export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
              export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
              export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
              
              echo "Successfully assumed role. Verifying identity..."
              aws sts get-caller-identity
            else
              echo "Failed to assume role $role_arn"
              exit 1
            fi
          )
        }

      - echo "--------------------------------------------------"
      - echo "Target Account 1: $TARGET_ACCOUNT_1"
      - if [ "$TARGET_ACCOUNT_1" != "placeholder" ] && [ -n "$TARGET_ACCOUNT_1" ]; then assume_role "$TARGET_ACCOUNT_1" "$ROLE_NAME"; else echo "Skipping Account 1 (not set)"; fi
      
      - echo "--------------------------------------------------"
      - echo "Target Account 2: $TARGET_ACCOUNT_2"
      - if [ "$TARGET_ACCOUNT_2" != "placeholder" ] && [ -n "$TARGET_ACCOUNT_2" ]; then assume_role "$TARGET_ACCOUNT_2" "$ROLE_NAME"; else echo "Skipping Account 2 (not set)"; fi
EOF
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # Environment variables to be overridden at runtime
    environment_variable {
      name  = "TARGET_ACCOUNT_1"
      value = "placeholder"
    }
    environment_variable {
      name  = "TARGET_ACCOUNT_2"
      value = "placeholder"
    }
    environment_variable {
      name  = "ROLE_NAME"
      value = "OrganizationAccountAccessRole"
    }
  }
}

# -----------------------------------------------------------------------------
# S3 Bucket for CodePipeline Artifacts
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "cross-account-pipeline-artifacts-"

  tags = {
    Name      = "Cross-Account Pipeline Artifacts"
    ManagedBy = "Terraform"
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

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# IAM Role for CodePipeline Service
# -----------------------------------------------------------------------------
resource "aws_iam_role" "codepipeline_role" {
  name = "cross-account-pipeline-service-role"

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
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline-permissions"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketVersioning"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.cross_account_test.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CodePipeline
# -----------------------------------------------------------------------------
resource "aws_codepipeline" "cross_account_test" {
  name     = "cross-account-test-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  # Source stage - Dummy S3 source (required by CodePipeline)
  stage {
    name = "Source"

    action {
      name             = "DummySource"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        S3Bucket             = aws_s3_bucket.pipeline_artifacts.bucket
        S3ObjectKey          = "dummy-source.zip"
        PollForSourceChanges = "false"
      }
    }
  }

  # Build/Test stage - Run cross-account tests
  stage {
    name = "Test"

    action {
      name             = "CrossAccountTest"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["test_output"]

      configuration = {
        ProjectName = aws_codebuild_project.cross_account_test.name
        EnvironmentVariables = jsonencode([
          {
            name  = "TARGET_ACCOUNT_1"
            value = length(var.target_account_ids) > 0 ? var.target_account_ids[0] : "placeholder"
            type  = "PLAINTEXT"
          },
          {
            name  = "TARGET_ACCOUNT_2"
            value = length(var.target_account_ids) > 1 ? var.target_account_ids[1] : "placeholder"
            type  = "PLAINTEXT"
          },
          {
            name  = "ROLE_NAME"
            value = var.target_role_name
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  tags = {
    Name      = "Cross-Account Test Pipeline"
    ManagedBy = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for CodeBuild
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "codebuild_logs" {
  name              = "/aws/codebuild/cross-account-test"
  retention_in_days = 7

  tags = {
    Name      = "CodeBuild Cross-Account Test Logs"
    ManagedBy = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# Dummy Source File for Pipeline
# -----------------------------------------------------------------------------
resource "aws_s3_object" "dummy_source" {
  bucket  = aws_s3_bucket.pipeline_artifacts.bucket
  key     = "dummy-source.zip"
  content = "dummy"
  etag    = md5("dummy")

  tags = {
    Name      = "Dummy Source for Pipeline Trigger"
    ManagedBy = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# EventBridge Rule for Hourly Trigger
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "hourly_trigger" {
  name                = "cross-account-test-schedule"
  description         = "Trigger cross-account test pipeline on schedule"
  schedule_expression = var.schedule_expression

  tags = {
    Name      = "Cross-Account Test Schedule Trigger"
    ManagedBy = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule     = aws_cloudwatch_event_rule.hourly_trigger.name
  arn      = aws_codepipeline.cross_account_test.arn
  role_arn = aws_iam_role.eventbridge_role.arn
}

# -----------------------------------------------------------------------------
# IAM Role for EventBridge to Trigger Pipeline
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eventbridge_role" {
  name = "cross-account-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name      = "EventBridge Pipeline Trigger Role"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy" "eventbridge_policy" {
  name = "eventbridge-pipeline-trigger"
  role = aws_iam_role.eventbridge_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codepipeline:StartPipelineExecution"
        ]
        Resource = aws_codepipeline.cross_account_test.arn
      }
    ]
  })
}
