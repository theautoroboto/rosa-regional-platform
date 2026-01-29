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

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule triggering the pipeline hourly"
  value       = aws_cloudwatch_event_rule.hourly_trigger.name
}

output "eventbridge_schedule" {
  description = "Schedule expression for the EventBridge trigger"
  value       = aws_cloudwatch_event_rule.hourly_trigger.schedule_expression
}

output "setup_instructions" {
  description = "Next steps to complete the setup"
  value       = <<-EOT
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║            Cross-Account Test Pipeline - Hourly Schedule                 ║
    ╚═══════════════════════════════════════════════════════════════════════════╝

    ✓ Pipeline Created:   ${aws_codepipeline.cross_account_test.name}
    ✓ CodeBuild Role:     ${aws_iam_role.codebuild_role.arn}
    ✓ Hourly Trigger:     ${aws_cloudwatch_event_rule.hourly_trigger.schedule_expression}
    ✓ Auto-Trigger:       Enabled (runs every hour)

    NEXT STEPS:

    1. In each target account, create IAM role with trust policy:

       Role Name: ${var.target_role_name}
       Trust Policy Principal: ${aws_iam_role.codebuild_role.arn}

       Example AWS CLI commands (run in each target account):

       cat > trust-policy.json <<EOF
       {
         "Version": "2012-10-17",
         "Statement": [{
           "Effect": "Allow",
           "Principal": {"AWS": "${aws_iam_role.codebuild_role.arn}"},
           "Action": "sts:AssumeRole"
         }]
       }
       EOF

       aws iam create-role \
         --role-name ${var.target_role_name} \
         --assume-role-policy-document file://trust-policy.json

       aws iam put-role-policy \
         --role-name ${var.target_role_name} \
         --policy-name GetCallerIdentity \
         --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}'

    2. Test the pipeline (optional - will run automatically every hour):

       # Manual trigger:
       aws codepipeline start-pipeline-execution --name ${aws_codepipeline.cross_account_test.name}

    3. Monitor execution:

       # View pipeline in console:
       https://console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.cross_account_test.name}/view

       # Tail logs:
       aws logs tail /aws/codebuild/cross-account-test --follow

       # Check next scheduled run:
       aws events list-rules --name-prefix ${aws_cloudwatch_event_rule.hourly_trigger.name}

    Target Accounts Configured:
    ${join("\n    ", [for id in var.target_account_ids : "- ${id}"])}

    The pipeline will automatically test cross-account access every hour!

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
