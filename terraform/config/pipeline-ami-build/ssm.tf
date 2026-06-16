# SSM parameters seed the pipeline's state machine.
# The Detect stage in CodeBuild compares the current EKS S3 build date against
# /ami-build/{minor}/build-date to decide whether a rebuild is needed.
# After a successful build, the Build stage writes the new AMI ID to
# /ami-build/{minor}/latest-ami-id.

resource "aws_ssm_parameter" "kubernetes_version" {
  for_each = var.k8s_versions

  name        = "/ami-build/${each.key}/kubernetes-version"
  type        = "String"
  value       = each.value.kubernetes_version
  description = "EKS patch version for Kubernetes ${each.key}"

  lifecycle {
    # Patch version bumps are done in variables.tf; don't drift on re-apply.
    ignore_changes = []
  }
}

resource "aws_ssm_parameter" "build_date" {
  for_each = var.k8s_versions

  name        = "/ami-build/${each.key}/build-date"
  type        = "String"
  value       = each.value.build_date
  description = "EKS binary build date last used to produce the AMI for Kubernetes ${each.key}"

  lifecycle {
    # The Detect and Build CodeBuild stages update this value at runtime.
    # Prevent terraform apply from reverting it to the initial seed.
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "latest_ami_id" {
  for_each = var.k8s_versions

  name        = "/ami-build/${each.key}/latest-ami-id"
  type        = "String"
  value       = "UNSET"
  description = "Most recent AMI ID produced by the pipeline for Kubernetes ${each.key}"

  lifecycle {
    # Written at runtime by the Build stage; never overwritten by Terraform.
    ignore_changes = [value]
  }
}
