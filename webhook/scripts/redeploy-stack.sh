#!/usr/bin/env sh
set -eu

# The webhook container is part of the compose stack it redeploys. Running
# `docker compose up -d --wait` here would recreate the webhook container
# mid-script, killing this process and leaving the stack half-updated. To
# survive, we fire off a detached helper container that does the actual
# work after we return HTTP 200 to the caller.

git -C /workspace rev-parse --is-inside-work-tree >/dev/null

# Self-discover the host path bind-mounted at /workspace so the helper
# container can mount the same host directory via the docker daemon.
HOST_REPO_PATH=$(docker inspect "$(hostname)" \
  --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}')

if [ -z "$HOST_REPO_PATH" ]; then
    echo "redeploy-stack.sh: could not discover host path for /workspace" >&2
    exit 1
fi

docker run --detach --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_REPO_PATH}:/workspace" \
    -v /etc/dev-lab:/etc/dev-lab:ro \
    -w /workspace \
    --entrypoint sh \
    dev-lab-webhook \
    -c '
        sleep 3
        git fetch origin main
        git checkout main
        git reset --hard origin/main
        docker compose up -d --wait --build
    '
