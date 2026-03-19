output "ca_arn" {
  description = "ARN of the ACM Private Certificate Authority"
  value       = aws_acmpca_certificate_authority.rhobs_ca.arn
}

output "ca_id" {
  description = "ID of the ACM Private Certificate Authority"
  value       = aws_acmpca_certificate_authority.rhobs_ca.id
}

output "ca_certificate" {
  description = "PEM-encoded certificate of the CA"
  value       = data.aws_acmpca_certificate_authority.ca.certificate
  sensitive   = true
}

output "truststore_s3_uri" {
  description = "S3 URI of the truststore PEM file for API Gateway"
  value       = "s3://${aws_s3_bucket.truststore.id}/${aws_s3_object.truststore_pem.key}"
}

output "truststore_version" {
  description = "S3 object version of the truststore (for mTLS updates)"
  value       = aws_s3_object.truststore_pem.version_id
}

output "truststore_bucket" {
  description = "S3 bucket name for the truststore"
  value       = aws_s3_bucket.truststore.id
}

output "truststore_role_arn" {
  description = "IAM role ARN for API Gateway to access truststore"
  value       = aws_iam_role.apigw_truststore.arn
}

output "crl_bucket" {
  description = "S3 bucket name for Certificate Revocation List"
  value       = aws_s3_bucket.crl.id
}
