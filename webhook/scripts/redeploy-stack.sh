#!/usr/bin/env sh
set -eu

# The webhook container is part of the compose stack it redeploys. Running
# `docker compose up -d --wait` here would recreate the webhook container
# and kill this script mid-run, leaving the stack half-updated. To survive,
# we fire off a detached helper container that continues the work after
# this script returns HTTP 200 to the caller.

git -C /workspace rev-parse --is-inside-work-tree >/dev/null

# Self-discover the host path bind-mounted at /workspace so the helper
# container can mount the same host directory through the docker daemon.
HOST_REPO_PATH=$(docker inspect "$(hostname)" \
  --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')

if [ -z "$HOST_REPO_PATH" ]; then
    echo "redeploy-stack.sh: could not discover host path for /workspace" >&2
    exit 1
fi

# Mount the repo at the SAME path inside the helper as it has on the host.
# docker compose resolves relative volume paths (./Caddyfile, ./webhook/...)
# against the compose file's directory, then passes the resulting absolute
# path to the daemon, which interprets it as a host path. Matching paths on
# both sides means those relative mounts resolve to valid host locations.
docker run --detach --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_REPO_PATH}:${HOST_REPO_PATH}" \
    -v /etc/dev-lab:/etc/dev-lab:ro \
    -w "${HOST_REPO_PATH}" \
    --entrypoint sh \
    dev-lab-webhook \
    -c '
        set -eu
        sleep 3
        git fetch origin main
        git checkout main
        git reset --hard origin/main
        docker compose up -d --wait --build
    '
