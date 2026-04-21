# dev-lab

Infrastructure and platform repo for cdavenport.io. Provisions a DigitalOcean (or Hetzner) droplet with Terraform, configures it with cloud-init, and runs the application stack (Caddy + [adnanh/webhook](https://github.com/adnanh/webhook) + N applications) with Docker Compose.

Applications run from pre-built images pulled from public registries; their source lives in separate repos. See [docs/deployment-workflow.md](docs/deployment-workflow.md) and [docs/webhook-runbook.md](docs/webhook-runbook.md) for how deploys work.

## Layout

- `terraform/` - DigitalOcean and Hetzner compute modules, DNS, and the cloud-init template.
- `docker-compose.yml`, `Caddyfile`, `Caddyfile.local` - runtime stack and reverse-proxy config.
- `webhook/` - deploy-webhook receiver Dockerfile, hook definitions, and redeploy scripts.
- `scripts/deploy.sh` - bootstrap entrypoint used by cloud-init and operator recovery.
- `docs/` - deployment workflow, webhook runbook, design specs, and implementation plans.

## Applications currently hosted

- `blog` = `ghcr.io/csdavenport6/cdavenport.io:latest` (source: [csdavenport6/cdavenport.io](https://github.com/csdavenport6/cdavenport.io))

## Onboarding a new application

1. In the new app's repo: add a Dockerfile, publish an image to a public registry (GHCR works well), add a CI workflow that signs a POST to `https://deploy.cdavenport.io/hooks/<app-id>` after publishing.
2. In this repo:
   - Add a service block to `docker-compose.yml` with `image:` pointing at the published image.
   - Add a Caddy site block with the desired hostname.
   - Add a Terraform A record for the hostname.
   - Add a hook entry to `webhook/hooks.yml` (reuse `redeploy-app.sh <service-name>` for per-app hooks).
   - Extend the `case` allowlist in `webhook/scripts/redeploy-app.sh` to include the new service name.
3. Add a matching `<APP>_HOOK_SECRET` line to `/etc/dev-lab/webhook.env` on the droplet, record the secret in 1Password, and set `DEPLOY_HOOK_SECRET` in the new app's repo secrets.
4. `terraform apply` for the DNS record, then merge the dev-lab PR; the infra hook brings the new service up.

## Operating

See [docs/deployment-workflow.md](docs/deployment-workflow.md) for deploys, secret rotation, rollback, and post-rebuild runbook.
