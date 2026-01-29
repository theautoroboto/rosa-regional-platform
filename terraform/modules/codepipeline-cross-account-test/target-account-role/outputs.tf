output "role_arn" {
  description = "ARN of the created cross-account role"
  value       = aws_iam_role.cross_account_role.arn
}

output "role_name" {
  description = "Name of the created cross-account role"
  value       = aws_iam_role.cross_account_role.name
}

output "account_id" {
  description = "AWS Account ID where this role was created"
  value       = data.aws_caller_identity.current.account_id
}
