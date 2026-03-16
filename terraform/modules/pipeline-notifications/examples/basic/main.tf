# Example: Basic pipeline notification setup

provider "aws" {
  region = "us-east-1"
}

# Example CodePipeline (simplified)
resource "aws_codepipeline" "example" {
  name     = "example-pipeline"
  role_arn = aws_iam_role.pipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        S3Bucket    = aws_s3_bucket.source.bucket
        S3ObjectKey = "source.zip"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = "example-build"
      }
    }
  }
}

# Add notifications for the pipeline
module "pipeline_notifications" {
  source = "../../"

  pipeline_name         = aws_codepipeline.example.name
  slack_webhook_secret  = "pipeline-notifications/slack-webhook"
  notification_channels = ["#pipeline-alerts"]

  notify_on_failed     = true
  notify_on_stopped    = true
  notify_on_superseded = false

  tags = {
    Environment = "example"
    ManagedBy   = "terraform"
  }
}

# Supporting resources (minimal example)
resource "aws_s3_bucket" "artifacts" {
  bucket = "example-pipeline-artifacts"
}

resource "aws_s3_bucket" "source" {
  bucket = "example-pipeline-source"
}

resource "aws_iam_role" "pipeline_role" {
  name = "example-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
}
