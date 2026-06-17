# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each          = toset(["detect", "build-1-34", "build-1-35", "build-1-36", "validate", "inspect"])
  name              = "/aws/codebuild/ami-build-${each.key}"
  retention_in_days = 30
}

# =============================================================================
# CodeBuild — Detect Stage
#
# Checks whether any k8s version has a newer EKS binary build date available
# on S3, then updates SSM if so.  Always exits 0 so the pipeline proceeds;
# the signal is written to SSM, not used to gate here.
# =============================================================================

resource "aws_codebuild_project" "detect" {
  name          = "ami-build-detect"
  description   = "Compare EKS S3 build date against last-known build date in SSM"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        build:
          commands:
            - |
              for MINOR in 1.34 1.35 1.36; do
                PARAM="/ami-build/$${MINOR}/build-date"
                CURRENT=$(aws ssm get-parameter --name "$${PARAM}" --query 'Parameter.Value' --output text)
                # List available build dates for this minor version and pick the latest
                LATEST=$(aws s3 ls "s3://amazon-eks/1.${MINOR}/" --recursive \
                  | grep -oP '\d{4}-\d{2}-\d{2}' | sort -u | tail -1 || echo "")
                echo "k8s $${MINOR}: SSM=$${CURRENT}  S3_latest=$${LATEST}"
                if [ -n "$${LATEST}" ] && [ "$${LATEST}" != "$${CURRENT}" ]; then
                  aws ssm put-parameter --name "$${PARAM}" --value "$${LATEST}" --overwrite
                  echo "Updated $${MINOR} build-date to $${LATEST}"
                fi
              done
    BUILDSPEC
  }

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["detect"].name
    }
  }
}

# =============================================================================
# CodeBuild — Build Stage (one project per k8s minor version)
#
# Assumes the Packer IAM role, then runs `make k8s`.
# Writes the resulting AMI ID back to SSM on success.
# =============================================================================

locals {
  build_env = {
    "1.34" = {
      kubernetes_version        = var.k8s_versions["1.34"].kubernetes_version
      source_ami_filter_name    = "RHEL-9.6*_HVM-*"
    }
    "1.35" = {
      kubernetes_version        = var.k8s_versions["1.35"].kubernetes_version
      source_ami_filter_name    = "RHEL-9.6*_HVM-*"
    }
    "1.36" = {
      kubernetes_version        = var.k8s_versions["1.36"].kubernetes_version
      source_ami_filter_name    = "RHEL-9.6*_HVM-*"
    }
  }
}

