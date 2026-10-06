#!/bin/bash
# up.sh — first boot: generate secrets, start the stack, wait for GitLab,
# create root token + runner registration. Run once, then run seed.sh.
set -euo pipefail
cd "$(dirname "$0")"

ENVF=.env
if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<EOF
DEVPI_PW=$(openssl rand -hex 16)
OTA_PUSH_TOKEN=$(openssl rand -hex 32)
SIGNING_KEY=$(openssl rand -hex 32)
SIGNING_PUB=$(openssl rand -hex 32)
GITLAB_ROOT_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
GITLAB_ROOT_TOKEN=placeholder-set-by-init
EOF
  chmod 600 "$ENVF"
  echo "[up] generated .env (0600)"
fi
source "$ENVF"

echo "[up] starting stack (GitLab takes ~3-5 min on first boot)..."
docker compose up -d
echo "[up] waiting for GitLab to be healthy..."
# NOTE: '/-/health' returns 404 on recent gitlab-ce images, so poll the sign-in
# page instead: 200 = nginx+workhorse+puma are all up.
until curl -sf -H 'Host: gitlab' http://127.0.0.1:8088/users/sign_in >/dev/null; do sleep 10; done
echo "[up] GitLab up. Run ./seed/seed.sh next."
