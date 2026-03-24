#!/usr/bin/env bash
#
# Ephemeral environment CLI for ROSA Regional Platform.
#
# Manages ephemeral developer environments in shared dev AWS accounts.
# Wraps the ephemeral provider (ci/ephemeral-provider/) with credential
# fetching, container execution, and local state tracking.
#
# Typically invoked via Makefile targets (make ephemeral-provision, etc.)
# but can be run directly: ./ci/ephemeral-env.sh provision --branch my-feature
#
# See docs/development-environment.md for full usage guide.

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONTAINER_ENGINE="${CONTAINER_ENGINE:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"
CI_IMAGE="rosa-regional-ci"
ENVS_FILE=".ephemeral-envs"

VAULT_ADDR="https://vault.ci.openshift.org"
VAULT_KV_MOUNT="kv"
VAULT_SECRET_PATH="selfservice/cluster-secrets-rosa-regional-platform-int/ephemeral-shared-dev-creds"
VAULT_CRED_KEYS=(
    central_access_key central_secret_key central_assume_role_arn
    regional_access_key regional_secret_key
    management_access_key management_secret_key
    github_token
)

# =============================================================================
# Helpers
# =============================================================================

die() { echo "Error: $*" >&2; exit 1; }

# Extract a KEY=VALUE field from an .ephemeral-envs line.
get_field() {
    echo "$1" | sed -n "s/.*${2}=\([^ ]*\).*/\1/p"
}

# Update the STATE field for a BUILD_ID in .ephemeral-envs.
update_state() {
    local id="$1" new_state="$2"
    grep -v "^${id} " "$ENVS_FILE" > "${ENVS_FILE}.tmp"
    grep "^${id} " "$ENVS_FILE" \
        | sed "s/STATE=[^ ]*/STATE=${new_state}/" >> "${ENVS_FILE}.tmp"
    mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Append KEY=VALUE to a BUILD_ID's line in .ephemeral-envs.
append_field() {
    local id="$1" key="$2" value="$3"
    sed "s|^${id} .*|& ${key}=${value}|" "$ENVS_FILE" > "${ENVS_FILE}.tmp" \
        && mv "${ENVS_FILE}.tmp" "$ENVS_FILE"
}

# Select an environment by explicit ID or interactive fzf picker.
# Sets global: BUILD_ID, ENV_LINE
#   $1 = grep pattern to filter candidates
#   $2 = fzf header text
#   $3 = "no match" message
select_env() {
    local state_filter="$1" header="$2" no_match_msg="$3"

    if [[ -n "${ID:-}" ]]; then
        BUILD_ID="$ID"
    else
        command -v fzf >/dev/null 2>&1 \
            || die "fzf is required for interactive selection. Install fzf or pass ID=<id> directly."
        [[ -f "$ENVS_FILE" && -s "$ENVS_FILE" ]] \
            || die "No environments found in $ENVS_FILE."

        local candidates
        candidates=$(grep -E "$state_filter" "$ENVS_FILE" || true)
        [[ -n "$candidates" ]] || die "$no_match_msg"

        local selected
        selected=$(echo "$candidates" | fzf --height=20 --header="$header") \
            || { echo "Aborted."; exit 1; }
        BUILD_ID=$(echo "$selected" | awk '{print $1}')
    fi

    ENV_LINE=$(grep "^${BUILD_ID} " "$ENVS_FILE" 2>/dev/null) \
        || die "ID $BUILD_ID not found in $ENVS_FILE."
}

# Check if .ephemeral-env/ override directory exists.
# Sets global: OVERRIDE_MOUNT (container flags), OVERRIDE_INFO (display string)
setup_override_mount() {
    OVERRIDE_MOUNT=""
    OVERRIDE_INFO="(default)"
    if [[ -d "${REPO_ROOT}/.ephemeral-env" ]]; then
        OVERRIDE_MOUNT="-v ${REPO_ROOT}/.ephemeral-env:/overrides:ro,z -e EPHEMERAL_OVERRIDE_DIR=/overrides"
        OVERRIDE_INFO=".ephemeral-env/"
    fi
}

# Fetch credentials from Vault via OIDC login.
# Sets global: CRED_FLAGS (container -e flags), REGIONAL_AK, REGIONAL_SK,
#              MANAGEMENT_AK, MANAGEMENT_SK
# Credentials never touch disk — they live only in this shell process.
fetch_creds() {
    echo "Fetching credentials from Vault (OIDC login)..."

    local vault_token
    vault_token=$(VAULT_ADDR="$VAULT_ADDR" vault login -method=oidc -token-only 2>/dev/null) \
        || die "Vault OIDC login failed."

    CRED_FLAGS=""
    REGIONAL_AK=""
    REGIONAL_SK=""
    MANAGEMENT_AK=""
    MANAGEMENT_SK=""

    for key in "${VAULT_CRED_KEYS[@]}"; do
        local val
        val=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$vault_token" \
            vault kv get -mount="$VAULT_KV_MOUNT" -field="$key" "$VAULT_SECRET_PATH" 2>/dev/null) \
            || die "Failed to fetch credential '$key' from Vault."

        local upper_key
        upper_key=$(echo "$key" | tr 'a-z' 'A-Z')
        CRED_FLAGS="$CRED_FLAGS -e ${upper_key}=${val}"

        case "$key" in
            regional_access_key)    REGIONAL_AK="$val" ;;
            regional_secret_key)    REGIONAL_SK="$val" ;;
            management_access_key)  MANAGEMENT_AK="$val" ;;
            management_secret_key)  MANAGEMENT_SK="$val" ;;
        esac
    done

    echo "Credentials loaded (in-memory only)."
}

