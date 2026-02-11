#!/usr/bin/env bash
#
# nuke-it.sh - Complete AWS Account Infrastructure Destroyer
#
# This script destroys all infrastructure in a target AWS account.
# It assumes the OrganizationAccountAccessRole to perform the cleanup.
#
# Usage:
#   ./nuke-it.sh <AWS_ACCOUNT_ID> [REGION]
#
# Example:
#   ./nuke-it.sh 633xxxxxx107 us-east-1
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
ASSUME_ROLE_NAME="OrganizationAccountAccessRole"
DEFAULT_REGION="us-east-1"
TEMP_DIR="/tmp/aws-destroy-$$"
mkdir -p "$TEMP_DIR"

# Trap to cleanup temp files
trap "rm -rf $TEMP_DIR" EXIT

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▶ $1${NC}"
    echo ""
}

# Check if required tools are installed
check_dependencies() {
    local missing=()

    for cmd in aws jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Please install: ${missing[*]}"
        exit 1
    fi
}

# Assume role to target account
assume_role() {
    local account_id="$1"
    local role_arn="arn:aws:iam::${account_id}:role/${ASSUME_ROLE_NAME}"

    log_info "Assuming role: $role_arn"

    if ! aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "destroy-account-session" \
        --duration-seconds 3600 \
        > "$TEMP_DIR/credentials.json" 2>&1; then
        log_error "Failed to assume role to account $account_id"
        log_error "Make sure you have permissions to assume the $ASSUME_ROLE_NAME role"
        exit 1
    fi

    export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' "$TEMP_DIR/credentials.json")
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' "$TEMP_DIR/credentials.json")
    export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' "$TEMP_DIR/credentials.json")

    # Verify credentials
    local assumed_account=$(aws sts get-caller-identity --query 'Account' --output text)
    if [ "$assumed_account" != "$account_id" ]; then
        log_error "Failed to assume role. Current account: $assumed_account, Expected: $account_id"
        exit 1
    fi

    log_success "Successfully assumed role to account $account_id"
}

# Scan for resources
scan_resources() {
    local region="$1"

    log_section "Scanning for resources in region: $region"

    # EKS Clusters
    local eks_clusters=$(aws eks list-clusters --region "$region" --output json 2>/dev/null | jq -r '.clusters[]' || echo "")
    echo "$eks_clusters" > "$TEMP_DIR/eks_clusters.txt"

    # VPCs (excluding default)
    aws ec2 describe-vpcs --region "$region" --output json 2>/dev/null | \
        jq -r '.Vpcs[] | select(.IsDefault == false) | "\(.VpcId)|\(.Tags // [] | from_entries | .Name // "No Name")"' \
        > "$TEMP_DIR/vpcs.txt" || true

    # IAM Roles (excluding OrganizationAccountAccessRole, AWS service roles, QuickSetup roles, and Qualys)
    aws iam list-roles --output json 2>/dev/null | \
        jq -r '.Roles[] | select(.RoleName != "OrganizationAccountAccessRole" and .RoleName != "QualysDiscovery" and (.RoleName | startswith("AWSServiceRole") | not) and (.RoleName | startswith("AWS-QuickSetup-ResourceExplorerRole-akkay-") | not)) | .RoleName' \
        > "$TEMP_DIR/iam_roles.txt" || true

    # S3 Buckets
    aws s3 ls 2>/dev/null | awk '{print $3}' > "$TEMP_DIR/s3_buckets.txt" || true

    # CloudWatch Log Groups
    aws logs describe-log-groups --region "$region" --output json 2>/dev/null | \
        jq -r '.logGroups[].logGroupName' \
        > "$TEMP_DIR/log_groups.txt" || true

    # KMS Keys (customer managed only)
    aws kms list-aliases --region "$region" --output json 2>/dev/null | \
        jq -r '.Aliases[] | select(.AliasName | startswith("alias/aws/") | not) | "\(.AliasName)|\(.TargetKeyId)"' \
        > "$TEMP_DIR/kms_aliases.txt" || true

    # CodePipeline
    aws codepipeline list-pipelines --region "$region" --output json 2>/dev/null | \
        jq -r '.pipelines[].name' \
        > "$TEMP_DIR/codepipelines.txt" || true

    # CodeBuild Projects
    aws codebuild list-projects --region "$region" --output json 2>/dev/null | \
        jq -r '.projects[]' \
        > "$TEMP_DIR/codebuild_projects.txt" || true

    # CodeStar Connections
    aws codestar-connections list-connections --region "$region" --output json 2>/dev/null | \
        jq -r '.Connections[] | "\(.ConnectionName)|\(.ConnectionArn)"' \
        > "$TEMP_DIR/codestar_connections.txt" || true

    # ECR Repositories
    aws ecr describe-repositories --region "$region" --output json 2>/dev/null | \
        jq -r '.repositories[].repositoryName' \
        > "$TEMP_DIR/ecr_repos.txt" || true

    # ECS Clusters
    aws ecs list-clusters --region "$region" --output json 2>/dev/null | \
        jq -r '.clusterArns[] | split("/") | .[-1]' \
        > "$TEMP_DIR/ecs_clusters.txt" || true

    # RDS Instances
    aws rds describe-db-instances --region "$region" --output json 2>/dev/null | \
        jq -r '.DBInstances[] | "\(.DBInstanceIdentifier)|\(.Engine)"' \
        > "$TEMP_DIR/rds_instances.txt" || true

    # Load Balancers (ALB/NLB)
    aws elbv2 describe-load-balancers --region "$region" --output json 2>/dev/null | \
        jq -r '.LoadBalancers[] | "\(.LoadBalancerName)|\(.Type)"' \
        > "$TEMP_DIR/load_balancers.txt" || true

    # Secrets Manager Secrets
    aws secretsmanager list-secrets --region "$region" --output json 2>/dev/null | \
        jq -r '.SecretList[] | "\(.Name)|\(.ARN)"' \
        > "$TEMP_DIR/secrets.txt" || true
}

