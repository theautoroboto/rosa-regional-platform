# Example: Deploy CodePipeline in Central Account
# This example shows how to deploy the cross-account testing pipeline
# in your central AWS account

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Configure your AWS authentication here
  # Examples:
  # profile = "central-account"
  # Or use AWS SSO, environment variables, etc.
}

module "cross_account_pipeline" {
  source = "../../"

  aws_region          = var.aws_region
  environment         = var.environment
  target_account_1_id = var.target_account_1_id
  target_account_2_id = var.target_account_2_id
  target_role_name    = var.target_role_name
}

# Outputs to use when setting up target accounts
output "codebuild_role_arn" {
  description = "CodeBuild role ARN - use this when configuring target account trust policies"
  value       = module.cross_account_pipeline.codebuild_role_arn
}

output "pipeline_name" {
  description = "Name of the created pipeline"
  value       = module.cross_account_pipeline.pipeline_name
}

output "artifacts_bucket" {
  description = "S3 bucket for pipeline artifacts"
  value       = module.cross_account_pipeline.artifacts_bucket
}

output "central_account_id" {
  description = "Central account ID where pipeline is deployed"
  value       = module.cross_account_pipeline.central_account_id
}

output "setup_instructions" {
  description = "Next steps for setting up target account roles"
  value       = module.cross_account_pipeline.setup_instructions
}

# Instructions for triggering the pipeline
output "trigger_pipeline_command" {
  description = "Command to trigger the pipeline manually"
  value       = <<-EOT
    # Create and upload trigger file:
    echo "trigger" > trigger.txt
    zip trigger.zip trigger.txt
    aws s3 cp trigger.zip s3://${module.cross_account_pipeline.artifacts_bucket}/trigger/dummy.zip

    # Start pipeline execution:
    aws codepipeline start-pipeline-execution --name ${module.cross_account_pipeline.pipeline_name}

    # Monitor pipeline status:
    aws codepipeline get-pipeline-state --name ${module.cross_account_pipeline.pipeline_name}
  EOT
}
