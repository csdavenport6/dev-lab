terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

module "do" {
  source = "./modules/digitalocean"
  count  = var.provider_choice == "do" ? 1 : 0

  ssh_key_name    = var.ssh_key_name
  region          = var.droplet_region
  size            = var.droplet_size
  image           = var.droplet_image
  username        = var.username
  ssh_port        = var.ssh_port
  repo_url        = var.repo_url
  cloud_init_path = "${path.module}/cloud-init.yml.tpl"
}

locals {
  server_ip = var.provider_choice == "do" ? module.do[0].ipv4_address : null
}

# DNS (always on DigitalOcean, regardless of compute provider)
resource "digitalocean_domain" "main" {
  name       = var.domain
  ip_address = local.server_ip
}

resource "digitalocean_record" "www" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "www"
  value  = local.server_ip
  ttl    = 3600
}
