# Split Blog and Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the Go blog into its own portable repository, replace per-repo SSH deploys with a narrow-scoped deploy-webhook receiver on the droplet, and leave `dev-lab` as a clean infra + platform repo that can host N applications.

**Architecture:** Pre-built images on GHCR + HTTP webhook receiver with per-app HMAC secrets. Each phase leaves the production site live; rollback is a retag-plus-hook at any point.

**Tech Stack:** Terraform, DigitalOcean, Docker Compose, Caddy, Go (`goldmark`), GitHub Actions, GHCR, `adnanh/webhook`, 1Password (secret canonical store).

---

## Guiding rules for this plan

- **Commit after every step that changes files.** Short messages are fine.
- **Do not delete anything irreversibly until the replacement is proven live.** "Verify in prod" steps appear before every deletion.
- **Every Terraform change runs `terraform validate` and `terraform plan` before `apply`.**
- **Absolute paths everywhere.** Assume the repo checkout is at `/Users/connor/Projects/dev-lab`. Substitute if different.
- **Two repos appear in this plan.** Each task header says **Context:** `dev-lab` or `cdavenport.io` so you always know which checkout you're in.

---

## Phase 0: Branch setup

### Task 0.1: Create working branch in dev-lab

**Context:** `dev-lab`

**Files:** none modified yet; branch-only change.

- [ ] **Step 1: Create and switch to a feature branch**

```bash
cd /Users/connor/Projects/dev-lab
git checkout -b split-blog-and-platform
```

Expected: "Switched to a new branch 'split-blog-and-platform'".

- [ ] **Step 2: Verify clean working tree**

```bash
git status
```

Expected: "nothing to commit, working tree clean".

---

## Phase 1: Add the webhook service to dev-lab (blog still built locally)

Intent: get the webhook receiver running in production, reachable at `https://deploy.cdavenport.io`, before any repo split happens. Blog stays as `build: ./blog` for the whole phase. Only the new `infra` hook is active at first so we can exercise the webhook end-to-end against a safe target.

### Task 1.1: Author the webhook Dockerfile

**Context:** `dev-lab`

**Files:**
- Create: `/Users/connor/Projects/dev-lab/webhook/Dockerfile`

- [ ] **Step 1: Create webhook directory**

```bash
cd /Users/connor/Projects/dev-lab
mkdir -p webhook/scripts
```

- [ ] **Step 2: Write Dockerfile**

Create `webhook/Dockerfile`:

```dockerfile
FROM docker:24-cli-alpine3.19

ARG WEBHOOK_VERSION=2.8.2

RUN apk add --no-cache git ca-certificates curl docker-cli-compose \
    && curl -fsSL "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-amd64.tar.gz" \
        | tar -xz -C /tmp \
    && mv /tmp/webhook-linux-amd64/webhook /usr/local/bin/webhook \
    && chmod +x /usr/local/bin/webhook \
    && rm -rf /tmp/webhook-linux-amd64

ENTRYPOINT ["webhook"]
```

Notes:
- Using Docker's official `docker:24-cli-alpine3.19` as a base gives us the docker CLI and a predictable Alpine version. `docker-cli-compose` is available in Alpine 3.18+.
- `WEBHOOK_VERSION=2.8.2` is pinned. If a newer stable release exists at execution time, bump and update references.
- The container runs as root; the webhook binary itself does not need root, but root is the simplest way to share the host docker socket's permissions. Threat model: localhost-only receiver, signature-authenticated, scripts-allowlisted.
- Target arch is `linux-amd64` (matches the x86_64 DO droplet). If the target ever becomes ARM64, switch the release filename.

- [ ] **Step 3: Commit**

```bash
git add webhook/Dockerfile
git commit -m "Add webhook service Dockerfile"
```

---

### Task 1.2: Author the redeploy scripts

**Context:** `dev-lab`

**Files:**
- Create: `/Users/connor/Projects/dev-lab/webhook/scripts/redeploy-app.sh`
- Create: `/Users/connor/Projects/dev-lab/webhook/scripts/redeploy-stack.sh`

- [ ] **Step 1: Write redeploy-app.sh**

Create `webhook/scripts/redeploy-app.sh`:

```bash
#!/usr/bin/env sh
set -eu

# Redeploy a single compose service by pulling its image and recreating it.
# Intended to be invoked by the webhook service with a trusted service name.

service="${1:?usage: redeploy-app.sh <service-name>}"

cd /workspace

docker compose pull "$service"
docker compose up -d --wait "$service"
```

- [ ] **Step 2: Write redeploy-stack.sh**

Create `webhook/scripts/redeploy-stack.sh`:

```bash
#!/usr/bin/env sh
set -eu

# Redeploy the entire stack after pulling the latest infra repo state.
# Used for Caddyfile / compose / hook-config changes landed on main.

cd /workspace

git fetch origin main
git checkout main
git reset --hard origin/main

docker compose pull
docker compose up -d --wait
```

Notes:
- `git reset --hard` rather than `pull --ff-only` because the container sees a mounted working tree and we want to tolerate local apply-time fiddles without failing the deploy. This is safe: the only writer to this checkout in production is the deploy hook.

- [ ] **Step 3: Make scripts executable**

```bash
chmod +x webhook/scripts/redeploy-app.sh webhook/scripts/redeploy-stack.sh
```

- [ ] **Step 4: Shell-lint with posix sh**

```bash
sh -n webhook/scripts/redeploy-app.sh && sh -n webhook/scripts/redeploy-stack.sh && echo OK
```

Expected: "OK".

- [ ] **Step 5: Commit**

```bash
git add webhook/scripts/redeploy-app.sh webhook/scripts/redeploy-stack.sh
git commit -m "Add redeploy-app and redeploy-stack hook scripts"
```

---

### Task 1.3: Author the webhook hook definitions

**Context:** `dev-lab`

**Files:**
- Create: `/Users/connor/Projects/dev-lab/webhook/hooks.yml`

This file defines only the `infra` hook for now. The `blog` hook is added later, once the blog image exists on GHCR.

- [ ] **Step 1: Write hooks.yml**

Create `webhook/hooks.yml`:

