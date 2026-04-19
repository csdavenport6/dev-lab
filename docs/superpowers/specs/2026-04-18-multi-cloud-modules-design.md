# Multi-cloud Terraform modules (DO + Hetzner)

## Goal

Refactor the current single-file Terraform config into a module-based layout that supports both DigitalOcean and Hetzner Cloud as compute providers, selectable via a single root variable. Switching providers should be one variable change followed by `terraform apply`.

The DigitalOcean setup must continue to work exactly as it does today; Hetzner is added alongside, not as a replacement.

## Motivation

The user wants to:

1. Practice cloud-infra patterns by working with multiple providers in one repo.
2. Keep the option open to migrate to Hetzner later (~75% monthly cost reduction vs the current `s-1vcpu-2gb` droplet) without losing the working DO setup.
3. Be able to A/B between providers cleanly without two simultaneous deployments.

## Non-goals

- Running both providers' compute resources simultaneously (e.g. blue/green or multi-region HA).
- Live migration with zero downtime. Switching providers is destroy-and-recreate.
- Abstracting region/size/image into provider-neutral names. Slugs stay provider-native.
- Moving DNS off DigitalOcean.
- Adding any third compute provider.

## Architecture

### Repo layout

```
terraform/
├── main.tf              # provider flag, module calls, DNS, locals
├── variables.tf         # shared + provider-specific root vars
├── outputs.tf           # unified ssh_command, server_ip
├── cloud-init.yml.tpl   # shared, passed into whichever module is active
└── modules/
    ├── digitalocean/
    │   ├── main.tf      # provider block, droplet, firewall
    │   ├── variables.tf
    │   └── outputs.tf   # ipv4_address
    └── hetzner/
        ├── main.tf      # provider block, hcloud_server, hcloud_firewall
        ├── variables.tf
        └── outputs.tf   # ipv4_address
```

Each compute module exposes the same output contract: `ipv4_address`. The root config is the only place that knows which provider is active.

### Provider selection

Root variable `provider_choice` accepts `"do"` or `"hetzner"` (validated). Both modules are declared in the root, each gated by `count`:

```hcl
module "do" {
  source = "./modules/digitalocean"
  count  = var.provider_choice == "do" ? 1 : 0
  # shared + DO-specific vars
}

module "hetzner" {
  source = "./modules/hetzner"
  count  = var.provider_choice == "hetzner" ? 1 : 0
  # shared + Hetzner-specific vars
}

locals {
  server_ip = var.provider_choice == "do"
    ? module.do[0].ipv4_address
    : module.hetzner[0].ipv4_address
}
```

DNS records reference `local.server_ip` and are unaffected by which compute module is active.

### DNS

DNS stays on DigitalOcean (free, no compute required). DNS resources live in the root, not in either compute module:

- `digitalocean_domain.main` for `cdavenport.io`, pointed at `local.server_ip`.
- `digitalocean_record.www` (A record) pointed at `local.server_ip`.

This means `do_token` is always required, even when `provider_choice = "hetzner"`.

### Tokens

- `do_token` (sensitive, required): used by the DO provider for DNS, and by the DO compute module when active.
- `hcloud_token` (sensitive, default `""`): used by the Hetzner module when active. Empty default is acceptable because the hcloud provider lazy-validates; with `count = 0` no API calls are made.

### Cloud-init

`cloud-init.yml.tpl` lives at the root and is passed into the active compute module. Both modules render it identically via `templatefile()` with the same variables (`username`, `ssh_public_key`, `ssh_port`, `repo_url`).

## Variables

### Shared (root, passed into the active compute module)

| Name | Type | Default |
|---|---|---|
| `username` | string | `"connor"` |
| `ssh_port` | number | `2222` |
| `repo_url` | string | (no default, required) |
| `ssh_key_name` | string | (no default, required) |
| `domain` | string | `"cdavenport.io"` |

`ssh_key_name` is assumed to refer to the same logical key uploaded under the same name in both providers.

### Provider-specific (root, only used when matching module is active)

| Name | Type | Default |
|---|---|---|
| `provider_choice` | string | `"do"` (validated: `do`, `hetzner`) |
| `do_token` | string, sensitive | required |
| `do_region` | string | `"sfo3"` |
| `do_size` | string | `"s-1vcpu-2gb"` |
| `do_image` | string | `"ubuntu-24-04-x64"` |
| `hcloud_token` | string, sensitive | `""` |
| `hetzner_location` | string | `"hil"` |
| `hetzner_server_type` | string | `"cx22"` |
| `hetzner_image` | string | `"ubuntu-24.04"` |

Provider-prefixed names are intentional: slugs are not interchangeable across providers, and unifying them would either lie about the abstraction or require a hand-maintained translation map.

## Module contracts

### `modules/digitalocean`

Inputs: shared vars + `do_token`, `do_region`, `do_size`, `do_image`.
Resources: `digitalocean_droplet.web`, `digitalocean_firewall.web`. (DNS is NOT here, it lives at the root.)
Outputs: `ipv4_address` (string).

### `modules/hetzner`

Inputs: shared vars + `hcloud_token`, `hetzner_location`, `hetzner_server_type`, `hetzner_image`.
Resources: `hcloud_server.web`, `hcloud_firewall.web`. Firewall rules mirror the DO firewall (in: 22, ssh_port, 80, 443 from anywhere; out: default allow-all, since hcloud firewalls allow all egress when no egress rules are specified).
Outputs: `ipv4_address` (string).

## Outputs (root)

| Name | Value |
|---|---|
| `server_ip` | `local.server_ip` |
| `ssh_command` | `"ssh -p ${var.ssh_port} ${var.username}@${local.server_ip}"` |
| `active_provider` | `var.provider_choice` |

## Switching providers

1. Lower DNS TTL well in advance of the switch (current TTL is 3600s).
2. Update tfvars: change `provider_choice` and ensure the target provider's token is set.
3. `terraform apply`. Terraform will:
   - Destroy the active provider's compute + firewall.
   - Create the new provider's compute + firewall.
   - Update the DO DNS A records to the new IP.
4. Wait for DNS propagation.

This is a destroy-and-recreate with downtime and a new IP. Acceptable for a personal blog.

## Testing strategy

- `terraform validate` and `terraform plan` against both `provider_choice` values to verify both module paths produce a clean plan.
- `terraform apply` with `provider_choice = "do"` should produce a plan diff equivalent to the current setup (same resource shapes, same firewall rules, same DNS records). The current droplet should ideally be importable into the new module address (`module.do[0].digitalocean_droplet.web`) via `terraform state mv` to avoid a destroy-recreate during the refactor itself.
- `terraform apply` with `provider_choice = "hetzner"` from a clean state should produce a working server reachable on the configured SSH port, serving the blog after cloud-init completes.

## Risks and open questions

- **State migration during the refactor.** The existing droplet is currently at `digitalocean_droplet.web`; after the refactor it will be at `module.do[0].digitalocean_droplet.web`. The implementation plan must include `terraform state mv` commands so the live droplet is not destroyed during the refactor itself. Same applies to the firewall and DNS resources (DNS resources stay at root, so only the compute + firewall move).
- **`ssh_key_name` assumption.** Assumes the same key name in both providers. If the user uploads keys under different names, this needs to become two vars.
- **`hcloud_token = ""` default.** Relies on lazy validation by the hcloud provider. If a future provider version eagerly validates, the default would need to change.
