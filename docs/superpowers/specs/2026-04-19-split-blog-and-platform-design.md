# Split the blog into its own repo; turn dev-lab into a multi-app platform

## Overview

Today `dev-lab` mixes infrastructure (Terraform, Caddy, docker-compose, cloud-init) with a single application (the Go blog). Application and infrastructure live in one repo, the droplet builds the Go binary from source at deploy time, and the GitHub Actions deploy job SSHes into the droplet with a repo-scoped SSH key.

This design splits the blog into its own repository, makes `dev-lab` into an infrastructure-and-platform repo that can host N applications, and replaces per-repo SSH deploy keys with a deploy-webhook receiver running on the droplet. Application repositories no longer hold shell-level credentials to the server; they only hold a narrow per-app HMAC token that can trigger one scoped redeploy.

## Motivation

The user wants:

1. **Future apps (B).** Plan to add more services over time (additional sites, small APIs, tools). Infra should be a platform the apps plug into, not a monorepo of applications.
2. **Portability (C).** The blog should be independently deployable - its repository should contain everything needed to build and ship it, with no dependency on `dev-lab` internals.
3. **Practice cloud-infra patterns.** The deploy-webhook receiver is a real small-ops pattern; building it fits the skills-practice goal from the homelab project context.
4. **Reduced blast radius.** Today every app that auto-deploys needs a full SSH key to the droplet. That does not scale safely as app count grows.

## Non-goals

- Zero-downtime rolling deploys. The blog restart today already has a brief gap; acceptable.
- Multi-environment (staging + prod). Production-on-main stays as today.
- Moving posts content out of the blog repo into a separate content store. Posts stay in the blog repo and are baked into the published image.
- Automated Terraform apply from CI. Terraform stays manual-from-laptop with 1Password-sourced tokens.
- GitOps frameworks (Flux, ArgoCD) or container orchestrators (Kubernetes, Nomad). Overkill for homelab.
- Observability/alerting for the webhook service. Deferred.

## Architecture

### Two repositories

**`cdavenport.io` (new, extracted from current `blog/`)** is the portable blog application. It owns the Go service, templates, static assets, posts, Dockerfile, and its own CI workflow. On push to `main`, CI tests, builds, pushes an image to GHCR, and POSTs to a deploy hook. The repo knows nothing about SSH, the droplet, or Terraform.

**`dev-lab` (this repository, slimmed)** is infrastructure plus platform. It owns Terraform, the Caddy site config, the compose file that wires services together, the deploy-webhook configuration, and the cloud-init template. It does not contain any application source code. Adding application N+1 is a local change in this repo: one service block in compose, one site block in Caddy, one hook entry in the webhook config.

### Application image pipeline

The blog repo's CI publishes images to `ghcr.io/csdavenport6/cdavenport.io`:

- `:latest` - floating tag consumed by the running compose stack.
- `:sha-<7>` - immutable per-commit tag for pinned rollback.

Image visibility is **public**. No server-side registry auth is needed, no PAT rotation, and the source is already public. The benefit of private images does not justify the plumbing for a homelab personal blog.

### Deploy webhook receiver

On the droplet, `adnanh/webhook` runs as a service inside the main compose file, exposed via Caddy at `deploy.cdavenport.io` (TLS provisioned by Caddy, new A record added in Terraform).

Per-app hook configuration lives in `webhook/hooks.yml`. Each hook:

- Authenticates the request with `payload-hmac-sha256` using a per-app secret injected from an env file.
- Executes a single, allowlisted shell script with the service name baked in.
- Cannot invoke arbitrary commands; the trigger rule only matches on signature.

The webhook container needs `/var/run/docker.sock` mounted to run `docker compose` against host state, and the dev-lab checkout mounted so it can `git pull` for infra updates. This is privileged; the mitigation is that hook commands are restricted to two vetted scripts (`redeploy-app.sh`, `redeploy-stack.sh`) that cannot be parameterised beyond a service name.

Because `almir/webhook` is a minimal base image, a thin `webhook/Dockerfile` layers `docker-ce-cli`, `docker-compose-plugin`, and `git` on top so the scripts can actually invoke compose and pull. The compose service builds from that Dockerfile rather than using an upstream image directly.

An app-repo CI step computes an HMAC of an empty body with its per-app token and POSTs to `https://deploy.cdavenport.io/hooks/<app-id>`. Blast radius of a leaked token: one redeploy of one app using whatever image is currently `:latest`. No shell access, no cross-app access, no infrastructure access.

The webhook also owns an `infra` hook that runs `git pull --ff-only && docker compose up -d --wait` for infra-side changes (compose edits, Caddy edits, new-app onboarding).

### Server-side stack

