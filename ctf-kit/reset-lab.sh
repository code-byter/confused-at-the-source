#!/bin/bash
# reset-lab.sh — rewind the DoorBellino CTF kit to demo-ready state.
#
#   ./reset-lab.sh               fast reset: keeps GitLab users/tokens/projects,
#                                rewinds everything a CTF run dirtied
#   ./reset-lab.sh --no-reseed   same, but skip the seed first-release redeploy
#                                (run ./seed/seed.sh yourself afterwards)
#   ./reset-lab.sh --full        factory reset: down -v, up, gitlab-init, seed
#                                (slow: GitLab re-initializes from scratch)
#
# What the fast reset rewinds (in order):
#   1. vendor repo .gitlab-ci.yml  — restored from git, pushed to GitLab,
#                                    read back and byte-compared
#   2. all GitLab pipelines        — deleted (stale red/green runs confuse the demo)
#   3. devpi-public evil package   — doorbellino-hal deleted from root/pub
#   4. OTA server state            — manifest + append-only history wiped, restart
#   5. virtual device flash        — flash.img wiped (implant gone), restart
#   6. collector log               — loot + beacons wiped
#   7. ./seed/seed.sh              — idempotent; step 7 sees no OTA manifest and
#                                    replays the vendor's first (clean) release
# NOT reset here: the PHYSICAL ESP32. Its flash still carries the implant:
#   idf.py -p PORT erase_flash && idf.py -p PORT flash monitor
#
# Run on the lab host, inside kit/ (needs docker + the kit .env).
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT_ROOT"
[ -f .env ] || { echo "[reset] ERROR: no .env — run ./up.sh first" >&2; exit 1; }
source .env

MODE=fast
case "${1:-}" in
  --full) MODE=full ;;
  --no-reseed) MODE=noreseed ;;
  "") ;;
  *) echo "usage: $0 [--full|--no-reseed]" >&2; exit 2 ;;
esac

say() { echo "[reset] $*"; }

first_ip() { docker inspect "$1" --format \
  '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{break}}{{end}}{{end}}'; }

# ---------------------------------------------------------------- full reset
if [ "$MODE" = full ]; then
  say "full factory reset requested (down -v)..."
  ./down.sh -v
  ./up.sh
  ./seed/gitlab-init.sh
  ./seed/seed.sh
  say "full reset complete."
  exit 0
fi

# ------------------------------------------------------------- preflight
GIT_IP=$(first_ip kit-gitlab-1)
[ -n "$GIT_IP" ] || { echo "[reset] ERROR: kit-gitlab-1 not running — ./up.sh first" >&2; exit 1; }
API="http://$GIT_IP:80/api/v4"
case "${GITLAB_ROOT_TOKEN:-}" in
  ""|placeholder-set-by-init)
    echo "[reset] ERROR: no root PAT in .env — run ./seed/gitlab-init.sh first" >&2; exit 1 ;;
esac
CODE=$(curl -s --connect-timeout 5 -o /tmp/reset-preflight.json -w '%{http_code}' \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" "$API/user" || true)
[ "$CODE" = 200 ] || { echo "[reset] ERROR: GitLab rejected the root PAT (HTTP $CODE) — ./seed/gitlab-init.sh" >&2; exit 1; }
say "preflight OK: stack up, root PAT valid"

# ------------------------------------------- 1. restore vendor CI config
# git checkout also restores the vendor CI yml from any demo variant
# (test-after-install) and any P5 hand-edit (public fallback removed).
VENDOR_REPO="$KIT_ROOT/vendor/firmware"
git -c safe.directory="$VENDOR_REPO" -C "$VENDOR_REPO" checkout -- .gitlab-ci.yml
grep -q "EXTRA_INDEX_URL" "$VENDOR_REPO/.gitlab-ci.yml" \
  || { echo "[reset] ERROR: restored .gitlab-ci.yml lacks the public fallback — vendor repo template changed?" >&2; exit 1; }
if grep -q "DEFENSE DEMO" "$VENDOR_REPO/.gitlab-ci.yml"; then
  echo "[reset] ERROR: restored .gitlab-ci.yml still has the defense-demo marker — check git status in vendor/firmware" >&2
  exit 1
fi

PID=1
B64=$(base64 -w0 < "$VENDOR_REPO/.gitlab-ci.yml")
CODE=$(curl -s -o /tmp/reset-yml-push.json -w '%{http_code}' -X PUT \
  "$API/projects/$PID/repository/files/.gitlab-ci.yml" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"branch\":\"main\",\"content\":\"$B64\",\"encoding\":\"base64\",\"commit_message\":\"reset-lab: restore default vulnerable pipeline\"}")
[ "$CODE" = 200 ] || [ "$CODE" = 201 ] || { echo "[reset] ERROR: CI yml push failed (HTTP $CODE)" >&2; cat /tmp/reset-yml-push.json >&2; exit 1; }
# verify the write: read back and byte-compare against the local file
curl -s -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  "$API/projects/$PID/repository/files/.gitlab-ci.yml/raw?ref=main" > /tmp/reset-yml-readback.txt
if cmp -s "$VENDOR_REPO/.gitlab-ci.yml" /tmp/reset-yml-readback.txt; then
  say "1/6 vendor .gitlab-ci.yml restored on GitLab (byte-identical to kit copy)"
else
  echo "[reset] ERROR: GitLab CI yml differs from local copy after push — aborting" >&2; exit 1
fi

# ------------------------------------------- 2. delete all pipelines
# Every project the kit creates; stale runs would sit in the CI/CD view and
# the "latest pipeline" badge would show last demo's outcome.
for P in $(curl -s -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" "$API/projects?per_page=100" \
             | python3 -c 'import sys,json;print("\n".join(str(p["id"]) for p in json.load(sys.stdin)))'); do
  for PIPE in $(curl -s -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
                  "$API/projects/$P/pipelines?per_page=100" \
                  | python3 -c 'import sys,json;print("\n".join(str(p["id"]) for p in json.load(sys.stdin)))' 2>/dev/null); do
    curl -s -X DELETE -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
      "$API/projects/$P/pipelines/$PIPE" > /dev/null
  done
done
say "2/6 all GitLab pipelines deleted"

# ------------------------------------------- 3. remove evil package (devpi-public)
PUB_HOST="127.0.0.1"; PUB_PORT=3141
PUB_IP=$(first_ip kit-devpi-public-1)
[ -n "$PUB_IP" ] || { echo "[reset] ERROR: kit-devpi-public-1 not running" >&2; exit 1; }
# prefer the container IP (works even when the host port is taken by something else)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "root:${DEVPI_PW}" \
  -X DELETE "http://$PUB_IP:3141/root/pub/doorbellino-hal" || true)
case "$CODE" in
  200) : ;;
  404) say "   devpi-public had no doorbellino-hal (already clean)" ;;
  403) echo "[reset] WARNING: devpi refused DELETE (403, non-volatile index?) — remove manually" >&2 ;;
  000) # container IP unreachable from host: fall back to the published host port
    curl -s -o /dev/null -u "root:${DEVPI_PW}" -X DELETE "http://$PUB_HOST:$PUB_PORT/root/pub/doorbellino-hal" || true ;;
