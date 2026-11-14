output "deployment_enabled" {
  value       = var.deploy_enabled
  description = "False means validation mode: no SSH or server changes."
}

output "application_url" {
  value       = var.deploy_enabled && var.domain != null ? "https://${var.domain}" : null
  description = "Application address after a successful deployment."
}

output "release_id" {
  value       = local.release_id
  description = "Content/configuration identifier used for the release and Docker image."
}