resource "aws_codebuild_project" "build" {
  for_each = var.k8s_versions

  name          = "ami-build-${replace(each.key, ".", "-")}"
  description   = "Build FIPS RHEL EKS AMI for Kubernetes ${each.key}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 90

  source {
    type            = "GITHUB"
    location        = "https://github.com/${var.github_repository}"
    git_clone_depth = 1
    buildspec       = <<-BUILDSPEC
      version: 0.2
      env:
        variables:
          MINOR_VERSION: "${each.key}"
      phases:
        install:
          commands:
            - yum install -y make jq
            - curl -fsSL https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_linux_amd64.zip -o /tmp/packer.zip
            - unzip /tmp/packer.zip -d /usr/local/bin
        pre_build:
          commands:
            - |
              CREDS=$(aws sts assume-role \
                --role-arn "${var.ami_packer_role_arn}" \
                --role-session-name "ami-build-$${MINOR_VERSION}-$(date +%s)" \
                --query 'Credentials' --output json)
              export AWS_ACCESS_KEY_ID=$(echo "$${CREDS}" | jq -r .AccessKeyId)
              export AWS_SECRET_ACCESS_KEY=$(echo "$${CREDS}" | jq -r .SecretAccessKey)
              export AWS_SESSION_TOKEN=$(echo "$${CREDS}" | jq -r .SessionToken)
            - BUILD_DATE=$(aws ssm get-parameter --name "/ami-build/$${MINOR_VERSION}/build-date" --query 'Parameter.Value' --output text)
            - K8S_VERSION=$(aws ssm get-parameter --name "/ami-build/$${MINOR_VERSION}/kubernetes-version" --query 'Parameter.Value' --output text)
        build:
          commands:
            - |
              make k8s \
                kubernetes_version=$${K8S_VERSION} \
                source_ami_filter_name="${local.build_env[each.key].source_ami_filter_name}" \
                binary_bucket_region=us-east-1 \
                kubernetes_build_date=$${BUILD_DATE} \
                iam_instance_profile=${var.ami_build_instance_profile_name} \
                subnet_id=${var.ami_build_subnet_id} \
                ami_users=${local.ami_users} \
                kms_key_id=${var.ami_kms_key_arn} \
                pause_container_image=${var.pause_container_image} \
                enable_fips=true \
                rhel_version=9.6 2>&1 | tee /tmp/packer-build.log
        post_build:
          commands:
            - |
              AMI_ID=$(grep -oP 'ami-[a-f0-9]+' /tmp/packer-build.log | tail -1)
              if [ -z "$${AMI_ID}" ]; then
                echo "ERROR: Could not extract AMI ID from build log"
                exit 1
              fi
              echo "Built AMI: $${AMI_ID}"
              aws ssm put-parameter \
                --name "/ami-build/$${MINOR_VERSION}/latest-ami-id" \
                --value "$${AMI_ID}" --overwrite
              echo "AMI_ID=$${AMI_ID}" > /tmp/ami-output.env
      artifacts:
        files:
          - /tmp/ami-output.env
    BUILDSPEC
  }

  artifacts {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
    path     = "build-outputs/${each.key}"
    name     = "ami-output.env"
    packaging = "NONE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_LARGE"
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  vpc_config {
    vpc_id             = local.build_vpc_id
    subnets            = [var.ami_build_subnet_id]
    security_group_ids = [aws_security_group.fips_test.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["build-${replace(each.key, ".", "-")}"].name
    }
  }
}

# =============================================================================
# CodeBuild — Validate Stage (FIPS)
#
# Launches a test EC2 instance using the most recently built AMI (read from
# SSM), waits for SSM agent registration, then runs fips-mode-setup --check
# and checks /proc/sys/crypto/fips_enabled.  Terminates the instance on
# success or failure, failing the build if FIPS is not enabled.
# =============================================================================

resource "aws_codebuild_project" "validate" {
  name          = "ami-build-validate-fips"
  description   = "Launch test instance and verify FIPS mode is active"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        build:
          commands:
            - |
              FAILED=0
              for MINOR in 1.34 1.35 1.36; do
                AMI_ID=$(aws ssm get-parameter --name "/ami-build/$${MINOR}/latest-ami-id" --query 'Parameter.Value' --output text)
                if [ "$${AMI_ID}" = "UNSET" ] || [ -z "$${AMI_ID}" ]; then
                  echo "No AMI built for $${MINOR}, skipping validation"
                  continue
                fi
                echo "Launching FIPS test instance for k8s $${MINOR} using $${AMI_ID}"
                INSTANCE_ID=$(aws ec2 run-instances \
                  --image-id "$${AMI_ID}" \
                  --instance-type t3.small \
                  --subnet-id "${var.ami_build_subnet_id}" \
                  --security-group-ids "${aws_security_group.fips_test.id}" \
                  --iam-instance-profile Name="${aws_iam_instance_profile.fips_test.name}" \
                  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=fips-validation},{Key=managed-by,Value=ami-build-pipeline}]' \
                  --query 'Instances[0].InstanceId' --output text)
                echo "Instance: $${INSTANCE_ID}"
                # Wait for instance running
                aws ec2 wait instance-running --instance-ids "$${INSTANCE_ID}"
                # Wait for SSM agent (poll up to 3 min)
                for i in $(seq 1 18); do
                  STATUS=$(aws ssm describe-instance-information \
                    --filters "Key=InstanceIds,Values=$${INSTANCE_ID}" \
                    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
                  [ "$${STATUS}" = "Online" ] && break
                  sleep 10
                done
                if [ "$${STATUS}" != "Online" ]; then
                  echo "ERROR: SSM agent never came online for $${INSTANCE_ID}"
                  aws ec2 terminate-instances --instance-ids "$${INSTANCE_ID}"
                  FAILED=1
                  continue
                fi
                # Run FIPS checks via SSM
                CMD_ID=$(aws ssm send-command \
                  --instance-ids "$${INSTANCE_ID}" \
                  --document-name "AWS-RunShellScript" \
                  --parameters '{"commands":["fips-mode-setup --check","cat /proc/sys/crypto/fips_enabled"]}' \
                  --query 'Command.CommandId' --output text)
                # Wait for command completion (poll up to 2 min)
                for i in $(seq 1 12); do
                  CMD_STATUS=$(aws ssm get-command-invocation \
                    --command-id "$${CMD_ID}" --instance-id "$${INSTANCE_ID}" \
                    --query 'Status' --output text 2>/dev/null || echo "Pending")
                  [ "$${CMD_STATUS}" = "Success" ] || [ "$${CMD_STATUS}" = "Failed" ] && break
                  sleep 10
                done
                OUTPUT=$(aws ssm get-command-invocation \
                  --command-id "$${CMD_ID}" --instance-id "$${INSTANCE_ID}" \
                  --query 'StandardOutputContent' --output text)
                echo "FIPS check output for $${MINOR}:"
                echo "$${OUTPUT}"
                aws ec2 terminate-instances --instance-ids "$${INSTANCE_ID}"
                if ! echo "$${OUTPUT}" | grep -q "FIPS mode is enabled" || ! echo "$${OUTPUT}" | grep -q "^1$"; then
                  echo "ERROR: FIPS validation failed for k8s $${MINOR}"
                  FAILED=1
                fi
              done
              exit $${FAILED}
    BUILDSPEC
  }

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["validate"].name
    }
  }
}

