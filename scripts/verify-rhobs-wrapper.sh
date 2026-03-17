#!/usr/bin/env bash
#
# verify-rhobs-wrapper.sh - RHOBS verification using ECS Fargate
#
# Runs RHOBS verification as an ECS Fargate task inside the VPC
# to access the private EKS cluster API.
#
# Usage: verify-rhobs-wrapper.sh
#
# Expected environment variables:
#   ENVIRONMENT - Environment name
#   TARGET_REGION - AWS region
#   REGIONAL_ID - Regional cluster identifier

set -euo pipefail

CLUSTER_TYPE="regional-cluster"
TERRAFORM_DIR="terraform/config/${CLUSTER_TYPE}"

echo "=========================================="
echo "RHOBS Verification Wrapper"
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

if [[ -z "${REGIONAL_ID:-}" ]]; then
    echo "❌ ERROR: REGIONAL_ID variable not set"
    exit 1
fi

export AWS_REGION="${TARGET_REGION}"
export REGION_DEPLOYMENT="${TARGET_REGION}"

echo "Verification environment configuration:"
echo "  ENVIRONMENT: ${ENVIRONMENT}"
echo "  REGION_DEPLOYMENT: ${REGION_DEPLOYMENT}"
echo "  AWS_REGION: ${AWS_REGION}"
echo "  REGIONAL_ID: ${REGIONAL_ID}"
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

echo "Running RHOBS verification on cluster: $CLUSTER_NAME"
echo ""

# Verification command to run in the ECS task
VERIFICATION_CMD=$(cat <<'VERIFY_EOF'
set -euo pipefail

echo "=========================================="
echo "RHOBS Verification"
echo "=========================================="

# Configure kubectl
aws eks update-kubeconfig --name $CLUSTER_NAME

# Verification parameters
MAX_RETRIES=30
RETRY_INTERVAL=10
METRICS_FOUND=false
LOGS_FOUND=false

echo ""
echo "Step 1: Verify RHOBS Infrastructure"
echo "========================================"

# Check namespace
if ! kubectl get namespace observability > /dev/null 2>&1; then
    echo "✗ observability namespace not found"
    exit 1
fi
echo "✓ observability namespace exists"

# Check required components
REQUIRED_COMPONENTS=(thanos-receive thanos-query loki-distributor loki-querier grafana)

for component in "${REQUIRED_COMPONENTS[@]}"; do
    if kubectl get pods -n observability -l "app.kubernetes.io/component=${component}" --no-headers 2>/dev/null | grep -q Running; then
        echo "✓ ${component} pods are running"
    else
        echo "✗ ${component} pods not found or not running"
        kubectl get pods -n observability -l "app.kubernetes.io/component=${component}" 2>/dev/null || true
        exit 1
    fi
done

echo ""
echo "Step 2: Wait for Metrics Flow"
echo "========================================"

# Port-forward to Thanos Query
echo "Setting up port-forward to Thanos Query..."
kubectl port-forward -n observability svc/thanos-query 9090:9090 > /dev/null 2>&1 &
PF_PID=$!
sleep 5

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up port-forwards..."
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Querying Thanos for metrics from management clusters..."
echo "This may take a few minutes for metrics to start flowing..."
echo ""

for i in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $i/$MAX_RETRIES: Querying for 'up' metric..."

    RESPONSE=$(curl -s "http://localhost:9090/api/v1/query?query=up{cluster_id=~\".+\"}" || echo "")

    if [ -n "$RESPONSE" ]; then
        RESULT_TYPE=$(echo "$RESPONSE" | jq -r '.data.resultType // "none"' 2>/dev/null || echo "none")
        RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [ "$RESULT_TYPE" = "vector" ] && [ "$RESULT_COUNT" -gt 0 ]; then
            echo "  ✓ Found metrics from management clusters!"
            echo ""
            echo "Metric details:"
            echo "$RESPONSE" | jq -r '.data.result[] | "  - cluster_id: \(.metric.cluster_id // "unknown"), job: \(.metric.job // "unknown"), value: \(.value[1])"' 2>/dev/null | head -10
            METRICS_FOUND=true
            break
        fi
    fi

    if [ $i -lt $MAX_RETRIES ]; then
        sleep $RETRY_INTERVAL
    fi
done

if [ "$METRICS_FOUND" = false ]; then
    echo "✗ FAILED: No metrics received from management clusters"
    exit 1
fi

echo ""
echo "Step 3: Wait for Logs Flow"
echo "========================================"

# Kill existing port-forward and create new one for Loki
kill $PF_PID 2>/dev/null || true
sleep 2

echo "Setting up port-forward to Loki Query Frontend..."
kubectl port-forward -n observability svc/loki-query-frontend 3100:3100 > /dev/null 2>&1 &
PF_PID=$!
sleep 5

echo "Querying Loki for logs from management clusters..."
echo ""

# Calculate time range (last 5 minutes)
END_TIME=$(date +%s)000000000
START_TIME=$((END_TIME - 300000000000))

for i in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $i/$MAX_RETRIES: Querying for logs with cluster label..."

    QUERY='{cluster=~".+"}'
    ENCODED_QUERY=$(printf '%s' "$QUERY" | jq -sRr @uri)

    RESPONSE=$(curl -s "http://localhost:3100/loki/api/v1/query_range?query=${ENCODED_QUERY}&start=${START_TIME}&end=${END_TIME}&limit=100" || echo "")

    if [ -n "$RESPONSE" ]; then
        RESULT_TYPE=$(echo "$RESPONSE" | jq -r '.data.resultType // "none"' 2>/dev/null || echo "none")
        RESULT_COUNT=$(echo "$RESPONSE" | jq -r '.data.result | length' 2>/dev/null || echo "0")

        if [ "$RESULT_TYPE" = "streams" ] && [ "$RESULT_COUNT" -gt 0 ]; then
            echo "  ✓ Found logs from management clusters!"
            echo ""
            echo "Log stream details:"
            echo "$RESPONSE" | jq -r '.data.result[] | "  - cluster: \(.stream.cluster // "unknown"), namespace: \(.stream.namespace // "unknown")"' 2>/dev/null | head -10
            LOGS_FOUND=true
            break
        fi
    fi

    if [ $i -lt $MAX_RETRIES ]; then
        sleep $RETRY_INTERVAL
    fi
done

if [ "$LOGS_FOUND" = false ]; then
    echo "✗ FAILED: No logs received from management clusters"
    exit 1
fi

echo ""
echo "========================================"
echo "RHOBS Verification Summary"
echo "========================================"
echo "✓ Metrics flowing from management clusters"
echo "✓ Logs flowing from management clusters"
echo "✓ RHOBS stack is operational"
echo ""
echo "RHOBS verification completed successfully!"
VERIFY_EOF
)