# Build the CI container image if not already present.
ensure_image() {
    [[ -n "$CONTAINER_ENGINE" ]] \
        || die "No container engine found. Install podman or docker."

    if ! $CONTAINER_ENGINE image inspect "$CI_IMAGE" >/dev/null 2>&1; then
        echo "Building CI image..."
        local build_output
        if ! build_output=$($CONTAINER_ENGINE build -t "$CI_IMAGE" -f ci/Containerfile ci 2>&1); then
            echo "$build_output"
            die "Failed to build CI image."
        fi
    fi
}

# Check that required CLI tools are available.
preflight() {
    local missing=""
    for tool in vault git python3; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [[ -n "$CONTAINER_ENGINE" ]] || missing="$missing podman/docker"
    [[ -z "$missing" ]] || die "Missing required tools:$missing"
}

# =============================================================================
# Commands
# =============================================================================

cmd_provision() {
    local repo="${REPO:-openshift-online/rosa-regional-platform}"
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

    # Generate an ID if not provided
    if [[ -z "${ID:-}" ]]; then
        ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    fi

    # Interactive remote + branch picker (when BRANCH not explicitly set)
    if [[ -z "${BRANCH:-}" ]] && command -v fzf >/dev/null 2>&1; then
        echo "Current branch: $branch"
        echo "Select a remote to pick a branch from (or Esc to abort):"

        local remote
        remote=$(git remote -v | grep '(fetch)' \
            | awk '{printf "%-15s %s\n", $1, $2}' \
            | fzf --height=10 --header="Select remote:" \
            | awk '{print $1}') \
            || { echo "Aborted."; exit 1; }

        repo=$(git remote get-url "$remote" | sed 's|.*github\.com[:/]||; s|\.git$||')
        echo "Fetching branches from $remote ($repo)..."

        branch=$(git ls-remote --heads "$remote" 2>/dev/null \
            | sed 's|.*refs/heads/||' \
            | fzf --height=20 --header="Select branch:") \
            || { echo "Aborted."; exit 1; }

        echo "Selected branch: $branch (from $remote)"
    fi

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials
    fetch_creds

    # Print summary
    echo "Provisioning ephemeral environment..."
    echo "  ID:                $ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Record initial state
    echo "$ID REPO=$repo BRANCH=$branch STATE=provisioning CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$ENVS_FILE"

    # Run the ephemeral provider
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}"' EXIT

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -v "${tmpdir}:/output:z" \
        -w /workspace \
        -e "BUILD_ID=$ID" \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --repo "$repo" --branch "$branch" \
            --save-regional-state /output/tf-outputs.json \
    || rc=$?

    # Record results
    if [[ $rc -eq 0 ]]; then
        local api_url="" region=""
        if [[ -f "$tmpdir/tf-outputs.json" ]] && command -v jq >/dev/null 2>&1; then
            api_url=$(jq -r '.api_gateway_invoke_url.value // empty' "$tmpdir/tf-outputs.json" 2>/dev/null || true)
        fi
        if [[ -f "$tmpdir/region" ]]; then
            region=$(cat "$tmpdir/region")
        fi

        update_state "$ID" "ready"
        [[ -z "$region" ]]  || append_field "$ID" "REGION" "$region"
        [[ -z "$api_url" ]] || append_field "$ID" "API_URL" "$api_url"

        echo ""
        echo "Environment recorded in $ENVS_FILE."
        [[ -z "$api_url" ]] || echo -e "\n  API Gateway:  $api_url"
        echo ""
        echo "  To interact with the API:"
        echo "    make ephemeral-shell ID=$ID"
        echo ""
        echo "  To run e2e tests:"
        echo "    make ephemeral-e2e ID=$ID"
        echo ""
        echo "  To tear down:"
        echo "    make ephemeral-teardown ID=$ID"
    else
        update_state "$ID" "provisioning-failed"
        echo "Provisioning failed. State updated to provisioning-failed."
        exit $rc
    fi
}

