# Webhook Redeploy Runbook

Operational reference for the deploy-webhook receiver that replaces per-repo SSH keys as the production deploy path.

> **Status:** the `infra` hook is live. The `blog` hook is added in Phase 4 of the split plan; this runbook covers both shapes.

## What it is

A dockerised [adnanh/webhook](https://github.com/adnanh/webhook) container runs on the droplet and listens for HMAC-signed POSTs at `https://deploy.cdavenport.io/hooks/<name>`. Each hook maps to a short shell script that pulls the relevant image(s) and runs `docker compose up -d --wait`. The receiver replaces the SSH deploy flow; CI holds only per-hook HMAC secrets, not an SSH key into the box.

## Request flow

```
GitHub Actions (or operator curl)
  |  POST /hooks/<name>
  |  X-Hub-Signature-256: sha256=<hmac of body>
  v
Caddy (cdavenport.io termination, Let's Encrypt cert)
  |  reverse_proxy webhook:9000
  v
webhook container (dev-lab-webhook-1)
  |  1. HMAC verify body against {{getenv "<NAME>_HOOK_SECRET"}}
  |  2. If mismatch, HTTP 403 "Hook rules were not satisfied."
  |  3. If match, exec redeploy-<stack|app>.sh
  v
docker compose pull + up -d --wait
```

## What's on the droplet

| Path | Role |
|------|------|
| `~/dev-lab` | the repo checkout; bind-mounted into the webhook container at `/workspace` so the script can `git pull` and `docker compose` against it |
| `/etc/dev-lab/webhook.env` | secret file, mode `0600`, owner `connor:connor`, loaded by the webhook service via `env_file:` |
| `/var/run/docker.sock` | host docker socket bind-mounted into the webhook container so it can drive compose |

The webhook container is defined in [docker-compose.yml](../docker-compose.yml). Hooks are defined in [webhook/hooks.yml](../webhook/hooks.yml). Redeploy scripts live in [webhook/scripts/](../webhook/scripts/).

## Defined hooks

| Hook | Script | Secret env var | Purpose |
|------|--------|----------------|---------|
| `infra` | `redeploy-stack.sh` | `INFRA_HOOK_SECRET` | fast-forwards `~/dev-lab` to `origin/main` then redeploys the whole stack; used for Caddyfile, compose, or hook-config changes |
| `blog` | `redeploy-app.sh blog` | `BLOG_HOOK_SECRET` | pulls the new `ghcr.io/csdavenport6/cdavenport.io:latest` image and recreates only the blog service |

`redeploy-app.sh` has a case-statement allowlist; to onboard a new app, add its service name to both `hooks.yml` and the allowlist in the script.

## Triggering a hook manually

From any shell with the secret available. Fish:

```fish
# fetch secret
set -l SECRET (op read "op://Personal/<item>/credential")

# sign body (empty body is fine for the infra hook)
set -l BODY ''
set -l SIG (printf '%s' $BODY | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

# send
curl -i -X POST \
  -H "X-Hub-Signature-256: sha256=$SIG" \
  --data "$BODY" \
  https://deploy.cdavenport.io/hooks/infra
```

Expected: `HTTP 200` with body `infra redeploy triggered`. The container logs show `infra got matched` immediately, followed by docker pull/up output.

### Gotcha: empty `$SIG`

`openssl dgst -hmac "$SECRET"` silently produces no output if `$SECRET` is unset. If the hook returns `HTTP 500 Error occurred while evaluating hook rules`, check `echo (string length -- "$SIG")` first. A valid SIG is 64 hex chars.

## Rotating a hook secret

1. Generate a new secret locally:
   ```fish
   openssl rand -hex 32
   ```
2. Update the 1Password item (`INFRA_HOOK_SECRET` or `BLOG_HOOK_SECRET`).
3. Update the GitHub Actions secret in the relevant repo:
   ```bash
   gh secret set DEPLOY_HOOK_SECRET --repo csdavenport6/<repo>
   ```
4. On the droplet, replace the value in `/etc/dev-lab/webhook.env`, keeping file mode `0600` and owner `connor:connor`:
   ```bash
   ssh -p 2222 connor@cdavenport.io
   sudoedit /etc/dev-lab/webhook.env   # or: nano, then chmod 0600 + chown connor:connor
   ```
5. Restart the webhook container so it picks up the new env var:
   ```bash
   cd ~/dev-lab && docker compose up -d webhook
   ```
   `-hotreload` only watches `hooks.yml`; env changes require a container restart.
6. Sanity-check with a signed POST (see above). Keep the previous secret around until the new one is verified in case of rollback.

## Troubleshooting

| Symptom | Most likely cause | Fix |
|---------|-------------------|-----|
| `HTTP 403 Hook rules were not satisfied.` | body was modified in transit, wrong secret, or client computed the HMAC over a different payload than it sent | re-fetch the secret from 1Password; hash exactly what curl sends (watch `printf '%s'` vs `echo` adding a newline) |
| `HTTP 500 Error occurred while evaluating hook rules.` | signature header missing or empty (`sha256=`); webhook rejects malformed sigs before the trigger-rule check | verify `$SIG` has length 64 before sending; if empty, `$SECRET` was unset |
| `curl: (35) ... tlsv1 alert internal error` on `deploy.cdavenport.io` | Caddy has no cert for the subdomain yet, or the running Caddy container is serving stale config | check `docker exec dev-lab-caddy-1 curl -s http://localhost:2019/config/apps/http/servers` to see loaded hosts; `docker compose up -d --force-recreate caddy` if hosts are stale (single-file bind-mount gotcha, [tracked follow-up](superpowers/plans/2026-04-19-split-blog-and-platform.md)) |
| hook edit in `hooks.yml` on `main` has no effect | webhook container was not recreated since the file changed | the `-hotreload` flag (in `docker-compose.yml` webhook `command`) watches `hooks.yml` for changes; if it's missing, `docker compose up -d --force-recreate webhook` |
| `docker compose` inside the container fails with permission denied on `/etc/dev-lab/webhook.env` | env file is owned by root | `sudo chown -R connor:connor /etc/dev-lab && sudo chmod 0700 /etc/dev-lab && sudo chmod 0600 /etc/dev-lab/webhook.env` |

## Observability

Tail webhook activity:

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose logs -f webhook"
```

Key log lines:
- `incoming HTTP POST request from <ip>`: request received
- `<name> got matched`: route found
- `<name> got matched, but didn't get triggered because the trigger rules were not satisfied`: auth fail (returns 403)
- `executing /scripts/...`: redeploy started
- `command output: ...`: docker compose output captured

## Recovery path when the webhook is down

Because the webhook runs inside the same `docker-compose` stack it deploys, a broken compose file can take the webhook down with it. If `deploy.cdavenport.io` is unreachable, fall back to SSH:

```bash
ssh -p 2222 connor@cdavenport.io
cd ~/dev-lab
git reset --hard origin/main
docker compose up -d --wait
```

This is the only case where SSH access to the droplet is required after the migration completes. Keep your SSH config working even after SSH deploy secrets are deleted from CI.