# =============================================================================
# CodeBuild — Inspector Stage
#
# TODO: Wire Inspector v2 ECR container scanning or AMI scanning once the
# Inspector enablement pattern is established for account 791666871613.
# Currently a pass-through placeholder that emits a warning.
# =============================================================================

resource "aws_codebuild_project" "inspect" {
  name          = "ami-build-inspect"
  description   = "Placeholder: Inspector v2 AMI vulnerability scanning"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        build:
          commands:
            - echo "WARNING: Inspector scanning not yet configured. Revisit once Inspector v2 is enabled for this account."
            - echo "Expected: Inspector AMI scan or ECR container scan gated on inspector_critical_threshold=${var.inspector_critical_threshold}"
            - exit 0
    BUILDSPEC
  }

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = var.codebuild_image
    type         = "LINUX_CONTAINER"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["inspect"].name
    }
  }
}

# =============================================================================
# CodePipeline
#
# Stages:
#   1. Source     — GitHub via CodeConnections
#   2. Detect     — Check S3 for newer EKS binary build dates; update SSM
#   3. Build      — 1.34, 1.35, 1.36 in parallel
#   4. Validate   — FIPS gate: all three AMIs must pass before continuing
#   5. Scan       — Inspector v2 placeholder
#   6. Notify     — SNS placeholder (TODO: configure SNS topic)
#
# Note: Manual trigger only for now. Automated scheduling TBD.
# =============================================================================

resource "aws_codepipeline" "ami_build" {
  name     = local.pipeline_name
  role_arn = aws_iam_role.codepipeline.arn

  pipeline_type = "V2"

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
    encryption_key {
      id   = var.ami_kms_key_arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn        = data.aws_codestarconnections_connection.github.arn
        FullRepositoryId     = var.github_repository
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "false"  # Manual trigger only — revisit for automated scheduling
      }
    }
  }

  stage {
    name = "Detect"
    action {
      name             = "CheckBuildDate"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = []
      configuration = {
        ProjectName = aws_codebuild_project.detect.name
      }
    }
  }

  stage {
    name = "Build"
    dynamic "action" {
      for_each = var.k8s_versions
      content {
        name             = "Build-${replace(action.key, ".", "-")}"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        run_order        = 1
        input_artifacts  = ["source_output"]
        output_artifacts = ["build_output_${replace(action.key, ".", "_")}"]
        configuration = {
          ProjectName = aws_codebuild_project.build[action.key].name
        }
      }
    }
  }

  stage {
    name = "Validate"
    action {
      name             = "FIPSCheck"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = []
      output_artifacts = []
      configuration = {
        ProjectName = aws_codebuild_project.validate.name
      }
    }
  }

  stage {
    name = "Scan"
    action {
      name             = "InspectorScan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = []
      output_artifacts = []
      configuration = {
        ProjectName = aws_codebuild_project.inspect.name
      }
    }
  }

  stage {
    name = "Notify"
    action {
      name             = "SNSNotification"
      category         = "Invoke"
      owner            = "AWS"
      provider         = "Lambda"
      version          = "1"
      input_artifacts  = []
      output_artifacts = []
      # TODO: Replace with a real Lambda/SNS notification once the SNS topic is
      # created for this pipeline.  Remove this entire action or swap provider
      # to "SNS" when ready.
      configuration = {
        FunctionName = "placeholder-do-not-deploy"
      }
    }
  }
}
