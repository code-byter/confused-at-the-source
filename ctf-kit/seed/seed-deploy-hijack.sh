#!/bin/bash
# seed-deploy-hijack.sh — create the project access token the evil hook
# will abuse to play the manual deploy job (P2's HIJACK move).
# Token scope: api. Masked CI var: GITLAB_TRIGGER_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

# 1. never trust a GITLAB_URL default from .env (IPs drift across restarts);
#    resolve the container IP fresh like seed.sh does
GIT_IP=$(docker inspect kit-gitlab-1 --format \
  '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{break}}{{end}}{{end}}')
API="${GITLAB_API:-http://$GIT_IP:80/api/v4}"
PID=1

# project access token: bot user, api scope, 30 days
RESP=$(curl -s -X POST "$API/projects/$PID/access_tokens" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"deploy-trigger","scopes":["api"],"expires_at":"2026-10-31"}')

TOK=$(echo "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("token",""))')
if [ -z "$TOK" ]; then
  echo "token create failed: $RESP" >&2
  exit 1
fi
echo "[hijack] project token created (masked)"

# store as masked CI variable — readable by any job in the project, so the
# "vendor's own build environment" holds the key to its own deploy gate.
# PUT (not POST): this script may re-run after seed.sh already created the
# variable, and a POST onto an existing key fails 400 'already been taken'.
# Verify the write: a silent failure here costs hours of tok=False debugging
# (build jobs report hijack-skip: tok=False), so fail loudly instead.
CODE=$(curl -s -o /tmp/hijack-var.json -w '%{http_code}' -X PUT \
  "$API/projects/$PID/variables/GITLAB_TRIGGER_TOKEN" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "key=GITLAB_TRIGGER_TOKEN&value=$TOK&masked=true")
if [ "$CODE" != "201" ] && [ "$CODE" != "200" ]; then
  # 404 = variable doesn't exist yet (first run after the seed.sh fix that
  # stopped pre-creating it empty) -> create it
  CODE=$(curl -s -o /tmp/hijack-var.json -w '%{http_code}' -X POST \
    "$API/projects/$PID/variables" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    -d "key=GITLAB_TRIGGER_TOKEN&value=$TOK&masked=true")
fi
if [ "$CODE" != "201" ] && [ "$CODE" != "200" ]; then
  echo "[hijack] ERROR: GITLAB_TRIGGER_TOKEN write failed (HTTP $CODE):" >&2
  cat /tmp/hijack-var.json >&2
  exit 1
fi
echo "[hijack] GITLAB_TRIGGER_TOKEN set as CI variable (masked)"
echo "[hijack] P2 note: any code running in the vendor's build can now read
       its deploy credential from the environment and fire the gate."
