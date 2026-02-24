#!/bin/bash
#
# Nightly E2E Test Runner
# This script is designed to be called from external CI/CD systems
# for nightly regression testing.

set -euo pipefail

export AWS_PAGER=""

# Validate required environment variables
if [[ -z "${RC_ACCOUNT_ID:-}" || -z "${MC_ACCOUNT_ID:-}" ]]; then
    echo "❌ ERROR: Required environment variables not set"
    echo "   RC_ACCOUNT_ID: ${RC_ACCOUNT_ID:-not set}"
    echo "   MC_ACCOUNT_ID: ${MC_ACCOUNT_ID:-not set}"
    exit 1
fi

# Set defaults for optional variables
export TEST_REGION="${TEST_REGION:-us-east-1}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-regional-platform}"
export GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

echo "=========================================="
echo "Nightly E2E Test"
echo "=========================================="
echo "RC Account: ${RC_ACCOUNT_ID}"
echo "MC Account: ${MC_ACCOUNT_ID}"
echo "Region: ${TEST_REGION}"
echo "Repository: ${GITHUB_REPOSITORY}"
echo "Branch: ${GITHUB_BRANCH}"
echo ""

# Call main e2e test script
exec "$(dirname "${BASH_SOURCE[0]}")/e2e-test.sh"