cmd_teardown() {
    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to tear down:" \
        "No active environments found."

    local repo branch region
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)
    region=$(get_field "$ENV_LINE" REGION)

    # Fetch credentials
    fetch_creds

    # Print summary
    echo "Tearing down ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  REGION:            $region"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Run teardown
    update_state "$BUILD_ID" "deprovisioning"

    local rc=0
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BUILD_ID=$BUILD_ID" \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --teardown --repo "$repo" --branch "$branch" \
    || rc=$?

    # Update state
    if [[ $rc -eq 0 ]]; then
        update_state "$BUILD_ID" "deprovisioned"
        echo "Environment $BUILD_ID deprovisioned."
    else
        update_state "$BUILD_ID" "deprovisioning-failed"
        echo "Teardown failed. State updated to deprovisioning-failed."
        exit $rc
    fi
}

cmd_resync() {
    # Select environment
    select_env "STATE=(provisioning|ready|provisioning-failed|deprovisioning|deprovisioning-failed)" \
        "Select environment to resync:" \
        "No active environments found."

    local repo branch
    repo=$(get_field "$ENV_LINE" REPO)
    branch=$(get_field "$ENV_LINE" BRANCH)

    # Check for local config overrides
    setup_override_mount

    # Fetch credentials
    fetch_creds

    # Print summary
    echo "Resyncing ephemeral environment..."
    echo "  ID:                $BUILD_ID"
    echo "  REPO:              $repo"
    echo "  BRANCH:            $branch"
    echo "  ENV CONFIG:        $OVERRIDE_INFO"
    echo "  CONTAINER_ENGINE:  $CONTAINER_ENGINE"
    echo "  IMAGE:             $CI_IMAGE"

    # Run resync
    # shellcheck disable=SC2086
    $CONTAINER_ENGINE run --rm \
        $CRED_FLAGS \
        $OVERRIDE_MOUNT \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BUILD_ID=$BUILD_ID" \
        -e WORKSPACE_DIR=/workspace \
        "$CI_IMAGE" \
        uv run --no-cache ci/ephemeral-provider/main.py \
            --resync --repo "$repo" --branch "$branch"
}

cmd_list() {
    if [[ ! -f "$ENVS_FILE" || ! -s "$ENVS_FILE" ]]; then
        echo "No ephemeral environments."
        return
    fi

    echo "Ephemeral environments:"
    echo ""
    printf "%-12s %-45s %-25s %-12s %-22s %-20s %s\n" \
        "ID" "REPO" "BRANCH" "REGION" "STATE" "CREATED" "API_URL"
    echo "------------ --------------------------------------------- ------------------------- ------------ ---------------------- -------------------- -------"

    while IFS= read -r line; do
        local build_id repo branch region state created api_url
        build_id=$(echo "$line" | awk '{print $1}')
        repo=$(get_field "$line" REPO)
        branch=$(get_field "$line" BRANCH)
        region=$(get_field "$line" REGION)
        state=$(get_field "$line" STATE)
        created=$(get_field "$line" CREATED)
        api_url=$(get_field "$line" API_URL)
        printf "%-12s %-45s %-25s %-12s %-22s %-20s %s\n" \
            "$build_id" "$repo" "$branch" "$region" "$state" "$created" "$api_url"
    done < "$ENVS_FILE"

    echo ""
    echo "To clear list: rm $ENVS_FILE"
}

