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

data "digitalocean_ssh_key" "main" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "web" {
  name     = "dev-lab"
  image    = var.droplet_image
  size     = var.droplet_size
  region   = var.droplet_region
  ssh_keys = [data.digitalocean_ssh_key.main.id]

  user_data = templatefile("${path.module}/cloud-init.yml.tpl", {
    username       = var.username
    ssh_public_key = data.digitalocean_ssh_key.main.public_key
    ssh_port       = var.ssh_port
    repo_url       = var.repo_url
  })

  tags = ["dev-lab"]
}

# DNS
resource "digitalocean_domain" "main" {
  name       = var.domain
  ip_address = digitalocean_droplet.web.ipv4_address
}

resource "digitalocean_record" "www" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "www"
  value  = digitalocean_droplet.web.ipv4_address
  ttl    = 3600
}

# Cloud firewall
resource "digitalocean_firewall" "web" {
  name        = "dev-lab-firewall"
  droplet_ids = [digitalocean_droplet.web.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.ssh_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
