# Pipeline-Based Deletion Process

**Last Updated Date**: 2026-02-25

## Summary

The ROSA Regional Platform implements a declarative, GitOps-driven deletion process using a `delete: true` flag in `config.yaml` that triggers automated infrastructure destruction through existing CodePipeline and CodeBuild resources, ensuring complete cleanup without requiring manual AWS console access or operator intervention.

## Context

The ROSA Regional Platform uses a fully automated GitOps-based provisioning system where infrastructure deployment is triggered by changes to configuration files in the Git repository. This approach successfully eliminated manual provisioning steps and enabled declarative infrastructure management. However, the original design lacked a corresponding deletion mechanism, creating an operational asymmetry.

- **Problem Statement**: How to safely delete regional clusters, management clusters, and their associated pipeline infrastructure in a way that is consistent with the platform's GitOps philosophy, maintains audit trails, and prevents manual console access
- **Constraints**: Must integrate with existing CodePipeline/CodeBuild architecture, maintain zero-operator AWS console access model, handle infrastructure dependencies correctly (destroy infrastructure before pipeline resources), and ensure complete cleanup to avoid lingering costs
- **Assumptions**: Operators have Git commit access but not AWS console access, Terraform state is centrally managed in S3 with lockfile-based locking, deletion operations are infrequent but must be reliable, and infrastructure destruction can take 30-60 minutes

## Alternatives Considered

1. **Manual AWS Console Deletion**: Operators access AWS console directly to delete resources through Terraform or manually delete infrastructure
2. **Separate Destroy CodeBuild Project**: Create dedicated CodeBuild projects for destruction operations with destroy-specific buildspecs and IAM permissions
3. **Makefile-Only Deletion**: Provide `make destroy-regional` and `make destroy-management` targets for local execution, no pipeline integration
4. **Declarative Delete Flag**: Add `delete: true` flag to `config.yaml`, render to JSON, pipeline-provisioner detects flag and orchestrates destruction (Chosen)

## Design Rationale

* **Justification**: The declarative delete flag approach was chosen because it maintains architectural consistency with the platform's GitOps foundation while ensuring complete, reliable cleanup of infrastructure and pipeline resources. By reusing existing CodeBuild projects and Terraform modules, the deletion process inherits the same reliability, security, and audit capabilities as the provisioning process.

* **Evidence**: The existing provisioning system successfully manages hundreds of potential regional deployments through declarative configuration (`config.yaml`). The two-phase destruction (infrastructure then pipeline) correctly handles dependency ordering without complex orchestration. Reusing Apply CodeBuild projects with environment variable override simplifies IAM permission management (destroy requires identical permissions to apply). Git commits provide immutable audit trail for FedRAMP compliance requirements. Force-destroy S3 buckets prevent orphaned resources while maintaining cost controls.

* **Comparison**:
  - **Manual Console Deletion** was rejected because it violates the zero-operator AWS console access security model, lacks Git audit trails, and doesn't scale across multiple regions
  - **Separate Destroy Projects** adds unnecessary complexity (doubles CodeBuild projects and IAM roles) without security benefits since destroy requires the same broad AWS permissions as apply operations
  - **Makefile-Only Deletion** works for development but lacks centralized execution and audit trails required for production multi-account environments
  - **Declarative Flag Approach** (chosen) provides the best balance of operational safety, audit compliance, and architectural consistency with the existing provisioning model

## Consequences

### Positive

* **GitOps Consistency**: Deletion operations follow the same declarative, Git-based workflow as provisioning, maintaining architectural uniformity
* **Complete Audit Trail**: All deletion operations are tracked through Git commits with PR reviews, meeting FedRAMP audit requirements
* **Zero Manual Access**: Operators never need AWS console access, maintaining strict zero-operator access security model
* **Cost Control**: Automatic cleanup of all infrastructure and pipeline resources prevents lingering costs from orphaned resources
* **Scalable Operations**: Deletion process scales to hundreds of regions without additional tooling or manual steps
* **Reduced IAM Complexity**: Reusing Apply CodeBuild projects means no additional IAM roles or permission boundaries for destruction
* **Dependency Management**: Two-phase destruction ensures infrastructure is removed before pipeline resources, preventing orphaned state
* **Idempotent Operations**: Re-running destruction on already-deleted resources gracefully handles missing state or resources

### Negative

* **Deletion Latency**: Destruction process takes 30-60 minutes due to pipeline execution, build queue times, and Terraform destroy duration (vs. seconds for immediate console deletion)
* **Irreversibility Risk**: Once Git commit with `delete: true` merges, destruction begins automatically with no "undo" mechanism (mitigated by PR review process)
* **State Corruption Handling**: If Terraform state is corrupted or lost, pipeline-provisioner may skip infrastructure destruction and proceed directly to pipeline cleanup, potentially orphaning resources
* **Error Recovery Complexity**: Failed destruction requires manual investigation and potential manual cleanup since retry logic is limited to transient failures
* **Configuration Bloat**: Deleted deployments must remain in `config.yaml` with `delete: true` until destruction completes, then be manually removed in second commit
* **Build Quota Impact**: Destruction operations consume CodeBuild concurrent build quota, potentially delaying other provisioning operations
* **Polling Overhead**: 30-second polling interval for build status creates delays and CloudWatch Logs API costs (though minimal)