```yaml
# compose/docker-compose.yml (conceptual - final form written during implementation)
services:
  caddy:
    image: caddy:2-alpine
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [blog, webhook]

  blog:
    image: ghcr.io/csdavenport6/cdavenport.io:latest
    restart: unless-stopped
    expose: ["8080"]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s

  webhook:
    image: almir/webhook:latest
    restart: unless-stopped
    expose: ["9000"]
    volumes:
      - ./webhook/hooks.yml:/etc/webhook/hooks.yml:ro
      - ./webhook/scripts:/scripts:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/workspace:rw
    env_file: /etc/dev-lab/webhook.env
    working_dir: /workspace
    command: ["-hooks=/etc/webhook/hooks.yml", "-verbose"]

volumes:
  caddy_data:
  caddy_config:
```

```
# compose/Caddyfile
deploy.cdavenport.io {
    reverse_proxy webhook:9000
}

cdavenport.io {
    reverse_proxy blog:8080
}

www.cdavenport.io {
    redir https://cdavenport.io{uri} permanent
}
```

### Deploy flows

**Blog change.** Push to `cdavenport.io` `main` -> CI runs `go test ./...` -> build image -> push `:latest` and `:sha-<7>` to GHCR -> `curl` signed POST to `/hooks/blog` -> webhook runs `redeploy-app.sh blog` -> `docker compose pull blog && docker compose up -d --wait blog`.

**Infra change (compose/Caddy edits).** Push to `dev-lab` `main` -> CI runs `terraform validate` and any other lightweight checks -> signed POST to `/hooks/infra` -> webhook runs `redeploy-stack.sh` -> `git pull --ff-only origin main && docker compose up -d --wait`.

**Terraform change.** Manual `terraform apply` from laptop with 1Password-sourced tokens. No CI automation: blast radius too large to justify.

**Onboarding app #2.** In the new app's repo: copy the blog repo's CI workflow, generate a new HMAC secret. In `dev-lab`: add a service block to compose, a Caddy site block (new subdomain or path), a hook entry to `hooks.yml`, and the secret to `webhook.env` (and to 1Password). Push to `dev-lab` -> infra hook redeploys the stack with the new service defined. First CI run of the new app pushes an image and triggers its own hook.

### Local development

The common path is `go run .` in the blog repo. The blog service embeds templates and static assets via `//go:embed` and reads posts from the local `posts/` directory, so no Docker is required for day-to-day authoring.

For full-stack local testing (Caddy + blog together), two options:

- `compose.dev.yml` inside the blog repo spins up blog + a local Caddy for e2e tests. Self-contained, fits the portability goal.
- For testing `dev-lab` Caddy/compose changes against uncommitted blog code, the infra repo ships a `compose.override.yml.example` showing how to swap `image:` for `build: ../cdavenport.io`. Users check out both repos side-by-side.

### Cloud-init changes

`cloud-init.yml.tpl` stops needing Go tooling. It still clones `dev-lab` (for infra state) and runs `scripts/deploy.sh`. The deploy script no longer builds anything locally - `docker compose up --wait` pulls the blog image from GHCR during first boot. Adds a step to create `/etc/dev-lab/webhook.env` with root-owned 600 perms from a Terraform-rendered secret file (or prompts the operator to populate it out-of-band).

### Secret management

- **Per-app webhook HMAC secrets.** Stored canonically in 1Password. Applied to the server at provisioning time in `/etc/dev-lab/webhook.env`. Applied to each app repo as a GH Actions secret named `DEPLOY_HOOK_SECRET`.
- **SSH keys.** Removed from all app repo secret stores. The operator (Connor) keeps a personal SSH key for recovery. The `dev-lab` repo itself removes its `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER` secrets once the infra hook is in place.
- **DigitalOcean / Hetzner tokens.** Unchanged. Read from 1Password at `terraform apply` time.

## Migration plan (high-level)

Each step is individually reversible and leaves the site live.

1. **Extract blog history.** `git filter-repo --subdirectory-filter blog` in a fresh clone of `dev-lab`. Push to new `csdavenport6/cdavenport.io` repo.
2. **Bootstrap blog CI.** Add CI on a non-main branch; verify an image lands in GHCR as `ghcr.io/csdavenport6/cdavenport.io:sha-<7>`.
3. **Add webhook service to dev-lab.** Edit compose, Caddyfile, add `webhook/` directory with `hooks.yml` and scripts. Add `deploy.cdavenport.io` A record to Terraform. Deploy via the existing SSH flow. Verify the endpoint responds and auth rejects unsigned requests.
4. **Switch blog service to GHCR image.** Change `docker-compose.yml` to pull `ghcr.io/csdavenport6/cdavenport.io:latest` instead of building `./blog/`. Deploy via SSH. Verify the site serves from the GHCR image.
5. **Enable blog auto-deploy via hook.** Flip blog repo CI to main-branch and add the signed-POST step. Push a trivial change; verify end-to-end.
6. **Delete `blog/` from dev-lab.** Along with the associated CI job fragments (Go test + docker build of `./blog`). Main branch now has no Go source.
7. **Enable infra hook.** Move `dev-lab` CI from SSH to signed POST to `/hooks/infra`. Verify by pushing an infra change.
8. **Remove SSH deploy secrets.** Delete `DEPLOY_SSH_KEY`/`DEPLOY_HOST`/etc from both repos. Confirm CI still works end-to-end without them.

