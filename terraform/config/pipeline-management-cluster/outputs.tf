output "github_connection_arn" {
  description = "ARN of the GitHub CodeStar connection"
  value       = data.aws_codestarconnections_connection.github.arn
}

output "pipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.regional_pipeline.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.regional_pipeline.arn
}

output "codebuild_regional_check_name" {
  description = "Name of the regional dependency check CodeBuild project"
  value       = aws_codebuild_project.regional_dependency_check.name
}

output "codebuild_validate_name" {
  description = "Name of the CodeBuild validate project"
  value       = aws_codebuild_project.management_validate.name
}

output "codebuild_apply_name" {
  description = "Name of the CodeBuild apply project"
  value       = aws_codebuild_project.management_apply.name
}

output "codebuild_bootstrap_name" {
  description = "Name of the CodeBuild bootstrap project"
  value       = aws_codebuild_project.management_bootstrap.name
}

output "artifact_bucket" {
  description = "S3 bucket used for pipeline artifacts"
  value       = aws_s3_bucket.pipeline_artifact.id
}
