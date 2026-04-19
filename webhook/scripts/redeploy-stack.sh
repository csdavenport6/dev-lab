#!/usr/bin/env sh
set -eu

# Redeploy the entire stack after pulling the latest infra repo state.
# Used for Caddyfile / compose / hook-config changes landed on main.

cd /workspace

# Fail loudly if /workspace is not a git checkout (mount misconfigured).
git -C /workspace rev-parse --is-inside-work-tree >/dev/null

git fetch origin main
git checkout main
git reset --hard origin/main

docker compose pull
docker compose up -d --wait