cmd_shell() {
    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment:" \
        "No ready environments found."

    local api_url region
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)

    # Fetch credentials
    fetch_creds

    # Launch interactive shell
    $CONTAINER_ENGINE run --rm -it \
        -e "AWS_ACCESS_KEY_ID=$REGIONAL_AK" \
        -e "AWS_SECRET_ACCESS_KEY=$REGIONAL_SK" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "API_URL=$api_url" \
        "$CI_IMAGE" \
        bash -c '
            echo ""
            echo "ROSA Regional Platform shell"
            echo ""
            echo "API Gateway: $API_URL"
            echo "Region:      $AWS_DEFAULT_REGION"
            echo ""
            echo "Example commands:"
            echo "  awscurl --service execute-api $API_URL/v0/live"
            exec bash'
}

cmd_bastion() {
    local cluster_type="${1:-}"

    # Validate cluster type
    case "$cluster_type" in
        regional|management) ;;
        *) die "Usage: $0 bastion <regional|management>" ;;
    esac

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for bastion access:" \
        "No ready environments found."

    local region
    region=$(get_field "$ENV_LINE" REGION)
    [[ -n "$region" ]] \
        || die "No REGION found for ID $BUILD_ID. Was it captured during provision?"

    # Compute ci_prefix from BUILD_ID (must match ci/ephemeral-provider/main.py)
    local ci_prefix
    ci_prefix="ci-$(echo -n "$BUILD_ID" | shasum -a 256 | cut -c1-6)"

    # Derive cluster ID and ECS resource names from ci_prefix
    local cluster_id
    if [[ "$cluster_type" == "regional" ]]; then
        cluster_id="${ci_prefix}-regional"
    else
        cluster_id="${ci_prefix}-mc01"
    fi
    local ecs_cluster="${cluster_id}-bastion"

    # Fetch credentials from Vault
    fetch_creds

    # Select the right credentials for the target account
    local target_ak target_sk
    if [[ "$cluster_type" == "regional" ]]; then
        target_ak="$REGIONAL_AK"
        target_sk="$REGIONAL_SK"
    else
        target_ak="$MANAGEMENT_AK"
        target_sk="$MANAGEMENT_SK"
    fi

    echo "Connecting to ephemeral bastion..."
    echo "  ID:           $BUILD_ID"
    echo "  CI prefix:    $ci_prefix"
    echo "  Cluster type: $cluster_type"
    echo "  Cluster ID:   $cluster_id"
    echo "  ECS cluster:  $ecs_cluster"
    echo "  Region:       $region"
    echo ""

    export AWS_ACCESS_KEY_ID="$target_ak"
    export AWS_SECRET_ACCESS_KEY="$target_sk"
    export AWS_DEFAULT_REGION="$region"
    export AWS_REGION="$region"

    # Check for an existing running task
    echo "==> Checking for running bastion tasks..."
    local existing_task
    existing_task=$(aws ecs list-tasks --cluster "$ecs_cluster" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)

    local task_id
    if [[ -n "$existing_task" && "$existing_task" != "None" ]]; then
        task_id=$(echo "$existing_task" | awk -F'/' '{print $NF}')
        echo "==> Found existing running task: $task_id"
    else
        echo "==> No running task found, starting a new one..."

        # Discover task definition, subnets, and security group from AWS
        local task_def="${cluster_id}-bastion"
        local sg_id subnets

        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${cluster_id}-bastion" \
            --query 'SecurityGroups[0].GroupId' --output text) \
            || die "Could not find security group '${cluster_id}-bastion'."
        [[ "$sg_id" != "None" ]] \
            || die "Security group '${cluster_id}-bastion' not found."

        # Find private subnets tagged for the cluster's VPC
        local vpc_id
        vpc_id=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].VpcId' --output text)

        subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
            --query 'Subnets[].SubnetId' --output text \
            | tr '\t' ',') \
            || die "Could not find private subnets in VPC $vpc_id."

        echo "    Task def:  $task_def"
        echo "    SG:        $sg_id"
        echo "    Subnets:   $subnets"

        AWS_PAGER="" aws ecs run-task \
            --cluster "$ecs_cluster" \
            --task-definition "$task_def" \
            --launch-type FARGATE \
            --enable-execute-command \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
            > /dev/null

        task_id=$(aws ecs list-tasks --cluster "$ecs_cluster" \
            --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
    fi

    # Wait for task to be running
    echo "==> Waiting for task to be running..."
    aws ecs wait tasks-running --cluster "$ecs_cluster" --tasks "$task_id"

    # Wait for the ECS exec agent to be ready
    echo "==> Waiting for execute command agent..."
    local agent_status=""
    for i in $(seq 1 30); do
        agent_status=$(aws ecs describe-tasks \
            --cluster "$ecs_cluster" --tasks "$task_id" --output json \
            | jq -r '.tasks[0].containers[] | select(.name=="bastion") | .managedAgents[] | select(.name=="ExecuteCommandAgent") | .lastStatus' 2>/dev/null || true)
        if [[ "$agent_status" == "RUNNING" ]]; then
            break
        fi
        sleep 2
    done
    [[ "$agent_status" == "RUNNING" ]] \
        || die "Execute command agent did not become ready (status: ${agent_status:-unknown})"

    echo ""
    echo "==> Bastion task ready"
    echo "    ECS cluster: $ecs_cluster"
    echo "    Task ID:     $task_id"
    echo ""
    echo "==> Connecting to bastion..."
    echo ""

    # Connect via ECS Exec
    aws ecs execute-command \
        --cluster "$ecs_cluster" \
        --task "$task_id" \
        --container bastion \
        --interactive \
        --command '/bin/bash'
}

