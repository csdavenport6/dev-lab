#!/usr/bin/env sh
set -eu

# Redeploy a single compose service by pulling its image and recreating it.
# Intended to be invoked by the webhook service with a trusted service name.

service="${1:?usage: redeploy-app.sh <service-name>}"

cd /workspace

docker compose pull "$service"
docker compose up -d --wait "$service"
