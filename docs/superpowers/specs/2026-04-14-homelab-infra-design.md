# Homelab Infrastructure & Personal Blog — Design Spec

## Overview

A reproducible, infrastructure-as-code setup for a DigitalOcean droplet serving a personal blog at `cdavenport.io`. The system is fully defined in code: Terraform provisions the cloud resources, cloud-init configures the server on first boot, and Docker Compose runs the application stack.

The goal is a setup where `terraform destroy && terraform apply` rebuilds everything from scratch with no manual steps beyond changing nameservers at Squarespace (a one-time operation).

## Architecture

Two layers, both managed in this repo:

1. **Infrastructure layer (Terraform)** — Provisions the DO droplet, DO cloud firewall, and DO DNS records for `cdavenport.io`.
2. **Server configuration layer (cloud-init)** — A template rendered by Terraform and passed to the droplet at creation. Handles all first-boot setup: user creation, SSH hardening, firewall, Docker installation, and starting the application stack.

### Application Stack (Docker Compose)

Two containers on a shared Docker network:

- **Caddy** — Reverse proxy. Automatic HTTPS via Let's Encrypt. Redirects HTTP to HTTPS. Proxies requests to the Go blog container.
- **Go blog** — HTTP server that reads markdown files, renders them to HTML via Go templates, and serves the result.

## Repository Structure

```
dev-lab/
├── terraform/
│   ├── main.tf            # DO provider, droplet, DNS, firewall resources
│   ├── variables.tf        # Droplet size, region, domain, SSH key fingerprint
│   ├── outputs.tf          # Droplet IP, domain info
│   └── cloud-init.yml.tpl  # Cloud-init template (rendered by Terraform)
├── blog/
│   ├── Dockerfile          # Multi-stage build: Go build → minimal runtime image
│   ├── main.go             # HTTP server, markdown rendering, routing
│   ├── posts/              # Markdown blog posts with frontmatter
│   ├── templates/          # Go html/template files (layout, post list, post detail)
│   └── static/             # CSS
├── docker-compose.yml      # Caddy + blog service definitions
├── Caddyfile               # Caddy reverse proxy configuration
└── docs/
    └── superpowers/
        └── specs/
            └── this file
```

## Terraform Resources

### Provider

- `digitalocean` provider, authenticated via `DIGITALOCEAN_TOKEN` environment variable.

### Resources

| Resource | Purpose |
|---|---|
| `digitalocean_droplet` | The server. Basic tier, Ubuntu LTS. cloud-init template attached via `user_data`. |
| `digitalocean_domain` | Registers `cdavenport.io` as a DO-managed domain. |
| `digitalocean_record` (A) | Points `cdavenport.io` to the droplet's IPv4 address. |
| `digitalocean_record` (A, www) | Points `www.cdavenport.io` to the droplet's IPv4 address. |
| `digitalocean_firewall` | Cloud-level firewall (see Firewall section). |

### Variables

| Variable | Description | Default |
|---|---|---|
| `do_token` | DigitalOcean API token | (none, required) |
| `ssh_key_fingerprint` | Fingerprint of SSH key already added to DO | (none, required) |
| `droplet_region` | DO region slug | `nyc1` (or nearest) |
| `droplet_size` | DO droplet size slug | `s-1vcpu-1gb` (basic tier) |
| `droplet_image` | OS image | `ubuntu-24-04-x64` |
| `domain` | Domain name | `cdavenport.io` |
| `username` | Non-root user to create | `connor` |

### Outputs

- Droplet IPv4 address
- Domain name
- SSH command for quick access

## DNS

- Terraform creates DO DNS zone and records.
- One-time manual step: change nameservers at Squarespace to `ns1.digitalocean.com`, `ns2.digitalocean.com`, `ns3.digitalocean.com`.
- A records for both `cdavenport.io` and `www.cdavenport.io` point to the droplet IP.

## Server Hardening (cloud-init)

All hardening happens automatically on first boot via cloud-init. No manual SSH required.

### SSH

- Create non-root user (`connor`) with sudo access.
- Copy SSH public key to new user's `~/.ssh/authorized_keys`.
- Disable root SSH login (`PermitRootLogin no`).
- Disable password authentication (`PasswordAuthentication no`).
- Change SSH port to `2222` to reduce bot noise.

### Firewall (UFW)

