# Cross-Account Testing Pipeline - Scheduled Execution

This Terraform configuration deploys a CodePipeline that automatically tests cross-account access on an hourly schedule. It validates that the central account can successfully assume roles in target AWS accounts.

## Features

- **⏰ Scheduled Execution**: Runs automatically every hour (configurable)
- **🔄 EventBridge Trigger**: No GitHub or manual intervention needed
- **📊 Cross-Account Testing**: Validates access to multiple AWS accounts
- **📝 Detailed Logging**: CloudWatch Logs capture all test execution details
- **🚀 Simple Setup**: Just configure account IDs and deploy

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Central Account                          │
│                                                              │
│  ┌──────────────────┐                                       │
│  │  EventBridge     │  ⏰ Every hour (configurable)         │
│  │  Cron Rule       │                                       │
│  └──────────────────┘                                       │
│           │                                                  │
│           ▼                                                  │
│  ┌──────────────────────────────┐                          │
│  │     CodePipeline             │                          │
│  │  - Source: Dummy S3          │                          │
│  │  - Test: CodeBuild           │                          │
│  └──────────────────────────────┘                          │
│           │                                                  │
│           ▼                                                  │
│  ┌──────────────────────────────┐                          │
│  │      CodeBuild Project       │                          │
│  │  - Assumes roles in targets  │───────┼────┐            │
│  │  - Runs get-caller-identity  │       │    │            │
│  └──────────────────────────────┘       │    │            │
└─────────────────────────────────────────┘    │            │
                                                                    │
┌────────────────────────────────────────────────────────┐        │
│                    Target Account 1                     │        │
│  IAM Role: OrganizationAccountAccessRole              │◀───────┘
│  Trust: Central Account CodeBuild Role                │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│                    Target Account 2                     │
│  IAM Role: OrganizationAccountAccessRole              │◀───────┘
│  Trust: Central Account CodeBuild Role                │
└────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

1. AWS Account (central account) with appropriate permissions
2. Target AWS accounts where cross-account access will be tested
3. Terraform >= 1.0

### Step 1: Configure Variables

```bash
# Copy the example file
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
vi terraform.tfvars
```

**Minimum required configuration:**

```hcl
# Target accounts to test
target_account_ids = [
  "123456789012",  # Account 1
  "987654321098"   # Account 2
]

# Role name in target accounts
target_role_name = "OrganizationAccountAccessRole"
```

**Optional customization:**

```hcl
# Change schedule (default: every hour)
schedule_expression = "rate(30 minutes)"  # Run every 30 minutes
# Or use cron format:
# schedule_expression = "cron(0 9 * * ? *)"  # Daily at 9 AM UTC
```

### Step 2: Deploy with Terraform

```bash
# Initialize Terraform
terraform init

# Review what will be created
terraform plan

# Deploy all resources
terraform apply
```

**What gets created:**
- ✅ EventBridge rule with hourly schedule
- ✅ CodePipeline with dummy S3 source and Test stage
- ✅ CodeBuild project for cross-account testing
- ✅ S3 bucket for artifacts (encrypted, versioned)
- ✅ IAM roles and policies
- ✅ CloudWatch Log Group

### Step 3: Configure Target Accounts

In **each target account**, create an IAM role that trusts the central account's CodeBuild role.

**Get the CodeBuild role ARN:**

```bash
terraform output codebuild_service_role_arn
# Example output: arn:aws:iam::999999999999:role/cross-account-test-service-role
```

**In each target account, create the role:**

**Trust Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::CENTRAL_ACCOUNT_ID:role/cross-account-test-service-role"
      },
      "Action": "sts:AssumeRole"
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

**Using AWS CLI:**
```bash
# Create the trust policy file
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::CENTRAL_ACCOUNT_ID:role/cross-account-test-service-role"
    },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Create the role
aws iam create-role \
  --role-name OrganizationAccountAccessRole \
  --assume-role-policy-document file://trust-policy.json

# Attach minimal permissions
aws iam put-role-policy \
  --role-name OrganizationAccountAccessRole \
  --policy-name GetCallerIdentity \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}'
```

