# FedRAMP High Compliance Audit Report

**ROSA Regional Platform**
**Audit Date:** 2026-03-25
**Auditor:** FedRAMP Compliance Agent
**Baseline:** NIST 800-53 Rev 5 - FedRAMP High

---

## Executive Summary

This audit evaluates the ROSA Regional Platform infrastructure against FedRAMP High baseline controls. The platform demonstrates strong security architecture with fully private EKS clusters, KMS encryption, and network isolation. However, several critical gaps must be addressed before FedRAMP High authorization.

| Category | Critical | High | Medium | Compliant |
|----------|----------|------|--------|-----------|
| Findings | 3 | 4 | 5 | 15+ |

---

## Critical Findings (Must Remediate)

### 1. FIPS 140-2 Endpoints Not Configured

**Status:** NON-COMPLIANT
**Control ID:** SC-13, IA-7
**GovCloud:** Required for federal deployment

**Findings:**
No `use_fips_endpoint` configuration found in any Terraform AWS provider blocks. All AWS API calls are using standard (non-FIPS) endpoints.

**Affected Files:**
- `terraform/config/regional-cluster/main.tf`
- `terraform/config/management-cluster/main.tf`
- `terraform/config/pipeline-regional-cluster/main.tf`
- All provider configurations

**Remediation:**
```hcl
provider "aws" {
  region = var.region

  # Enable FIPS 140-2 validated endpoints for all AWS API calls
  use_fips_endpoint = true

  # ... existing configuration
}
```

**Reference:** https://aws.amazon.com/compliance/fips/

---

### 2. CloudTrail Not Configured

**Status:** NON-COMPLIANT
**Control ID:** AU-2, AU-3, AU-6, AU-12
**GovCloud:** N/A (Configuration gap)

**Findings:**
No `aws_cloudtrail` resources found in the Terraform codebase. CloudTrail is essential for:
- API activity logging (AU-2)
- Audit record content (AU-3)
- Audit review and reporting (AU-6)
- Audit generation (AU-12)

**Remediation:**
Create a CloudTrail module with:
```hcl
resource "aws_cloudtrail" "main" {
  name                          = "${var.regional_id}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_logging                = true

  # KMS encryption required for FedRAMP High
  kms_key_id = aws_kms_key.cloudtrail.arn

  # Log all management events
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  # Enable CloudWatch integration
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn
}
```

---

### 3. Insufficient Log Retention Period

**Status:** NON-COMPLIANT
**Control ID:** AU-11
**GovCloud:** N/A (Configuration gap)

**Findings:**
CloudWatch log retention is set to 30 days in `terraform/modules/eks-cluster/main.tf:16`:
```hcl
retention_in_days = 30
```

FedRAMP High requires minimum 1 year (365 days) retention for audit records.

**Remediation:**
```hcl
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = 365  # FedRAMP High minimum
  kms_key_id        = aws_kms_key.logs.arn  # Encrypt logs at rest
}
```

---

## High Priority Findings

### 4. WAF Not Configured for API Gateway

**Status:** NON-COMPLIANT
**Control ID:** SC-7, SC-7(5)
**GovCloud:** Available

**Findings:**
No AWS WAF (Web Application Firewall) configuration found. WAF is required for:
- Boundary protection (SC-7)
- Deny by default / allow by exception (SC-7(5))
- Protection against OWASP Top 10 attacks

**Remediation:**
```hcl
resource "aws_wafv2_web_acl" "api" {
  name        = "${var.regional_id}-api-waf"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Add AWS Managed Rules
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
    }
  }
}

resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_api_gateway_stage.main.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}
```

---

### 5. ALB Access Logging Not Enabled

**Status:** NON-COMPLIANT
**Control ID:** AU-2, AU-3
**GovCloud:** N/A (Configuration gap)

**Findings:**
No `access_logs` block in ALB configuration at `terraform/modules/api-gateway/alb.tf`.

**Remediation:**
```hcl
resource "aws_lb" "platform" {
  # ... existing config

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb-logs"
    enabled = true
  }
}
```

