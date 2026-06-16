provider "aws" {
  region            = var.region
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# Derive VPC ID from the build subnet so callers don't need to pass it separately.
data "aws_subnet" "build" {
  id = var.ami_build_subnet_id
}

locals {
  name_prefix            = "ami-build-pipeline"
  account_id             = data.aws_caller_identity.current.account_id
  artifact_bucket_name   = "${local.name_prefix}-artifacts-${substr(local.account_id, -8, 8)}"
  codebuild_role_name    = "${local.name_prefix}-codebuild"
  codepipeline_role_name = "${local.name_prefix}-codepipeline"
  pipeline_name          = local.name_prefix
  build_vpc_id           = data.aws_subnet.build.vpc_id

  ami_users = join(",", var.ami_consumer_account_ids)

  k8s_minors = keys(var.k8s_versions)
}