# Display resources to be deleted
display_resources() {
    log_header "RESOURCES TO BE DELETED"

    local total_count=0

    # EKS Clusters
    if [ -s "$TEMP_DIR/eks_clusters.txt" ]; then
        echo -e "${BOLD}EKS Clusters:${NC}"
        while IFS= read -r cluster; do
            echo "  • $cluster"
            ((total_count++))
        done < "$TEMP_DIR/eks_clusters.txt"
        echo ""
    fi

    # VPCs
    if [ -s "$TEMP_DIR/vpcs.txt" ]; then
        echo -e "${BOLD}VPCs:${NC}"
        while IFS='|' read -r vpc_id vpc_name; do
            echo "  • $vpc_id ($vpc_name)"

            # Count subnets, NAT gateways, IGWs
            local subnet_count=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'length(Subnets)' --output text 2>/dev/null || echo "0")
            local nat_count=$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$vpc_id" --query 'length(NatGateways[?State==`available`])' --output text 2>/dev/null || echo "0")
            local igw_count=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$vpc_id" --query 'length(InternetGateways)' --output text 2>/dev/null || echo "0")
            local sg_count=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'length(SecurityGroups[?GroupName!=`default`])' --output text 2>/dev/null || echo "0")
            local vpce_count=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'length(VpcEndpoints)' --output text 2>/dev/null || echo "0")

            echo "    ├─ Subnets: $subnet_count"
            echo "    ├─ NAT Gateways: $nat_count"
            echo "    ├─ Internet Gateways: $igw_count"
            echo "    ├─ Security Groups: $sg_count"
            echo "    └─ VPC Endpoints: $vpce_count"

            ((total_count += 1 + subnet_count + nat_count + igw_count + sg_count + vpce_count))
        done < "$TEMP_DIR/vpcs.txt"
        echo ""
    fi

    # IAM Roles
    if [ -s "$TEMP_DIR/iam_roles.txt" ]; then
        local role_count=$(wc -l < "$TEMP_DIR/iam_roles.txt")
        echo -e "${BOLD}IAM Roles: ($role_count)${NC}"
        head -10 "$TEMP_DIR/iam_roles.txt" | while IFS= read -r role; do
            echo "  • $role"
        done
        if [ "$role_count" -gt 10 ]; then
            echo "  ... and $((role_count - 10)) more"
        fi
        echo ""
        ((total_count += role_count))
    fi

    # S3 Buckets
    if [ -s "$TEMP_DIR/s3_buckets.txt" ]; then
        local bucket_count=$(wc -l < "$TEMP_DIR/s3_buckets.txt")
        echo -e "${BOLD}S3 Buckets: ($bucket_count)${NC}"
        while IFS= read -r bucket; do
            echo "  • $bucket"
        done < "$TEMP_DIR/s3_buckets.txt"
        echo ""
        ((total_count += bucket_count))
    fi

    # CloudWatch Log Groups
    if [ -s "$TEMP_DIR/log_groups.txt" ]; then
        local log_count=$(wc -l < "$TEMP_DIR/log_groups.txt")
        echo -e "${BOLD}CloudWatch Log Groups: ($log_count)${NC}"
        head -10 "$TEMP_DIR/log_groups.txt" | while IFS= read -r log_group; do
            echo "  • $log_group"
        done
        if [ "$log_count" -gt 10 ]; then
            echo "  ... and $((log_count - 10)) more"
        fi
        echo ""
        ((total_count += log_count))
    fi

    # KMS Keys
    if [ -s "$TEMP_DIR/kms_aliases.txt" ]; then
        echo -e "${BOLD}KMS Keys:${NC}"
        while IFS='|' read -r alias key_id; do
            echo "  • $alias (Key: ${key_id:0:8}...)"
            ((total_count++))
        done < "$TEMP_DIR/kms_aliases.txt"
        echo ""
    fi

    # CodePipeline
    if [ -s "$TEMP_DIR/codepipelines.txt" ]; then
        local pipeline_count=$(wc -l < "$TEMP_DIR/codepipelines.txt")
        echo -e "${BOLD}CodePipelines: ($pipeline_count)${NC}"
        while IFS= read -r pipeline; do
            echo "  • $pipeline"
        done < "$TEMP_DIR/codepipelines.txt"
        echo ""
        ((total_count += pipeline_count))
    fi

    # CodeBuild Projects
    if [ -s "$TEMP_DIR/codebuild_projects.txt" ]; then
        local cb_count=$(wc -l < "$TEMP_DIR/codebuild_projects.txt")
        echo -e "${BOLD}CodeBuild Projects: ($cb_count)${NC}"
        while IFS= read -r project; do
            echo "  • $project"
        done < "$TEMP_DIR/codebuild_projects.txt"
        echo ""
        ((total_count += cb_count))
    fi

    # CodeStar Connections
    if [ -s "$TEMP_DIR/codestar_connections.txt" ]; then
        echo -e "${BOLD}CodeStar Connections:${NC}"
        while IFS='|' read -r name arn; do
            echo "  • $name"
            ((total_count++))
        done < "$TEMP_DIR/codestar_connections.txt"
        echo ""
    fi

    # ECR Repositories
    if [ -s "$TEMP_DIR/ecr_repos.txt" ]; then
        local ecr_count=$(wc -l < "$TEMP_DIR/ecr_repos.txt")
        echo -e "${BOLD}ECR Repositories: ($ecr_count)${NC}"
        while IFS= read -r repo; do
            echo "  • $repo"
        done < "$TEMP_DIR/ecr_repos.txt"
        echo ""
        ((total_count += ecr_count))
    fi

    # ECS Clusters
    if [ -s "$TEMP_DIR/ecs_clusters.txt" ]; then
        local ecs_count=$(wc -l < "$TEMP_DIR/ecs_clusters.txt")
        echo -e "${BOLD}ECS Clusters: ($ecs_count)${NC}"
        while IFS= read -r cluster; do
            echo "  • $cluster"
        done < "$TEMP_DIR/ecs_clusters.txt"
        echo ""
        ((total_count += ecs_count))
    fi

    # RDS Instances
    if [ -s "$TEMP_DIR/rds_instances.txt" ]; then
        echo -e "${BOLD}RDS Instances:${NC}"
        while IFS='|' read -r db_id engine; do
            echo "  • $db_id ($engine)"
            ((total_count++))
        done < "$TEMP_DIR/rds_instances.txt"
        echo ""
    fi

    # Load Balancers
    if [ -s "$TEMP_DIR/load_balancers.txt" ]; then
        echo -e "${BOLD}Load Balancers:${NC}"
        while IFS='|' read -r lb_name lb_type; do
            echo "  • $lb_name ($lb_type)"
            ((total_count++))
        done < "$TEMP_DIR/load_balancers.txt"
        echo ""
    fi

    # Secrets Manager Secrets
    if [ -s "$TEMP_DIR/secrets.txt" ]; then
        local secret_count=$(wc -l < "$TEMP_DIR/secrets.txt")
        echo -e "${BOLD}Secrets Manager Secrets: ($secret_count)${NC}"
        while IFS='|' read -r name arn; do
            echo "  • $name"
        done < "$TEMP_DIR/secrets.txt"
        echo ""
        ((total_count += secret_count))
    fi

    if [ "$total_count" -eq 0 ]; then
        log_warning "No resources found to delete"
        return 1
    fi

    echo -e "${BOLD}${RED}TOTAL RESOURCES: $total_count${NC}"
    echo ""

    return 0
}