esac
LEFT=$(curl -s -o /dev/null -w '%{http_code}' "http://$PUB_IP:3141/root/pub/doorbellino-hal/")
[ "$LEFT" = 404 ] && say "3/6 devpi-public clean (no doorbellino-hal)" \
  || echo "[reset] WARNING: devpi-public still serves doorbellino-hal (HTTP $LEFT)" >&2

# ------------------------------------------- 4. wipe OTA state
docker exec kit-ota-1 sh -c 'rm -rf /data/manifest-history.jsonl /data/manifest-history-board.jsonl /data/firmware /data/firmware-board /data/access.log'
docker compose restart ota > /dev/null
sleep 2
M=$(curl -s --connect-timeout 5 "http://$(first_ip kit-ota-1):8080/manifest.json" || true)
if echo "$M" | grep -q '"version"'; then
  echo "[reset] ERROR: OTA still serves a manifest after wipe" >&2; exit 1
fi
say "4/6 OTA state wiped (no manifest, history gone)"

# ------------------------------------------- 5. wipe virtual device flash
docker exec kit-virtual-device-1 rm -f /data/flash/flash.img
docker compose restart virtual-device > /dev/null
sleep 2
IMPL=$(docker exec kit-virtual-device-1 python3 -c "
f = open('/data/flash/flash.img','rb')
for base in (0x10000, 0x200000):
    f.seek(base + 0x1E0000)
    print(f.read(8))
" 2>/dev/null || echo "")
if echo "$IMPL" | grep -q "IMPLANT"; then
  echo "[reset] ERROR: implant magic still in flash after wipe" >&2; exit 1
fi
say "5/6 virtual device flash wiped (no implant in either bank)"

# ------------------------------------------- 6. clear collector log
docker exec kit-collector-1 rm -f /data/collector.log
L=$(curl -s "http://$(first_ip kit-collector-1):9000/log")
[ -z "$L" ] && say "6/6 collector log cleared" \
  || echo "[reset] WARNING: collector log not empty: $(echo "$L" | head -c 120)" >&2

# ------------------------------------------- re-seed the first release
if [ "$MODE" = noreseed ]; then
  say "skipping seed (--no-reseed). Run ./seed/seed.sh before the demo:"
  say "  it sees no OTA manifest and replays the vendor's clean 1.4.2 release."
else
  say "re-running ./seed/seed.sh (idempotent; first-release step redeploys 1.4.2)..."
  ./seed/seed.sh
fi

# ------------------------------------------- final state
say "--- post-reset state ---"
M=$(curl -s "http://$(first_ip kit-ota-1):8080/manifest.json" 2>/dev/null || echo none)
if [ "$MODE" = noreseed ]; then
  say "OTA manifest: none (expected with --no-reseed)"
else
  V=$(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo none)
  say "OTA manifest version: $V (want 1.4.2)"
fi
say "physical ESP32 NOT touched: erase + reflash it yourself before the demo"
say "  idf.py -p PORT erase_flash && idf.py -p PORT flash monitor"
say "reset complete."
