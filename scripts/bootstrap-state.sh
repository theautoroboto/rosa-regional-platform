#!/bin/bash
set -euo pipefail

# Get account ID with error checking
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager 2>/dev/null); then
    echo "❌ Error: Failed to get AWS account ID. Check your AWS credentials."
    exit 1
fi

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Error: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

REGION=${1:-$(aws configure get region 2>/dev/null)}
REGION=${REGION:-us-east-1}
BUCKET_NAME="terraform-state-${ACCOUNT_ID}"

echo "Bootstrapping Terraform State in $REGION..."
echo "Bucket: $BUCKET_NAME"
echo ""

# Function to apply bucket security settings
apply_bucket_security() {
    echo "Applying security settings to bucket $BUCKET_NAME..."

    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION"

    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$REGION"

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$REGION"

    # Get AWS Organization ID to restrict access to organization members only
    ORG_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null || echo "")

    # Add bucket policy to allow cross-account access
    # Note: For AWS Organizations, we rely on IAM policies instead of bucket policies
    # to avoid issues with Principal: "*" which AWS may reject in some configurations
    if [ -n "$ORG_ID" ]; then
        echo "Detected AWS Organization: $ORG_ID"
        echo "⚠️  Skipping bucket policy for Organization accounts"
        echo "⚠️  Access control will be managed via IAM policies (OrganizationAccountAccessRole)"
        echo "⚠️  Ensure cross-account roles have s3:* permissions for ${BUCKET_NAME}"
        # No bucket policy needed for org accounts - IAM handles it
        echo '{"Version":"2012-10-17","Statement":[]}' > /tmp/bucket-policy.json
        SKIP_POLICY=true
    else
        echo "⚠️  Warning: Not in an AWS Organization"
        echo "⚠️  Bucket policy will restrict access to this account only"
        # Use jq to generate policy to avoid heredoc/escaping issues
        jq -n \
          --arg bucket "arn:aws:s3:::${BUCKET_NAME}" \
          --arg bucketObjects "arn:aws:s3:::${BUCKET_NAME}/*" \
          --arg accountRoot "arn:aws:iam::${ACCOUNT_ID}:root" \
          '{
            "Version": "2012-10-17",
            "Statement": [
              {
                "Sid": "AllowCurrentAccountBucket",
                "Effect": "Allow",
                "Principal": {
                  "AWS": $accountRoot
                },
                "Action": [
                  "s3:ListBucket",
                  "s3:GetBucketVersioning",
                  "s3:GetBucketLocation"
                ],
                "Resource": $bucket
              },
              {
                "Sid": "AllowCurrentAccountObjects",
                "Effect": "Allow",
                "Principal": {
                  "AWS": $accountRoot
                },
                "Action": [
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:DeleteObject",
                  "s3:GetObjectVersion"
                ],
                "Resource": $bucketObjects
              }
            ]
          }' > /tmp/bucket-policy.json
    fi

    if [ "${SKIP_POLICY:-false}" != "true" ]; then
        echo ""
        echo "Generated bucket policy:"
        cat /tmp/bucket-policy.json
        echo ""

        # Validate JSON before applying
        if ! jq empty /tmp/bucket-policy.json 2>/dev/null; then
            echo "❌ ERROR: Generated policy is not valid JSON"
            cat /tmp/bucket-policy.json
            rm -f /tmp/bucket-policy.json
            exit 1
        fi

        echo "Applying bucket policy..."
        aws s3api put-bucket-policy \
            --bucket "$BUCKET_NAME" \
            --policy file:///tmp/bucket-policy.json \
            --region "$REGION"

        rm -f /tmp/bucket-policy.json
        echo "✅ Security settings and bucket policy applied"
    else
        rm -f /tmp/bucket-policy.json
        echo "✅ Security settings applied (bucket policy skipped for Organization account)"
    fi
}

# Create S3 Bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "✅ Bucket $BUCKET_NAME already exists."
    apply_bucket_security
else
    echo "Creating bucket $BUCKET_NAME..."
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" --region "$REGION"
    fi
    echo "✅ Bucket created successfully"
    apply_bucket_security
fi

echo ""
echo "✅ Bootstrap complete."
echo "   State bucket: $BUCKET_NAME"
echo "   Locking: lockfile (stored in S3)"