---

### 6. RDS Backup Retention Too Short

**Status:** PARTIAL
**Control ID:** CP-9, CP-10
**GovCloud:** N/A (Configuration gap)

**Findings:**
Default backup retention is 7 days in:
- `terraform/modules/maestro-infrastructure/variables.tf:87`
- `terraform/modules/hyperfleet-infrastructure/variables.tf:90`

FedRAMP High recommends minimum 35 days for database backups.

**Remediation:**
```hcl
variable "db_backup_retention_period" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 35  # FedRAMP High recommended minimum
}
```

---

### 7. Deletion Protection Disabled by Default

**Status:** PARTIAL
**Control ID:** CM-6, SC-28
**GovCloud:** N/A (Configuration gap)

**Findings:**
`db_deletion_protection` defaults to `false` in:
- `terraform/modules/maestro-infrastructure/variables.tf:93`
- `terraform/modules/hyperfleet-infrastructure/variables.tf:96`

Production databases should have deletion protection enabled.

**Remediation:**
Set default to `true` for production environments or enforce via variable validation.

---

## Medium Priority Findings

### 8. IMDSv2 Not Enforced on EKS Nodes

**Status:** PARTIAL
**Control ID:** CM-6, AC-3
**GovCloud:** N/A (Configuration gap)

**Findings:**
TODO comment in `terraform/modules/eks-cluster/main.tf:57-61` indicates IMDSv2 enforcement is pending AWS provider support.

**Remediation:**
Monitor AWS provider releases and implement when available. IMDSv2 prevents SSRF attacks on instance metadata.

---

### 9. Internal ALB Uses HTTP

**Status:** PARTIAL
**Control ID:** SC-8
**GovCloud:** N/A

**Findings:**
ALB listener at `terraform/modules/api-gateway/alb.tf:67-76` uses HTTP on port 80.

**Mitigating Factors:**
- ALB is internal (not internet-facing)
- Traffic is within VPC only
- API Gateway terminates TLS at edge

**Remediation (Optional):**
For defense-in-depth, configure HTTPS listener with internal certificate.

---

### 10. TLS Security Policy Not Specified

**Status:** PARTIAL
**Control ID:** SC-8, SC-13
**GovCloud:** N/A

**Findings:**
No `security_policy` specified on API Gateway custom domain at `terraform/modules/api-gateway/custom-domain.tf:60-73`.

**Remediation:**
```hcl
resource "aws_api_gateway_domain_name" "api" {
  # ... existing config
  security_policy = "TLS_1_2"  # Enforce TLS 1.2 minimum
}
```

---

### 11. Multi-AZ Disabled by Default for RDS

**Status:** PARTIAL
**Control ID:** CP-10, SC-5
**GovCloud:** N/A

**Findings:**
`db_multi_az` defaults to `false` in database modules. Production deployments should use Multi-AZ for high availability.

---

### 12. Final Snapshot Skip Enabled by Default

**Status:** PARTIAL
**Control ID:** CP-9
**GovCloud:** N/A

**Findings:**
`db_skip_final_snapshot` defaults to `true`. Should be `false` for production to ensure data recovery capability.

---

## Compliant Controls

| Control ID | Control Name | Status | Evidence |
|------------|--------------|--------|----------|
| SC-28 | Protection of Information at Rest | COMPLIANT | KMS encryption for EKS secrets (`main.tf:38-42`), RDS `storage_encrypted = true` |
| SC-12 | Cryptographic Key Establishment | COMPLIANT | KMS key rotation enabled (`kms.tf:19`) |
| SC-7 | Boundary Protection | COMPLIANT | Fully private EKS clusters, no public endpoints (`main.tf:48`) |
| SC-7(21) | Isolation of System Components | COMPLIANT | No network path between RC and MC VPCs (documented in design) |
| AC-3 | Access Enforcement | COMPLIANT | AWS IAM authentication on API Gateway (`main.tf:55`) |
| AU-2 | Audit Events | COMPLIANT | EKS control plane logging enabled for all types (`main.tf:76`) |
| AC-6 | Least Privilege | COMPLIANT | Security groups use specific ports, no 0.0.0.0/0 ingress |
| IA-2 | Identification and Authentication | COMPLIANT | AWS IAM for all authentication, X.509 for MQTT |
| CM-2 | Baseline Configuration | COMPLIANT | GitOps-driven configuration via ArgoCD |
| SC-8(1) | Cryptographic Protection | COMPLIANT | TLS 1.2+ for MQTT (IoT Core port 8883), API Gateway HTTPS |

