variable "ssh_key_name" {
  description = "Name of the SSH key uploaded to Hetzner Cloud"
  type        = string
}

variable "location" {
  description = "Hetzner Cloud location code (e.g. hil for Hillsboro OR)"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type slug (e.g. cx22)"
  type        = string
}

variable "image" {
  description = "Hetzner image name (e.g. ubuntu-24.04)"
  type        = string
}

variable "username" {
  description = "Non-root user to create on the server"
  type        = string
}

variable "ssh_port" {
  description = "Custom SSH port"
  type        = number
}

variable "repo_url" {
  description = "Git repo URL to clone on the server"
  type        = string
}

variable "cloud_init_path" {
  description = "Absolute path to the cloud-init template"
  type        = string
}
