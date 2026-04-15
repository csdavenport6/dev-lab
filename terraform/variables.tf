variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name of the SSH key in DigitalOcean"
  type        = string
}

variable "droplet_region" {
  description = "DigitalOcean region slug"
  type        = string
  default     = "nyc1"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "droplet_image" {
  description = "DigitalOcean droplet image slug"
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "domain" {
  description = "Domain name"
  type        = string
  default     = "cdavenport.io"
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
