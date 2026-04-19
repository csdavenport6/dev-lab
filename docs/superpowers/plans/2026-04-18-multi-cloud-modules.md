# Multi-cloud Terraform Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the single-file Terraform config into DigitalOcean and Hetzner Cloud compute modules selectable via a single `provider_choice` root variable, with DNS staying on DigitalOcean at the root.

**Architecture:** Root config holds the provider flag, both module instantiations (each gated by `count`), DNS resources, and shared cloud-init. Each compute module declares its own provider requirements, takes the same shared vars (username, ssh_port, repo_url, ssh_key_name, cloud_init_path) plus provider-specific compute vars, and exposes a uniform `ipv4_address` output. The active module's IP feeds into root DNS via a local.

**Tech Stack:** Terraform >= 1.3, `digitalocean/digitalocean ~> 2.0`, `hetznercloud/hcloud ~> 1.48`, cloud-init (Ubuntu 24.04).

**Spec:** [docs/superpowers/specs/2026-04-18-multi-cloud-modules-design.md](../specs/2026-04-18-multi-cloud-modules-design.md)

---

## Notes for the engineer

- "Tests" for Terraform here means `terraform fmt -check`, `terraform validate`, and `terraform plan` with expected output. There is no `pytest` equivalent. The most important verification is "plan shows no changes after a refactor". That is how we prove the refactor is behavior-preserving.
- The current setup has a live DigitalOcean droplet running `cdavenport.io`. **Do not destroy and recreate it.** State migrations (`terraform state mv`) are how we keep the live droplet attached as we move resources into modules.
- Run all `terraform` commands from the `terraform/` directory.
- The user has DO and (eventually) Hetzner credentials in environment vars / tfvars. Tasks that need `terraform plan` or `terraform apply` against real providers assume `do_token` is set in `terraform.tfvars` (already exists). For the Hetzner verification step, `hcloud_token` will need to be provided.
- **Style:** match the existing style of the Terraform files (2-space indent, no trailing commas in HCL, lowercase resource names). Run `terraform fmt` before committing.
- **No em or en dashes** anywhere in code, commit messages, or docs. Plain hyphens only. A hook enforces this on writes.

---

## File Structure

After this plan completes, the layout is:

```
terraform/
├── main.tf                  # MODIFIED: provider flag, module calls, DNS, locals
├── variables.tf             # MODIFIED: shared + prefixed provider-specific vars
├── outputs.tf               # MODIFIED: server_ip, ssh_command, active_provider
├── cloud-init.yml.tpl       # UNCHANGED
└── modules/
    ├── digitalocean/
    │   ├── main.tf          # CREATED: ssh_key data, droplet, firewall, required_providers
    │   ├── variables.tf     # CREATED
    │   └── outputs.tf       # CREATED: ipv4_address
    └── hetzner/
        ├── main.tf          # CREATED: ssh_key data, hcloud_server, hcloud_firewall, required_providers
        ├── variables.tf     # CREATED
        └── outputs.tf       # CREATED: ipv4_address
```

---

## Task 1: Extract DigitalOcean compute into a module (no behavior change)

**Goal:** Move the existing droplet, firewall, and SSH key data source into `modules/digitalocean/` and call the module from root. DNS stays at root. State migration keeps the live droplet attached.

**Files:**
- Create: `terraform/modules/digitalocean/main.tf`
- Create: `terraform/modules/digitalocean/variables.tf`
- Create: `terraform/modules/digitalocean/outputs.tf`
- Modify: `terraform/main.tf`
- Modify: `terraform/outputs.tf`

- [ ] **Step 1: Create `terraform/modules/digitalocean/variables.tf`**

```hcl
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
```

- [ ] **Step 2: Create `terraform/modules/digitalocean/main.tf`**