## Cross-Cutting Concerns

### Reliability:

* **Scalability**: The deletion process scales linearly with the number of deployments. Each regional cluster or management cluster deletion is independent, enabling parallel destruction across regions. The pipeline-provisioner processes JSON configs sequentially but continues if individual deletions fail, preventing cascading failures.

* **Observability**: Deletion operations produce comprehensive logs across multiple layers - Git commit history provides high-level audit trail of deletion intent, CodePipeline execution history shows pipeline-provisioner trigger events, CodeBuild logs capture detailed destruction progress for both infrastructure and pipeline phases, Terraform state changes are recorded in S3 state bucket (until deletion), and CloudWatch Logs retain build logs for 90 days by default for post-mortem analysis.

* **Resiliency**: The two-phase destruction process handles partial failures gracefully. If infrastructure destruction fails, pipeline resources remain intact for retry. If pipeline destruction fails, infrastructure is already removed (primary cost driver). Terraform state locking prevents concurrent modifications during destruction. S3 bucket `force_destroy` ensures deletion succeeds even with versioned objects. Graceful degradation when Terraform output unavailable (assumes infrastructure already destroyed).

### Security:

* **Authentication**: Destruction operations use the same AWS IAM authentication as provisioning. Pipeline-provisioner runs in central account with access to Terraform state S3 bucket. Apply CodeBuild projects assume OrganizationAccountAccessRole for cross-account operations. No additional credentials or roles required specifically for destruction.

* **Authorization**: IAM permissions for destruction are identical to provisioning (no separate destroy-specific policies needed). CodeBuild IAM role includes full EC2, EKS, IAM, S3, etc. permissions. Destruction operations reuse existing IAM boundaries without privilege escalation. Terraform state access controlled by S3 bucket policies in central account.

* **Audit Trail**: Git commits provide immutable, cryptographically-signed record of deletion intent. Pull request reviews enforce approval gates before destruction begins. Commit SHAs uniquely identify which version of config triggered deletion. CodePipeline execution ARNs link Git commits to specific destroy operations.

* **Compliance**: FedRAMP compliance requirements satisfied through no operator AWS console access (zero-trust model maintained), all changes tracked through version control with PR approvals, automated destruction prevents privileged access to production accounts, and CloudWatch Logs retention provides audit evidence for 90 days.

### Performance:

* **Latency**: Deletion operations have multi-stage latency characteristics - Git commit to pipeline trigger: 0-60 seconds (GitHub webhook delay), Pipeline-provisioner queue time: 0-300 seconds (depends on concurrent builds), Infrastructure destruction: 20-45 minutes (EKS cluster deletion dominates), Pipeline resource cleanup: 2-5 minutes (S3 bucket emptying dominates), Total end-to-end: 30-60 minutes typical, 90 minutes worst-case.

* **Throughput**: Concurrent deletion capacity limited by CodeBuild concurrent build quota (default 60 concurrent builds per region), Terraform state locking (prevents concurrent modifications to same cluster state), and AWS API rate limits (EC2 DeleteSubnet, EKS DeleteCluster have burst limits).

* **Resource Utilization**: Destruction operations consume CodeBuild compute (BUILD_GENERAL1_SMALL instance for 30-60 minutes at ~$0.05/build), CloudWatch Logs storage (~100 MB per destruction operation), and S3 API calls (50-100 requests for state read/write and artifact cleanup).

### Cost:

* **Direct Costs**: Deletion operations incur minimal direct costs - CodeBuild execution time: ~$0.05 per regional cluster destruction, CloudWatch Logs storage: ~$0.01 per destruction operation (90-day retention), S3 API requests: <$0.01 per destruction, Total per-deletion cost: ~$0.06-$0.10.

* **Cost Avoidance**: Automated deletion prevents significant cost accumulation - EKS cluster: ~$73/month control plane + worker node costs, RDS instance: ~$50-200/month depending on instance type, NAT Gateways: ~$96/month for multi-AZ configuration, Data transfer and storage costs, Total avoided cost per cluster per month: ~$250-500.

* **Operational Expenses**: Manual deletion alternatives would incur higher costs through operator time for manual console deletion (1-2 hours per cluster), risk of orphaned resources without automated cleanup, and audit compliance overhead for manual access justification.

### Operability:

* **Deployment Complexity**: Deletion process requires multi-step operator workflow: (1) Update `config.yaml` to add `delete: true` flag, (2) Run `uv run scripts/render.py` to regenerate deploy/ directory, (3) Commit changes and create pull request, (4) Obtain approval from reviewer, (5) Merge pull request to trigger destruction, (6) Monitor CodeBuild logs for completion, (7) Remove deleted entries from `config.yaml` after destruction completes.

