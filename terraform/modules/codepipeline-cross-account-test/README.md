# CodePipeline Cross-Account Testing Module

This Terraform module creates a CodePipeline in a central AWS account that can assume roles in two different target AWS accounts to test cross-account access patterns. It's designed to help you understand and validate the IAM permissions required for cross-account operations.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Central Account                          │
│                                                              │
│  ┌──────────────┐      ┌─────────────────────────────┐     │
│  │ CodePipeline │─────▶│ CodeBuild (Account 1 Test)  │     │
│  │              │      │   - Assumes role in Acct 1  │────┼─────┐
│  │              │      │   - Runs get-caller-identity │     │     │
│  │              │      └─────────────────────────────┘     │     │
│  │              │                                           │     │
│  │              │      ┌─────────────────────────────┐     │     │
│  │              │─────▶│ CodeBuild (Account 2 Test)  │     │     │
│  │              │      │   - Assumes role in Acct 2  │────┼─────┼─────┐
│  │              │      │   - Runs get-caller-identity │     │     │     │
│  └──────────────┘      └─────────────────────────────┘     │     │     │
│                                                              │     │     │
│  IAM Role: codebuild-cross-account-*                        │     │     │
│  Permissions: sts:AssumeRole on target accounts             │     │     │
└─────────────────────────────────────────────────────────────┘     │     │
                                                                     │     │
                                                                     │     │
┌────────────────────────────────────────────────────────────┐     │     │
│                    Target Account 1                         │     │     │
│                                                             │◀────┘     │
│  IAM Role: CodePipelineCrossAccountRole                    │           │
│  Trust Policy: Allow central account CodeBuild role        │           │
│  Permissions: sts:GetCallerIdentity (minimal for testing)  │           │
└────────────────────────────────────────────────────────────┘           │
                                                                          │
┌────────────────────────────────────────────────────────────┐           │
│                    Target Account 2                         │           │
│                                                             │◀──────────┘
│  IAM Role: CodePipelineCrossAccountRole                    │
│  Trust Policy: Allow central account CodeBuild role        │
│  Permissions: sts:GetCallerIdentity (minimal for testing)  │
└────────────────────────────────────────────────────────────┘
```

## Required Access Patterns

### Central Account (Where Pipeline Runs)

**CodePipeline Service Role Permissions:**
- `s3:GetObject`, `s3:PutObject` on artifacts bucket
- `codebuild:StartBuild`, `codebuild:BatchGetBuilds` on CodeBuild projects

**CodeBuild Service Role Permissions:**
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` for CloudWatch Logs
- `s3:GetObject`, `s3:PutObject` on artifacts bucket
- `sts:AssumeRole` on target account roles:
  - `arn:aws:iam::<TARGET_ACCOUNT_1_ID>:role/CodePipelineCrossAccountRole`
  - `arn:aws:iam::<TARGET_ACCOUNT_2_ID>:role/CodePipelineCrossAccountRole`

### Target Accounts (Account 1 & Account 2)

**Cross-Account IAM Role (`CodePipelineCrossAccountRole`):**

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<CENTRAL_ACCOUNT_ID>:role/codebuild-cross-account-*"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<optional-external-id>"
        }
      }
    }
  ]
}
```

**Permissions Policy (minimal for testing):**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

## Usage

### Step 1: Deploy in Central Account

Create a `terraform.tfvars` file:

```hcl
aws_region          = "us-east-1"
environment         = "test"
target_account_1_id = "111111111111"  # Replace with actual account ID
target_account_2_id = "222222222222"  # Replace with actual account ID
target_role_name    = "CodePipelineCrossAccountRole"
```

Deploy the main module:

```hcl
module "cross_account_pipeline" {
  source = "./modules/codepipeline-cross-account-test"

  aws_region          = var.aws_region
  environment         = var.environment
  target_account_1_id = var.target_account_1_id
  target_account_2_id = var.target_account_2_id
  target_role_name    = var.target_role_name
}

output "setup_instructions" {
  value = module.cross_account_pipeline.setup_instructions
}

output "codebuild_role_arn" {
  value = module.cross_account_pipeline.codebuild_role_arn
}
```

Run Terraform:

```bash
terraform init
terraform plan
terraform apply
```

**Important:** Note the `codebuild_role_arn` from the output - you'll need this for the next step.

### Step 2: Deploy Roles in Target Accounts

In **Target Account 1**, create a Terraform configuration:

```hcl
# Configure provider for Target Account 1
provider "aws" {
  region = "us-east-1"
  # Use appropriate authentication method (AWS SSO, profile, etc.)
  profile = "target-account-1"
}

module "cross_account_role" {
  source = "./modules/codepipeline-cross-account-test/target-account-role"

  role_name                  = "CodePipelineCrossAccountRole"
  central_account_id         = "999999999999"  # Central account ID
  central_codebuild_role_arn = "arn:aws:iam::999999999999:role/codebuild-cross-account-XXXXX"
  external_id                = ""  # Optional: add for extra security
}

output "role_arn" {
  value = module.cross_account_role.role_arn
}
```

Repeat for **Target Account 2** with appropriate credentials.

### Step 3: Trigger the Pipeline

The pipeline uses S3 as a source with manual triggering. Create a dummy trigger file:

```bash
# Create a dummy file
echo "trigger" > trigger.txt
zip trigger.zip trigger.txt

