output "pipeline_name" {
  description = "CodePipeline name"
  value       = aws_codepipeline.ami_build.name
}

output "artifact_bucket" {
  description = "S3 bucket holding pipeline artifacts"
  value       = aws_s3_bucket.artifacts.bucket
}

output "codebuild_role_arn" {
  description = "ARN of the CodeBuild IAM role. Add this to trusted_principal_arns in central-account-bootstrap so the packer-ami-build role trusts it."
  value       = aws_iam_role.codebuild.arn
}

output "ssm_parameter_paths" {
  description = "SSM parameter paths written by the pipeline (one set per k8s minor version)"
  value = {
    for minor in keys(var.k8s_versions) : minor => {
      kubernetes_version = aws_ssm_parameter.kubernetes_version[minor].name
      build_date         = aws_ssm_parameter.build_date[minor].name
      latest_ami_id      = aws_ssm_parameter.latest_ami_id[minor].name
    }
  }
}
