# Bastion

In ROSA Regionality Platform, the Regional Cluster and the Management Cluster are private. The only access to them will happen through ZOA processes.

This module creates an **ECS Fargate bastion task definition** that can be used to launch ephemeral bastion containers for accessing private EKS clusters. The bastion shares the ECS cluster created by the `ecs-bootstrap` module. This bastion should only be leveraged in the following scenarios:

- Emergency break-glass access to the Regional or Management Cluster (note that this is a temporary solution for break-glass that is not adequate since it has no auditing, etc.).
- Development purposes where a developer needs to access the Regional or Management Cluster for debugging purposes.

## Architecture

The bastion uses **ECS Fargate** with **ECS Exec** (built on SSM) for shell access. It creates a dedicated ECS cluster with ECS Exec enabled for session logging.

## Enabling the Bastion

The bastion is disabled by default. To enable it, set `enable_bastion = true` in your `terraform.tfvars`:

```hcl
# terraform.tfvars
enable_bastion = true
```

Then apply the configuration:

```bash
# From terraform/config/regional-cluster or terraform/config/management-cluster
terraform apply
```

## Requirements

Install the **Session Manager plugin** for AWS CLI: [documentation](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

## Pre-installed Tools

The bastion container includes a full SRE toolkit:

- **kubectl** - Kubernetes CLI
- **helm** - Kubernetes package manager
- **aws** - AWS CLI v2
- **k9s** - Terminal UI for Kubernetes
- **stern** - Multi-pod log tailing
- **oc** - OpenShift CLI
- **jq** / **yq** - JSON/YAML processors
- Standard utilities: git, vim, less, dig, etc.

Please extend the tooling as required. Also note that the tools are installed at container startup so they might still not be installed when you first connect, and only become available after a minute or so.

## Usage

After enabling the bastion and applying terraform, use the terraform outputs to interact with the bastion.

### 1. Start a bastion task

```bash
# Get terraform outputs
cd terraform/config/regional-cluster  # or management-cluster

# Start the bastion task
eval "$(terraform output -raw bastion_run_task_command)"

# Get the task ID from the output, or list running tasks:
CLUSTER=$(terraform output -raw bastion_ecs_cluster_name)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')

# Wait for task to be running (tool installation takes ~60 seconds)
aws ecs wait tasks-running --cluster $CLUSTER --tasks $TASK_ID

# Get the runtimeId for port forwarding (save for later)
RUNTIME_ID=$(aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ID \
  --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
  --output text)

# Save task info for later use
echo "{\"cluster\":\"$CLUSTER\",\"task_id\":\"$TASK_ID\",\"runtime_id\":\"$RUNTIME_ID\"}" > bastion_task.json
```

### 2. Connect to the bastion

```bash
# Load task info
CLUSTER=$(jq -r '.cluster' bastion_task.json)
TASK_ID=$(jq -r '.task_id' bastion_task.json)

# Connect via ECS Exec
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ID \
  --container bastion \
  --interactive \
  --command '/bin/bash'
```

The bastion is already connected to the EKS cluster:

```bash
bash-5.2$ kubectl get namespaces
NAME              STATUS   AGE
argocd            Active   76m
default           Active   84m
kube-node-lease   Active   84m
kube-public       Active   84m
kube-system       Active   84m
```

NOTE: The container is accessible before the tools are fully installed. If it says `kubectl: command not found` wait a minute and try again.

### 3. Port-forward to access Kubernetes services (e.g., ArgoCD UI)

This requires two terminals and uses SSM port forwarding with the container's `runtimeId`. Here follows a worked example to access the ArgoCD UI.

**Terminal 1** - Start kubectl port-forward on the bastion:

```bash
# Load task info
CLUSTER=$(jq -r '.cluster' bastion_task.json)
TASK_ID=$(jq -r '.task_id' bastion_task.json)

aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ID \
  --container bastion \
  --interactive \
  --command '/bin/bash'

# On the bastion:
# get the password for ArgoCD admin user
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
# start port-forward
kubectl port-forward svc/argocd-server 8443:443 -n argocd --address 0.0.0.0
```

**Terminal 2** - SSM port forward from your laptop to the bastion:

```bash
# Load task info
CLUSTER=$(jq -r '.cluster' bastion_task.json)
TASK_ID=$(jq -r '.task_id' bastion_task.json)
RUNTIME_ID=$(jq -r '.runtime_id' bastion_task.json)

aws ssm start-session \
  --target "ecs:${CLUSTER}_${TASK_ID}_${RUNTIME_ID}" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
```

**Access in browser:** `https://localhost:8443`

Get the ArgoCD admin password (on the bastion):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 4. Stop when done

Stop the task when you're finished to avoid ongoing costs.

> **Cost note**: Fargate tasks are billed per-second while running (~$0.02/hour for this config).

```bash
# Load task info
CLUSTER=$(jq -r '.cluster' bastion_task.json)
TASK_ID=$(jq -r '.task_id' bastion_task.json)

aws ecs stop-task --cluster $CLUSTER --task $TASK_ID
```

## Troubleshooting

### Logs

View container logs to debug startup issues or check tool installation progress:

```bash
# Tail logs (follow mode)
aws logs tail $(terraform output -raw bastion_log_group_name) --follow --since 5m

# Wait for bastion to be ready
aws logs tail $(terraform output -raw bastion_log_group_name) --follow --since 1m | grep -m1 "Bastion ready"
```

### Bastion not available

If bastion outputs are `null`, ensure you have `enable_bastion = true` in your tfvars and have run `terraform apply`.
