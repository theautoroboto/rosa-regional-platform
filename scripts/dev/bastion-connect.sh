#!/bin/bash

set -euo pipefail

# Usage information
usage() {
  echo "Usage: $0 [OPTIONS] [regional|management]"
  echo ""
  echo "Start (if needed) and connect to a bastion ECS task"
  echo ""
  echo "Options:"
  echo "  -l, --list      List all bastion tasks"
  echo "  -c, --cleanup   Clean up stopped bastion tasks"
  echo "  -r, --reconnect Reconnect to existing task if available (default behavior)"
  echo "  -n, --new       Force create a new task instead of reusing existing"
  echo "  -h, --help      Show this help message"
  echo ""
  echo "Arguments:"
  echo "  regional    - Use regional cluster bastion (default)"
  echo "  management  - Use management cluster bastion"
  echo ""
  echo "Examples:"
  echo "  $0                    # Connect to regional cluster (reuses existing task)"
  echo "  $0 management         # Connect to management cluster"
  echo "  $0 -l regional        # List all regional cluster tasks"
  echo "  $0 -c                 # Clean up regional cluster tasks"
  echo "  $0 -n management      # Force new management cluster task"
  exit 1
}

# Parse options
ACTION="connect"
CLUSTER_TYPE=""
FORCE_NEW=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -l|--list)
      ACTION="list"
      shift
      ;;
    -c|--cleanup)
      ACTION="cleanup"
      shift
      ;;
    -r|--reconnect)
      ACTION="connect"
      FORCE_NEW=false
      shift
      ;;
    -n|--new)
      ACTION="connect"
      FORCE_NEW=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    regional|management)
      CLUSTER_TYPE="$1"
      shift
      ;;
    *)
      echo "Error: Unknown option or argument '$1'"
      echo ""
      usage
      ;;
  esac
done

# Default to regional if no argument provided
CLUSTER_TYPE=${CLUSTER_TYPE:-regional}

# Validate cluster type
case $CLUSTER_TYPE in
  regional|management)
    CONFIG_DIR="terraform/config/${CLUSTER_TYPE}-cluster"
    TASK_FILE="bastion_task_${CLUSTER_TYPE}.json"
    ;;
  *)
    echo "Error: Invalid cluster type '$CLUSTER_TYPE'"
    echo ""
    usage
    ;;
esac

CURRENT_DIR=$(pwd)

# Verify terraform config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Terraform config directory '$CONFIG_DIR' not found"
  exit 1
fi

# Get terraform outputs
cd $CONFIG_DIR
CLUSTER=$(terraform output -raw bastion_ecs_cluster_name 2>/dev/null || echo "")

if [ -z "$CLUSTER" ]; then
  echo "Error: Could not get bastion ECS cluster name from terraform output"
  exit 1
fi

cd $CURRENT_DIR

# Function to list all bastion tasks
list_tasks() {
  echo "==> Listing bastion tasks for $CLUSTER_TYPE cluster..."
  echo ""

  # Get all tasks (running and stopped)
  RUNNING_TASKS=$(aws ecs list-tasks --cluster $CLUSTER --desired-status RUNNING --query 'taskArns[]' --output text)
  STOPPED_TASKS=$(aws ecs list-tasks --cluster $CLUSTER --desired-status STOPPED --query 'taskArns[]' --output text)

  if [ -z "$RUNNING_TASKS" ] && [ -z "$STOPPED_TASKS" ]; then
    echo "No bastion tasks found"
    return
  fi

  # Display running tasks
  if [ -n "$RUNNING_TASKS" ]; then
    echo "Running tasks:"
    for task_arn in $RUNNING_TASKS; do
      TASK_ID=$(echo $task_arn | awk -F'/' '{print $NF}')
      TASK_INFO=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ID --query 'tasks[0]' --output json)
      STARTED_AT=$(echo $TASK_INFO | jq -r '.startedAt // "N/A"')
      RUNTIME_ID=$(echo $TASK_INFO | jq -r '.containers[0].runtimeId // "N/A"')
      CPU=$(echo $TASK_INFO | jq -r '.cpu // "N/A"')
      MEMORY=$(echo $TASK_INFO | jq -r '.memory // "N/A"')
      echo "  - Task ID: $TASK_ID"
      echo "    Started: $STARTED_AT"
      echo "    Runtime ID: $RUNTIME_ID"
      echo "    CPU/Memory: $CPU / $MEMORY"
      echo ""
    done
  fi

  # Display stopped tasks
  if [ -n "$STOPPED_TASKS" ]; then
    echo "Stopped tasks:"
    for task_arn in $STOPPED_TASKS; do
      TASK_ID=$(echo $task_arn | awk -F'/' '{print $NF}')
      TASK_INFO=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ID --query 'tasks[0]' --output json)
      STOPPED_AT=$(echo $TASK_INFO | jq -r '.stoppedAt // "N/A"')
      STOPPED_REASON=$(echo $TASK_INFO | jq -r '.stoppedReason // "N/A"')
      echo "  - Task ID: $TASK_ID"
      echo "    Stopped: $STOPPED_AT"
      echo "    Reason: $STOPPED_REASON"
      echo ""
    done
  fi
}

