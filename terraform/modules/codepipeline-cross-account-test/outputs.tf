output "pipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.cross_account_test.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.cross_account_test.arn
}

output "codebuild_role_arn" {
  description = "ARN of the CodeBuild IAM role that needs assume role permissions"
  value       = aws_iam_role.codebuild_role.arn
}

output "artifacts_bucket" {
  description = "S3 bucket for pipeline artifacts"
  value       = aws_s3_bucket.pipeline_artifacts.bucket
}

output "target_role_arn_account_1" {
  description = "ARN of the role to create in target account 1"
  value       = "arn:aws:iam::${var.target_account_1_id}:role/${var.target_role_name}"
}

output "target_role_arn_account_2" {
  description = "ARN of the role to create in target account 2"
  value       = "arn:aws:iam::${var.target_account_2_id}:role/${var.target_role_name}"
}

output "codebuild_account1_project" {
  description = "Name of the CodeBuild project for Account 1"
  value       = aws_codebuild_project.account1_test.name
}

output "codebuild_account2_project" {
  description = "Name of the CodeBuild project for Account 2"
  value       = aws_codebuild_project.account2_test.name
}

output "central_account_id" {
  description = "AWS Account ID where the pipeline is deployed (central account)"
  value       = data.aws_caller_identity.current.account_id
}

output "setup_instructions" {
  description = "Instructions for setting up target account roles"
  value       = <<-EOT
    To complete the cross-account setup, create the following IAM role in each target account:

    Account 1 (${var.target_account_1_id}):
      Role Name: ${var.target_role_name}
      Trust Policy: Allow sts:AssumeRole from ${aws_iam_role.codebuild_role.arn}

    Account 2 (${var.target_account_2_id}):
      Role Name: ${var.target_role_name}
      Trust Policy: Allow sts:AssumeRole from ${aws_iam_role.codebuild_role.arn}

    You can use the target-account-role module or manually create these roles.
  EOT
}
