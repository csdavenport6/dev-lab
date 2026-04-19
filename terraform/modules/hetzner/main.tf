terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

data "hcloud_ssh_key" "main" {
  name = var.ssh_key_name
}

resource "hcloud_firewall" "web" {
  name = "dev-lab-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(var.ssh_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "web" {
  name         = "dev-lab"
  image        = var.image
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [data.hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.web.id]

  user_data = templatefile(var.cloud_init_path, {
    username       = var.username
    ssh_public_key = data.hcloud_ssh_key.main.public_key
    ssh_port       = var.ssh_port
    repo_url       = var.repo_url
  })

  labels = {
    project = "dev-lab"
  }
}