- Default deny incoming, allow outgoing.
- Allow port `2222` (SSH).
- Allow port `80` (HTTP — needed for Caddy's ACME challenge and redirect).
- Allow port `443` (HTTPS).

### DigitalOcean Cloud Firewall (Terraform)

Mirrors UFW rules at the network level. Defense in depth — traffic blocked before it reaches the droplet.

| Direction | Port | Source/Dest |
|---|---|---|
| Inbound | 2222 | 0.0.0.0/0 |
| Inbound | 80 | 0.0.0.0/0 |
| Inbound | 443 | 0.0.0.0/0 |
| Outbound | All | 0.0.0.0/0 |

### Fail2ban

- Installed via cloud-init.
- Configured to monitor SSH on port `2222`.
- Bans IPs after repeated failed authentication attempts.

### Automatic Security Updates

- `unattended-upgrades` enabled for security patches.

### Docker

- Docker and Docker Compose installed via cloud-init.
- User `connor` added to `docker` group.
- No `--privileged` containers.
- Application containers run as non-root users where possible.

## Caddy Configuration

```
cdavenport.io {
    reverse_proxy blog:8080
}

www.cdavenport.io {
    redir https://cdavenport.io{uri} permanent
}
```

- Automatic Let's Encrypt certificate provisioning.
- Automatic certificate renewal (well before 90-day expiry).
- HTTP to HTTPS redirect is default Caddy behavior.
- `www` subdomain redirects to apex domain.

## Go Blog Application

### Routes

| Route | Handler |
|---|---|
| `GET /` | List all posts, sorted by date descending. |
| `GET /posts/{slug}` | Render a single post by slug. |

### Markdown Posts

Posts live in `blog/posts/` as `.md` files with YAML frontmatter:

```markdown
---
title: "Post Title"
date: 2026-04-14
tags: ["go", "homelab"]
slug: "post-title"
---

Post content in markdown.
```

### Rendering Pipeline

1. Read `.md` files from `posts/` directory.
2. Parse YAML frontmatter for metadata (title, date, tags, slug).
3. Convert markdown body to HTML using `goldmark`.
4. Wrap in Go `html/template` templates.

### Templates

- `layout.html` — Base layout (head, nav, footer).
- `index.html` — Post listing page.
- `post.html` — Single post page.

### Static Assets

- CSS served from `blog/static/`.
- Embedded in the binary via Go's `embed` package for a single-artifact deploy.

### Docker Image

Multi-stage build:

1. **Build stage:** `golang:1.22-alpine` — compile the binary.
2. **Runtime stage:** `alpine:latest` — copy binary, expose port 8080, run as non-root user.

Keeps the final image small (important on a resource-constrained droplet).

## Docker Compose

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      blog:
        condition: service_healthy

  blog:
    build: ./blog
    restart: unless-stopped
    expose:
      - "8080"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s

volumes:
  caddy_data:
  caddy_config:
```

`caddy_data` persists certificates across container restarts.

## Deployment Flow

### Initial Deploy (from zero)

1. Set `DIGITALOCEAN_TOKEN` environment variable.
2. `terraform init` then `terraform apply` in the `terraform/` directory.
3. Cloud-init runs: hardens server, installs Docker, clones the git repo, and starts the stack through the shared deployment script.
4. Caddy provisions TLS certificate on first HTTPS request.
5. Blog is live at `https://cdavenport.io`.

### Updating Blog Content

1. Commit new markdown post to repo, push to remote.
2. GitHub Actions runs the blog test suite and Docker build on push to `main`.
3. If verification passes, the workflow SSHes to the droplet and runs `./scripts/deploy.sh`.
4. The deploy completes only after Docker Compose reports the stack healthy.

### Full Rebuild

`terraform destroy` then `terraform apply` recreates everything. Blog posts are safe in git. The only state on the server that matters is Caddy's TLS certificates, which it re-provisions automatically.

## Accepted Tradeoffs

- **No config drift management.** Cloud-init runs once at creation. Manual SSH changes are not tracked or reverted. If drift becomes a problem, Ansible can be layered on later.
- **Single-environment deploys only.** The workflow targets production directly on `main`; there is no staging environment yet.
- **No monitoring or alerting.** Out of scope for v1. Can add later (DO monitoring, or something self-hosted like Uptime Kuma).
- **No backup strategy.** Blog content is in git. Droplet state is fully reproducible. No database to back up.

## Out of Scope

- Monitoring / alerting
- Database
- Admin interface / CMS
- JavaScript / client-side interactivity
- Multiple environments (staging/prod)