```hcl
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

data "digitalocean_ssh_key" "main" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "web" {
  name     = "dev-lab"
  image    = var.image
  size     = var.size
  region   = var.region
  ssh_keys = [data.digitalocean_ssh_key.main.id]

  user_data = templatefile(var.cloud_init_path, {
    username       = var.username
    ssh_public_key = data.digitalocean_ssh_key.main.public_key
    ssh_port       = var.ssh_port
    repo_url       = var.repo_url
  })

  tags = ["dev-lab"]
}

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
```

- [ ] **Step 3: Create `terraform/modules/digitalocean/outputs.tf`**

```hcl
output "ipv4_address" {
  description = "Public IPv4 address of the droplet"
  value       = digitalocean_droplet.web.ipv4_address
}
```

- [ ] **Step 4: Rewrite `terraform/main.tf` to call the module and keep DNS at root**

Replace the entire file with:

```hcl
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
```

Variables stay in `variables.tf` for now. Task 2 will add `provider_choice` and rename them.

- [ ] **Step 5: Update `terraform/outputs.tf`**

Replace the entire file with:

```hcl
output "server_ip" {
  description = "Public IPv4 address of the server"
  value       = module.do.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -p ${var.ssh_port} ${var.username}@${module.do.ipv4_address}"
}
```

- [ ] **Step 6: Format and validate**

Run:
```bash
cd terraform && terraform fmt -recursive && terraform init -upgrade && terraform validate
```

Expected: `terraform fmt` may rewrite spacing (fine). `terraform init` re-initializes including the new module. `terraform validate` reports `Success! The configuration is valid.`

- [ ] **Step 7: Move state for the droplet, firewall, and ssh key data**

Run, one at a time:
```bash
cd terraform
terraform state mv digitalocean_droplet.web module.do.digitalocean_droplet.web
terraform state mv digitalocean_firewall.web module.do.digitalocean_firewall.web
terraform state mv data.digitalocean_ssh_key.main module.do.data.digitalocean_ssh_key.main
```

Expected output for each: `Move "X" to "Y" Successfully moved 1 object(s).`

- [ ] **Step 8: Verify `terraform plan` shows no changes**

Run:
```bash
cd terraform && terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

If you see a diff, **stop and investigate** before applying. Most likely cause is a typo in module variable wiring. Compare the `module.do` block against the original root resources field by field. The droplet's `name`, `image`, `size`, `region`, `ssh_keys`, `user_data`, and `tags` should all be identical; same for firewall rules.

- [ ] **Step 9: Commit**

```bash
cd terraform
git add modules/digitalocean main.tf outputs.tf
git commit -m "$(cat <<'EOF'
refactor(terraform): extract DigitalOcean compute into a module

Move droplet, firewall, and SSH key data source into
modules/digitalocean/. DNS stays at root. State migration via
terraform state mv keeps the live droplet attached.

Behavior-preserving: terraform plan shows no changes.
EOF
)"
```

---

## Task 2: Add provider_choice flag and gate the DO module with count

**Goal:** Introduce `var.provider_choice` (default `"do"`), add `count = var.provider_choice == "do" ? 1 : 0` to the DO module, and rewire root references through a `local.server_ip`. State moves from `module.do.*` to `module.do[0].*`. Default behavior unchanged.

**Files:**
- Modify: `terraform/main.tf`
- Modify: `terraform/variables.tf`
- Modify: `terraform/outputs.tf`

- [ ] **Step 1: Add `provider_choice` variable to `terraform/variables.tf`**

Insert at the top of the file (above `do_token`):

```hcl
variable "provider_choice" {
  description = "Which compute provider to use: do or hetzner"
  type        = string
  default     = "do"

  validation {
    condition     = contains(["do", "hetzner"], var.provider_choice)
    error_message = "provider_choice must be 'do' or 'hetzner'."
  }
}
```

Leave the existing variables (`do_token`, `ssh_key_name`, `droplet_region`, `droplet_size`, `droplet_image`, `domain`, `username`, `ssh_port`, `repo_url`) unchanged. Task 3 will rename `droplet_*` to `do_*` for symmetry; we do that with the Hetzner additions to keep this task focused.

- [ ] **Step 2: Update `terraform/main.tf` to gate the DO module with count and introduce a local for the active server IP**

Replace the entire file with:

```hcl
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
```

The `null` branch for `local.server_ip` is a placeholder. Task 3 will replace it with `module.hetzner[0].ipv4_address`.

- [ ] **Step 3: Update `terraform/outputs.tf` to use the local**

Replace the entire file with:

```hcl
output "server_ip" {
  description = "Public IPv4 address of the active server"
  value       = local.server_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -p ${var.ssh_port} ${var.username}@${local.server_ip}"
}

