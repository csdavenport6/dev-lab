output "ipv4_address" {
  description = "Public IPv4 address of the Hetzner server"
  value       = hcloud_server.web.ipv4_address
}
