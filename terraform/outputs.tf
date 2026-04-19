output "server_ip" {
  description = "Public IPv4 address of the active server"
  value       = local.server_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -p ${var.ssh_port} ${var.username}@${local.server_ip}"
}

output "active_provider" {
  description = "Currently selected compute provider"
  value       = var.provider_choice
}
