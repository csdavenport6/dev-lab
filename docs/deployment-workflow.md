# Deployment Workflow

The production deploy path now has three stages:

1. Push to `main`.
2. GitHub Actions runs `go test ./...` in `blog/` and builds the blog Docker image.
3. If verification passes, the workflow SSHes to the droplet, fast-forwards the server checkout to `origin/main`, and then runs `./scripts/deploy.sh` with `SKIP_GIT_PULL=1`.

## Server Deploy Script

`scripts/deploy.sh` is the single deployment entrypoint for the repo.

- In CI or manual SSH deploys, it fast-forwards the server checkout to `origin/main`.
- In GitHub Actions, the workflow updates the server checkout first, then calls the script with `SKIP_GIT_PULL=1` so the first automated deploy works even on an older clone.
- In first-boot systemd startup, cloud-init sets `SKIP_GIT_PULL=1` so the same script can bring the stack up without trying to update git.
- The script runs `docker compose up -d --build --wait`, so deploy completion depends on container health.

## Health Checks

The Go app now serves `GET /healthz`, which returns `200 OK` with the body `ok`.

Docker Compose uses that endpoint as the blog container health check, and Caddy waits for the blog service to become healthy before it starts.

## GitHub Secrets

Set these repository secrets before enabling automated deploys:

- `DEPLOY_HOST`: production server hostname or IP
- `DEPLOY_PORT`: SSH port, such as `2222`
- `DEPLOY_USER`: server user, such as `connor`
- `DEPLOY_SSH_KEY`: private key for the deploy user

## Manual Fallback

If GitHub Actions is unavailable, the same deployment path works over SSH:

```bash
ssh -p 2222 connor@your-host
cd ~/dev-lab
./scripts/deploy.sh
```
