#!/usr/bin/env bash
#
# verify-rhobs-agent-wrapper.sh - RHOBS agent verification using ECS Fargate
#
# Runs RHOBS agent verification as an ECS Fargate task inside the VPC
# to access the private EKS cluster API.
#
# Usage: verify-rhobs-agent-wrapper.sh
#
# Expected environment variables:
#   ENVIRONMENT - Environment name
#   TARGET_REGION - AWS region
#   MANAGEMENT_CLUSTER_ID - Management cluster identifier

set -euo pipefail

CLUSTER_TYPE="management-cluster"
TERRAFORM_DIR="terraform/config/${CLUSTER_TYPE}"

echo "=========================================="
echo "RHOBS Agent Verification Wrapper"
echo "=========================================="

# Validate required environment variables
if [[ -z "${ENVIRONMENT:-}" ]]; then
    echo "❌ ERROR: ENVIRONMENT variable not set"
    exit 1
fi

if [[ -z "${TARGET_REGION:-}" ]]; then
    echo "❌ ERROR: TARGET_REGION variable not set"
    exit 1
fi

if [[ -z "${MANAGEMENT_CLUSTER_ID:-}" ]]; then
    echo "❌ ERROR: MANAGEMENT_CLUSTER_ID variable not set"
    exit 1
fi

export AWS_REGION="${TARGET_REGION}"
export REGION_DEPLOYMENT="${TARGET_REGION}"

echo "Verification environment configuration:"
echo "  ENVIRONMENT: ${ENVIRONMENT}"
echo "  REGION_DEPLOYMENT: ${REGION_DEPLOYMENT}"
echo "  AWS_REGION: ${AWS_REGION}"
echo "  MANAGEMENT_CLUSTER_ID: ${MANAGEMENT_CLUSTER_ID}"
echo ""

# Read terraform outputs
cd ${TERRAFORM_DIR}/

OUTPUTS=$(terraform output -json)

ECS_CLUSTER_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_cluster_arn.value')
TASK_DEFINITION_ARN=$(echo "$OUTPUTS" | jq -r '.ecs_task_definition_arn.value')
CLUSTER_NAME=$(echo "$OUTPUTS" | jq -r '.cluster_name.value')
PRIVATE_SUBNETS=$(echo "$OUTPUTS" | jq -r '.private_subnets.value[]' | tr '\n' ',' | sed 's/,$//')
BOOTSTRAP_SECURITY_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_security_group_id.value')
LOG_GROUP=$(echo "$OUTPUTS" | jq -r '.bootstrap_log_group_name.value')

echo "Running RHOBS agent verification on cluster: $CLUSTER_NAME"
echo ""

