# Infrastructure Destruction via Lifecycle Management

**Last Updated Date**: 2026-02-24

## Summary

Infrastructure destruction for Regional and Management Clusters will be triggered declaratively through a `delete: true` field in configuration files, executed via existing GitOps pipelines with manual approval gates for safety, and include automatic cleanup of pipeline infrastructure after successful resource destruction.

## Context

### Problem Statement

The ROSA Regional Platform currently provides automated provisioning of Regional Clusters (RC) and Management Clusters (MC) through GitOps-driven CodePipelines, but lacks a safe, auditable mechanism to tear down infrastructure. Operators need the ability to:

- Destroy individual Management Clusters without affecting the Regional Cluster
- Destroy entire Regional Clusters (including all dependent Management Clusters)
- Remove pipeline infrastructure after destroying the underlying resources
- Maintain audit trails of destruction events
- Prevent accidental deletion through safety mechanisms

### Constraints

- **GitOps Principle**: Must align with the platform's GitOps-first architecture documented in CLAUDE.md
- **AWS CodePipeline**: Limited to stages available in CodePipeline (no custom orchestration)
- **Dependency Order**: Management Clusters must be destroyed before Regional Clusters
- **State Management**: Terraform state is stored in S3 in central account
- **Zero-Operator Access**: No direct SSH/kubectl access to clusters (break-glass only)
- **Audit Requirements**: All destructive actions must be traceable to Git commits and AWS CloudTrail

### Assumptions

- Operators have Git commit access to the repository
- Pipeline infrastructure (CodeBuild, CodePipeline) has necessary IAM permissions for `terraform destroy`
- Customer Hosted Clusters (control planes on MCs) are already drained/migrated before MC destruction
- SNS topics or similar notification mechanisms exist or can be created for approval alerts
- Manual approval can be performed within reasonable timeframes (not blocking urgent operations)

## Alternatives Considered

1. **Lifecycle State Field with Auto-Destruction**: Configuration files include a `lifecycle` field with values like `active`, `destroy`, `destroying`, `destroyed`. Pipelines automatically execute destruction without manual approval when set to `destroy`.

2. **Dedicated Destroy Pipeline with Manual Trigger**: Separate destroy-only pipelines created alongside provisioning pipelines, triggered manually via AWS CLI/Console with explicit confirmation flags required.

3. **Hybrid: Git-Triggered with Manual Approval Gate** (Chosen): Combines declarative Git-based trigger (`delete: true` in config files) with manual approval stage in pipeline before executing destruction.

## Design Rationale

### Justification

Option 3 (Hybrid Approach) provides the optimal balance between GitOps principles and operational safety:

- **GitOps Compliance**: Destruction intent is declared in version-controlled configuration files, providing audit trail and enabling code review processes
- **Safety Gate**: Manual approval stage prevents accidental destruction from errant commits or automation errors
- **Operational Flexibility**: Approval can be granted/denied based on current operational context (e.g., delay destruction during incident)
- **Consistency**: Uses same pipeline infrastructure for create/update/destroy operations, reducing maintenance burden
- **Gradual Rollout**: Approval gates can be environment-specific (stricter in production, relaxed in development)

### Evidence

Analysis of existing pipeline architecture in `terraform/config/pipeline-regional-cluster/main.tf` and `terraform/config/pipeline-management-cluster/main.tf` shows:

- Current pipelines have 3 stages: Source → Deploy → Bootstrap-ArgoCD
- CodePipeline supports manual approval actions natively (no custom implementation needed)
- Existing buildspecs follow pattern of checking environment variables to determine actions
- IAM policies already grant `*` permissions to CodeBuild roles (lines 61-77 in pipeline-regional-cluster/main.tf), sufficient for destroy operations

### Comparison

**Why not Option 1 (Auto-Destruction)?**
- No safety mechanism to prevent accidental destruction from bad commits
- Production environments require human verification before destructive actions
- Violates principle of "defense in depth" for high-impact operations

**Why not Option 2 (Separate Destroy Pipeline)?**
- Diverges from GitOps principles by requiring out-of-band CLI actions
- No declarative record of destruction intent in Git history
- Additional infrastructure to maintain (separate pipelines per cluster)
- Destruction events not linked to specific code commits

## Consequences

### Positive

- **Audit Trail**: Every destruction event traced to specific Git commit with author, timestamp, and justification in commit message
- **Safety by Default**: Manual approval prevents accidental destruction from configuration errors or premature commits
- **GitOps Native**: Destruction follows same declarative pattern as provisioning, consistent with platform architecture
- **Granular Control**: Can destroy individual Management Clusters without affecting Regional Cluster or other MCs
- **Self-Cleaning**: Pipeline-provisioner automatically removes pipeline infrastructure after detecting successful destruction
- **Review Process**: Configuration changes go through standard PR review before triggering destruction
- **Flexible Safety**: Approval gates can be environment-specific (production requires approval, development auto-approves)

### Negative

- **Manual Intervention Required**: Someone must approve destruction, adding latency to the process
- **Notification Dependency**: Requires SNS or email integration to alert approvers of pending destruction
- **State Transition Complexity**: Buildspecs must handle multiple states (`delete: true`, `delete: false`, absence of field)
- **Dependency Management**: Regional Cluster destruction must verify all MCs are destroyed first
- **Pipeline Complexity**: Additional stages (approval, destroy) increase pipeline definition size and maintenance
- **Potential Delays**: Approval gates can block destruction if approver is unavailable
- **Partial Automation**: Not fully automated end-to-end (requires human action)