* **Maintenance Burden**: Ongoing maintenance requirements include monitoring CodeBuild quotas to ensure deletion capacity, reviewing Terraform state consistency (detect state drift before deletion), updating destroy logic when new infrastructure components added, and testing deletion workflow in development environments before production use.

* **Troubleshooting**: Common scenarios include stuck deletions (check CodeBuild logs for API throttling or Terraform errors), partial failures (review Terraform state to identify remaining resources, manually clean up via Terraform console or AWS CLI), state corruption (restore from S3 state bucket versioning or manually delete resources and state file), and orphaned resources (use AWS Resource Groups Tagging to identify untracked resources by cluster identifier).

* **Emergency Procedures**: Abort deletion is not possible once infrastructure destruction begins (Terraform destroy is non-interruptible). Rollback failed deletion by restoring infrastructure through removing `delete: true` flag and re-provisioning (if state intact). Force cleanup by manually deleting resources via AWS CLI if pipeline-based deletion fails irrecoverably.

---

## Architecture Details

### Deletion Flow

The deletion process extends the existing pipeline-provisioner architecture by adding destruction logic triggered by a declarative flag:

1. **Configuration**: Operator sets `delete: true` in `config.yaml` terraform_vars for target deployment
2. **Rendering**: `scripts/render.py` generates JSON files in `deploy/` directory with delete flag
3. **Trigger**: Pipeline-provisioner CodePipeline detects changes to JSON files
4. **Detection**: `destroy_pipeline()` function detects delete flag in JSON configuration
5. **Phase 1 - Infrastructure**: Triggers Apply CodeBuild project with `IS_DESTROY=true` environment variable
6. **Execution**: Apply buildspec runs `make pipeline-destroy-regional` or `make pipeline-destroy-management`
7. **Polling**: Waits for infrastructure destruction to complete (polls build status every 30 seconds)
8. **Phase 2 - Pipeline**: Runs `terraform destroy` on pipeline resources (CodePipeline, CodeBuild, S3)
9. **Completion**: All resources cleaned up, operator removes entry from `config.yaml`

### Configuration Example

```yaml
# config.yaml - Regional cluster deletion
region_deployments:
  - name: "us-east-1"
    aws_region: "us-east-1"
    sector: "integration"
    account_id: "123456789012"
    terraform_vars:
      delete: true  # Triggers destruction
      region: "{{ aws_region }}"
      alias: "regional-{{ region_alias }}"
    management_clusters:
      - cluster_id: "mc01-{{ region_alias }}"
        account_id: "987654321098"
        terraform_vars:
          delete: true  # Triggers MC destruction
```

### Key Implementation Details

**Reusing Apply CodeBuild**: The deletion process triggers the same CodeBuild project used for provisioning but with `IS_DESTROY=true` environment variable. This ensures identical IAM permissions, reuses battle-tested buildspecs, and maintains consistency between apply and destroy workflows.

**S3 Force Destroy**: Pipeline artifact buckets include `force_destroy = true` to enable deletion even when containing build artifacts ([terraform/config/pipeline-regional-cluster/main.tf:153](terraform/config/pipeline-regional-cluster/main.tf#L153), [terraform/config/pipeline-management-cluster/main.tf:289](terraform/config/pipeline-management-cluster/main.tf#L289)).

**Graceful Degradation**: The `destroy_pipeline()` function reads `codebuild_apply_name` from Terraform state to identify the CodeBuild project. If state is empty or corrupted, it gracefully continues to pipeline resource destruction ([terraform/config/pipeline-provisioner/buildspec.yml:105-107](terraform/config/pipeline-provisioner/buildspec.yml#L105-L107)).

### File Locations

**Configuration**:
- [config.yaml](config.yaml) - Declarative cluster configuration with delete flags
- [scripts/render.py](scripts/render.py) - Renders config.yaml to deploy/ JSON files

**Deletion Orchestration**:
- [terraform/config/pipeline-provisioner/buildspec.yml:94-153](terraform/config/pipeline-provisioner/buildspec.yml#L94-L153) - `destroy_pipeline()` function

**Destruction Execution**:
- [terraform/config/pipeline-regional-cluster/buildspec-apply.yml:97-100](terraform/config/pipeline-regional-cluster/buildspec-apply.yml#L97-L100) - Detects `IS_DESTROY` environment variable
- [terraform/config/pipeline-management-cluster/buildspec-apply.yml:170-189](terraform/config/pipeline-management-cluster/buildspec-apply.yml#L170-L189) - Detects `IS_DESTROY` environment variable
- [Makefile:176-197](Makefile#L176-L197) - `pipeline-destroy-regional` and `pipeline-destroy-management` targets

**Infrastructure Configuration**:
- [terraform/config/pipeline-regional-cluster/main.tf:153](terraform/config/pipeline-regional-cluster/main.tf#L153) - S3 bucket `force_destroy`
- [terraform/config/pipeline-management-cluster/main.tf:289](terraform/config/pipeline-management-cluster/main.tf#L289) - S3 bucket `force_destroy`