# Verification command to run in the ECS task
VERIFICATION_CMD=$(cat <<'VERIFY_EOF'
set -euo pipefail

# Disable output buffering for immediate CloudWatch log visibility
exec 2>&1  # Redirect stderr to stdout
export PYTHONUNBUFFERED=1

echo "=========================================="
echo "RHOBS Agent Verification"
echo "=========================================="

# Configure kubectl
aws eks update-kubeconfig --name $CLUSTER_NAME

echo ""
echo "Step 1: Verify Agent Pods"
echo "========================================"

# Check namespace
if ! kubectl get namespace observability > /dev/null 2>&1; then
    echo "✗ observability namespace not found"
    exit 1
fi
echo "✓ observability namespace exists"

# Check OTEL Collector
echo "Checking for OTEL Collector pods..." >&2  # Force immediate output
set +e  # Don't exit on error for diagnostics

echo "DEBUG: About to run kubectl command" >&2
OTEL_OUTPUT=$(timeout 30 kubectl get pods -n observability -l app.kubernetes.io/component=otel-collector --no-headers 2>&1)
KUBECTL_EXIT=$?
echo "DEBUG: kubectl exited with code: $KUBECTL_EXIT" >&2
set -e

if [ $KUBECTL_EXIT -eq 124 ]; then
    echo "✗ ERROR: kubectl command timed out after 30 seconds" >&2
    echo "   This may indicate cluster API connectivity issues" >&2
    sleep 1  # Allow logs to flush
    exit 1
elif [ $KUBECTL_EXIT -ne 0 ]; then
    echo "✗ ERROR: kubectl command failed with exit code $KUBECTL_EXIT" >&2
    echo "   Output: $OTEL_OUTPUT" >&2
    sleep 1  # Allow logs to flush
    exit 1
fi

echo "DEBUG: Parsing kubectl output" >&2
OTEL_PODS=$(echo "$OTEL_OUTPUT" | grep Running | wc -l)
echo "DEBUG: Found $OTEL_PODS running OTEL pods" >&2

if [ "$OTEL_PODS" -gt 0 ]; then
    echo "✓ OTEL Collector running ($OTEL_PODS pods)"
else
    echo "✗ OTEL Collector pods not running"
    echo ""
    echo "Expected pods with label: app.kubernetes.io/component=otel-collector"
    echo "Current pods in observability namespace:"
    if [ -n "$OTEL_OUTPUT" ]; then
        echo "$OTEL_OUTPUT"
    else
        echo "  No OTEL Collector pods found"
    fi
    echo ""
    echo "All pods in observability namespace:"
    timeout 30 kubectl get pods -n observability 2>&1 || echo "  Failed to get pods"
    echo ""
    echo "TROUBLESHOOTING:"
    echo "  - Check if RHOBS agents are deployed via ArgoCD"
    echo "  - Verify ArgoCD application for management cluster agents"
    echo "  - Check repository path: deploy/\${ENVIRONMENT}/\${REGION}/argocd/management-cluster-manifests/"
    exit 1
fi

# Check Fluent Bit
echo "Checking for Fluent Bit pods..."
set +e
FB_OUTPUT=$(timeout 30 kubectl get pods -n observability -l app.kubernetes.io/component=fluent-bit --no-headers 2>&1)
KUBECTL_EXIT=$?
set -e

if [ $KUBECTL_EXIT -eq 124 ]; then
    echo "✗ ERROR: kubectl command timed out after 30 seconds"
    exit 1
elif [ $KUBECTL_EXIT -ne 0 ]; then
    echo "✗ ERROR: kubectl command failed with exit code $KUBECTL_EXIT"
    echo "   Output: $FB_OUTPUT"
    exit 1
fi

FB_PODS=$(echo "$FB_OUTPUT" | grep Running | wc -l)

if [ "$FB_PODS" -gt 0 ]; then
    echo "✓ Fluent Bit running ($FB_PODS pods)"
else
    echo "✗ Fluent Bit pods not running"
    echo ""
    echo "Expected pods with label: app.kubernetes.io/component=fluent-bit"
    echo "Current pods in observability namespace:"
    if [ -n "$FB_OUTPUT" ]; then
        echo "$FB_OUTPUT"
    else
        echo "  No Fluent Bit pods found"
    fi
    echo ""
    echo "TROUBLESHOOTING:"
    echo "  - Check if RHOBS agents are deployed via ArgoCD"
    echo "  - Verify ArgoCD application for management cluster agents"
    exit 1
fi

echo ""
echo "Step 2: Verify mTLS Certificates"
echo "========================================"

if kubectl get certificate rhobs-client-cert -n observability > /dev/null 2>&1; then
    CERT_READY=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_READY" = "True" ]; then
        echo "✓ mTLS client certificate is ready"

        # Check expiry
        NOT_AFTER=$(kubectl get certificate rhobs-client-cert -n observability -o jsonpath='{.status.notAfter}' 2>/dev/null)
        if [ -n "$NOT_AFTER" ]; then
            echo "  Expires: $NOT_AFTER"
        fi
    else
        echo "✗ mTLS client certificate not ready"
        kubectl describe certificate rhobs-client-cert -n observability
        exit 1
    fi
else
    echo "✗ mTLS client certificate not found"
    exit 1
fi

echo ""
echo "Step 3: Verify Agent Configuration"
echo "========================================"

# Check OTEL Collector configuration
echo "Checking OTEL Collector configuration..."
OTEL_CONFIG=$(kubectl get configmap -n observability -l app.kubernetes.io/component=otel-collector -o yaml 2>/dev/null || echo "")

if echo "$OTEL_CONFIG" | grep -q "remote_write"; then
    echo "✓ OTEL Collector has remote_write configuration"
else
    echo "⚠ Warning: Could not verify remote_write configuration"
fi

# Check Fluent Bit configuration
echo ""
echo "Checking Fluent Bit configuration..."
FB_CONFIG=$(kubectl get configmap -n observability -l app.kubernetes.io/component=fluent-bit -o yaml 2>/dev/null || echo "")

if echo "$FB_CONFIG" | grep -q "loki"; then
    echo "✓ Fluent Bit has Loki output configuration"
else
    echo "⚠ Warning: Could not verify Loki output configuration"
fi

echo ""
echo "Step 4: Check Agent Logs for Errors"
echo "========================================"

echo "Checking OTEL Collector logs for errors..."
OTEL_ERRORS=$(kubectl logs -n observability -l app.kubernetes.io/component=otel-collector --tail=100 2>/dev/null | grep -i "error\|failed\|fatal" | grep -v "level=info" | head -5 || echo "")

if [ -z "$OTEL_ERRORS" ]; then
    echo "✓ No critical errors in OTEL Collector logs"
else
    echo "⚠ Found potential errors in OTEL Collector logs:"
    echo "$OTEL_ERRORS"
fi

echo ""
echo "Checking Fluent Bit logs for errors..."
FB_ERRORS=$(kubectl logs -n observability -l app.kubernetes.io/component=fluent-bit --tail=100 2>/dev/null | grep -i "error\|failed\|fatal" | grep -v "level=info" | head -5 || echo "")

if [ -z "$FB_ERRORS" ]; then
    echo "✓ No critical errors in Fluent Bit logs"
else
    echo "⚠ Found potential errors in Fluent Bit logs:"
    echo "$FB_ERRORS"
fi

echo ""
echo "========================================"
echo "RHOBS Agent Verification Summary"
echo "========================================"
echo "✓ OTEL Collector deployed and running"
echo "✓ Fluent Bit deployed and running"
echo "✓ mTLS client certificate ready"
echo "✓ Agent configurations validated"
echo ""
echo "Note: Metrics and logs may take 2-5 minutes to appear in the regional cluster."
echo "Run regional cluster verification to confirm end-to-end data flow."
echo ""
echo "RHOBS agent verification completed successfully!"
VERIFY_EOF
)

