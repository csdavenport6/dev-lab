terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# The hcloud provider validates token format at configure time regardless of
# count, so a 64-char placeholder fills in when hcloud_token is unset. Real
# Hetzner API calls only happen when provider_choice = "hetzner".
provider "hcloud" {
  token = var.hcloud_token != "" ? var.hcloud_token : "placeholder-not-in-use-do-is-active-0000000000000000000000000000"
}

module "do" {
  source = "./modules/digitalocean"
  count  = var.provider_choice == "do" ? 1 : 0

  ssh_key_name    = var.ssh_key_name
  region          = var.do_region
  size            = var.do_size
  image           = var.do_image
  username        = var.username
  ssh_port        = var.ssh_port
  repo_url        = var.repo_url
  cloud_init_path = "${path.module}/cloud-init.yml.tpl"
}

module "hetzner" {
  source = "./modules/hetzner"
  count  = var.provider_choice == "hetzner" ? 1 : 0

  ssh_key_name    = var.ssh_key_name
  location        = var.hetzner_location
  server_type     = var.hetzner_server_type
  image           = var.hetzner_image
  username        = var.username
  ssh_port        = var.ssh_port
  repo_url        = var.repo_url
  cloud_init_path = "${path.module}/cloud-init.yml.tpl"
}

locals {
  server_ip = (
    var.provider_choice == "do"
    ? module.do[0].ipv4_address
    : module.hetzner[0].ipv4_address
  )
}

# DNS (always on DigitalOcean)
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