### Step 4: Wait for First Run (or Trigger Manually)

The pipeline will automatically run every hour. You can also trigger it manually immediately:

```bash
# Get the pipeline name
PIPELINE_NAME=$(terraform output -raw pipeline_name)

# Trigger manually
aws codepipeline start-pipeline-execution --name $PIPELINE_NAME

# Monitor execution
aws codepipeline get-pipeline-state --name $PIPELINE_NAME

# View logs
aws logs tail /aws/codebuild/cross-account-test --follow
```

## How It Works

### Pipeline Execution Flow

1. **Trigger**: Push to GitHub branch or manual trigger
2. **Source Stage**: CodePipeline downloads code from GitHub via CodeStar Connection
3. **Test Stage**: CodeBuild runs the cross-account test script
4. **For Each Target Account**:
   - Assume the cross-account IAM role using `aws sts assume-role`
   - Export temporary credentials (access key, secret, session token)
   - Run `aws sts get-caller-identity` with assumed credentials
   - Verify the returned account ID matches the target account
5. **Results**: Success/failure logged to CloudWatch Logs

### What Gets Validated

✅ CodeBuild role has `sts:AssumeRole` permission
✅ Target account roles trust the CodeBuild role
✅ Role assumption succeeds and returns valid credentials
✅ Assumed role can execute `get-caller-identity`
✅ Returned account ID matches expected target account

## Monitoring and Troubleshooting

### Check Connection Status

```bash
# Get connection ARN
terraform output github_connection_arn

# Check status
aws codestar-connections get-connection \
  --connection-arn $(terraform output -raw github_connection_arn)
```

**Status values:**
- `PENDING`: Needs approval (see Step 3)
- `AVAILABLE`: Ready to use
- `ERROR`: Check connection settings

### View Pipeline Status

```bash
# Open in console
terraform output pipeline_url

# CLI - Watch pipeline state
watch -n 5 "aws codepipeline get-pipeline-state --name $(terraform output -raw pipeline_name)"

# Get execution history
aws codepipeline list-pipeline-executions \
  --pipeline-name $(terraform output -raw pipeline_name)
```

### View Build Logs

```bash
# Tail logs in real-time
aws logs tail /aws/codebuild/cross-account-test --follow

# Get recent builds
aws codebuild list-builds-for-project \
  --project-name cross-account-test
```

### Common Issues

#### Pipeline Fails at Source Stage

**Error**: "Could not access CodeStar Connection"

**Cause**: Connection is in PENDING status.

**Solution**: Complete GitHub authorization (see Step 3).

```bash
# Check connection status
terraform output github_connection_status

# Open approval URL
terraform output github_connection_url
```

#### Build Fails: "User is not authorized to perform: sts:AssumeRole"

**Cause**: CodeBuild role doesn't have permission to assume the target role.

**Solution**: This should be automatic from Terraform. Verify:

```bash
aws iam get-role-policy \
  --role-name cross-account-test-service-role \
  --policy-name allow-assume-cross-account
```

Should include `sts:AssumeRole` on target account role ARNs.

#### Build Fails: "is not authorized to perform: sts:AssumeRole on resource"

**Cause**: Target account role doesn't trust the CodeBuild role.

**Solution**: Verify trust policy in target account:

```bash
# In target account
aws iam get-role \
  --role-name OrganizationAccountAccessRole \
  --query 'Role.AssumeRolePolicyDocument'
```

Should include the central account CodeBuild role ARN as Principal.

#### Pipeline Not Triggering on Push

**Cause**: Connection not approved or `DetectChanges` disabled.

**Solutions**:

1. Verify connection is AVAILABLE:
   ```bash
   terraform output github_connection_status
   ```

