output "kms_key_arn" {
  description = "KMS key ARN for RHEL FIPS AMI EBS encryption — set as ami_kms_key_arn in RC/MC deployments"
  value       = aws_kms_key.ami.arn
}

output "kms_key_alias_arn" {
  description = "KMS key alias ARN"
  value       = aws_kms_alias.ami.arn
}

output "packer_role_arn" {
  description = "IAM role ARN to assume before running Packer builds"
  value       = aws_iam_role.packer.arn
}

output "build_instance_profile_name" {
  description = "IAM instance profile name for Packer build EC2 instances"
  value       = aws_iam_instance_profile.build_instance.name
}

output "vpc_id" {
  description = "VPC ID for Packer build instances"
  value       = aws_vpc.build.id
}

output "subnet_id" {
  description = "Subnet ID for Packer build instances"
  value       = aws_subnet.build.id
}