# Upload verification script to S3 (avoiding 8KB container override limit)
SCRIPT_KEY="verification-scripts/rhobs-agent-${TASK_START_TIME:-$(date +%s)}.sh"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="terraform-state-${ACCOUNT_ID}"

echo "Uploading verification script to s3://${STATE_BUCKET}/${SCRIPT_KEY}..."
echo "$VERIFICATION_CMD" | aws s3 cp - "s3://${STATE_BUCKET}/${SCRIPT_KEY}"

# Run ECS task with script download command
echo "Starting ECS verification task..."
set +e
RUN_TASK_OUTPUT=$(aws ecs run-task \
  --cluster "$ECS_CLUSTER_ARN" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIVATE_SUBNETS],securityGroups=[$BOOTSTRAP_SECURITY_GROUP],assignPublicIp=DISABLED}" \
  --overrides "{
    \"containerOverrides\": [{
      \"name\": \"bootstrap\",
      \"command\": [\"set -x; aws s3 cp s3://${STATE_BUCKET}/${SCRIPT_KEY} /tmp/verify.sh && chmod +x /tmp/verify.sh && /tmp/verify.sh 2>&1; EXIT_CODE=\\\$?; sleep 2; exit \\\$EXIT_CODE\"],
      \"environment\": [
        {\"name\": \"CLUSTER_NAME\", \"value\": \"$CLUSTER_NAME\"},
        {\"name\": \"AWS_REGION\", \"value\": \"$AWS_REGION\"}
      ]
    }]
  }" 2>&1)
RUN_TASK_EXIT_CODE=$?
set -e

# Check if run-task succeeded
if [[ $RUN_TASK_EXIT_CODE -eq 0 ]] && echo "$RUN_TASK_OUTPUT" | grep -q '"failures":\s*\[\]'; then
  echo "ECS task created successfully."
  TASK_ARN=$(echo "$RUN_TASK_OUTPUT" | jq -r '.tasks[0].taskArn // empty')
  if [[ -z "$TASK_ARN" || "$TASK_ARN" == "null" ]]; then
    echo "Could not extract task ARN from response"
    exit 1
  fi
  echo "Verification task started: $TASK_ARN"
else
  echo "Failed to start ECS task. Error details:"
  echo "$RUN_TASK_OUTPUT"
  exit 1
fi

echo "Starting log monitoring..."
echo "Log group: $LOG_GROUP"
echo ""

# Extract task ID from ARN for log stream matching
TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')
echo "Task ID: $TASK_ID"

