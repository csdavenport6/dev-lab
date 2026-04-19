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

  ssh_key_name    = var.ssh_key_name
  region          = var.droplet_region
  size            = var.droplet_size
  image           = var.droplet_image
  username        = var.username
  ssh_port        = var.ssh_port
  repo_url        = var.repo_url
  cloud_init_path = "${path.module}/cloud-init.yml.tpl"
}

# DNS
resource "digitalocean_domain" "main" {
  name       = var.domain
  ip_address = module.do.ipv4_address
}

resource "digitalocean_record" "www" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "www"
  value  = module.do.ipv4_address
  ttl    = 3600
}
