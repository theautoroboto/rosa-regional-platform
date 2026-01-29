# Cross-Account CodePipeline Setup Guide

This guide walks you through the complete setup process for testing cross-account access with AWS CodePipeline.

## Prerequisites

- Terraform >= 1.0 installed
- AWS CLI configured
- Access to three AWS accounts:
  - **Central Account**: Where CodePipeline will run
  - **Target Account 1**: First test account
  - **Target Account 2**: Second test account
- Appropriate IAM permissions in all three accounts

## Architecture Summary

The setup creates:
1. **Central Account**: CodePipeline + CodeBuild projects
2. **Target Accounts**: IAM roles that trust the central account

The CodeBuild projects will:
1. Assume a role in each target account
2. Run `aws sts get-caller-identity` to verify access
3. Validate the assumed identity matches the target account

## Step-by-Step Setup

### Phase 1: Deploy in Central Account

#### 1.1 Gather Account IDs

```bash
# Note your three account IDs
CENTRAL_ACCOUNT_ID="999999999999"    # Replace with actual
TARGET_ACCOUNT_1_ID="111111111111"   # Replace with actual
TARGET_ACCOUNT_2_ID="222222222222"   # Replace with actual
```

#### 1.2 Configure Terraform for Central Account

```bash
cd examples/central-account

# Copy the example tfvars
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your account IDs
cat > terraform.tfvars <<EOF
aws_region          = "us-east-1"
environment         = "test"
target_account_1_id = "$TARGET_ACCOUNT_1_ID"
target_account_2_id = "$TARGET_ACCOUNT_2_ID"
target_role_name    = "CodePipelineCrossAccountRole"
EOF
```

#### 1.3 Deploy Central Account Infrastructure

```bash
# Authenticate to central account
# Example with AWS SSO:
aws sso login --profile central-account
export AWS_PROFILE=central-account

# Initialize and apply
terraform init
terraform plan
terraform apply
```

#### 1.4 Capture Outputs

```bash
# Save these outputs - you'll need them for target accounts
terraform output codebuild_role_arn
terraform output central_account_id
terraform output artifacts_bucket
```

Example output:
```
codebuild_role_arn = "arn:aws:iam::999999999999:role/codebuild-cross-account-20260129123456"
central_account_id = "999999999999"
artifacts_bucket = "codepipeline-cross-account-test-20260129123456"
```

**IMPORTANT**: Save the `codebuild_role_arn` - you'll use this in the next phase.

### Phase 2: Deploy in Target Account 1

#### 2.1 Configure Terraform for Target Account 1

```bash
cd ../target-account

# Copy the example tfvars
cp terraform.tfvars.example terraform.tfvars.account1

# Edit with values from central account outputs
cat > terraform.tfvars.account1 <<EOF
aws_region                 = "us-east-1"
role_name                  = "CodePipelineCrossAccountRole"
central_account_id         = "$CENTRAL_ACCOUNT_ID"
central_codebuild_role_arn = "arn:aws:iam::$CENTRAL_ACCOUNT_ID:role/codebuild-cross-account-XXXXX"
external_id                = ""
EOF
```

#### 2.2 Deploy Target Account 1 Role

```bash
# Authenticate to target account 1
aws sso login --profile target-account-1
export AWS_PROFILE=target-account-1

# Deploy the role
terraform init
terraform apply -var-file=terraform.tfvars.account1
```

#### 2.3 Verify Role Creation

```bash
# Verify the role exists
aws iam get-role --role-name CodePipelineCrossAccountRole

# Check the trust policy
aws iam get-role \
  --role-name CodePipelineCrossAccountRole \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json
```

You should see the central account's CodeBuild role in the Principal.

### Phase 3: Deploy in Target Account 2

#### 3.1 Configure Terraform for Target Account 2

```bash
# Create tfvars for account 2
cat > terraform.tfvars.account2 <<EOF
aws_region                 = "us-east-1"
role_name                  = "CodePipelineCrossAccountRole"
central_account_id         = "$CENTRAL_ACCOUNT_ID"
central_codebuild_role_arn = "arn:aws:iam::$CENTRAL_ACCOUNT_ID:role/codebuild-cross-account-XXXXX"
external_id                = ""
EOF
```

