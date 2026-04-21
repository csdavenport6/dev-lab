# Deployment Workflow

Two repos, two deploy paths, one webhook receiver.

## Overview

- **Blog source:** [csdavenport6/cdavenport.io](https://github.com/csdavenport6/cdavenport.io). CI builds an image on push to `main`, pushes to `ghcr.io/csdavenport6/cdavenport.io:{latest,sha-<7>}`, then signs a POST to the blog hook.
- **Infra source:** [csdavenport6/dev-lab](https://github.com/csdavenport6/dev-lab) (this repo). CI runs `terraform fmt + validate` on push to `main`, then signs a POST to the infra hook.
- **Receiver:** `adnanh/webhook` running on the droplet behind Caddy at `https://deploy.cdavenport.io`.

See [webhook-runbook.md](webhook-runbook.md) for a deeper dive on the receiver, hook execution model, and troubleshooting.

## Hooks

- `POST /hooks/blog` runs `redeploy-app.sh blog`, which pulls the latest blog image and recreates the blog service.
- `POST /hooks/infra` runs `redeploy-stack.sh`, which spawns a detached helper that does `git reset --hard origin/main` in the droplet checkout, then `docker compose up -d --wait --build`.

Both require an HMAC-SHA256 signature of the request body in header `X-Hub-Signature-256: sha256=<hex>`. Unsigned or mis-signed requests return HTTP 403.

The infra hook is detached because the webhook container is part of the compose stack it redeploys; running compose directly from the webhook would kill the running script. The detached helper returns immediately and continues the work in the background.

## Secrets

Canonical store: 1Password.

- `dev-lab INFRA_HOOK_SECRET` - used by [dev-lab CI](https://github.com/csdavenport6/dev-lab/blob/main/.github/workflows/deploy.yml) and by the webhook container on the droplet (`INFRA_HOOK_SECRET` in `/etc/dev-lab/webhook.env`).
- `dev-lab BLOG_HOOK_SECRET` - used by [cdavenport.io CI](https://github.com/csdavenport6/cdavenport.io/blob/main/.github/workflows/ci.yml) and by the webhook container (`BLOG_HOOK_SECRET` in the same env file).

Each hook secret has three storage locations. To rotate:

1. Generate a new hex with `openssl rand -hex 32`.
2. Update 1Password.
3. Update the corresponding repo's `DEPLOY_HOOK_SECRET` secret (`gh secret set`).
4. SSH to the droplet, edit `/etc/dev-lab/webhook.env`, then `cd ~/dev-lab && docker compose up -d webhook` to reload the env file (`-hotreload` only watches `hooks.yml`, not env).

## Rollback

- **Blog:** retag an earlier `ghcr.io/csdavenport6/cdavenport.io:sha-<7>` as `latest` via the GHCR UI or API, then trigger `POST /hooks/blog` (or `workflow_dispatch` the blog CI on a known-good commit).
- **Infra:** `git revert` the offending commit on dev-lab main; CI redeploys via the infra hook.

## Post-rebuild runbook (terraform destroy + apply)

After `terraform apply` brings up a fresh droplet, cloud-init clones `dev-lab`, creates `/etc/dev-lab/` owned by the service user with an empty `webhook.env`, and starts the stack. On first boot the webhook service runs but no hooks can authenticate until the env file is populated.

**Operator checklist:**

- [ ] Wait for cloud-init to finish (`ssh -p 2222 connor@cdavenport.io "cloud-init status --wait"`).
- [ ] Fetch the two hook secrets from 1Password (`dev-lab INFRA_HOOK_SECRET`, `dev-lab BLOG_HOOK_SECRET`).
- [ ] Append `INFRA_HOOK_SECRET=<hex>` and `BLOG_HOOK_SECRET=<hex>` lines to `/etc/dev-lab/webhook.env` on the droplet.
- [ ] Verify `ls -la /etc/dev-lab/webhook.env` shows `-rw------- connor connor`.
- [ ] Reload the webhook container: `cd ~/dev-lab && docker compose up -d webhook`.
- [ ] Verify certs came up: `curl -sSf https://cdavenport.io/healthz` and `curl -sSf https://deploy.cdavenport.io/`. First request may take a minute as Caddy provisions Let's Encrypt certificates.
- [ ] Sanity-check hooks with unsigned POSTs: `curl -X POST https://deploy.cdavenport.io/hooks/infra -d ''` and the same for `/hooks/blog`; both should return HTTP 403.

No GitHub Actions changes are needed per rebuild: repo secrets, secrets in 1Password, and the GHCR package visibility all persist across droplet replacements.

## Operator recovery

If the webhook service is down, the site stays up (Caddy and blog keep serving) but automated deploys cannot reach the hook. Recovery is a single SSH:

```bash
ssh -p 2222 connor@cdavenport.io
cd ~/dev-lab
git reset --hard origin/main
docker compose up -d --wait --build
```

This is the only scenario where SSH access to the droplet is required after the migration completes. Keep your operator SSH key valid even after removing the CI deploy key.
