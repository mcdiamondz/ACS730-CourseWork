# SSM Parameter data source for application configuration
data "aws_ssm_parameter" "app_config" {
  name = var.ssm_parameter_name
}

output "vpc_id" {
  description = "Id of the VPC this configuration created."
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "Public subnet ids, keyed like var.public_subnets."
  value       = { for key, subnet in aws_subnet.public : key => subnet.id }
}

output "web_public_ips" {
  description = "Public IPs of the web servers."
  value       = aws_instance.web[*].public_ip
}

output "web_instance_ids" {
  description = "Instance IDs of the web servers."
  value       = aws_instance.web[*].id
}

output "security_group_id" {
  description = "Security group ID for web servers."
  value       = aws_security_group.web.id
}

output "artifact_bucket" {
  description = "Name of the optional bucket, or null when it was not created."
  value       = var.create_artifact_bucket ? aws_s3_bucket.artifacts[0].bucket : null
}

output "provider_target" {
  description = "Which endpoint this run actually talked to."
  value       = local.provider_target
}

output "app_config_value" {
  description = "Value read from SSM Parameter Store."
  value       = data.aws_ssm_parameter.app_config.value
  sensitive   = true
}