#### 3.2 Deploy Target Account 2 Role

```bash
# Authenticate to target account 2
aws sso login --profile target-account-2
export AWS_PROFILE=target-account-2

# Deploy the role
terraform apply -var-file=terraform.tfvars.account2
```

#### 3.3 Verify Role Creation

```bash
aws iam get-role --role-name CodePipelineCrossAccountRole
```

### Phase 4: Test the Pipeline

#### 4.1 Switch Back to Central Account

```bash
aws sso login --profile central-account
export AWS_PROFILE=central-account
cd ../central-account
```

#### 4.2 Create Pipeline Trigger

The pipeline uses S3 as a source, so we need to upload a trigger file:

```bash
# Get the artifacts bucket name
ARTIFACTS_BUCKET=$(terraform output -raw artifacts_bucket)

# Create and upload trigger file
echo "trigger" > trigger.txt
zip trigger.zip trigger.txt
aws s3 cp trigger.zip s3://$ARTIFACTS_BUCKET/trigger/dummy.zip

# Verify upload
aws s3 ls s3://$ARTIFACTS_BUCKET/trigger/
```

#### 4.3 Start Pipeline Execution

```bash
# Get pipeline name
PIPELINE_NAME=$(terraform output -raw pipeline_name)

# Start the pipeline
aws codepipeline start-pipeline-execution \
  --name $PIPELINE_NAME

# Get execution ID from output
EXECUTION_ID="<execution-id-from-previous-command>"
```

#### 4.4 Monitor Pipeline Progress

```bash
# Watch pipeline state
watch -n 5 "aws codepipeline get-pipeline-state --name $PIPELINE_NAME"

# Or check specific execution
aws codepipeline get-pipeline-execution \
  --pipeline-name $PIPELINE_NAME \
  --pipeline-execution-id $EXECUTION_ID
```

#### 4.5 View Build Logs

```bash
# Account 1 logs
aws logs tail /aws/codebuild/cross-account-test/account1 --follow

# Account 2 logs (in separate terminal)
aws logs tail /aws/codebuild/cross-account-test/account2 --follow
```

### Phase 5: Verify Success

#### 5.1 Expected Success Output

In the CodeBuild logs, you should see:

```
=== Cross-Account STS Test for Account-1 ===
Central Account (running in):
{
    "UserId": "AIDACKCEVSQ6C2EXAMPLE",
    "Account": "999999999999",
    "Arn": "arn:aws:iam::999999999999:role/codebuild-cross-account-..."
}

=== Successfully assumed role! ===
Session ARN: arn:aws:sts::111111111111:assumed-role/CodePipelineCrossAccountRole/...

=== Getting Caller Identity in Target Account ===
{
    "UserId": "AROACKCEVSQ6C2EXAMPLE:...",
    "Account": "111111111111",
    "Arn": "arn:aws:sts::111111111111:assumed-role/CodePipelineCrossAccountRole/..."
}

✓ Successfully verified access to Account-1 (Account ID: 111111111111)
```

#### 5.2 Validation Checklist

- [ ] Pipeline execution status: "Succeeded"
- [ ] Account 1 test stage: "Succeeded"
- [ ] Account 2 test stage: "Succeeded"
- [ ] Logs show correct account IDs for both target accounts
- [ ] No "Access Denied" errors in logs

## Understanding the Access Pattern

### What Just Happened?

1. **CodePipeline** started execution in the central account
2. **CodeBuild Project 1** ran in the central account and:
   - Used its IAM role credentials
   - Called `sts:AssumeRole` to get temporary credentials for Target Account 1
   - Used those temporary credentials to call `sts:GetCallerIdentity`
   - Verified the identity matches Target Account 1
3. **CodeBuild Project 2** repeated the same process for Target Account 2

### IAM Permission Flow

