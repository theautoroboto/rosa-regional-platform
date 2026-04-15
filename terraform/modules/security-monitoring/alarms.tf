# =============================================================================
# CloudWatch Metric Filters — FedRAMP SI-04
#
# Extracts security-relevant events from JSON-formatted EKS Kubernetes audit
# logs and publishes counts to the custom CloudWatch namespace
# "Security/<cluster-id>". YACE (Yet Another CloudWatch Exporter) scrapes
# those metrics into Prometheus; Alertmanager handles routing and notification.
#
# Metric names are static so Prometheus metric names are predictable:
#   aws_security_unauthorizedaccess401_sum
#   aws_security_forbiddenaccess403_sum
#   aws_security_privilegeescalation_sum
#   aws_security_anonymousaccess_sum
#
# EKS audit log event schema (Kubernetes audit.k8s.io/v1):
#   $.verb                 — API verb (get, list, create, delete, bind, ...)
#   $.responseStatus.code  — HTTP status code returned to caller
#   $.user.username        — Identity of the requestor
# =============================================================================

# --- 401 Unauthorized ---
# Fires when the EKS API server rejects a request with missing or invalid
# credentials. Repeated 401s may indicate credential stuffing or token reuse.

resource "aws_cloudwatch_log_metric_filter" "unauthorized_401" {
  name           = "${var.cluster_id}-unauthorized-401"
  log_group_name = var.eks_audit_log_group_name
  pattern        = "{ $.responseStatus.code = 401 }"

  metric_transformation {
    name      = "UnauthorizedAccess401"
    namespace = "Security/${var.cluster_id}"
    value     = "1"
    unit      = "Count"
  }
}

# --- 403 Forbidden ---
# Fires when a request was authenticated but not authorised by RBAC. Bursts
# may indicate privilege probing or a misconfigured service account.

resource "aws_cloudwatch_log_metric_filter" "forbidden_403" {
  name           = "${var.cluster_id}-forbidden-403"
  log_group_name = var.eks_audit_log_group_name
  pattern        = "{ $.responseStatus.code = 403 }"

  metric_transformation {
    name      = "ForbiddenAccess403"
    namespace = "Security/${var.cluster_id}"
    value     = "1"
    unit      = "Count"
  }
}

# --- Privilege Escalation Verbs ---
# Matches requests using verbs that directly alter the privilege model:
#   escalate  — direct escalate subresource
#   bind      — creating RoleBindings / ClusterRoleBindings
#   impersonate — acting as another user, group, or service account
# Any use of these verbs warrants investigation in a zero-operator environment.

resource "aws_cloudwatch_log_metric_filter" "privilege_escalation" {
  name           = "${var.cluster_id}-privilege-escalation"
  log_group_name = var.eks_audit_log_group_name
  pattern        = "{ ($.verb = \"escalate\") || ($.verb = \"bind\") || ($.verb = \"impersonate\") }"

  metric_transformation {
    name      = "PrivilegeEscalation"
    namespace = "Security/${var.cluster_id}"
    value     = "1"
    unit      = "Count"
  }
}

# --- Anonymous API Access ---
# Matches requests from system:anonymous. The EKS API is fully private — any
# anonymous request reaching it is anomalous and requires immediate action.

resource "aws_cloudwatch_log_metric_filter" "anonymous_access" {
  name           = "${var.cluster_id}-anonymous-access"
  log_group_name = var.eks_audit_log_group_name
  pattern        = "{ $.user.username = \"system:anonymous\" }"

  metric_transformation {
    name      = "AnonymousAccess"
    namespace = "Security/${var.cluster_id}"
    value     = "1"
    unit      = "Count"
  }
}
