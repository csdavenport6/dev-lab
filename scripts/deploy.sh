#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

branch="${DEPLOY_BRANCH:-main}"
remote="${DEPLOY_REMOTE:-origin}"

if [[ "${SKIP_GIT_PULL:-0}" != "1" ]]; then
  git fetch "$remote" "$branch"
  git checkout "$branch"
  git pull --ff-only "$remote" "$branch"
fi

docker compose up -d --build --wait