# Delete EKS clusters
delete_eks_clusters() {
    if [ ! -s "$TEMP_DIR/eks_clusters.txt" ]; then
        return 0
    fi

    log_section "Deleting EKS Clusters"

    while IFS= read -r cluster; do
        # Skip empty lines
        [ -z "$cluster" ] && continue

        log_info "Deleting EKS cluster: $cluster"

        # Delete addons
        local addons=$(aws eks list-addons --cluster-name "$cluster" --region "$REGION" --output json 2>/dev/null | jq -r '.addons[]' || echo "")
        for addon in $addons; do
            log_info "  Deleting addon: $addon"
            aws eks delete-addon --cluster-name "$cluster" --addon-name "$addon" --region "$REGION" &>/dev/null || true
        done

        # Wait for addons to delete
        if [ -n "$addons" ]; then
            log_info "  Waiting for addons to delete..."
            sleep 10
        fi

        # Delete cluster
        aws eks delete-cluster --name "$cluster" --region "$REGION" &>/dev/null || log_warning "  Failed to delete cluster $cluster"

        # Wait for cluster deletion
        log_info "  Waiting for cluster deletion (this may take 5-10 minutes)..."
        aws eks wait cluster-deleted --name "$cluster" --region "$REGION" 2>/dev/null || true

        log_success "Deleted EKS cluster: $cluster"
    done < "$TEMP_DIR/eks_clusters.txt"
}