# Upload to S3 (replace bucket name from outputs)
aws s3 cp trigger.zip s3://<artifacts-bucket>/trigger/dummy.zip

# Start the pipeline
aws codepipeline start-pipeline-execution \
  --name cross-account-test-pipeline
```

### Step 4: Monitor Results

View the pipeline execution:

```bash
aws codepipeline get-pipeline-state --name cross-account-test-pipeline
```

Check CloudWatch Logs:

```bash
# Account 1 logs
aws logs tail /aws/codebuild/cross-account-test/account1 --follow

# Account 2 logs
aws logs tail /aws/codebuild/cross-account-test/account2 --follow
```

## What This Tests

This module validates:

1. **Trust Relationship**: Central account CodeBuild role can assume roles in target accounts
2. **IAM Permissions**: CodeBuild has `sts:AssumeRole` permissions
3. **Role Assumption**: Temporary credentials are correctly obtained via `AssumeRole`
4. **Cross-Account Identity**: `get-caller-identity` returns target account details
5. **Session Management**: Role session credentials work correctly

## Expected Output

When successful, you'll see output like:

```
=== Cross-Account STS Test for Account-1 ===
Central Account (running in):
{
    "UserId": "AIDACKCEVSQ6C2EXAMPLE",
    "Account": "999999999999",
    "Arn": "arn:aws:iam::999999999999:role/codebuild-cross-account-XXXXX"
}

=== Assuming role in target account ===
Role ARN: arn:aws:iam::111111111111:role/CodePipelineCrossAccountRole

=== Successfully assumed role! ===
Session ARN: arn:aws:sts::111111111111:assumed-role/CodePipelineCrossAccountRole/codepipeline-cross-account-test-1

=== Getting Caller Identity in Target Account ===
{
    "UserId": "AROACKCEVSQ6C2EXAMPLE:codepipeline-cross-account-test-1",
    "Account": "111111111111",
    "Arn": "arn:aws:sts::111111111111:assumed-role/CodePipelineCrossAccountRole/codepipeline-cross-account-test-1"
}

✓ Successfully verified access to Account-1 (Account ID: 111111111111)
```

## Troubleshooting

### Error: "User is not authorized to perform: sts:AssumeRole"

**Cause:** CodeBuild role doesn't have `sts:AssumeRole` permission on target role.

**Solution:** Verify the CodeBuild role policy includes:
```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<TARGET_ACCOUNT_ID>:role/CodePipelineCrossAccountRole"
}
```

### Error: "is not authorized to perform: sts:AssumeRole on resource"

**Cause:** Target account role doesn't trust the central account CodeBuild role.

**Solution:** Check the trust policy in the target account role:
```bash
aws iam get-role --role-name CodePipelineCrossAccountRole --query 'Role.AssumeRolePolicyDocument'
```

Ensure it includes the central account CodeBuild role ARN in the Principal.

### Error: "Access Denied" on get-caller-identity

**Cause:** Target account role doesn't have the permission policy attached.

**Solution:** Verify the role has the minimal policy:
```bash
aws iam list-attached-role-policies --role-name CodePipelineCrossAccountRole
aws iam list-role-policies --role-name CodePipelineCrossAccountRole
```

### External ID Mismatch

**Cause:** External ID in trust policy doesn't match what's being passed.

**Solution:** Either remove the external ID condition from the trust policy, or ensure both sides use the same value.

## Security Best Practices

1. **Use External IDs**: Add an external ID to prevent the "confused deputy" problem
2. **Least Privilege**: Target roles should have minimal permissions (only what's needed)
3. **Session Duration**: Keep session duration short (default: 900s / 15 minutes)
4. **MFA Requirement**: Consider requiring MFA for role assumption in production
5. **Audit Logging**: Enable CloudTrail in all accounts to track cross-account access
6. **Regular Rotation**: Regularly review and rotate external IDs

## Extending This Module

To use this pattern for actual workloads:

1. **Add Real Permissions**: Update `additional_policy_json` in target account roles
2. **Custom BuildSpecs**: Replace the test buildspec with your actual commands
3. **Add More Stages**: Extend the pipeline with additional test or deployment stages
4. **Environment Variables**: Add secrets via AWS Secrets Manager or SSM Parameter Store
5. **Approval Gates**: Add manual approval actions between stages

## Module Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| aws_region | AWS region for pipeline deployment | string | us-east-1 | no |
| environment | Environment name | string | test | no |
| target_account_1_id | First target AWS account ID | string | - | yes |
| target_account_2_id | Second target AWS account ID | string | - | yes |
| target_role_name | IAM role name in target accounts | string | CodePipelineCrossAccountRole | no |

## Module Outputs

| Name | Description |
|------|-------------|
| pipeline_name | Name of the CodePipeline |
| pipeline_arn | ARN of the CodePipeline |
| codebuild_role_arn | ARN of CodeBuild role (needed for target account trust) |
| artifacts_bucket | S3 bucket for artifacts |
| central_account_id | Central account ID where pipeline runs |
| setup_instructions | Step-by-step setup instructions |

## Cost Considerations

- **CodePipeline**: $1/active pipeline/month
- **CodeBuild**: $0.005/build minute (general1.small)
- **S3**: Minimal storage costs for artifacts
- **CloudWatch Logs**: $0.50/GB ingested, $0.03/GB stored

Expected cost for testing: **< $5/month** with occasional runs.

## License

This module is part of the ROSA Regional Platform project.