---

## GovCloud Service Availability

| AWS Service | Used In | GovCloud Available | Notes |
|-------------|---------|-------------------|-------|
| EKS | Core infrastructure | Yes | FedRAMP High authorized |
| RDS PostgreSQL | Maestro, HyperFleet | Yes | FedRAMP High authorized |
| AWS IoT Core | Maestro MQTT | Yes | Available in us-gov-west-1 |
| API Gateway | Platform API | Yes | FedRAMP High authorized |
| DynamoDB | AuthZ | Yes | FedRAMP High authorized |
| Secrets Manager | Credentials | Yes | FedRAMP High authorized |
| KMS | Encryption | Yes | FedRAMP High authorized |
| CloudFront | HyperShift OIDC | Yes | FedRAMP High authorized |
| ECS Fargate | Bootstrap | Yes | FedRAMP High authorized |
| Application Load Balancer | Internal API | Yes | FedRAMP High authorized |
| Route53 | DNS | Yes | FedRAMP High authorized |
| Amazon MQ (RabbitMQ) | HyperFleet | Yes | FedRAMP High authorized |
| ACM | Certificates | Yes | FedRAMP High authorized |
| CloudWatch | Logging | Yes | FedRAMP High authorized |

**EKS Auto Mode:** Verify availability in GovCloud regions before deployment. Standard EKS with managed node groups is the fallback.

---

## Remediation Priority Matrix

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| P0 | Enable FIPS endpoints | Low | Critical - Required for FedRAMP |
| P0 | Configure CloudTrail | Medium | Critical - Required for audit |
| P0 | Increase log retention to 365 days | Low | Critical - Required for FedRAMP |
| P1 | Add WAF to API Gateway | Medium | High - Boundary protection |
| P1 | Enable ALB access logging | Low | High - Audit completeness |
| P1 | Increase backup retention to 35 days | Low | High - Data protection |
| P2 | Enable deletion protection | Low | Medium - Operational safety |
| P2 | Enforce TLS 1.2 security policy | Low | Medium - Defense in depth |
| P2 | Enable Multi-AZ for production | Low | Medium - High availability |
| P3 | Implement IMDSv2 enforcement | Low | Medium - Pending AWS support |

---

## Recommendations

1. **Immediate Actions (P0):**
   - Add `use_fips_endpoint = true` to all AWS provider configurations
   - Create CloudTrail module with KMS encryption
   - Update CloudWatch log retention to 365 days

2. **Short-term (P1):**
   - Implement WAF with AWS Managed Rules
   - Enable ALB access logging to S3
   - Create production-specific tfvars with appropriate retention periods

3. **Pre-Production (P2/P3):**
   - Validate all services in GovCloud regions
   - Implement IMDSv2 when AWS provider support available
   - Enable deletion protection for all production databases

---

## Appendix: Files Audited

- `terraform/modules/eks-cluster/*.tf`
- `terraform/modules/api-gateway/*.tf`
- `terraform/modules/maestro-infrastructure/*.tf`
- `terraform/modules/hyperfleet-infrastructure/*.tf`
- `terraform/modules/authz/*.tf`
- `terraform/modules/bastion/*.tf`
- `terraform/modules/ecs-bootstrap/*.tf`
- `terraform/config/regional-cluster/*.tf`
- `terraform/config/management-cluster/*.tf`
- `docs/design/*.md`
- `docs/README.md`
- `docs/FAQ.md`

---

*Report generated by FedRAMP Compliance Agent*
*NIST 800-53 Rev 5 | FedRAMP High Baseline*
