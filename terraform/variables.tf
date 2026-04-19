variable "provider_choice" {
  description = "Which compute provider to use: do or hetzner"
  type        = string
  default     = "do"

  validation {
    condition     = contains(["do", "hetzner"], var.provider_choice)
    error_message = "provider_choice must be 'do' or 'hetzner'."
  }
}

# Shared
variable "ssh_key_name" {
  description = "Name of the SSH key in the active provider (assumed identical name in both)"
  type        = string
}

variable "username" {
  description = "Non-root user to create on the server"
  type        = string
  default     = "connor"
}

variable "ssh_port" {
  description = "Custom SSH port"
  type        = number
  default     = 2222
}

variable "repo_url" {
  description = "Git repo URL to clone on the server"
  type        = string
}

variable "domain" {
  description = "Domain name (always managed in DigitalOcean DNS)"
  type        = string
  default     = "cdavenport.io"
}

# DigitalOcean
variable "do_token" {
  description = "DigitalOcean API token (always required for DNS)"
  type        = string
  sensitive   = true
}

variable "do_region" {
  description = "DigitalOcean region slug"
  type        = string
  default     = "sfo3"
}

variable "do_size" {
  description = "DigitalOcean droplet size slug"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "do_image" {
  description = "DigitalOcean droplet image slug"
  type        = string
  default     = "ubuntu-24-04-x64"
}

# Hetzner
variable "hcloud_token" {
  description = "Hetzner Cloud API token (only required when provider_choice = hetzner)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "hetzner_location" {
  description = "Hetzner Cloud location code"
  type        = string
  default     = "hil"
}

variable "hetzner_server_type" {
  description = "Hetzner Cloud server type slug"
  type        = string
  default     = "cx22"
}

variable "hetzner_image" {
  description = "Hetzner Cloud image name"
  type        = string
  default     = "ubuntu-24.04"
}