# Delete VPCs and their dependencies
delete_vpcs() {
    if [ ! -s "$TEMP_DIR/vpcs.txt" ]; then
        return 0
    fi

    log_section "Deleting VPCs and Dependencies"

    while IFS='|' read -r vpc_id vpc_name; do
        log_info "Deleting VPC: $vpc_id ($vpc_name)"

        # Delete NAT Gateways
        log_info "  Deleting NAT Gateways..."
        local nat_gws=$(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$vpc_id" --query 'NatGateways[?State==`available`].NatGatewayId' --output text 2>/dev/null || echo "")
        for nat in $nat_gws; do
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" &>/dev/null || true
            log_info "    Deleted NAT Gateway: $nat"
        done

        # Wait for NAT Gateways to delete
        if [ -n "$nat_gws" ]; then
            log_info "  Waiting for NAT Gateways to delete..."
            for nat in $nat_gws; do
                while true; do
                    state=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat" --region "$REGION" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
                    [ "$state" = "deleted" ] && break
                    sleep 5
                done
            done
        fi

        # Release Elastic IPs
        log_info "  Releasing Elastic IPs..."
        local eips=$(aws ec2 describe-addresses --region "$REGION" --filters "Name=domain,Values=vpc" --output json 2>/dev/null | jq -r ".Addresses[] | select(.NetworkInterfaceId == null or .NetworkInterfaceId == \"\") | .AllocationId" || echo "")
        for eip in $eips; do
            aws ec2 release-address --allocation-id "$eip" --region "$REGION" &>/dev/null || true
        done

        # Delete Internet Gateway
        log_info "  Deleting Internet Gateway..."
        local igw=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$vpc_id" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
        if [ -n "$igw" ] && [ "$igw" != "None" ]; then
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$REGION" &>/dev/null || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" &>/dev/null || true
        fi

        # Delete VPC Endpoints
        log_info "  Deleting VPC Endpoints..."
        local vpces=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || echo "")
        if [ -n "$vpces" ]; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpces --region "$REGION" &>/dev/null || true
            sleep 30 # Wait for ENIs to detach
        fi

        # Delete remaining ENIs
        log_info "  Deleting network interfaces..."
        local enis=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null || echo "")
        for eni in $enis; do
            aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" &>/dev/null || true
        done

        # Wait for all ENIs to be removed
        log_info "  Waiting for network interfaces to be removed..."
        for i in {1..30}; do
            eni_count=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
            [ "$eni_count" = "0" ] && break
            sleep 5
        done

        # Delete Subnets
        log_info "  Deleting subnets..."
        local subnets=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
        for subnet in $subnets; do
            aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" &>/dev/null || true
        done

        # Delete Route Tables
        log_info "  Deleting route tables..."
        local route_tables=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --output json 2>/dev/null | jq -r '.RouteTables[] | select(any(.Associations[]; .Main == false)) | .RouteTableId' || echo "")
        for rt in $route_tables; do
            aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" &>/dev/null || true
        done

        # Delete Security Groups
        log_info "  Deleting security groups..."
        local sgs=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" --output json 2>/dev/null | jq -r '.SecurityGroups[] | select(.GroupName != "default") | .GroupId' || echo "")
        for sg in $sgs; do
            aws ec2 delete-security-group --group-id "$sg" --region "$REGION" &>/dev/null || true
        done

        # Delete VPC
        log_info "  Deleting VPC..."
        sleep 5 # Brief wait for eventual consistency
        aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION" &>/dev/null || log_warning "  Failed to delete VPC $vpc_id (may have remaining dependencies)"

        log_success "Deleted VPC: $vpc_id"
    done < "$TEMP_DIR/vpcs.txt"
}