```yaml
- id: infra
  execute-command: /scripts/redeploy-stack.sh
  command-working-directory: /workspace
  response-message: "infra redeploy triggered"
  trigger-rule:
    match:
      type: payload-hmac-sha256
      secret: '{{getenv "INFRA_HOOK_SECRET"}}'
      parameter:
        source: header
        name: X-Hub-Signature-256
```

Notes:
- The HMAC secret is read from `INFRA_HOOK_SECRET` in the container environment at startup. The secret itself lives in `/etc/dev-lab/webhook.env` on the droplet (see Task 1.7).
- Template expansion requires the `-template` flag on the `webhook` command (added to the compose service command in Task 1.4). adnanh/webhook 2.8+ supports `{{getenv}}`.
- The single-quoted YAML value avoids needing to escape the inner double quotes around the variable name.

- [ ] **Step 2: Commit**

```bash
git add webhook/hooks.yml
git commit -m "Add infra hook definition"
```

---

### Task 1.4: Add the webhook service to docker-compose.yml

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/docker-compose.yml`

- [ ] **Step 1: Read current compose file to confirm state**

```bash
cat /Users/connor/Projects/dev-lab/docker-compose.yml
```

- [ ] **Step 2: Add webhook service**

Edit `docker-compose.yml` so it becomes:

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
      webhook:
        condition: service_started

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

  webhook:
    build: ./webhook
    restart: unless-stopped
    expose:
      - "9000"
    volumes:
      - ./webhook/hooks.yml:/etc/webhook/hooks.yml:ro
      - ./webhook/scripts:/scripts:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/workspace:rw
    env_file: /etc/dev-lab/webhook.env
    working_dir: /workspace
    command: ["-hooks=/etc/webhook/hooks.yml", "-verbose", "-port=9000", "-template"]

volumes:
  caddy_data:
  caddy_config:
```

- [ ] **Step 3: Validate compose syntax locally**

`docker compose config -q` reads `env_file:` paths eagerly, so the absolute path must exist during validation. Create a placeholder that mirrors the production location, validate, leave it (the same path is also needed for `docker compose up` locally).

```bash
cd /Users/connor/Projects/dev-lab
sudo install -m 0700 -d /etc/dev-lab
sudo touch /etc/dev-lab/webhook.env
sudo chmod 0600 /etc/dev-lab/webhook.env
docker compose config -q && echo OK
```

Expected: "OK".

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "Add webhook service to compose stack"
```

---

### Task 1.5: Route deploy.cdavenport.io through Caddy

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/Caddyfile`
- Modify: `/Users/connor/Projects/dev-lab/Caddyfile.local`

- [ ] **Step 1: Update production Caddyfile**

Replace contents of `Caddyfile` with:

```
cdavenport.io {
    reverse_proxy blog:8080
}

www.cdavenport.io {
    redir https://cdavenport.io{uri} permanent
}

deploy.cdavenport.io {
    reverse_proxy webhook:9000
}
```

- [ ] **Step 2: Update local Caddyfile**

Replace contents of `Caddyfile.local` with:

```
:80 {
    reverse_proxy blog:8080
}

:9090 {
    reverse_proxy webhook:9000
}
```

Rationale: the local Caddy exposes the webhook on a separate port (9090) to avoid hostname routing during dev. Production TLS + subdomain happens only in the main `Caddyfile`.

- [ ] **Step 3: Commit**

```bash
git add Caddyfile Caddyfile.local
git commit -m "Route deploy subdomain and local /_deploy path to webhook"
```

---

### Task 1.6: Add deploy subdomain A record in Terraform

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/terraform/main.tf`

- [ ] **Step 1: Append deploy record**

Add to `terraform/main.tf` below the existing `digitalocean_record.www` block:

```hcl
resource "digitalocean_record" "deploy" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "deploy"
  value  = local.server_ip
  ttl    = 3600
}
```

- [ ] **Step 2: Validate**

```bash
cd /Users/connor/Projects/dev-lab/terraform
terraform validate
```

Expected: "Success! The configuration is valid."

- [ ] **Step 3: Plan with current tokens**

Ensure `TF_VAR_do_token` is set in the shell, then:

```bash
terraform plan -out plan.bin
```

Expected: plan shows exactly one resource to add: `digitalocean_record.deploy`.

- [ ] **Step 4: Apply**

```bash
terraform apply plan.bin
```

Expected: "Apply complete! Resources: 1 added, 0 changed, 0 destroyed."

- [ ] **Step 5: Remove plan file**

```bash
rm plan.bin
```

- [ ] **Step 6: Commit the Terraform change**

```bash
cd /Users/connor/Projects/dev-lab
git add terraform/main.tf
git commit -m "Add deploy.cdavenport.io A record"
```

---

### Task 1.7: Seed the webhook secret on the droplet

**Context:** operator-side (local shell + `ssh` to droplet)

**Files:** none in repo; droplet file `/etc/dev-lab/webhook.env`.

- [ ] **Step 1: Generate a random secret locally**

```bash
openssl rand -hex 32
```

Copy the 64-char hex string. Treat it as sensitive.

- [ ] **Step 2: Record the secret in 1Password**

In 1Password, create a new item titled `dev-lab INFRA_HOOK_SECRET`, category "Password", with the hex string as the password field. This is the canonical store.

- [ ] **Step 3: Write the env file on the droplet**

Substitute `<hex>` with the value from step 1:

```bash
ssh -p 2222 connor@cdavenport.io \
  "sudo install -m 0700 -d /etc/dev-lab && \
   echo 'INFRA_HOOK_SECRET=<hex>' | sudo tee /etc/dev-lab/webhook.env > /dev/null && \
   sudo chmod 0600 /etc/dev-lab/webhook.env && \
   sudo ls -l /etc/dev-lab/webhook.env"
```

Expected: file listed with `-rw-------` perms and root owner.

- [ ] **Step 4: Verify the value**

```bash
ssh -p 2222 connor@cdavenport.io "sudo cat /etc/dev-lab/webhook.env"
```

Expected: one line `INFRA_HOOK_SECRET=<hex>` matching what you set.

---

### Task 1.8: Deploy Phase 1 to the droplet via the current SSH flow

**Context:** `dev-lab`

**Files:** none modified.

- [ ] **Step 1: Push branch and open a PR**

```bash
cd /Users/connor/Projects/dev-lab
git push -u origin split-blog-and-platform
gh pr create --title "Phase 1: add deploy webhook receiver" --body "$(cat <<'EOF'
## Summary
- Adds dockerised adnanh/webhook service behind Caddy at deploy.cdavenport.io
- Adds Terraform A record for the deploy subdomain
- Adds hook scripts for app redeploy and stack redeploy
- Blog service is unchanged: still built from ./blog

