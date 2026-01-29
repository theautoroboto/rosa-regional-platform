output "codebuild_project_name" {
  description = "The name of the CodeBuild project"
  value       = aws_codebuild_project.cross_account_test.name
}

output "codebuild_project_arn" {
  description = "The ARN of the CodeBuild project"
  value       = aws_codebuild_project.cross_account_test.arn
}

output "codebuild_service_role_arn" {
  description = "The ARN of the IAM role used by CodeBuild (use this in target account trust policies)"
  value       = aws_iam_role.codebuild_role.arn
}

output "pipeline_name" {
  description = "The name of the CodePipeline"
  value       = aws_codepipeline.cross_account_test.name
}

output "pipeline_arn" {
  description = "The ARN of the CodePipeline"
  value       = aws_codepipeline.cross_account_test.arn
}

output "pipeline_url" {
  description = "Console URL to view the pipeline"
  value       = "https://console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.cross_account_test.name}/view"
}

output "artifacts_bucket" {
  description = "S3 bucket for pipeline artifacts"
  value       = aws_s3_bucket.pipeline_artifacts.bucket
}

output "github_connection_arn" {
  description = "ARN of the CodeStar Connection to GitHub"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Status of the GitHub connection (PENDING requires manual approval)"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "github_connection_url" {
  description = "Console URL to complete GitHub connection approval"
  value       = "https://console.aws.amazon.com/codesuite/settings/connections/${aws_codestarconnections_connection.github.id}"
}

output "setup_instructions" {
  description = "Next steps to complete the setup"
  value       = <<-EOT
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                    Cross-Account Pipeline Setup                          ║
    ╚═══════════════════════════════════════════════════════════════════════════╝

    Pipeline Created:     ${aws_codepipeline.cross_account_test.name}
    CodeBuild Role:       ${aws_iam_role.codebuild_role.arn}
    GitHub Connection:    ${aws_codestarconnections_connection.github.arn}
    Connection Status:    ${aws_codestarconnections_connection.github.connection_status}

    NEXT STEPS:

    ${aws_codestarconnections_connection.github.connection_status == "PENDING" ? "⚠️  IMPORTANT: GitHub Connection Requires Approval!" : "✓ GitHub Connection is ready!"}

    ${aws_codestarconnections_connection.github.connection_status == "PENDING" ? "1. Approve GitHub Connection:\n\n       Open this URL in your browser:\n       https://console.aws.amazon.com/codesuite/settings/connections/${aws_codestarconnections_connection.github.id}\n\n       Click \"Update pending connection\" and authorize AWS to access GitHub.\n       This creates an OAuth app in your GitHub account.\n\n    2." : "1."} In each target account, create IAM role with trust policy:

       Role Name: ${var.target_role_name}
       Trust Policy Principal: ${aws_iam_role.codebuild_role.arn}

       Example trust policy:
       {
         "Version": "2012-10-17",
         "Statement": [{
           "Effect": "Allow",
           "Principal": {"AWS": "${aws_iam_role.codebuild_role.arn}"},
           "Action": "sts:AssumeRole"
         }]
       }

    ${aws_codestarconnections_connection.github.connection_status == "PENDING" ? "3." : "2."} Test the pipeline:

       # Manual trigger:
       aws codepipeline start-pipeline-execution --name ${aws_codepipeline.cross_account_test.name}

       # Or push to GitHub branch: ${var.github_repo_branch}

    ${aws_codestarconnections_connection.github.connection_status == "PENDING" ? "4." : "3."} Monitor execution:

       Pipeline: ${aws_codepipeline.cross_account_test.name}
       Logs:     /aws/codebuild/cross-account-test

       View in console:
       ${aws_codepipeline.cross_account_test.name != "" ? "https://console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.cross_account_test.name}/view" : ""}

    Target Accounts Configured:
    ${join("\n    ", [for id in var.target_account_ids : "- ${id}"])}

    ═══════════════════════════════════════════════════════════════════════════
  EOT
}

output "manual_trigger_command" {
  description = "Command to manually trigger the pipeline"
  value       = "aws codepipeline start-pipeline-execution --name ${aws_codepipeline.cross_account_test.name}"
}

output "view_logs_commands" {
  description = "Commands to view CodeBuild logs"
  value = {
    tail_logs   = "aws logs tail /aws/codebuild/cross-account-test --follow"
    list_groups = "aws logs describe-log-groups --log-group-name-prefix /aws/codebuild/cross-account-test"
  }
}