# Delete IAM roles
delete_iam_roles() {
    if [ ! -s "$TEMP_DIR/iam_roles.txt" ]; then
        return 0
    fi

    log_section "Deleting IAM Roles"

    while IFS= read -r role; do
        log_info "Deleting IAM role: $role"

        # Detach managed policies
        local policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
        for policy in $policies; do
            aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" &>/dev/null || true
        done

        # Delete inline policies
        local inline_policies=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
        for policy in $inline_policies; do
            aws iam delete-role-policy --role-name "$role" --policy-name "$policy" &>/dev/null || true
        done

        # Delete instance profiles
        local instance_profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || echo "")
        for profile in $instance_profiles; do
            aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" &>/dev/null || true
            aws iam delete-instance-profile --instance-profile-name "$profile" &>/dev/null || true
        done

        # Delete role
        aws iam delete-role --role-name "$role" &>/dev/null || log_warning "  Failed to delete role $role"

        log_success "Deleted IAM role: $role"
    done < "$TEMP_DIR/iam_roles.txt"
}

# Delete S3 buckets
delete_s3_buckets() {
    if [ ! -s "$TEMP_DIR/s3_buckets.txt" ]; then
        return 0
    fi

    log_section "Deleting S3 Buckets"

    while IFS= read -r bucket; do
        log_info "Deleting S3 bucket: $bucket"

        # Delete all versions and objects
        aws s3 rm "s3://$bucket" --recursive &>/dev/null || true

        # Delete bucket
        aws s3 rb "s3://$bucket" --force &>/dev/null || log_warning "  Failed to delete bucket $bucket"

        log_success "Deleted S3 bucket: $bucket"
    done < "$TEMP_DIR/s3_buckets.txt"
}