## Test plan
- [ ] CI passes (existing test + build job)
- [ ] After merge + SSH deploy, `curl https://deploy.cdavenport.io/hooks/infra` returns a 4xx without a signature
- [ ] Signed POST to /hooks/infra returns success and stack redeploys cleanly
EOF
)"
```

- [ ] **Step 2: Let CI run and merge when green**

Wait for the existing deploy workflow to pass the `verify` job. Since the workflow also SSH-deploys on merge to main, merging will trigger the droplet to fetch the new compose layout and bring the webhook service up.

```bash
gh pr checks --watch
```

Once checks pass:

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 3: Confirm webhook container is running on the droplet**

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose ps webhook"
```

Expected: webhook service `Up (healthy)` or `Up`, port 9000 exposed internally.

- [ ] **Step 4: Probe the deploy endpoint from a browser or curl**

```bash
curl -i https://deploy.cdavenport.io/
```

Expected: a 404 or webhook-default page over HTTPS. The key signal is that TLS completes and Caddy is routing to the webhook service. If DNS has not propagated yet, wait and retry.

- [ ] **Step 5: Probe an unsigned call to /hooks/infra**

```bash
curl -i -X POST https://deploy.cdavenport.io/hooks/infra -d ''
```

Expected: HTTP 4xx (webhook rejects due to missing/bad signature). No 5xx, no 200.

---

### Task 1.9: Dry-run the infra hook against itself

**Context:** local shell

**Files:** none.

Prove the infra hook path works before we rely on it. Sign an empty body with the secret we seeded.

- [ ] **Step 1: Produce a valid signature**

Set `SECRET=<hex>` in the current shell to the value from 1Password, then:

```bash
SIG=$(printf '' | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')
echo "X-Hub-Signature-256: sha256=$SIG"
```

- [ ] **Step 2: POST the signed request**

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=$SIG" \
  --data '' \
  https://deploy.cdavenport.io/hooks/infra
```

Expected: HTTP 200 with body `infra redeploy triggered`.

- [ ] **Step 3: Observe the server-side effect**

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose logs --tail=50 webhook"
```

Expected: log lines showing the hook matched, the script executed, `docker compose pull` + `up -d --wait` completed without error.

- [ ] **Step 4: Confirm site is still healthy**

```bash
curl -sSf https://cdavenport.io/healthz
```

Expected: `ok`.

---

## Phase 2: Extract the blog into its own repository

### Task 2.1: Create the extracted repo locally with git filter-repo

**Context:** local shell (new checkout location)

**Files:**
- Create: `/Users/connor/Projects/cdavenport.io/` (new directory, full extracted repo).

- [ ] **Step 1: Clone a fresh mirror of dev-lab next to it**

```bash
cd /Users/connor/Projects
git clone https://github.com/connordavenport/dev-lab.git dev-lab-extract
```

Using a fresh clone, not the working checkout, so extraction cannot damage live work.

- [ ] **Step 2: Install git-filter-repo if missing**

```bash
command -v git-filter-repo >/dev/null || brew install git-filter-repo
```

- [ ] **Step 3: Extract the blog subtree preserving history**

```bash
cd /Users/connor/Projects/dev-lab-extract
git filter-repo --subdirectory-filter blog
```

Expected: filter-repo reports the number of rewritten commits. Working directory now contains the contents of the old `blog/` as the repo root.

- [ ] **Step 4: Sanity check the extraction**

```bash
git log --oneline | head -20
ls
```

Expected: commits relate only to blog changes; top-level files are `Dockerfile`, `go.mod`, `main.go`, `templates/`, `static/`, `posts/`, etc.

- [ ] **Step 5: Rename to the final path**

```bash
cd /Users/connor/Projects
mv dev-lab-extract cdavenport.io
```

- [ ] **Step 6: Verify tests still pass on the extracted tree**

```bash
cd /Users/connor/Projects/cdavenport.io
go test ./...
```

Expected: all tests pass. If import paths break, note them; they may reference `github.com/connordavenport/dev-lab/blog` and need updating in a later step.

---

### Task 2.2: Update the Go module path and import references

**Context:** `cdavenport.io`

**Files:**
- Modify: `/Users/connor/Projects/cdavenport.io/go.mod`
- Modify: any `*.go` file with the old import path.

- [ ] **Step 1: Update go.mod module line**

Replace the first line of `go.mod`:

```
module github.com/connordavenport/dev-lab/blog
```

with:

```
module github.com/connordavenport/cdavenport.io
```

- [ ] **Step 2: Find any references to the old import path**

```bash
cd /Users/connor/Projects/cdavenport.io
grep -r "connordavenport/dev-lab/blog" --include='*.go' . || echo "no references"
```

- [ ] **Step 3: Replace them if any exist**

For each file with a match, edit the import to `github.com/connordavenport/cdavenport.io/...`. If the output of step 2 was "no references", skip.

- [ ] **Step 4: Re-run tests**

```bash
go test ./...
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Rename module to github.com/connordavenport/cdavenport.io"
```

---

### Task 2.3: Add a README and standalone dev compose file

**Context:** `cdavenport.io`

**Files:**
- Create: `/Users/connor/Projects/cdavenport.io/README.md`
- Create: `/Users/connor/Projects/cdavenport.io/compose.dev.yml`

- [ ] **Step 1: Write README.md**

```markdown
# cdavenport.io

The Go blog that serves https://cdavenport.io. Reads Markdown posts with YAML frontmatter, renders them with Go `html/template` and `goldmark`, and embeds templates and static assets via `//go:embed`.

## Run locally

```sh
go run .
```

Open http://127.0.0.1:8080/.

## Run with Docker

```sh
docker build -t cdavenport.io .
docker run --rm -p 8080:8080 cdavenport.io
```

## Deploy

