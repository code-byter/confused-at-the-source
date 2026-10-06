#!/bin/bash
# down.sh — tear down the full challenge stack.
#
#   ./down.sh          stop containers, keep volumes (state survives; `up.sh` + no re-seed needed)
#   ./down.sh -v       stop containers AND wipe volumes (GitLab repos, tokens, devpi,
#                      OTA/collector data, device flash) — full factory reset, next boot needs seed.sh
#
# Also removes labnet/pubnet networks and the build images' stray containers.
set -euo pipefail
cd "$(dirname "$0")"

WIPE=0
[ "${1:-}" = "-v" ] && WIPE=1

echo "[down] stopping stack..."
docker compose down --remove-orphans --timeout 30

if [ "$WIPE" = "1" ]; then
  echo "[down] removing volumes (full reset)..."
  docker compose down -v --remove-orphans --timeout 30
  # compose -v only removes declared volumes; sweep any label-orphans too
  docker volume ls -q | grep -E '^(kit_|doorbellino)' | xargs -r docker volume rm 2>/dev/null || true
  echo "[down] volumes gone. Next ./up.sh boots a fresh GitLab: run ./seed/seed.sh again."
else
  echo "[down] volumes kept. ./up.sh brings it back as it was (no re-seed)."
fi

echo "[down] done. Remaining project containers:"
docker ps -a --filter "label=com.docker.compose.project" --format '  {{.Names}}  {{.Status}}' || true
