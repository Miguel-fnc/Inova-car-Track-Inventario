output "website_url" {
  description = "Public website URL served directly by Nginx on the EC2 instance."
  value       = "http://${aws_instance.web.public_ip}"
}

output "instance_id" {
  description = "EC2 instance serving the website."
  value       = aws_instance.web.id
}

output "s3_artifact_bucket" {
  description = "Existing private bucket where deploy.ps1 uploads the site."
  value       = data.aws_s3_bucket.artifacts.bucket
}