Push to `main`. CI builds, tags, and pushes an image to `ghcr.io/connordavenport/cdavenport.io`, then signs a POST to `https://deploy.cdavenport.io/hooks/blog` to trigger a production redeploy. Secrets required in GitHub Actions:

- `DEPLOY_HOOK_URL` - e.g. `https://deploy.cdavenport.io/hooks/blog`
- `DEPLOY_HOOK_SECRET` - HMAC secret shared with the server's `webhook.env`.

## Writing posts

Drop a new `.md` file into `posts/` with frontmatter:

```markdown
---
title: "Post Title"
date: 2026-04-19
slug: "post-title"
tags: ["go"]
---

Post body in Markdown.
```

## Rotating the deploy hook secret

1. Generate a new secret: `openssl rand -hex 32`.
2. Update the value in 1Password (`dev-lab BLOG_HOOK_SECRET`).
3. Update the repo secret `DEPLOY_HOOK_SECRET`.
4. Update `/etc/dev-lab/webhook.env` on the droplet (`BLOG_HOOK_SECRET=<new>`), then `docker compose up -d webhook` in `~/dev-lab`.
```

- [ ] **Step 2: Write compose.dev.yml**

Create `compose.dev.yml`:

```yaml
services:
  blog:
    build: .
    ports:
      - "8080:8080"
```

Minimal full-stack dev compose for the blog alone.

- [ ] **Step 3: Commit**

```bash
git add README.md compose.dev.yml
git commit -m "Add README and standalone compose.dev.yml"
```

---

### Task 2.4: Create the GitHub repo and push

**Context:** `cdavenport.io`

**Files:** none.

- [ ] **Step 1: Create the empty GitHub repo**

```bash
cd /Users/connor/Projects/cdavenport.io
gh repo create connordavenport/cdavenport.io --public \
  --description "The Go blog that serves cdavenport.io" \
  --source . --remote origin
```

- [ ] **Step 2: Push history**

```bash
git push -u origin main
```

- [ ] **Step 3: Open the repo in the browser and confirm commits present**

```bash
gh browse
```

Spot-check a couple of historical commits are visible.

---

### Task 2.5: Add blog CI workflow (test + build + push image; no deploy yet)

**Context:** `cdavenport.io`

**Files:**
- Create: `/Users/connor/Projects/cdavenport.io/.github/workflows/ci.yml`

- [ ] **Step 1: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: cdavenport-io-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/${{ github.repository_owner }}/cdavenport.io

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go test ./...

  build-and-push:
    needs: test
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set image tags
        id: tags
        run: |
          short_sha=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "tags=$IMAGE:latest,$IMAGE:sha-$short_sha" >> "$GITHUB_OUTPUT"

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.tags.outputs.tags }}
```

Notes:
- `build-and-push` runs only on `main`. PRs run `test` only.
- `deploy` job intentionally absent in this task; added in Task 4.1 once we have an image to deploy.

- [ ] **Step 2: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI workflow: test and push image to GHCR"
git push
```

- [ ] **Step 3: Watch the first run**

```bash
gh run watch
```

Expected: `test` and `build-and-push` jobs both succeed on `main`.

- [ ] **Step 4: Confirm the image lives in GHCR**

In the browser, open `https://github.com/connordavenport/cdavenport.io/pkgs/container/cdavenport.io` and confirm `latest` and `sha-<7>` tags exist.

Alternatively:

```bash
gh api /users/connordavenport/packages/container/cdavenport.io/versions --jq '.[].metadata.container.tags'
```

Expected: JSON arrays containing `latest` and the short SHA.

- [ ] **Step 5: Mark the package public**

In the GHCR UI (Packages -> cdavenport.io -> Package settings -> Change visibility), set visibility to Public. Public images require no server-side auth.

- [ ] **Step 6: Smoke-pull the image anonymously**

```bash
docker pull ghcr.io/connordavenport/cdavenport.io:latest
docker run --rm -p 8080:8080 ghcr.io/connordavenport/cdavenport.io:latest &
sleep 3
curl -sSf http://127.0.0.1:8080/healthz
kill %1 2>/dev/null || true
```

Expected: `ok` from the running container.

---

## Phase 3: Switch the production blog service to the GHCR image

### Task 3.1: Flip docker-compose.yml to pull the GHCR image

**Context:** `dev-lab` (on the `split-blog-and-platform` branch or a fresh branch off main; see step 1)

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/docker-compose.yml`

- [ ] **Step 1: Create fresh branch from main**

```bash
cd /Users/connor/Projects/dev-lab
git checkout main
git pull --ff-only
git checkout -b switch-blog-to-ghcr
```

- [ ] **Step 2: Replace the blog service build with image**

In `docker-compose.yml`, replace:

```yaml
  blog:
    build: ./blog
    restart: unless-stopped
    expose:
      - "8080"
```

with:

```yaml
  blog:
    image: ghcr.io/connordavenport/cdavenport.io:latest
    pull_policy: always
    restart: unless-stopped
    expose:
      - "8080"
```

- [ ] **Step 3: Validate**

```bash
docker compose config -q && echo OK
```

Expected: "OK". (The local `/etc/dev-lab/webhook.env` placeholder from Task 1.4 step 3 is still in place from earlier.)

- [ ] **Step 4: Open PR and merge**

```bash
git add docker-compose.yml
git commit -m "Switch blog service to GHCR image"
git push -u origin switch-blog-to-ghcr
gh pr create --title "Switch blog to GHCR image" --body "Blog now pulled from ghcr.io/connordavenport/cdavenport.io:latest instead of built from local ./blog. The ./blog directory is not yet deleted; that happens after the new deploy path is wired up."
gh pr checks --watch
gh pr merge --squash --delete-branch
```

The existing SSH-based deploy workflow runs on merge, bringing the change live.

- [ ] **Step 5: Verify the site serves from the GHCR image**

```bash
ssh -p 2222 connor@cdavenport.io "docker image ls ghcr.io/connordavenport/cdavenport.io"
```

Expected: the `latest` tag listed with a recent `CREATED` timestamp.

```bash
curl -sSf https://cdavenport.io/healthz
curl -sSfI https://cdavenport.io/ | head -5
```

Expected: `ok` and HTTP/2 200 with a recent `Last-Modified` or a valid HTML response.

---

## Phase 4: Wire up the blog deploy hook

### Task 4.1: Add the `blog` hook definition and secret

**Context:** `dev-lab` + operator-side (droplet)

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/webhook/hooks.yml`
- Modify: `/etc/dev-lab/webhook.env` on the droplet (out-of-band)