# Delete CloudWatch log groups
delete_log_groups() {
    if [ ! -s "$TEMP_DIR/log_groups.txt" ]; then
        return 0
    fi

    log_section "Deleting CloudWatch Log Groups"

    while IFS= read -r log_group; do
        aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" &>/dev/null || true
        log_success "Deleted log group: $log_group"
    done < "$TEMP_DIR/log_groups.txt"
}

# Delete KMS keys
delete_kms_keys() {
    if [ ! -s "$TEMP_DIR/kms_aliases.txt" ]; then
        return 0
    fi

    log_section "Deleting KMS Keys"

    while IFS='|' read -r alias key_id; do
        log_info "Deleting KMS key: $alias"

        # Delete alias
        aws kms delete-alias --alias-name "$alias" --region "$REGION" &>/dev/null || true

        # Schedule key deletion
        aws kms schedule-key-deletion --key-id "$key_id" --pending-window-in-days 7 --region "$REGION" &>/dev/null || true

        log_success "Scheduled KMS key for deletion (7 days): $alias"
    done < "$TEMP_DIR/kms_aliases.txt"
}

# Delete CodePipelines
delete_codepipelines() {
    if [ ! -s "$TEMP_DIR/codepipelines.txt" ]; then
        return 0
    fi

    log_section "Deleting CodePipelines"

    while IFS= read -r pipeline; do
        aws codepipeline delete-pipeline --name "$pipeline" --region "$REGION" &>/dev/null || true
        log_success "Deleted pipeline: $pipeline"
    done < "$TEMP_DIR/codepipelines.txt"
}

# Delete CodeBuild projects
delete_codebuild_projects() {
    if [ ! -s "$TEMP_DIR/codebuild_projects.txt" ]; then
        return 0
    fi

    log_section "Deleting CodeBuild Projects"

    while IFS= read -r project; do
        aws codebuild delete-project --name "$project" --region "$REGION" &>/dev/null || true
        log_success "Deleted project: $project"
    done < "$TEMP_DIR/codebuild_projects.txt"
}

# Delete CodeStar Connections
delete_codestar_connections() {
    if [ ! -s "$TEMP_DIR/codestar_connections.txt" ]; then
        return 0
    fi

    log_section "Deleting CodeStar Connections"

    while IFS='|' read -r name arn; do
        aws codestar-connections delete-connection --connection-arn "$arn" --region "$REGION" &>/dev/null || true
        log_success "Deleted connection: $name"
    done < "$TEMP_DIR/codestar_connections.txt"
}

# Delete ECR repositories
delete_ecr_repos() {
    if [ ! -s "$TEMP_DIR/ecr_repos.txt" ]; then
        return 0
    fi

    log_section "Deleting ECR Repositories"

    while IFS= read -r repo; do
        aws ecr delete-repository --repository-name "$repo" --force --region "$REGION" &>/dev/null || true
        log_success "Deleted ECR repository: $repo"
    done < "$TEMP_DIR/ecr_repos.txt"
}

# Delete ECS clusters
delete_ecs_clusters() {
    if [ ! -s "$TEMP_DIR/ecs_clusters.txt" ]; then
        return 0
    fi

    log_section "Deleting ECS Clusters"

    while IFS= read -r cluster; do
        aws ecs delete-cluster --cluster "$cluster" --region "$REGION" &>/dev/null || true
        log_success "Deleted ECS cluster: $cluster"
    done < "$TEMP_DIR/ecs_clusters.txt"
}

# Delete RDS instances
delete_rds_instances() {
    if [ ! -s "$TEMP_DIR/rds_instances.txt" ]; then
        return 0
    fi

    log_section "Deleting RDS Instances"

    while IFS='|' read -r db_id engine; do
        log_info "Deleting RDS instance: $db_id"
        aws rds delete-db-instance --db-instance-identifier "$db_id" --skip-final-snapshot --delete-automated-backups --region "$REGION" &>/dev/null || true
        log_success "Deleted RDS instance: $db_id (deletion in progress)"
    done < "$TEMP_DIR/rds_instances.txt"
}