```
Central Account CodeBuild Role
  |
  ├─ Has permission: "sts:AssumeRole"
  |  on "arn:aws:iam::111111111111:role/CodePipelineCrossAccountRole"
  |
  └─ Calls: aws sts assume-role --role-arn arn:aws:iam::111111111111:role/...
        |
        ├─ Target Account 1 checks trust policy
        |  ├─ Does trust policy allow central account CodeBuild role? YES
        |  └─ Returns temporary credentials (AccessKeyId, SecretAccessKey, SessionToken)
        |
        └─ CodeBuild exports these credentials and uses them
           └─ Now acting AS the Target Account 1 role
              └─ Can perform actions allowed by Target Account 1 role's permissions
```

### Key IAM Components

#### Central Account - CodeBuild Role Permission Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::111111111111:role/CodePipelineCrossAccountRole",
        "arn:aws:iam::222222222222:role/CodePipelineCrossAccountRole"
      ]
    }
  ]
}
```

This says: "CodeBuild role can ATTEMPT to assume roles in target accounts"

#### Target Account - Role Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::999999999999:role/codebuild-cross-account-XXXXX"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

This says: "This role TRUSTS the central account CodeBuild role and allows it to assume this role"

#### Target Account - Role Permission Policy

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

This says: "Once assumed, this role can call GetCallerIdentity"

### Both Sides Required

Cross-account access requires **BOTH**:
1. Central account role must have `sts:AssumeRole` permission on target role (Permission Policy)
2. Target account role must trust the central account role (Trust Policy)

If either is missing, the assume role call will fail with "Access Denied".

## Troubleshooting

### Problem: "User is not authorized to perform: sts:AssumeRole"

**Root Cause**: Central account CodeBuild role doesn't have the permission.

**Fix**:
```bash
# In central account, check the CodeBuild role policy
aws iam get-role-policy \
  --role-name codebuild-cross-account-XXXXX \
  --policy-name codebuild-assume-role-policy
```

Verify it includes `sts:AssumeRole` on the target account role ARNs.

### Problem: "is not authorized to perform: sts:AssumeRole on resource"

**Root Cause**: Target account role doesn't trust the central account.

**Fix**:
```bash
# In target account, check the trust policy
aws iam get-role \
  --role-name CodePipelineCrossAccountRole \
  --query 'Role.AssumeRolePolicyDocument'
```

Verify the Principal includes the central account CodeBuild role ARN.

### Problem: Pipeline stuck at "Source" stage

**Root Cause**: Trigger file not uploaded to S3.

**Fix**:
```bash
# Upload the trigger file
echo "trigger" > trigger.txt
zip trigger.zip trigger.txt
aws s3 cp trigger.zip s3://$ARTIFACTS_BUCKET/trigger/dummy.zip
```

### Problem: "NoSuchKey" error in pipeline

**Root Cause**: S3 object key doesn't match pipeline configuration.

**Fix**: Ensure you upload to exactly `trigger/dummy.zip` in the artifacts bucket.

## Next Steps

### Extending for Real Workloads

Once you've verified cross-account access works, you can:

1. **Add Real Permissions**: Update target account roles with actual permissions needed
   ```hcl
   additional_policy_json = jsonencode({
     Version = "2012-10-17"
     Statement = [
       {
         Effect = "Allow"
         Action = ["eks:DescribeCluster", "eks:ListClusters"]
         Resource = "*"
       }
     ]
   })
   ```

2. **Customize BuildSpecs**: Replace the test buildspec with real deployment commands

3. **Add External ID**: Enhance security with external IDs

4. **Add More Accounts**: Extend the pattern to additional target accounts

5. **Integrate with CI/CD**: Trigger pipeline from Git commits, webhooks, etc.

## Cleanup

To remove all resources:

```bash
# Target Account 2
export AWS_PROFILE=target-account-2
terraform destroy -var-file=terraform.tfvars.account2

# Target Account 1
export AWS_PROFILE=target-account-1
terraform destroy -var-file=terraform.tfvars.account1

# Central Account
export AWS_PROFILE=central-account
terraform destroy
```

## Summary

You now understand:
- How to set up cross-account IAM roles
- The trust relationship between accounts
- How CodePipeline/CodeBuild can assume roles in other accounts
- The permissions required on both sides
- How to verify and troubleshoot cross-account access

This pattern can be extended to any cross-account automation scenario.
