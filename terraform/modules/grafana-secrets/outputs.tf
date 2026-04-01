output "grafana_admin_secret_arn" {
  description = "ARN of the Grafana admin credentials secret in Secrets Manager"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "grafana_secret_key_arn" {
  description = "ARN of the Grafana database secret key in Secrets Manager"
  value       = aws_secretsmanager_secret.grafana_secrets.arn
}

output "grafana_admin_username" {
  description = "TEMPORARY - Grafana admin username. Remove once SSO is configured."
  value       = var.grafana_admin_username
}

output "grafana_admin_password" {
  description = "TEMPORARY - Grafana admin password. Remove once SSO is configured."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

# TEMPORARY: kubectl command to retrieve the Grafana URL after ArgoCD deploys.
# Remove once Grafana has a Route53 domain + TLS.
output "grafana_url_command" {
  description = "TEMPORARY - Run this command to get the Grafana URL after ArgoCD deploys the LoadBalancer service."
  value       = "kubectl get svc grafana -n grafana -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}'"
}
