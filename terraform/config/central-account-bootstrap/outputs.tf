# =============================================================================
# Pipeline Provisioner Outputs
# =============================================================================

output "provisioner_pipeline_name" {
  description = "Name of the Pipeline Provisioner CodePipeline"
  value       = module.pipeline_provisioner.provisioner_pipeline_name
}

output "provisioner_pipeline_arn" {
  description = "ARN of the Pipeline Provisioner CodePipeline"
  value       = module.pipeline_provisioner.provisioner_pipeline_arn
}

output "github_connection_arn" {
  description = "ARN of the shared GitHub connection (used by all pipelines)"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_name" {
  description = "Name of the shared GitHub connection"
  value       = aws_codestarconnections_connection.github.name
}

output "github_connection_status" {
  description = "Status of the shared GitHub connection (requires manual authorization if PENDING)"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "provisioner_role_arn" {
  description = "ARN of the IAM role used by the provisioner CodeBuild project"
  value       = module.pipeline_provisioner.provisioner_role_arn
}

# =============================================================================
# General Information
# =============================================================================

output "central_account_id" {
  description = "AWS Account ID where pipelines are deployed"
  value       = data.aws_caller_identity.current.account_id
}

output "deployment_region" {
  description = "AWS Region where pipelines are deployed"
  value       = data.aws_region.current.id
}

# =============================================================================
# Platform Image
# =============================================================================

output "platform_ecr_repository_url" {
  description = "URL of the platform image ECR repository"
  value       = module.platform_image.ecr_repository_url
}

output "platform_image_tag" {
  description = "Tag of the platform image (based on Dockerfile hash)"
  value       = module.platform_image.image_tag
}

# =============================================================================
# AMI Builder
# =============================================================================

output "ami_kms_key_arn" {
  description = "KMS key ARN for RHEL FIPS AMI EBS encryption — set as ami_kms_key_arn in RC/MC deployments"
  value       = module.ami_builder.kms_key_arn
}

output "ami_packer_role_arn" {
  description = "IAM role ARN to assume before running Packer builds"
  value       = module.ami_builder.packer_role_arn
}

output "ami_build_instance_profile_name" {
  description = "IAM instance profile name for Packer build EC2 instances"
  value       = module.ami_builder.build_instance_profile_name
}

output "ami_build_subnet_id" {
  description = "Subnet ID for Packer build instances"
  value       = module.ami_builder.subnet_id
}
