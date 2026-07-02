#!/usr/bin/env bash
# Safely restarts the stack: pulls latest images, recreates only what
# changed, verifies health before finishing.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[restart] Pulling latest images..."
docker compose pull

echo "[restart] Recreating containers..."
docker compose up -d --remove-orphans

echo "[restart] Waiting for health check..."
for i in $(seq 1 15); do
  if curl -fsS http://localhost/health > /dev/null; then
    echo "[restart] Healthy."
    exit 0
  fi
  sleep 2
done

echo "[restart] ERROR: service did not become healthy in time." >&2
docker compose logs --tail=100 api
exit 1