# Delete Load Balancers
delete_load_balancers() {
    if [ ! -s "$TEMP_DIR/load_balancers.txt" ]; then
        return 0
    fi

    log_section "Deleting Load Balancers"

    while IFS='|' read -r lb_name lb_type; do
        local lb_arn=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$lb_name" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
        if [ -n "$lb_arn" ]; then
            aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" --region "$REGION" &>/dev/null || true
            log_success "Deleted load balancer: $lb_name"
        fi
    done < "$TEMP_DIR/load_balancers.txt"
}

# Delete Secrets Manager Secrets
delete_secrets() {
    if [ ! -s "$TEMP_DIR/secrets.txt" ]; then
        return 0
    fi

    log_section "Deleting Secrets Manager Secrets"

    while IFS='|' read -r name arn; do
        # Delete without retention period (force delete)
        aws secretsmanager delete-secret --secret-id "$name" --force-delete-without-recovery --region "$REGION" &>/dev/null || true
        log_success "Deleted secret (no retention): $name"
    done < "$TEMP_DIR/secrets.txt"
}

# Main deletion sequence
perform_deletion() {
    log_header "STARTING DELETION PROCESS"

    # Delete in order to handle dependencies
    delete_eks_clusters
    delete_rds_instances
    delete_load_balancers
    delete_codepipelines
    delete_codebuild_projects
    delete_codestar_connections
    delete_ecs_clusters
    delete_ecr_repos
    delete_vpcs
    delete_iam_roles
    delete_secrets
    delete_s3_buckets
    delete_log_groups
    delete_kms_keys

    log_header "DELETION COMPLETE"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 <AWS_ACCOUNT_ID> [REGION]

Destroys all infrastructure in the specified AWS account.

Arguments:
  AWS_ACCOUNT_ID    The target AWS account ID (required)
  REGION            AWS region (default: us-east-1)

Examples:
  $0 633630779107
  $0 633630779107 us-west-2

Notes:
  - Assumes the OrganizationAccountAccessRole in the target account
  - Ignores CloudTrail and OrganizationAccountAccessRole
  - KMS keys are scheduled for deletion (7 day waiting period)
  - This action is IRREVERSIBLE

EOF
}

#------------------------------------------------------------------------------
# Main Script
#------------------------------------------------------------------------------

main() {
    # Parse arguments
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    ACCOUNT_ID="$1"
    REGION="${2:-$DEFAULT_REGION}"

    # Validate account ID format
    if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        log_error "Invalid AWS account ID format: $ACCOUNT_ID"
        log_info "Account ID must be exactly 12 digits"
        exit 1
    fi

    log_header "AWS ACCOUNT DESTROYER"

    echo -e "${BOLD}Target Account:${NC} $ACCOUNT_ID"
    echo -e "${BOLD}Region:${NC} $REGION"
    echo ""

    # Check dependencies
    check_dependencies

    # Assume role
    assume_role "$ACCOUNT_ID"

    # Scan resources
    scan_resources "$REGION"

    # Display resources
    if ! display_resources; then
        log_success "Account is already clean. Nothing to delete."
        exit 0
    fi

    # Confirmation
    echo ""
    echo -e "${RED}${BOLD}⚠  WARNING: This will PERMANENTLY DELETE all resources listed above!${NC}"
    echo -e "${RED}${BOLD}⚠  This action is IRREVERSIBLE!${NC}"
    echo ""
    read -p "Type 'DESTROY ${ACCOUNT_ID}' to confirm: " confirmation

    if [ "$confirmation" != "DESTROY ${ACCOUNT_ID}" ]; then
        log_warning "Operation cancelled"
        exit 1
    fi

    # Perform deletion
    perform_deletion

    # Final verification
    log_section "Final Verification"
    scan_resources "$REGION"

    local remaining=0
    for file in "$TEMP_DIR"/*.txt; do
        if [ -s "$file" ]; then
            remaining=$((remaining + $(wc -l < "$file")))
        fi
    done

    if [ "$remaining" -eq 0 ]; then
        log_success "All resources successfully deleted!"
    else
        log_warning "Some resources may still remain ($remaining). Manual cleanup may be required."
    fi

    echo ""
    log_info "Destruction complete for account: $ACCOUNT_ID"
}

# Run main
main "$@"
