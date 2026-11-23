output "website_url" {
  description = "Public website URL served by Nginx through the internet-facing ALB."
  value       = "http://${aws_lb.app.dns_name}"
}

output "api_url" {
  description = "Public API Gateway URL forwarding requests to the ALB and Auto Scaling Group."
  value       = aws_apigatewayv2_api.inventory.api_endpoint
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group name for the application instances."
  value       = aws_autoscaling_group.app.name
}

output "application_alb_dns_name" {
  description = "Public Application Load Balancer DNS name serving the site and API."
  value       = aws_lb.app.dns_name
}

output "cache_endpoint" {
  description = "Private shared Valkey endpoint used by the application instances."
  value       = aws_elasticache_replication_group.cache.primary_endpoint_address
}

output "s3_artifact_bucket" {
  description = "Pre-existing private bucket used for site and API files."
  value       = data.aws_s3_bucket.artifacts.bucket
}