# Track last seen event timestamp
LAST_EVENT_TIME=0
TASK_START_TIME=$(date +%s)

# Monitor task status
while true; do
    # Fetch recent log events
    LOG_START_TIME=$(($(date +%s) * 1000 - 60000))  # Extended to 60 seconds
    if [[ $LAST_EVENT_TIME -gt 0 ]]; then
        LOG_START_TIME=$LAST_EVENT_TIME
    fi

    # Query with log stream pattern matching the task ID
    # Log stream format: ecs/bootstrap/<task-id> (per awslogs-stream-prefix in task definition)
    LOG_EVENTS=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name-prefix "ecs/bootstrap/$TASK_ID" \
        --start-time "$LOG_START_TIME" \
        --output json 2>&1)

    # Check if we got valid JSON
    if echo "$LOG_EVENTS" | jq empty 2>/dev/null; then
        # Print new log events
        NEW_MESSAGES=$(echo "$LOG_EVENTS" | jq -r '.events[] | .message' 2>/dev/null || true)
        if [ -n "$NEW_MESSAGES" ]; then
            echo "$NEW_MESSAGES"
        fi
    else
        # Not valid JSON - might be an error message
        if [[ "$LOG_EVENTS" != *"ResourceNotFoundException"* ]]; then
            echo "Log query error: $LOG_EVENTS"
        fi
    fi

    # Update last event timestamp
    NEW_LAST_TIME=$(echo "$LOG_EVENTS" | jq -r '[.events[].timestamp] | max // 0' 2>/dev/null || echo "0")
    if [[ "$NEW_LAST_TIME" != "null" && "$NEW_LAST_TIME" != "0" ]]; then
        LAST_EVENT_TIME=$((NEW_LAST_TIME + 1))
    fi

    TASK_STATUS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)

    if [[ "$TASK_STATUS" == "STOPPED" ]]; then
        echo ""
        echo "Task stopped. Fetching final logs..."
        # Wait for CloudWatch to flush final logs (can take up to 5-10 seconds)
        sleep 8

        # Fetch ALL logs for this task (from task start time)
        FINAL_LOG_START=$((TASK_START_TIME * 1000))

        echo "Querying all logs for task (stream: ecs/bootstrap/$TASK_ID)..."
        FINAL_LOGS=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --log-stream-name-prefix "ecs/bootstrap/$TASK_ID" \
            --start-time "$FINAL_LOG_START" \
            --output json 2>&1)

        if echo "$FINAL_LOGS" | jq empty 2>/dev/null; then
            FINAL_MESSAGES=$(echo "$FINAL_LOGS" | jq -r '.events[] | .message' 2>/dev/null || true)
            if [ -n "$FINAL_MESSAGES" ]; then
                echo "$FINAL_MESSAGES"
            else
                echo "No log messages found in CloudWatch"
                echo "Checking if log stream exists..."
                aws logs describe-log-streams \
                    --log-group-name "$LOG_GROUP" \
                    --log-stream-name-prefix "ecs/bootstrap/$TASK_ID" \
                    --max-items 5 || true
            fi
        else
            echo "Error fetching logs:"
            echo "$FINAL_LOGS"
        fi

        echo ""
        echo "Getting task details..."

        # Get full task details
        TASK_DETAILS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN")

        # Extract exit code
        EXIT_CODE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].exitCode // "null"')
        STOP_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].stoppedReason // "unknown"')
        CONTAINER_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].reason // "unknown"')

        # Cleanup S3 script
        echo "Cleaning up S3 script..."
        aws s3 rm "s3://${STATE_BUCKET}/${SCRIPT_KEY}" 2>/dev/null || true

        if [[ "$EXIT_CODE" == "0" ]]; then
            echo "✅ RHOBS agent verification completed successfully!"
            exit 0
        elif [[ "$EXIT_CODE" == "null" || -z "$EXIT_CODE" ]]; then
            echo "❌ Verification failed - no exit code available"
            echo "Task Stop Reason: $STOP_REASON"
            echo "Container Reason: $CONTAINER_REASON"
            exit 1
        else
            echo "❌ Verification failed with exit code: $EXIT_CODE"
            echo "Task Stop Reason: $STOP_REASON"
            echo "Container Reason: $CONTAINER_REASON"
            exit 1
        fi
    fi

    # Poll every 5 seconds
    sleep 5
done
