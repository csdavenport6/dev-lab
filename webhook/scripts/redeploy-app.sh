#!/usr/bin/env sh
set -eu

# Redeploy a single compose service by pulling its image and recreating it.
# Intended to be invoked by the webhook service with a trusted service name.

service="${1:?usage: redeploy-app.sh <service-name>}"

# Defence in depth: hook config is the primary gate, but the script refuses
# anything that is not an explicitly enumerated app service. Update this list
# when onboarding a new app.
case "$service" in
    blog) ;;
    *) echo "redeploy-app.sh: refusing unknown service: $service" >&2; exit 1 ;;
esac

cd /workspace

docker compose pull "$service"
docker compose up -d --wait "$service"
