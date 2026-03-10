#!/bin/bash
set -euo pipefail

# =============================================================================
# Ephemeral resource janitor — purge leaked AWS resources from ephemeral CI accounts.
# =============================================================================
# Fallback cleanup for when terraform destroy does not fully tear down
# resources after ephemeral tests. 
#
# Credentials are mounted at /var/run/rosa-credentials/ by ci-operator.
# =============================================================================

DRY_RUN=false

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="/var/run/rosa-credentials"
PURGE_SCRIPT="${SCRIPT_DIR}/janitor/purge-aws-account.sh"

PURGE_ARGS=()
if [ "${DRY_RUN}" = false ]; then
  PURGE_ARGS+=(--no-dry-run)
fi


## ===============================
## Purge regional ephemeral account
## ===============================
echo "==== Purging Regional Account ===="

REGIONAL_CREDS=$(mktemp)
cat > "${REGIONAL_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/regional_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/regional_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
"${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"

## ===============================
## Purge management ephemeral account
## ===============================
echo ""
echo "==== Purging Management Account ===="

MGMT_CREDS=$(mktemp)
cat > "${MGMT_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/management_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/management_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
"${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"


## ===============================
## Purge central ephemeral account
## ===============================
echo "==== Purging Central Account ===="

# Use central IAM user creds to assume the central role
CENTRAL_BASE_CREDS=$(mktemp)
cat > "${CENTRAL_BASE_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/central_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/central_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${CENTRAL_BASE_CREDS}"
ROLE_ARN=$(cat "${CREDS_DIR}/central_assume_role_arn")

echo "Assuming central account ci role"
read -r key secret token <<< "$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "JanitorCentralPurge" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)"

CENTRAL_CREDS=$(mktemp)
cat > "${CENTRAL_CREDS}" <<EOF
[default]
aws_access_key_id = ${key}
aws_secret_access_key = ${secret}
aws_session_token = ${token}
EOF

export AWS_SHARED_CREDENTIALS_FILE="${CENTRAL_CREDS}"
"${PURGE_SCRIPT}" "${PURGE_ARGS[@]+"${PURGE_ARGS[@]}"}"

echo ""
echo "==== Janitor complete ===="