cmd_e2e() {
    local api_ref="${API_REF:-main}"

    # Select environment (ready only)
    select_env "STATE=ready" \
        "Select environment for e2e tests:" \
        "No ready environments found."

    local api_url region
    api_url=$(get_field "$ENV_LINE" API_URL)
    region=$(get_field "$ENV_LINE" REGION)
    [[ -n "$api_url" ]] \
        || die "No API_URL found for ID $BUILD_ID. Was it captured during provision?"

    # Fetch credentials
    fetch_creds

    # Run tests
    echo "Running e2e tests..."
    echo "  ID:         $BUILD_ID"
    echo "  API_URL:    $api_url"
    echo "  REGION:     $region"
    echo "  API_REF:    $api_ref"

    $CONTAINER_ENGINE run --rm \
        -v "${REPO_ROOT}:/workspace:ro,z" \
        -w /workspace \
        -e "BASE_URL=$api_url" \
        -e "AWS_ACCESS_KEY_ID=$REGIONAL_AK" \
        -e "AWS_SECRET_ACCESS_KEY=$REGIONAL_SK" \
        -e "AWS_DEFAULT_REGION=$region" \
        -e "AWS_REGION=$region" \
        -e "API_REF=$api_ref" \
        "$CI_IMAGE" \
        bash ci/e2e-tests.sh
}

# =============================================================================
# Main
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Commands that don't need preflight or container image
case "${1:-help}" in
    list) cmd_list; exit 0 ;;
esac

# Bastion needs vault + aws but not container engine
case "${1:-help}" in
    bastion)
        for tool in vault aws; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
        done
        ;;
    *)
        # All other commands need tools + container image
        preflight
        ensure_image
        ;;
esac

case "${1:-help}" in
    provision) cmd_provision ;;
    teardown)  cmd_teardown ;;
    resync)    cmd_resync ;;
    shell)     cmd_shell ;;
    bastion)   cmd_bastion "$2" ;;
    e2e)       cmd_e2e ;;
    help|*)
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  provision   Provision an ephemeral environment"
        echo "  teardown    Tear down an ephemeral environment"
        echo "  resync      Resync an ephemeral environment to your branch"
        echo "  list        List ephemeral environments"
        echo "  shell       Interactive shell for Platform API access"
        echo "  bastion     Connect to RC/MC bastion in an ephemeral env"
        echo "  e2e         Run e2e tests against an ephemeral env"
        ;;
esac
