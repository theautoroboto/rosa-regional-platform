# =============================================================================
# CodePipeline Role
# =============================================================================

resource "aws_iam_role" "codepipeline" {
  name = local.codepipeline_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:GetObjectVersion",
          "s3:PutObject", "s3:GetBucketVersioning",
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = data.aws_codestarconnections_connection.github.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.ami_kms_key_arn
      },
    ]
  })
}

# =============================================================================
# CodeBuild Role
#
# Needs to: assume the Packer role, read/write SSM params, run EC2 instances
# for FIPS testing, invoke Inspector, and publish to the artifact bucket.
#
# IMPORTANT: After applying this config, add the CodeBuild role ARN to
# trusted_principal_arns in central-account-bootstrap so the packer-ami-build
# role trusts it:
#   arn:aws:iam::<account>:role/ami-build-pipeline-codebuild
# =============================================================================

resource "aws_iam_role" "codebuild" {
  name = local.codebuild_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPackerRoleAssumption"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = var.ami_packer_role_arn
      },
      {
        Sid    = "AllowArtifactBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        Sid    = "AllowEKSBinaryBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetObject"]
        Resource = ["arn:aws:s3:::amazon-eks", "arn:aws:s3:::amazon-eks/*"]
      },
      {
        Sid    = "AllowSSMState"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters",
          "ssm:PutParameter",
        ]
        Resource = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/ami-build/*"
      },
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowFIPSTestEC2"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances", "ec2:TerminateInstances",
          "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowFIPSTestInstanceProfile"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.fips_test_instance.arn
      },
      {
        Sid    = "AllowFIPSTestSSMCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand", "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowInspector"
        Effect = "Allow"
        Action = [
          "inspector2:ListFindings",
          "inspector2:BatchGetFindingDetails",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowKMSForArtifacts"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.ami_kms_key_arn
      },
    ]
  })
}

# =============================================================================
# FIPS Test Instance Role
#
# Minimal role for the EC2 instance launched during FIPS validation.
# Needs only SSM core permissions so CodeBuild can send commands to it.
# =============================================================================

resource "aws_iam_role" "fips_test_instance" {
  name = "${local.name_prefix}-fips-test-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fips_test_ssm" {
  role       = aws_iam_role.fips_test_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "fips_test" {
  name = "${local.name_prefix}-fips-test"
  role = aws_iam_role.fips_test_instance.name
}

# =============================================================================
# Security Group for FIPS Test Instances
#
# Outbound HTTPS only — required for SSM agent to communicate with the
# SSM service endpoint. No inbound rules needed.
# =============================================================================

resource "aws_security_group" "fips_test" {
  name        = "${local.name_prefix}-fips-test"
  description = "FIPS validation test instances — outbound HTTPS for SSM only"
  vpc_id      = local.build_vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSM agent HTTPS"
  }

  tags = { Name = "${local.name_prefix}-fips-test" }
}