2. Check pipeline configuration:
   ```bash
   aws codepipeline get-pipeline \
     --name $(terraform output -raw pipeline_name) \
     | jq '.pipeline.stages[0].actions[0].configuration.DetectChanges'
   ```
   Should return `"true"`.

3. Verify GitHub App has repository access:
   - GitHub → Settings → Applications → AWS CodeStar → Configure
   - Check repository access list

## Terraform Outputs Reference

| Output | Description |
|--------|-------------|
| `pipeline_name` | Name of the CodePipeline |
| `pipeline_url` | Console URL to view pipeline |
| `codebuild_service_role_arn` | CodeBuild role ARN (for target account trust policies) |
| `github_connection_arn` | ARN of the CodeStar Connection |
| `github_connection_status` | Connection status (PENDING/AVAILABLE) |
| `github_connection_url` | URL to approve the connection |
| `artifacts_bucket` | S3 bucket for pipeline artifacts |
| `manual_trigger_command` | Command to manually trigger pipeline |

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `target_account_ids` | List of AWS account IDs to test | Required |
| `target_role_name` | IAM role name in target accounts | `OrganizationAccountAccessRole` |
| `github_repo_full_name` | Repository in format "owner/repo" | `theautoroboto/rosa-regional-platform` |
| `github_repo_branch` | Branch to monitor | `main` |
| `github_connection_name` | Name for CodeStar Connection | `github-rosa-pipeline` |

## Security Best Practices

1. **Least Privilege**: Target account roles should only have minimum required permissions
2. **Audit Logging**: Enable CloudTrail in all accounts to track cross-account access
3. **Connection Management**: Regularly review GitHub App permissions and repository access
4. **Branch Protection**: Protect monitored branch to prevent unauthorized triggers
5. **External IDs**: Consider adding external IDs to trust policies for enhanced security
6. **Encrypted Artifacts**: S3 bucket uses AES-256 encryption (enabled by default)

## Cost Estimation

- **CodePipeline**: $1/month (active pipeline)
- **CodeBuild**: ~$0.025/execution (5 minutes @ $0.005/minute)
- **CodeStar Connection**: Free
- **S3 Storage**: Minimal (< $0.10/month)
- **CloudWatch Logs**: ~$0.50/GB ingested

**Estimated monthly cost**: ~$2-5 depending on execution frequency

## Cleanup

To remove all resources:

```bash
# Destroy Terraform-managed resources
terraform destroy

# Note: You may need to manually delete:
# - CloudWatch Log streams (if retention is still active)
# - S3 bucket contents (if not empty)
```

The CodeStar Connection will also be deleted. If you want to keep it for other pipelines, you can:

```bash
# Remove the connection from Terraform state without deleting it
terraform state rm aws_codestarconnections_connection.github

# Then run destroy
terraform destroy
```

## Extending This Pipeline

### Add More Target Accounts

Edit `terraform.tfvars`:

```hcl
target_account_ids = [
  "123456789012",
  "987654321098",
  "555555555555",  # New account
  "666666666666"   # Another account
]
```

Then:
```bash
terraform apply
```

Create the IAM role in the new accounts (see Step 4).

### Add Additional Pipeline Stages

Edit `main.tf` to add stages after the Test stage:

```hcl
stage {
  name = "Deploy"

  action {
    name     = "DeployToProduction"
    category = "Build"
    # ... deployment configuration
  }
}
```

### Customize Test Logic

Edit the buildspec in `main.tf` (around line 82) to add custom validation:

```yaml
- echo "Running custom validation..."
- # Add your commands here
```

## Related Documentation

- [AWS CodePipeline](https://docs.aws.amazon.com/codepipeline/)
- [CodeStar Connections](https://docs.aws.amazon.com/dtconsole/latest/userguide/connections.html)
- [Cross-Account IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html)
- [CodeBuild BuildSpec](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