- [ ] **Step 1: Generate blog hook secret locally**

```bash
openssl rand -hex 32
```

Store in 1Password as `dev-lab BLOG_HOOK_SECRET`.

- [ ] **Step 2: Update droplet env file**

```bash
ssh -p 2222 connor@cdavenport.io "sudo sh -c 'echo \"BLOG_HOOK_SECRET=<hex>\" >> /etc/dev-lab/webhook.env && chmod 0600 /etc/dev-lab/webhook.env && cat /etc/dev-lab/webhook.env'"
```

Expected: file now has two lines, `INFRA_HOOK_SECRET=...` and `BLOG_HOOK_SECRET=...`.

- [ ] **Step 3: Restart webhook to load the new env**

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose up -d webhook"
```

Expected: webhook recreated, up and listening.

- [ ] **Step 4: Add blog hook to hooks.yml**

Create a branch and edit `webhook/hooks.yml` so it reads:

```yaml
- id: infra
  execute-command: /scripts/redeploy-stack.sh
  command-working-directory: /workspace
  response-message: "infra redeploy triggered"
  trigger-rule:
    match:
      type: payload-hmac-sha256
      secret: '{{getenv "INFRA_HOOK_SECRET"}}'
      parameter:
        source: header
        name: X-Hub-Signature-256

- id: blog
  execute-command: /scripts/redeploy-app.sh
  command-working-directory: /workspace
  pass-arguments-to-command:
    - source: string
      name: blog
  response-message: "blog redeploy triggered"
  trigger-rule:
    match:
      type: payload-hmac-sha256
      secret: '{{getenv "BLOG_HOOK_SECRET"}}'
      parameter:
        source: header
        name: X-Hub-Signature-256
```

- [ ] **Step 5: Commit, PR, merge**

```bash
cd /Users/connor/Projects/dev-lab
git checkout -b add-blog-hook
git add webhook/hooks.yml
git commit -m "Add blog deploy hook"
git push -u origin add-blog-hook
gh pr create --title "Add blog deploy hook" --body "Adds the /hooks/blog endpoint backed by its own per-app HMAC secret."
gh pr checks --watch
gh pr merge --squash --delete-branch
```

Merge triggers the existing SSH deploy, which pulls the updated compose (no structural change) and the updated hooks.yml is picked up by the running webhook because the file is mounted read-only. If hot reload is not in use, restart the webhook:

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose restart webhook"
```

- [ ] **Step 6: Probe the new endpoint with a signed empty body**

```bash
SECRET=<blog-hex-from-1password>
SIG=$(printf '' | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')
curl -i -X POST \
  -H "X-Hub-Signature-256: sha256=$SIG" \
  --data '' \
  https://deploy.cdavenport.io/hooks/blog
```

Expected: HTTP 200, body `blog redeploy triggered`. Server-side, `docker compose pull blog` runs and the container recreates.

- [ ] **Step 7: Confirm site still healthy**

```bash
curl -sSf https://cdavenport.io/healthz
```

Expected: `ok`.

---

### Task 4.2: Add deploy step to blog CI

**Context:** `cdavenport.io`

**Files:**
- Modify: `/Users/connor/Projects/cdavenport.io/.github/workflows/ci.yml`

- [ ] **Step 1: Add repo secrets**

In the GitHub UI for `connordavenport/cdavenport.io`, add two repository secrets:

- `DEPLOY_HOOK_URL` = `https://deploy.cdavenport.io/hooks/blog`
- `DEPLOY_HOOK_SECRET` = the blog HMAC hex from 1Password

Or via CLI:

```bash
gh secret set DEPLOY_HOOK_URL --repo connordavenport/cdavenport.io --body 'https://deploy.cdavenport.io/hooks/blog'
gh secret set DEPLOY_HOOK_SECRET --repo connordavenport/cdavenport.io
# paste the hex when prompted
```

- [ ] **Step 2: Append deploy job to ci.yml**

Edit `.github/workflows/ci.yml` to add a `deploy` job after `build-and-push`:

```yaml
  deploy:
    needs: build-and-push
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger production redeploy
        env:
          DEPLOY_HOOK_URL: ${{ secrets.DEPLOY_HOOK_URL }}
          DEPLOY_HOOK_SECRET: ${{ secrets.DEPLOY_HOOK_SECRET }}
        run: |
          sig=$(printf '' | openssl dgst -sha256 -hmac "$DEPLOY_HOOK_SECRET" | awk '{print $2}')
          curl --fail --show-error -sS -X POST \
            -H "X-Hub-Signature-256: sha256=$sig" \
            --data '' \
            "$DEPLOY_HOOK_URL"
```

- [ ] **Step 3: Commit and push**

```bash
cd /Users/connor/Projects/cdavenport.io
git add .github/workflows/ci.yml
git commit -m "Deploy via webhook after GHCR push"
git push
```

- [ ] **Step 4: Watch the run and verify end-to-end**

```bash
gh run watch
```

Expected: `test`, `build-and-push`, `deploy` all pass.

- [ ] **Step 5: Make a visible blog change and push**

Edit one post (e.g. change a character in `posts/hello-world.md`) or bump a static asset; commit and push to main:

```bash
git commit -am "Tweak hello-world to validate deploy"
git push
gh run watch
```

Expected: new commit SHA shows up on the running container.

- [ ] **Step 6: Confirm the running image matches the new SHA**

```bash
ssh -p 2222 connor@cdavenport.io "docker inspect ghcr.io/connordavenport/cdavenport.io:latest --format '{{ index .RepoDigests 0 }}'"
```

And confirm the site still returns healthy and the change is live:

```bash
curl -sSf https://cdavenport.io/healthz
```

Expected: `ok` and your visible blog change is observable in the browser.

---

## Phase 5: Remove the blog from dev-lab

Only run this phase after Phase 4 end-to-end verification is green and the site has been serving from GHCR without incident for at least one full deploy cycle.

