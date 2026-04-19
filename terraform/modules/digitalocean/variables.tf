variable "ssh_key_name" {
  description = "Name of the SSH key in DigitalOcean"
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug"
  type        = string
}

variable "size" {
  description = "DigitalOcean droplet size slug"
  type        = string
}

variable "image" {
  description = "DigitalOcean droplet image slug"
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