output "active_provider" {
  description = "Currently selected compute provider"
  value       = var.provider_choice
}
```

- [ ] **Step 4: Format and validate**

Run:
```bash
cd terraform && terraform fmt -recursive && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Move state from `module.do.*` to `module.do[0].*`**

Run, one at a time:
```bash
cd terraform
terraform state mv 'module.do.digitalocean_droplet.web' 'module.do[0].digitalocean_droplet.web'
terraform state mv 'module.do.digitalocean_firewall.web' 'module.do[0].digitalocean_firewall.web'
terraform state mv 'module.do.data.digitalocean_ssh_key.main' 'module.do[0].data.digitalocean_ssh_key.main'
```

Expected: `Successfully moved 1 object(s).` for each.

**Note on quoting:** Single quotes around the addresses are required, since `[0]` is interpreted by the shell otherwise. Fish shell users: single quotes work the same way.

- [ ] **Step 6: Verify `terraform plan` shows no changes**

Run:
```bash
cd terraform && terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 7: Commit**

```bash
cd terraform
git add main.tf variables.tf outputs.tf
git commit -m "$(cat <<'EOF'
feat(terraform): add provider_choice flag, gate DO module with count

provider_choice (default 'do') selects which compute module is active.
local.server_ip resolves to the active module's IPv4 and feeds DNS.
State moved to indexed module addresses. No behavior change at default.
EOF
)"
```

---

## Task 3: Add the Hetzner module and wire it into root

**Goal:** Create `modules/hetzner/`, add Hetzner-related root vars, instantiate the Hetzner module gated by count, and rename `droplet_*` vars to `do_*` for symmetry. After this task, `provider_choice = "hetzner"` produces a valid plan that destroys DO compute and creates Hetzner compute.

**Files:**
- Create: `terraform/modules/hetzner/main.tf`
- Create: `terraform/modules/hetzner/variables.tf`
- Create: `terraform/modules/hetzner/outputs.tf`
- Modify: `terraform/main.tf`
- Modify: `terraform/variables.tf`

- [ ] **Step 1: Create `terraform/modules/hetzner/variables.tf`**

```hcl
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
```

- [ ] **Step 2: Create `terraform/modules/hetzner/main.tf`**

```hcl
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
```

- [ ] **Step 3: Create `terraform/modules/hetzner/outputs.tf`**

```hcl
output "ipv4_address" {
  description = "Public IPv4 address of the Hetzner server"
  value       = hcloud_server.web.ipv4_address
}
```

- [ ] **Step 4: Update `terraform/variables.tf` to rename DO vars and add Hetzner vars**

Replace the entire file with:

```hcl
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
```

- [ ] **Step 5: Update `terraform/main.tf` to add the hcloud provider, the Hetzner module call, and wire `local.server_ip`**

Replace the entire file with:

```hcl
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