### Task 5.1: Delete `blog/` and drop the Go build job from CI

**Context:** `dev-lab`

**Files:**
- Delete: `/Users/connor/Projects/dev-lab/blog/`
- Modify: `/Users/connor/Projects/dev-lab/.github/workflows/deploy.yml`
- Modify: `/Users/connor/Projects/dev-lab/.gitignore`

- [ ] **Step 1: Create a branch**

```bash
cd /Users/connor/Projects/dev-lab
git checkout main
git pull --ff-only
git checkout -b remove-blog-source
```

- [ ] **Step 2: Delete the blog directory**

```bash
git rm -r blog
```

- [ ] **Step 3: Simplify the CI workflow**

Edit `.github/workflows/deploy.yml`. The `verify` job currently tests and builds the Go service; remove it entirely. The `deploy` job still SSH-deploys and stays for now (it is replaced in Phase 6).

New content for `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches:
      - main
  workflow_dispatch:

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Configure SSH key
        env:
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
        run: |
          install -m 700 -d ~/.ssh
          printf '%s' "$DEPLOY_SSH_KEY" | tr -d '\r' > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519

      - name: Validate SSH key format
        run: ssh-keygen -y -f ~/.ssh/id_ed25519 > /dev/null

      - name: Trust deploy host key
        env:
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
          DEPLOY_PORT: ${{ secrets.DEPLOY_PORT }}
        run: ssh-keyscan -p "${DEPLOY_PORT}" "${DEPLOY_HOST}" >> ~/.ssh/known_hosts

      - name: Deploy over SSH
        env:
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
          DEPLOY_PORT: ${{ secrets.DEPLOY_PORT }}
          DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
        run: |
          ssh -p "${DEPLOY_PORT}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
            'cd ~/dev-lab && git fetch origin main && git checkout main && git pull --ff-only origin main && SKIP_GIT_PULL=1 ./scripts/deploy.sh'
```

- [ ] **Step 4: Remove blog-specific gitignore entries**

Edit `.gitignore` to remove the `blog/blog` line. Leave the others. Resulting file:

```
# Terraform
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.*
terraform/*.tfvars

# OS
.DS_Store
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Remove blog source; blog now ships from GHCR"
```

- [ ] **Step 6: PR, wait, merge**

```bash
git push -u origin remove-blog-source
gh pr create --title "Remove blog source from dev-lab" --body "Blog is now published from connordavenport/cdavenport.io to GHCR. dev-lab is infra-only."
gh pr checks --watch
gh pr merge --squash --delete-branch
```

The SSH deploy on merge brings the change live; the compose stack is unchanged in shape (blog service still points to the GHCR image) so the deploy is a no-op for the running blog.

- [ ] **Step 7: Verify production is unaffected**

```bash
curl -sSf https://cdavenport.io/healthz
```

Expected: `ok`.

---

## Phase 6: Move dev-lab CI onto the infra hook

### Task 6.1: Replace SSH deploy step with signed POST

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/.github/workflows/deploy.yml`

- [ ] **Step 1: Add repo secrets to dev-lab**

```bash
gh secret set DEPLOY_HOOK_URL --repo connordavenport/dev-lab --body 'https://deploy.cdavenport.io/hooks/infra'
gh secret set DEPLOY_HOOK_SECRET --repo connordavenport/dev-lab
# paste the INFRA_HOOK_SECRET hex when prompted
```

- [ ] **Step 2: Create branch and rewrite the workflow**

```bash
cd /Users/connor/Projects/dev-lab
git checkout main
git pull --ff-only
git checkout -b infra-ci-uses-hook
```

Replace `.github/workflows/deploy.yml` with:

```yaml
name: Deploy

on:
  push:
    branches:
      - main
  workflow_dispatch:

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.9.0
      - name: terraform fmt check
        run: terraform -chdir=terraform fmt -check -recursive
      - name: terraform init -backend=false
        run: terraform -chdir=terraform init -backend=false -input=false
      - name: terraform validate
        run: terraform -chdir=terraform validate

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Trigger infra redeploy
        env:
          DEPLOY_HOOK_URL: ${{ secrets.DEPLOY_HOOK_URL }}
          DEPLOY_HOOK_SECRET: ${{ secrets.DEPLOY_HOOK_SECRET }}
        run: |
          sig=$(printf '' | openssl dgst -sha256 -hmac "$DEPLOY_HOOK_SECRET" | awk '{print $2}')
          curl --fail --show-error -sS -X POST \
            -H "X-Hub-Signature-256: sha256=$sig" \
            --data '' \
            "$DEPLOY_HOOK_URL"
```

- [ ] **Step 3: Commit, PR, merge**

```bash
git add .github/workflows/deploy.yml
git commit -m "Use infra deploy hook; add terraform validate"
git push -u origin infra-ci-uses-hook
gh pr create --title "Infra CI via deploy hook" --body "Dev-lab no longer SSHes to the droplet. terraform validate runs before deploy. Secrets: DEPLOY_HOOK_URL, DEPLOY_HOOK_SECRET."
gh pr checks --watch
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: Verify the hook-driven deploy ran**

```bash
gh run list --workflow deploy.yml --limit 1
gh run view --log <run-id>
```

Expected: `deploy` job returns HTTP 200 from the webhook. Server-side:

```bash
ssh -p 2222 connor@cdavenport.io "cd ~/dev-lab && docker compose logs --tail=100 webhook | tail -40"
```

Expected: infra hook matched, `redeploy-stack.sh` executed, `docker compose pull`/`up -d --wait` succeeded.

- [ ] **Step 5: Trigger a trivial infra change to test the loop**

Modify a comment in Caddyfile (e.g. add a blank line), commit on a branch, merge via PR:

```bash
git checkout main && git pull --ff-only
printf '\n' >> Caddyfile
git checkout -b poke-caddyfile
git commit -am "Noop Caddyfile edit to exercise infra hook"
git push -u origin poke-caddyfile
gh pr create --title "Exercise infra hook" --body "Noop"
gh pr merge --squash --delete-branch --auto
```

Wait for CI to run. Verify:

```bash
curl -sSf https://cdavenport.io/healthz
curl -sSf https://deploy.cdavenport.io/ | head -5
```

