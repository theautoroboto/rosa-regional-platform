variable "region" {
  type        = string
  description = "AWS region for the pipeline"
  default     = "us-east-1"
}

variable "github_connection_arn" {
  type        = string
  description = "ARN of the shared GitHub CodeStar connection (from central-account-bootstrap output github_connection_arn)"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/name format"
  default     = "aws-samples/amazon-eks-ami-rhel"
  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in 'owner/name' format"
  }
}

variable "github_branch" {
  type        = string
  description = "GitHub branch to build from"
  default     = "main"
}

variable "ami_kms_key_arn" {
  type        = string
  description = "KMS key ARN for AMI EBS encryption (from central-account-bootstrap output ami_kms_key_arn)"
}

variable "ami_packer_role_arn" {
  type        = string
  description = "IAM role ARN the pipeline assumes before running Packer (from central-account-bootstrap output ami_packer_role_arn)"
}

variable "ami_build_subnet_id" {
  type        = string
  description = "Subnet ID for Packer build and FIPS test EC2 instances (from central-account-bootstrap output ami_build_subnet_id)"
}

variable "ami_build_instance_profile_name" {
  type        = string
  description = "Instance profile name for Packer build EC2 instances (from central-account-bootstrap output ami_build_instance_profile_name)"
}

variable "ami_consumer_account_ids" {
  type        = list(string)
  description = "Account IDs to share built AMIs with via ami_users"
  default     = ["855246887846", "599476212575"]
}

variable "pause_container_image" {
  type        = string
  description = "EKS pause container image URI"
  default     = "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/pause:3.10"
}

# K8s version configuration. kubernetes_version and initial build_date are seeded
# into SSM at apply time. The detect stage updates build_date on each pipeline run.
# Update kubernetes_version here when AWS publishes a new patch release.
variable "k8s_versions" {
  type = map(object({
    kubernetes_version = string
    build_date         = string
  }))
  description = "Kubernetes minor version → initial patch version and build date"
  default = {
    "1.34" = { kubernetes_version = "1.34.8", build_date = "2026-06-09" }
    "1.35" = { kubernetes_version = "1.35.4", build_date = "2026-06-09" }
    "1.36" = { kubernetes_version = "1.36.1", build_date = "2026-06-09" }
  }
}

variable "inspector_critical_threshold" {
  type        = number
  description = "Number of Inspector Critical findings that fail the pipeline (0 = any Critical fails)"
  default     = 0
}

variable "codebuild_image" {
  type        = string
  description = "CodeBuild Docker image URI. Defaults to AWS standard AL2023 image; override with platform image if Packer is pre-installed."
  default     = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
}
