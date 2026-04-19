output "server_ip" {
  description = "Public IPv4 address of the server"
  value       = module.do.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -p ${var.ssh_port} ${var.username}@${module.do.ipv4_address}"
}