## Cross-Cutting Concerns

### Reliability

#### Scalability
- Destruction process is serial by nature (one cluster at a time), no scaling concerns
- Pipeline-provisioner cleanup phase processes all destroyed clusters in single run, acceptable for expected volume (< 100 clusters)
- Manual approval does not impact system throughput (destructive operations are intentionally low-frequency)

#### Observability
- **Logging**: All pipeline executions logged to CloudWatch Logs with retention policies
- **Metrics**: CloudWatch metrics for pipeline execution duration, success/failure rates
- **Alerting**: SNS notifications for approval requests and destruction completion
- **Tracing**: Git commit SHA embedded in pipeline execution metadata for linking events to code changes
- **State Tracking**: Terraform state changes tracked in S3 versioning, enabling recovery if needed

#### Resiliency
- **Idempotency**: `terraform destroy` is idempotent, safe to retry on failure
- **Partial Failure Handling**: If destroy fails mid-operation, Terraform state reflects partial destruction, can be resumed
- **Dependency Protection**: RC destruction blocked if MCs exist, preventing orphaned resources
- **Approval Timeout**: Manual approval stage has configurable timeout (default 7 days), auto-rejects after expiration
- **Self-Healing**: Pipeline-provisioner cleanup phase runs on every execution, eventually consistent cleanup

### Security

- **Authentication**: Manual approval requires AWS IAM credentials with `codepipeline:PutApprovalResult` permission
- **Authorization**: Approval permissions can be scoped to specific principals (e.g., only SRE team for production)
- **Audit Logging**: All approval actions logged to CloudTrail with identity of approver
- **Least Privilege**: Destroy operations use same CodeBuild role as apply, no additional privilege escalation
- **Input Validation**: Buildspecs validate `delete` field is boolean, reject invalid values
- **Defense in Depth**: Multiple layers: Git commit + PR review + approval gate + dependency checks
- **Complete Mediation**: Every destruction attempt validated against configuration state before execution

### Performance

- **Destruction Duration**: Terraform destroy typically 15-30 minutes for RC, 10-20 minutes for MC
- **Approval Latency**: Human-dependent, measured in hours/days not seconds
- **Pipeline Overhead**: Approval stage adds ~2 minutes to pipeline execution time
- **Concurrent Destruction**: Multiple MCs can be destroyed in parallel (separate pipelines)
- **Cleanup Efficiency**: Pipeline-provisioner cleanup phase adds ~5 minutes to provisioning pipeline runs

### Cost

- **No Additional Infrastructure**: Reuses existing CodePipeline/CodeBuild resources
- **Pipeline Execution Cost**: Destruction runs incur standard CodeBuild charges (~$0.005 per build-minute)
- **Approval Stage Cost**: Manual approval actions are free in CodePipeline
- **State Storage**: S3 state files remain after destruction for audit purposes, minimal storage cost
- **SNS Notifications**: ~$0.50 per million notifications, negligible cost for expected volume
- **Net Savings**: Destroying unused infrastructure reduces ongoing EC2, RDS, and networking costs

### Operability

- **Deployment Complexity**: Moderate - requires updating pipeline definitions, buildspecs, and Makefile targets
- **Learning Curve**: Operators must understand `delete: true` syntax and approval process
- **Runbook Required**: Need documented procedure for destruction workflow and troubleshooting
- **Monitoring**: Standard CodePipeline dashboard shows pending approvals and execution status
- **Rollback**: Cannot rollback destruction (resources are deleted), must re-provision if needed
- **Testing**: Can test in development environment before applying to production
- **Migration Path**: Existing clusters unaffected, destruction capability added as opt-in feature

---

## Implementation Plan

### Phase 1: Core Functionality (Management Clusters)
1. Add `delete` field support to MC buildspec-apply.yml
2. Create MC buildspec-destroy.yml with dependency checks
3. Add destroy CodeBuild project to MC pipeline
4. Add manual approval stage (conditional on environment)
5. Create `pipeline-destroy-management` Makefile target
6. Test in development environment

### Phase 2: Regional Cluster Support
1. Add `delete` field support to RC buildspec-apply.yml
2. Create RC buildspec-destroy.yml with MC dependency checks
3. Add destroy CodeBuild project to RC pipeline
4. Add manual approval stage
5. Create `pipeline-destroy-regional` Makefile target
6. Test full RC+MC destruction workflow

### Phase 3: Pipeline Cleanup
1. Update pipeline-provisioner buildspec to detect `delete: true` with zero infrastructure
2. Implement pipeline self-destruction logic
3. Add state file cleanup (optional)
4. Test complete lifecycle: provision → destroy → cleanup

### Phase 4: Production Rollout
1. Create operator runbook documentation
2. Configure SNS notification topics per environment
3. Set approval IAM policies for production
4. Enable in staging environment
5. Monitor for 2 weeks
6. Enable in production

---

## Related Documentation

- [GitOps Cluster Configuration](./gitops-cluster-configuration.md) - Details GitOps patterns used for provisioning
- [Central Pipeline Provisioning](../central-pipeline-provisioning.md) - Pipeline-provisioner architecture
- [CLAUDE.md](../../CLAUDE.md) - Platform architecture principles
- [AGENTS.md](../../AGENTS.md) - Security principles for the platform

## Approval

**Proposed By**: Claude Code (Architecture Analysis Agent)
**Date**: 2026-02-24
**Status**: Proposed

**Approvers**: [To be filled by team]
- [ ] Platform Architect
- [ ] SRE Lead
- [ ] Security Team
- [ ] Product Owner
