# Example: Deploy Cross-Account Role in Target Account
# Deploy this in EACH target account (Account 1 and Account 2)

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
  # Configure authentication for the TARGET account
  # Examples:
  # profile = "target-account-1"  # or "target-account-2"
  # Or use AWS SSO with the appropriate account
}

module "cross_account_role" {
  source = "../../target-account-role"

  role_name                  = var.role_name
  central_account_id         = var.central_account_id
  central_codebuild_role_arn = var.central_codebuild_role_arn
  external_id                = var.external_id

  # Optional: Add additional permissions beyond just sts:GetCallerIdentity
  # additional_policy_json = jsonencode({
  #   Version = "2012-10-17"
  #   Statement = [
  #     {
  #       Effect = "Allow"
  #       Action = [
  #         "eks:DescribeCluster",
  #         "eks:ListClusters"
  #       ]
  #       Resource = "*"
  #     }
  #   ]
  # })
}

output "role_arn" {
  description = "ARN of the created cross-account role"
  value       = module.cross_account_role.role_arn
}

output "role_name" {
  description = "Name of the created cross-account role"
  value       = module.cross_account_role.role_name
}

output "account_id" {
  description = "Account ID where this role was created"
  value       = module.cross_account_role.account_id
}

output "verification_command" {
  description = "Command to verify the role was created correctly"
  value       = <<-EOT
    # Verify role exists:
    aws iam get-role --role-name ${module.cross_account_role.role_name}

    # Check trust policy:
    aws iam get-role --role-name ${module.cross_account_role.role_name} \
      --query 'Role.AssumeRolePolicyDocument' --output json

    # List attached policies:
    aws iam list-role-policies --role-name ${module.cross_account_role.role_name}
  EOT
}