# Function to cleanup stopped tasks
cleanup_tasks() {
  echo "==> Cleaning up bastion tasks for $CLUSTER_TYPE cluster..."
  echo ""

  # Get running tasks
  RUNNING_TASKS=$(aws ecs list-tasks --cluster $CLUSTER --desired-status RUNNING --query 'taskArns[]' --output text)

  if [ -z "$RUNNING_TASKS" ]; then
    echo "No running tasks to clean up"

    # Clean up local task file if it exists
    if [ -f "$CURRENT_DIR/$TASK_FILE" ]; then
      rm "$CURRENT_DIR/$TASK_FILE"
      echo "Removed local task file: $TASK_FILE"
    fi
    return
  fi

  echo "Found running tasks:"
  for task_arn in $RUNNING_TASKS; do
    TASK_ID=$(echo $task_arn | awk -F'/' '{print $NF}')
    TASK_INFO=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ID --query 'tasks[0]' --output json)
    STARTED_AT=$(echo $TASK_INFO | jq -r '.startedAt // "N/A"')
    echo "  - Task ID: $TASK_ID (started: $STARTED_AT)"
  done
  echo ""

  read -p "Do you want to stop all running tasks? (y/N): " -n 1 -r
  echo ""

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    for task_arn in $RUNNING_TASKS; do
      TASK_ID=$(echo $task_arn | awk -F'/' '{print $NF}')
      echo "Stopping task $TASK_ID..."
      aws ecs stop-task --cluster $CLUSTER --task $TASK_ID --no-cli-pager > /dev/null
    done
    echo "All tasks stopped"

    # Clean up local task files
    if [ -f "$CURRENT_DIR/$TASK_FILE" ]; then
      rm "$CURRENT_DIR/$TASK_FILE"
      echo "Removed local task file: $TASK_FILE"
    fi
  else
    echo "Cleanup cancelled"
  fi
}

# Handle list and cleanup actions
if [ "$ACTION" == "list" ]; then
  list_tasks
  exit 0
elif [ "$ACTION" == "cleanup" ]; then
  cleanup_tasks
  exit 0
fi

# For connect action, check if there's an existing running task
echo "==> Starting/verifying bastion task for $CLUSTER_TYPE cluster..."

# Check for existing running tasks
EXISTING_TASK=$(aws ecs list-tasks --cluster $CLUSTER --desired-status RUNNING --query 'taskArns[0]' --output text)

if [ -n "$EXISTING_TASK" ] && [ "$EXISTING_TASK" != "None" ] && [ "$FORCE_NEW" = false ]; then
  TASK_ID=$(echo $EXISTING_TASK | awk -F'/' '{print $NF}')
  echo "==> Found existing running task: $TASK_ID"
  echo "==> Reconnecting to existing task instead of creating a new one..."
  echo "    (Use --new flag to force creation of a new task)"
else
  if [ "$FORCE_NEW" = true ]; then
    echo "==> --new flag specified, starting a new task..."
  else
    echo "==> No existing task found, starting a new one..."
  fi

  # Get terraform outputs and start new task
  cd $CONFIG_DIR

  # Start the bastion task (idempotent - will reuse existing task if already running)
  eval "$(terraform output -raw bastion_run_task_command)"

  # Get the task ID from the output, or list running tasks:
  TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')

  cd $CURRENT_DIR
fi

# Wait for task to be running (tool installation takes ~60 seconds)
echo "==> Waiting for task to be running..."
aws ecs wait tasks-running --cluster $CLUSTER --tasks $TASK_ID

# Get the runtimeId for port forwarding (save for later)
RUNTIME_ID=$(aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ID \
  --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
  --output text)

if [[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "None" ]]; then
  echo "Error: runtime_id not found for task '$TASK_ID' in cluster '$CLUSTER'"
  exit 1
fi

# Save task info for later use
echo "{\"cluster_type\":\"$CLUSTER_TYPE\",\"cluster\":\"$CLUSTER\",\"task_id\":\"$TASK_ID\",\"runtime_id\":\"$RUNTIME_ID\"}" > $CURRENT_DIR/$TASK_FILE

echo ""
echo "==> Bastion task ready for $CLUSTER_TYPE cluster"
echo "    Cluster: $CLUSTER"
echo "    Task ID: $TASK_ID"
echo "    Runtime ID: $RUNTIME_ID"
echo ""
echo "==> Connecting to bastion..."
echo ""

# Connect via ECS Exec
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ID \
  --container bastion \
  --interactive \
  --command '/bin/bash'