# Base64 encode the verification command to avoid JSON escaping issues
VERIFICATION_CMD_B64=$(echo "$VERIFICATION_CMD" | base64 -w 0)

# Run ECS task with verification command
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
      \"command\": [\"/bin/bash\", \"-c\", \"echo \$VERIFICATION_SCRIPT | base64 -d | /bin/bash\"],
      \"environment\": [
        {\"name\": \"CLUSTER_NAME\", \"value\": \"$CLUSTER_NAME\"},
        {\"name\": \"AWS_REGION\", \"value\": \"$AWS_REGION\"},
        {\"name\": \"VERIFICATION_SCRIPT\", \"value\": \"$VERIFICATION_CMD_B64\"}
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

# Track last seen event timestamp
LAST_EVENT_TIME=0
TASK_START_TIME=$(date +%s)

# Monitor task status
while true; do
    # Fetch recent log events
    LOG_START_TIME=$(($(date +%s) * 1000 - 30000))
    if [[ $LAST_EVENT_TIME -gt 0 ]]; then
        LOG_START_TIME=$LAST_EVENT_TIME
    fi

    LOG_EVENTS=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --start-time "$LOG_START_TIME" \
        --output json 2>/dev/null || echo '{"events":[]}')

    # Print new log events
    NEW_MESSAGES=$(echo "$LOG_EVENTS" | jq -r '.events[] | .message' 2>/dev/null || true)
    if [ -n "$NEW_MESSAGES" ]; then
        echo "$NEW_MESSAGES"
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
        sleep 5

        # Fetch remaining logs with extended time window
        FINAL_LOG_START=$(($(date +%s) * 1000 - 60000))
        if [[ $LAST_EVENT_TIME -gt 0 ]]; then
            FINAL_LOG_START=$LAST_EVENT_TIME
        fi

        FINAL_LOGS=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --start-time "$FINAL_LOG_START" \
            --output json 2>/dev/null || echo '{"events":[]}')

        FINAL_MESSAGES=$(echo "$FINAL_LOGS" | jq -r '.events[] | .message' 2>/dev/null || true)
        if [ -n "$FINAL_MESSAGES" ]; then
            echo "$FINAL_MESSAGES"
        fi

        echo ""
        echo "Getting task details..."

        # Get full task details
        TASK_DETAILS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_ARN" --tasks "$TASK_ARN")

        # Extract exit code
        EXIT_CODE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].exitCode // "null"')
        STOP_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].stoppedReason // "unknown"')
        CONTAINER_REASON=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].containers[0].reason // "unknown"')

        if [[ "$EXIT_CODE" == "0" ]]; then
            echo "✅ RHOBS verification completed successfully!"
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
