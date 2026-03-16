# =============================================================================
# IAM Roles for RHOBS Components (Pod Identity)
#
# Creates IAM roles and policies for:
# - Thanos components (S3 access for metrics)
# - Loki components (S3 access for logs)
# - External Secrets Operator (Secrets Manager access)
# =============================================================================

# =============================================================================
# Thanos IAM Role (Metrics Storage)
# =============================================================================

# IAM role for Thanos components to access S3 metrics bucket
resource "aws_iam_role" "thanos" {
  name               = "${var.regional_id}-rhobs-thanos"
  assume_role_policy = data.aws_iam_policy_document.thanos_assume_role.json

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-rhobs-thanos-role"
      Component = "thanos"
    }
  )
}

# Trust policy for Thanos Pod Identity
data "aws_iam_policy_document" "thanos_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

# Policy for Thanos S3 access
data "aws_iam_policy_document" "thanos_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.rhobs_metrics.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.rhobs_metrics.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "thanos_s3" {
  name   = "thanos-s3-access"
  role   = aws_iam_role.thanos.id
  policy = data.aws_iam_policy_document.thanos_s3.json
}

# Pod Identity Association for Thanos
resource "aws_eks_pod_identity_association" "thanos" {
  cluster_name    = var.eks_cluster_name
  namespace       = "observability"
  service_account = "thanos"
  role_arn        = aws_iam_role.thanos.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-thanos-pod-identity"
      Component = "thanos"
    }
  )
}

# =============================================================================
# Loki IAM Role (Logs Storage)
# =============================================================================

# IAM role for Loki components to access S3 logs bucket
resource "aws_iam_role" "loki" {
  name               = "${var.regional_id}-rhobs-loki"
  assume_role_policy = data.aws_iam_policy_document.loki_assume_role.json

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-rhobs-loki-role"
      Component = "loki"
    }
  )
}

# Trust policy for Loki Pod Identity
data "aws_iam_policy_document" "loki_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

# Policy for Loki S3 access
data "aws_iam_policy_document" "loki_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.rhobs_logs.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.rhobs_logs.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "loki_s3" {
  name   = "loki-s3-access"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_s3.json
}

# Pod Identity Association for Loki
resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.eks_cluster_name
  namespace       = "observability"
  service_account = "loki"
  role_arn        = aws_iam_role.loki.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-loki-pod-identity"
      Component = "loki"
    }
  )
}
