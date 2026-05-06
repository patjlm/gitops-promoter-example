output "environment" {
  description = "The deployment environment"
  value       = var.environment
}

output "region" {
  description = "The cloud region"
  value       = var.region
}

output "instance_count" {
  description = "Number of compute instances"
  value       = var.instance_count
}
