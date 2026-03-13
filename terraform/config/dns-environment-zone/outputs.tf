output "zone_id" {
  description = "Route53 hosted zone ID for the environment domain"
  value       = aws_route53_zone.environment.zone_id
}

output "name_servers" {
  description = "NS records for the environment zone — delegate these from the parent zone (e.g. rosa.devshift.net)"
  value       = aws_route53_zone.environment.name_servers
}

output "environment_domain" {
  description = "Environment domain name"
  value       = aws_route53_zone.environment.name
}
