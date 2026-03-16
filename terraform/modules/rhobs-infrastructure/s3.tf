# =============================================================================
# S3 Buckets for RHOBS Long-Term Storage
#
# - Metrics bucket: Thanos long-term storage backend
# - Logs bucket: Loki long-term storage backend
# - Both encrypted at rest with KMS
# - Lifecycle policies for automatic retention management
# =============================================================================

# S3 Bucket for Metrics (Thanos)
resource "aws_s3_bucket" "rhobs_metrics" {
  bucket = local.metrics_bucket_name

  tags = merge(
    local.common_tags,
    {
      Name      = local.metrics_bucket_name
      Purpose   = "RHOBS Thanos metrics storage"
      Component = "thanos"
    }
  )
}

# Enable versioning for metrics bucket
resource "aws_s3_bucket_versioning" "rhobs_metrics" {
  bucket = aws_s3_bucket.rhobs_metrics.id

  versioning_configuration {
    status = var.enable_s3_versioning ? "Enabled" : "Suspended"
  }
}

# Server-side encryption for metrics bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "rhobs_metrics" {
  bucket = aws_s3_bucket.rhobs_metrics.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block public access for metrics bucket
resource "aws_s3_bucket_public_access_block" "rhobs_metrics" {
  bucket = aws_s3_bucket.rhobs_metrics.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for metrics bucket
resource "aws_s3_bucket_lifecycle_configuration" "rhobs_metrics" {
  bucket = aws_s3_bucket.rhobs_metrics.id

  rule {
    id     = "retention-${var.metrics_retention_days}-days"
    status = "Enabled"

    expiration {
      days = var.metrics_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# S3 Bucket for Logs (Loki)
resource "aws_s3_bucket" "rhobs_logs" {
  bucket = local.logs_bucket_name

  tags = merge(
    local.common_tags,
    {
      Name      = local.logs_bucket_name
      Purpose   = "RHOBS Loki logs storage"
      Component = "loki"
    }
  )
}

# Enable versioning for logs bucket
resource "aws_s3_bucket_versioning" "rhobs_logs" {
  bucket = aws_s3_bucket.rhobs_logs.id

  versioning_configuration {
    status = var.enable_s3_versioning ? "Enabled" : "Suspended"
  }
}

# Server-side encryption for logs bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "rhobs_logs" {
  bucket = aws_s3_bucket.rhobs_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block public access for logs bucket
resource "aws_s3_bucket_public_access_block" "rhobs_logs" {
  bucket = aws_s3_bucket.rhobs_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for logs bucket
resource "aws_s3_bucket_lifecycle_configuration" "rhobs_logs" {
  bucket = aws_s3_bucket.rhobs_logs.id

  rule {
    id     = "retention-${var.logs_retention_days}-days"
    status = "Enabled"

    expiration {
      days = var.logs_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
