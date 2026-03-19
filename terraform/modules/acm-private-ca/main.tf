# ACM Private CA Module
# Creates a Private Certificate Authority for mTLS client authentication

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ACM Private CA - ROOT CA for standalone operation
resource "aws_acmpca_certificate_authority" "rhobs_ca" {
  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name         = "RHOBS mTLS CA - ${var.regional_id}"
      organization        = "Red Hat"
      organizational_unit = "ROSA Regional Platform"
      country             = "US"
      state               = "North Carolina"
      locality            = "Raleigh"
    }
  }

  revocation_configuration {
    crl_configuration {
      enabled            = true
      expiration_in_days = 7
      s3_bucket_name     = aws_s3_bucket.crl.bucket
    }
  }

  permanent_deletion_time_in_days = 30
  enabled                         = true

  tags = merge(
    var.tags,
    {
      Name      = "${var.regional_id}-rhobs-ca"
      Component = "rhobs"
      Purpose   = "mtls-authentication"
    }
  )

  depends_on = [
    aws_s3_bucket_policy.crl
  ]
}

# S3 bucket for Certificate Revocation List (CRL)
resource "aws_s3_bucket" "crl" {
  bucket = "${var.regional_id}-rhobs-ca-crl"

  tags = merge(
    var.tags,
    {
      Name      = "${var.regional_id}-rhobs-ca-crl"
      Component = "rhobs"
      Purpose   = "certificate-revocation-list"
    }
  )
}

resource "aws_s3_bucket_versioning" "crl" {
  bucket = aws_s3_bucket.crl.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crl" {
  bucket = aws_s3_bucket.crl.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "crl" {
  bucket = aws_s3_bucket.crl.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy to allow ACM PCA to write CRL
resource "aws_s3_bucket_policy" "crl" {
  bucket = aws_s3_bucket.crl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSPCABucketPermissions"
        Effect = "Allow"
        Principal = {
          Service = "acm-pca.amazonaws.com"
        }
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.crl.arn,
          "${aws_s3_bucket.crl.arn}/*"
        ]
      }
    ]
  })
}

# Certificate for the Private CA (self-signed for ROOT)
resource "aws_acmpca_certificate" "ca_cert" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.rhobs_ca.arn
  certificate_signing_request = aws_acmpca_certificate_authority.rhobs_ca.certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"

  template_arn = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

# Activate the Private CA by importing the signed certificate
resource "aws_acmpca_certificate_authority_certificate" "ca_cert" {
  certificate_authority_arn = aws_acmpca_certificate_authority.rhobs_ca.arn
  certificate               = aws_acmpca_certificate.ca_cert.certificate
  certificate_chain         = aws_acmpca_certificate.ca_cert.certificate_chain
}

# S3 bucket for API Gateway truststore
resource "aws_s3_bucket" "truststore" {
  bucket = "${var.regional_id}-rhobs-mtls-truststore"

  tags = merge(
    var.tags,
    {
      Name      = "${var.regional_id}-rhobs-mtls-truststore"
      Component = "rhobs"
      Purpose   = "api-gateway-truststore"
    }
  )
}

resource "aws_s3_bucket_versioning" "truststore" {
  bucket = aws_s3_bucket.truststore.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "truststore" {
  bucket = aws_s3_bucket.truststore.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "truststore" {
  bucket = aws_s3_bucket.truststore.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Get CA certificate data for truststore
data "aws_acmpca_certificate_authority" "ca" {
  arn = aws_acmpca_certificate_authority.rhobs_ca.arn

  depends_on = [aws_acmpca_certificate_authority_certificate.ca_cert]
}

# Upload CA certificate to truststore bucket
resource "aws_s3_object" "truststore_pem" {
  bucket       = aws_s3_bucket.truststore.id
  key          = "truststore.pem"
  content      = data.aws_acmpca_certificate_authority.ca.certificate
  content_type = "application/x-pem-file"

  # Force update when certificate changes
  etag = md5(data.aws_acmpca_certificate_authority.ca.certificate)

  tags = merge(
    var.tags,
    {
      Name      = "${var.regional_id}-rhobs-truststore-pem"
      Component = "rhobs"
    }
  )
}

# IAM role for API Gateway to access truststore
resource "aws_iam_role" "apigw_truststore" {
  name = "${var.regional_id}-apigw-truststore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })

  tags = merge(
    var.tags,
    {
      Name      = "${var.regional_id}-apigw-truststore-role"
      Component = "rhobs"
    }
  )
}

resource "aws_iam_role_policy" "apigw_truststore" {
  role = aws_iam_role.apigw_truststore.id
  name = "truststore-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ]
      Resource = "${aws_s3_bucket.truststore.arn}/*"
    }]
  })
}