Expected: `ok` from blog, webhook endpoint still responding.

---

## Phase 7: Remove SSH deploy secrets and update docs

### Task 7.1: Remove SSH secrets from both repos

**Context:** operator-side

- [ ] **Step 1: Delete dev-lab repo SSH secrets**

```bash
gh secret delete DEPLOY_SSH_KEY --repo connordavenport/dev-lab
gh secret delete DEPLOY_HOST --repo connordavenport/dev-lab
gh secret delete DEPLOY_PORT --repo connordavenport/dev-lab
gh secret delete DEPLOY_USER --repo connordavenport/dev-lab
```

- [ ] **Step 2: Confirm the deleted list**

```bash
gh secret list --repo connordavenport/dev-lab
```

Expected: only `DEPLOY_HOOK_URL` and `DEPLOY_HOOK_SECRET` remain (plus any other unrelated secrets).

- [ ] **Step 3: Revoke the droplet deploy key**

In `~/.ssh/authorized_keys` on the droplet, remove the key that was previously used by CI (the public half of the GH secret). Keep your operator key.

```bash
ssh -p 2222 connor@cdavenport.io
# Inside the droplet shell:
$EDITOR ~/.ssh/authorized_keys
# remove the CI deploy key line, save, exit
exit
```

Verify your operator key still works by reconnecting:

```bash
ssh -p 2222 connor@cdavenport.io "echo operator-ok"
```

Expected: "operator-ok".

---

### Task 7.2: Update deployment-workflow.md

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/docs/deployment-workflow.md`

- [ ] **Step 1: Rewrite to reflect hook-based flow**

Replace contents with:

```markdown
# Deployment Workflow

Two repos, two deploy paths, one webhook receiver.

## Overview

- **Blog source:** `github.com/connordavenport/cdavenport.io`. CI builds an image on push to `main`, pushes to `ghcr.io/connordavenport/cdavenport.io:{latest,sha-<7>}`, then signs a POST to the blog hook.
- **Infra source:** `github.com/connordavenport/dev-lab` (this repo). CI runs `terraform validate` on push to `main`, then signs a POST to the infra hook.
- **Receiver:** `adnanh/webhook` running on the droplet behind Caddy at `https://deploy.cdavenport.io`.

## Hooks

- `POST /hooks/blog` - pulls the latest blog image and recreates the blog service.
- `POST /hooks/infra` - `git reset --hard origin/main` in the droplet's dev-lab checkout, then `docker compose pull && up -d --wait`.

Both require a signed body. The signature is HMAC-SHA256 of the request body using the per-hook secret, passed in header `X-Hub-Signature-256: sha256=<hex>`.

## Secrets

Canonical store: 1Password.

- `dev-lab INFRA_HOOK_SECRET` - used by dev-lab CI and by the webhook container on the droplet (`INFRA_HOOK_SECRET` in `/etc/dev-lab/webhook.env`).
- `dev-lab BLOG_HOOK_SECRET` - used by cdavenport.io CI and by the webhook container (`BLOG_HOOK_SECRET` in the same env file).

Each hook secret has three storage locations. To rotate:

1. Generate new hex with `openssl rand -hex 32`.
2. Update 1Password.
3. Update the corresponding repo's `DEPLOY_HOOK_SECRET` secret (`gh secret set`).
4. SSH to the droplet, edit `/etc/dev-lab/webhook.env`, restart the webhook container with `docker compose up -d webhook`.

## Rollback

- **Blog:** retag an earlier `ghcr.io/connordavenport/cdavenport.io:sha-<7>` as `latest` via the GHCR UI or API, then trigger `POST /hooks/blog` (or simply `workflow_dispatch` the CI on a known-good commit).
- **Infra:** revert the offending commit on `dev-lab` main; CI redeploys via the infra hook.

## Operator recovery

If the webhook service itself is down, the site is still up but automated deploys fail. Recovery is manual:

```bash
ssh -p 2222 connor@cdavenport.io
cd ~/dev-lab
docker compose up -d --wait
```
```

- [ ] **Step 2: Commit via PR so the infra hook exercises itself**

```bash
cd /Users/connor/Projects/dev-lab
git checkout -b update-deployment-docs
git add docs/deployment-workflow.md
git commit -m "Update deployment-workflow.md for hook-based deploys"
git push -u origin update-deployment-docs
gh pr create --title "Doc: hook-based deploy workflow" --body "Documents the post-split deploy flow."
gh pr checks --watch
gh pr merge --squash --delete-branch
```

- [ ] **Step 3: Verify the infra hook fired cleanly**

```bash
gh run list --workflow deploy.yml --limit 1
```

Expected: most recent run was green.

---

### Task 7.3: Update the top-level README

**Context:** `dev-lab`

**Files:**
- Create or modify: `/Users/connor/Projects/dev-lab/README.md`

- [ ] **Step 1: Write README**

If `README.md` exists, replace; otherwise create:

```markdown
# dev-lab

Infrastructure and platform repo for cdavenport.io. Provisions the droplet with Terraform, configures it with cloud-init, and runs the application stack (Caddy + adnanh/webhook + N applications) with Docker Compose.

Applications run from pre-built images pulled from public registries; their source lives in separate repos. See `docs/deployment-workflow.md` for how deploys work.

## Layout

- `terraform/` - DO and Hetzner compute modules, DNS, cloud-init template.
- `docker-compose.yml`, `Caddyfile`, `Caddyfile.local` - runtime stack and reverse-proxy config.
- `webhook/` - deploy webhook receiver config, Dockerfile, and hook scripts.
- `scripts/deploy.sh` - bootstrap entrypoint used by cloud-init and recovery.
- `docs/` - deployment workflow, design specs, and implementation plans.

## Applications currently hosted

| Name | Image | Source repo |
|---|---|---|
| blog | `ghcr.io/connordavenport/cdavenport.io:latest` | `connordavenport/cdavenport.io` |

## Onboarding a new application