Rollback plan: for an unhealthy blog deploy, retag a known-good `:sha-*` image as `:latest` in GHCR and POST to the blog hook. For an unhealthy infra deploy, revert the commit in `dev-lab` and POST to the infra hook.

## Repository structure (target)

**`cdavenport.io`**

```
cdavenport.io/
|-- .github/
|   `-- workflows/
|       `-- ci.yml
|-- Dockerfile
|-- go.mod
|-- go.sum
|-- main.go
|-- handler.go
|-- post.go
|-- handler_test.go
|-- post_test.go
|-- templates/
|-- static/
|-- posts/
|-- testdata/
|-- compose.dev.yml
`-- README.md
```

**`dev-lab`** (flat structure retained; compose and Caddy files stay at repo root to keep cloud-init and existing scripts working with minimal path churn)

```
dev-lab/
|-- .github/
|   `-- workflows/
|       `-- ci.yml
|-- terraform/
|   |-- main.tf
|   |-- variables.tf
|   |-- outputs.tf
|   |-- cloud-init.yml.tpl
|   `-- modules/
|       |-- digitalocean/
|       `-- hetzner/
|-- docker-compose.yml
|-- Caddyfile
|-- Caddyfile.local
|-- compose.override.yml.example
|-- webhook/
|   |-- Dockerfile
|   |-- hooks.yml
|   `-- scripts/
|       |-- redeploy-app.sh
|       `-- redeploy-stack.sh
|-- scripts/
|   `-- deploy.sh
|-- docs/
`-- README.md
```

A `compose/` subdirectory reorganisation is deferred. If/when application count grows past two, the grouping can be revisited as a cheap, well-scoped refactor.

## Accepted tradeoffs

- **Webhook has docker socket access.** Mitigated by strict script allowlist. Acceptable at homelab scale.
- **Mutable `:latest` tag.** Rollback is a manual retag plus re-hook. Simpler than per-service SHA pins via env vars; revisit if rollback frequency rises.
- **No staging environment.** Every deploy goes directly to production. Matches current behaviour; scope is deliberate.
- **Webhook is SPOF for automation.** If the container is down, automated deploys fail until manual recovery. Operator SSH access remains as the recovery path.
- **Webhook service shares the main compose lifecycle.** If `docker compose down` happens, automated deploys cannot restart the stack. Recovery is manual SSH. Acceptable tradeoff for homelab; can be moved to a systemd unit later if needed.
- **No automated monitoring of deploy health.** Healthcheck on the blog service already exists and `docker compose up --wait` fails fast on unhealthy containers; the webhook script returns that failure as an HTTP 5xx. No alerting wired up beyond that.

## Risks and open questions

- **`git filter-repo` path mapping.** If any blog files were moved in/out of `blog/` historically, history preservation might be imperfect. The implementation plan should verify by comparing commit counts before and after extraction.
- **Cloud-init secret seeding.** The server needs `/etc/dev-lab/webhook.env` populated before the webhook container starts. Two viable approaches: Terraform renders the file from a sensitive variable and cloud-init writes it, or the operator populates it out-of-band after first boot. The implementation plan should pick one. Terraform-rendered is more reproducible but widens the Terraform state's sensitivity surface.
- **Webhook image pinning.** `almir/webhook:latest` is the commonly used Docker image for `adnanh/webhook`; the implementation plan should pin to a specific tag for reproducibility.
- **CORS / rate limiting for the deploy endpoint.** Public HTTPS endpoint accepting signed POSTs. Signature verification mitigates abuse, but a flood of unsigned requests could still consume resources. Out of scope for v1; revisit if observed.
- **DNS TTL for `deploy.cdavenport.io`.** Current DNS TTL of 3600s is fine for a deploy endpoint; noted so it is not accidentally lowered.
- **Cross-repo secret consistency.** The per-app HMAC secret has to be identical in three places: 1Password, `webhook.env` on the droplet, and the app repo's GH secret. Rotation needs to touch all three. Runbook should be included in the blog repo README.