provider "hcloud" {
  token = var.hcloud_token
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
```

- [ ] **Step 6: Init, format, validate**

Run:
```bash
cd terraform && terraform init -upgrade && terraform fmt -recursive && terraform validate
```

Expected: `terraform init` downloads `hetznercloud/hcloud`. `terraform validate` reports `Success!`.

- [ ] **Step 7: Verify `terraform plan` (default `provider_choice = "do"`) still shows no changes**

Run:
```bash
cd terraform && terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

The renamed variables (`droplet_region` becomes `do_region`, etc.) are wired through the module by their internal names (`region`, `size`, `image`), so the values reaching the droplet are identical and there should be no diff.

If `terraform.tfvars` references the old variable names (`droplet_region`, `droplet_size`, `droplet_image`), you will see warnings about undefined variables. Update `terraform.tfvars` to use the new names (`do_region`, `do_size`, `do_image`).

- [ ] **Step 8: Commit**

```bash
cd terraform
git add modules/hetzner main.tf variables.tf
git commit -m "$(cat <<'EOF'
feat(terraform): add Hetzner Cloud compute module

modules/hetzner/ mirrors the DO module's contract: same shared vars,
same ipv4_address output, equivalent firewall rules. Root wires both
modules through local.server_ip; provider_choice picks one.

DO vars renamed droplet_* to do_* for symmetry with hetzner_*.
hcloud_token defaults to "" (lazy validation; only used when active).
EOF
)"
```

---

## Task 4: Verify the Hetzner plan is well-formed

**Goal:** Confirm that flipping `provider_choice` to `"hetzner"` produces a sensible plan. Do NOT apply.

**Files:** None modified.

- [ ] **Step 1: Run a dry-run plan with `provider_choice = "hetzner"`**

If you do not have an `hcloud_token` available, request one from the user before running this step. Then:

```bash
cd terraform && terraform plan -var="provider_choice=hetzner" -var="hcloud_token=$HCLOUD_TOKEN"
```

Expected diff:
- `module.do[0].digitalocean_droplet.web` destroy
- `module.do[0].digitalocean_firewall.web` destroy
- `module.do[0].data.digitalocean_ssh_key.main` read
- `module.hetzner[0].data.hcloud_ssh_key.main` read
- `module.hetzner[0].hcloud_firewall.web` create
- `module.hetzner[0].hcloud_server.web` create
- `digitalocean_domain.main` update in place (ip_address change)
- `digitalocean_record.www` update in place (value change)

Plan summary should report something like `Plan: 2 to add, 2 to change, 2 to destroy.`

- [ ] **Step 2: Stop here. Do NOT apply.**

The user will decide if and when to actually switch providers. The verification above proves the configuration is valid and the switching mechanism works.

If the plan errors with `Error: ssh key not found` for Hetzner, that means the SSH key has not been uploaded to Hetzner under the same name as in DO. Pause and ask the user to upload it (Hetzner Cloud Console, Security, SSH Keys), or to provide a different `ssh_key_name`.

- [ ] **Step 3: No commit needed for this task** (verification only).

---

## Manual verification after the plan completes

After all tasks are done, sanity-check from the user's machine:

1. `terraform plan` returns "No changes" (DO is the live, active provider).
2. `terraform plan -var="provider_choice=hetzner" -var="hcloud_token=..."` returns the expected diff above.
3. `cdavenport.io` still resolves to the live droplet IP and serves the blog.
4. SSH still works on the configured port.

---

## Risks and gotchas (lifted from the spec, repeated here for the implementer)

- **State migration during the refactor.** Tasks 1 and 2 use `terraform state mv`. Verify each move with `terraform plan` showing "No changes" before proceeding. If you ever see destroy/recreate planned for the live droplet, **stop**.
- **`ssh_key_name` is shared across providers.** If the user has different key names in DO vs Hetzner, Task 4 will fail at plan time. Surface the error to the user; they may want a separate `ssh_key_name` per provider.
- **`hcloud_token = ""` default.** Relies on lazy validation. Currently safe with `hcloud ~> 1.48`. If a future version eagerly validates, the default may need to change to `null` with `nullable = false` on the var, plus a precondition.
- **`tfvars` file may need updates.** Renaming `droplet_*` to `do_*` (Task 3) will break any existing `terraform.tfvars` that uses the old names. Update those references.