1. In the new app's repo: add a Dockerfile, push an image to a public registry, add a CI workflow that signs POST to `https://deploy.cdavenport.io/hooks/<app-id>` after publishing.
2. In this repo:
   - Add a service block to `docker-compose.yml` with `image:` pointing at the published image.
   - Add a Caddy site block with the desired hostname.
   - Add a Terraform A record for the hostname.
   - Add a hook entry in `webhook/hooks.yml` (use `redeploy-app.sh <service-name>`).
   - Add a matching `<APP>_HOOK_SECRET` line to `/etc/dev-lab/webhook.env` on the droplet and record the secret in 1Password and in the new app's repo secrets as `DEPLOY_HOOK_SECRET`.
3. `terraform apply` for the DNS record, then merge the dev-lab PR; the infra hook brings the new service up.

## Operating

See `docs/deployment-workflow.md` for deploys, secret rotation, and rollback.
```

- [ ] **Step 2: Commit via PR**

```bash
cd /Users/connor/Projects/dev-lab
git checkout -b update-readme
git add README.md
git commit -m "Update README for post-split platform layout"
git push -u origin update-readme
gh pr create --title "README: post-split platform" --body ""
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

### Task 7.4: Update cloud-init to remove Go-era assumptions

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/terraform/cloud-init.yml.tpl`

Go tooling was never explicitly installed in cloud-init; the blog was built inside Docker. The only change needed is to create `/etc/dev-lab/` so first-boot does not fail when the webhook service starts and looks for `/etc/dev-lab/webhook.env`.

- [ ] **Step 1: Add env-dir creation to cloud-init**

Edit `terraform/cloud-init.yml.tpl`. In the `runcmd:` list, above the `git clone` line, add:

```yaml
  # Ensure webhook env directory exists. The secrets file itself must be
  # populated out-of-band by the operator on first boot before the webhook
  # service can pass authenticated hooks through.
  - install -m 0700 -d /etc/dev-lab
  - touch /etc/dev-lab/webhook.env
  - chmod 0600 /etc/dev-lab/webhook.env
```

- [ ] **Step 2: Validate**

```bash
cd /Users/connor/Projects/dev-lab/terraform
terraform validate
terraform plan -out plan.bin
```

Expected: no resource changes; the cloud-init content is only consumed on new droplet creation.

- [ ] **Step 3: Commit via PR**

```bash
rm plan.bin
cd /Users/connor/Projects/dev-lab
git checkout -b cloud-init-webhook-env
git add terraform/cloud-init.yml.tpl
git commit -m "cloud-init: create /etc/dev-lab/webhook.env stub on first boot"
git push -u origin cloud-init-webhook-env
gh pr create --title "cloud-init: prep webhook env file" --body ""
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

### Task 7.5: Add a post-rebuild runbook to the design doc

**Context:** `dev-lab`

**Files:**
- Modify: `/Users/connor/Projects/dev-lab/docs/deployment-workflow.md`

- [ ] **Step 1: Append post-rebuild runbook**

Append to `docs/deployment-workflow.md`:

```markdown
## Post-rebuild runbook (terraform destroy + apply)

After `terraform apply` brings up a fresh droplet, cloud-init will clone `dev-lab`, create an empty `/etc/dev-lab/webhook.env`, and start the stack. On the first boot the webhook service will be up but no hooks can authenticate until the env file is populated.

Operator steps:

1. SSH to the new droplet as the operator.
2. Paste each hook secret from 1Password into `/etc/dev-lab/webhook.env` in the form `INFRA_HOOK_SECRET=...` / `BLOG_HOOK_SECRET=...`.
3. `sudo chmod 0600 /etc/dev-lab/webhook.env`.
4. `cd ~/dev-lab && docker compose up -d webhook` to reload the env file.

The blog is already live at this point - it only needs the GHCR image which is public. Hook-driven deploys resume as soon as the secrets file is populated.
```

- [ ] **Step 2: Commit via PR**

```bash
git checkout -b runbook-post-rebuild
git add docs/deployment-workflow.md
git commit -m "Add post-rebuild runbook to deployment-workflow.md"
git push -u origin runbook-post-rebuild
gh pr create --title "Runbook: post-rebuild operator steps" --body ""
gh pr checks --watch
gh pr merge --squash --delete-branch
```

---

## Phase 8: Close out

### Task 8.1: End-to-end proof

**Context:** both repos

- [ ] **Step 1: Make a visible blog change**

In `cdavenport.io`, edit a post's title, commit, push. Watch CI:

```bash
cd /Users/connor/Projects/cdavenport.io
git commit -am "Title tweak for end-to-end verification"
git push
gh run watch
```

- [ ] **Step 2: Verify the change is live**

```bash
curl -s https://cdavenport.io/ | grep -i 'title tweak'
```

Expected: the new title visible.

- [ ] **Step 3: Make an infra change**

In `dev-lab`, add a comment to `Caddyfile`, commit, push via PR. Verify the infra hook runs without error and the site stays up.

- [ ] **Step 4: Confirm no SSH key is used**

```bash
gh secret list --repo connordavenport/cdavenport.io
gh secret list --repo connordavenport/dev-lab
```

Expected: neither repo has any `DEPLOY_SSH_*` secrets. Only `DEPLOY_HOOK_URL` and `DEPLOY_HOOK_SECRET`.

- [ ] **Step 5: Final commit to memory**

Update the user's memory noting the split is complete. (Handled by the agent driving this plan; not a repo commit.)

---

## Done criteria

- `dev-lab` contains no application source code.
- `cdavenport.io` is an independent repo on GitHub with preserved blog history.
- Production blog is served by `ghcr.io/connordavenport/cdavenport.io:latest`.
- Both repos auto-deploy via signed POST to `https://deploy.cdavenport.io`.
- Neither repo holds SSH access to the droplet.
- `docs/deployment-workflow.md` reflects reality; post-rebuild runbook is in place.

## Rollback at any phase

- **Phase 1 (webhook added):** revert the PR in `dev-lab`; SSH deploy still works.
- **Phase 3 (blog switched to GHCR):** revert the compose change; `build: ./blog` still produces a working image as long as `blog/` has not yet been deleted.
- **Phase 5 (blog/ deleted):** if a rollback is needed, `git revert` restores `blog/` and the `build:` path.
- **Phase 6 (CI moved to hook):** revert to reinstate SSH deploy (secrets must not yet be deleted).
- **Phase 7 (SSH secrets deleted):** if an issue appears here, re-add the SSH secrets from 1Password and revert the hook-based CI.
