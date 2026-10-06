#!/bin/bash
# seed.sh — bring up the DoorBellino vendor: devpi indexes, GitLab project,
# CI variables, internal package publish, first pipeline release.
#
# Preconditions: ./up.sh ran; GitLab healthy; ./seed/gitlab-init.sh created the
# root PAT (preflight below enforces both, with the fix-it message).
set -euo pipefail
# Absolute kit root: this script cd's into vendor/firmware mid-run, so any
# later relative "$(dirname "$0")" would resolve against the WRONG cwd
# (seed-deploy-hijack.sh once failed with 'No such file or directory' here).
SEED_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SEED_DIR/.." && pwd)"
cd "$KIT_ROOT"
[ -f .env ] || { echo "[seed] ERROR: no .env — run ./up.sh first" >&2; exit 1; }
source .env

# NB: no default GITLAB_URL here. Container IPs drift between up/down cycles
# (this file once hardcoded http://172.18.0.9 and only worked by luck), so the
# fresh container-IP resolution below is the default path; an explicit
# GITLAB_URL/GITLAB_API from the environment still wins.
INT_PYPI="${INT_PYPI:-http://devpi-internal:3141/root/doorbellino}"
PUB_PYPI="${PUB_PYPI:-http://devpi-public:3141/root/pub}"

say() { echo "[seed] $*"; }
# Resolve GitLab + devpi IPs; take the network that has a unique IP so the
# two-network GitLab container can't produce '172.22.0.6172.21.0.3' garbage.
# Container IPs change between up/down cycles, so ALWAYS resolve them fresh;
# only an explicit GITLAB_URL/GITLAB_API from the environment wins.
first_ip() { docker inspect "$1" --format \
  '{{range .NetworkSettings.Networks}}{{if .IPAddress}}{{.IPAddress}}{{break}}{{end}}{{end}}'; }
GIT_IP=$(first_ip kit-gitlab-1)
[ -n "$GIT_IP" ] || { echo "[seed] ERROR: container kit-gitlab-1 not found/running — run ./up.sh first (and wait for GitLab to be healthy)" >&2; exit 1; }
GITLAB_API="${GITLAB_API:-${GITLAB_URL:-http://$GIT_IP:80}/api/v4}"
say "GitLab API at $GITLAB_API"

# Preflight: is the root PAT present and valid? Without gitlab-init.sh (or with
# an expired PAT) every later API call answers with an error object and the
# failures surface as confusing 'KeyError: 0' / 'could not resolve group' much
# deeper in. Fail here, loudly, with the fix.
case "${GITLAB_ROOT_TOKEN:-}" in
  ""|placeholder-set-by-init)
    echo "[seed] ERROR: no root PAT in .env (still the placeholder?) — run ./seed/gitlab-init.sh first" >&2; exit 1 ;;
esac
CODE=$(curl -s --connect-timeout 5 -o /tmp/seed-preflight.json -w '%{http_code}' \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" "$GITLAB_API/user" || true)
# curl exit 7 (unreachable) must NOT abort via set -e before the fix-it hint:
# on failure -w still prints 000, so CODE is non-200 and we fall into the hint
if [ "$CODE" != 200 ]; then
  echo "[seed] ERROR: GitLab rejected the root PAT (GET /user -> HTTP $CODE)." >&2
  echo "  If GitLab was freshly recreated (./down.sh -v && ./up.sh), run ./seed/gitlab-init.sh first." >&2
  echo "  Response: $(head -c 300 /tmp/seed-preflight.json)" >&2
  exit 1
fi
say "preflight OK: root PAT valid ($(python3 -c 'import json;print(json.load(open("/tmp/seed-preflight.json")).get("username","?"))' 2>/dev/null || echo '?'))"

# devpi publish/upload endpoints: single stable IP per server.
INT_IDX=$(first_ip kit-devpi-internal-1)
PUB_IDX=$(first_ip kit-devpi-public-1)
INT_IDX="http://$INT_IDX:3141"
PUB_IDX="http://$PUB_IDX:3141"

# Create the indexes (idempotent, 409 = already exists is fine). Uses devpi's
# HTTP API directly via curl, same as services/devpi-*/init.sh, so the host
# needs no devpi client. Also: containers started before init.sh gained this
# still get their index here.
create_index() {  # $1 = container ip, $2 = index name
  # devpi-server >= 6.2 rejects form-encoded index config ("could not decode
  # json", leaving the index silently missing), so send JSON like devpi's own
  # client. 200 = created, 409 = already exists (non-volatile re-seed), both fine.
  local out code
  out=$(curl -s -w '\n%{http_code}' -u "root:${DEVPI_PW}" \
    -X PUT "http://$1:3141/root/$2" \
    -H 'Content-Type: application/json' -d '{"bases":"","volatile":false}')
  code=$(tail -n1 <<<"$out")
  if [ "$code" != 200 ] && [ "$code" != 409 ]; then
    echo "[seed] devpi index root/$2: HTTP $code" >&2
    echo "$out" >&2
    exit 1
  fi
}

create_index "$(first_ip kit-devpi-internal-1)" doorbellino
create_index "$(first_ip kit-devpi-public-1)" pub
say "devpi indexes ready"

# 2. publish internal hal (vendor's private package)
rm -rf /tmp/wh-int && mkdir -p /tmp/wh-int
(cd vendor/doorbellino-hal && pip wheel . -w /tmp/wh-int -q)
if command -v twine >/dev/null; then
  # NB: the dist glob MUST be part of the array (host branch). Without it this
  # path dies with 'twine upload: error: the following arguments are required:
  # dist' the moment the host happens to have twine installed (fresh host,
  # seedenv, pipx...). The docker branch already passed /w/*.whl.
  TWINE=(twine upload --repository-url "$INT_IDX/root/doorbellino/" \
    -u root -p "$DEVPI_PW" --non-interactive /tmp/wh-int/*.whl)
else
  say "host twine missing: uploading wheel via docker+twine"
  TWINE=(docker run --rm --network host -v /tmp/wh-int:/w -w /w python:3-slim \
    sh -c "pip install -q twine && twine upload --repository-url '$INT_IDX/root/doorbellino/' -u root -p '$DEVPI_PW' --non-interactive /w/*.whl")
fi
# devpi rejects re-uploads to a non-volatile index with 409 "already exists",
# so a re-seed after a partial seed must not die here (set -e would kill the
# whole script). Tolerate exactly that case; surface everything else.
if ! OUT=$("${TWINE[@]}" 2>&1); then
  if grep -q "already exists" <<<"$OUT"; then
    say "doorbellino-hal 1.4.2 already on INTERNAL devpi, skipping upload"
  else
    echo "$OUT" >&2
    exit 1
  fi
fi
say "doorbellino-hal 1.4.2 -> INTERNAL devpi only"

# 2b. build tooling on the internal index. The evil SDIST (P2) is BUILT
# inside the vendor CI: pip's isolated build env resolves setuptools from
# the configured indexes, and the lab indexes proxy nothing. Without these
# wheels the sdist path dies with 'No matching distribution found for
# setuptools>=61'. Vendor-mirror plausible, offline-safe.
mkdir -p /tmp/wh-int-tools
# Guard on the SPECIFIC wheels, not just 'any whl here': a partial previous
# run (interrupted pip download leaves *.tmp, or a stale wheel from an older
# setuptools) passes the old glob check while the file twine needs is gone,
# which then fails as 'Cannot find file'.
if ! ls /tmp/wh-int-tools/setuptools-*.whl /tmp/wh-int-tools/wheel-*.whl >/dev/null 2>&1; then
  rm -rf /tmp/wh-int-tools
  if ! pip download setuptools wheel --no-deps -q -d /tmp/wh-int-tools 2>/dev/null; then
    say "host pip download failed: pulling build wheels via docker"
    docker run --rm -v /tmp/wh-int-tools:/w python:3-slim \
      sh -c "pip download -q --no-deps setuptools wheel -d /w"
  fi
fi
# NB: curl -X POST --upload-file always exits 0 even when devpi answers 404
# (wrong endpoint), so a curl-based upload "succeeds" silently and the CI
# later dies with 'No matching distribution found for setuptools'. Upload
# via twine (the same mechanism step 2 uses) and VERIFY the +simple page.
if command -v twine >/dev/null; then
  TWINE_TOOLS=(twine upload --repository-url "$INT_IDX/root/doorbellino/" \
    -u root -p "$DEVPI_PW" --non-interactive)
else
  say "host twine missing: uploading tool wheels via docker+twine"
  # Mount at the SAME absolute path as the host (not /w): the loop below
  # passes host paths (/tmp/wh-int-tools/<whl>), and a file must exist at
  # that exact path inside the container or twine dies with
  # 'Cannot find file (or expand pattern)' — which is exactly what the
  # old -v ...:/w mount caused. (Step 2's hal upload passes /w/*.whl and
  # was fine; this one wasn't.)
  TWINE_TOOLS=(docker run --rm --network host -v /tmp/wh-int-tools:/tmp/wh-int-tools \
    -w /tmp/wh-int-tools python:3-slim \
    sh -c "pip install -q twine && twine upload --repository-url '$INT_IDX/root/doorbellino/' -u root -p '$DEVPI_PW' --non-interactive \"\$@\"" --)
fi
for WHL in /tmp/wh-int-tools/*.whl; do
  if ! OUT=$("${TWINE_TOOLS[@]}" "$WHL" 2>&1); then
    if ! grep -q "already exists" <<<"$OUT"; then
      echo "$OUT" >&2; exit 1
    fi
  fi
done
TOOLS_IP=$(first_ip kit-devpi-internal-1)
for PKG in setuptools wheel; do
  if ! curl -sf -u "root:${DEVPI_PW}" \
      "$TOOLS_IP:3141/root/doorbellino/+simple/$PKG/" | grep -q whl; then
    echo "[seed] ERROR: $PKG missing from INTERNAL devpi after upload (index: $TOOLS_IP)" >&2
    exit 1
  fi
done
say "setuptools/wheel mirrored to INTERNAL devpi (verified on +simple)"

# 3. GitLab group + project
# 409 'already exists' on create is fine (re-seed); the search fallback then
# resolves the id. If the API answers with an error object (bad/expired token)
# instead of a list, the naive [0] lookup raised 'KeyError: 0' with no clue —
# so parse defensively and fail with a real message if the id stays empty.
GID=$(curl -s -X POST "$GITLAB_API/groups" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=doorbellino&path=doorbellino&visibility=private" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$GID" ]; then
  GID=$(curl -s "$GITLAB_API/groups?search=doorbellino" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null || true)
fi
[ -z "$GID" ] && { echo "[seed] ERROR: could not resolve group doorbellino id (is GITLAB_ROOT_TOKEN valid? did gitlab-init.sh run?)" >&2; exit 1; }
PID=$(curl -s -X POST "$GITLAB_API/projects" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=firmware&namespace_id=$GID&visibility=private" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$PID" ]; then
  PID=$(curl -s "$GITLAB_API/projects?search=firmware" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null || true)
fi
[ -z "$PID" ] && { echo "[seed] ERROR: could not resolve project firmware id (is GITLAB_ROOT_TOKEN valid? did gitlab-init.sh run?)" >&2; exit 1; }
say "project doorbellino/firmware id=$PID"

# 3b. register the CI runner as a PROJECT runner scoped to this project.
# Newer gitlab-ce images restrict instance-runner creation (gitlab-init.sh
# used to do exactly that and died with 'token is missing' / 403); a
# maintainer creating a runner for their own project always works. Idempotent
# for re-seeds: if a runner is already registered for this project, skip.
EXISTING=$(curl -s "$GITLAB_API/projects/$PID/runners?status=online" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 0)' 2>/dev/null || echo 0)
if [ "${EXISTING:-0}" -gt 0 ]; then
  say "project runner already registered, skipping"
else
  # POST /user/runners with runner_type=project_type CREATES a runner;
  # POST /projects/:id/runners merely ENABLES an existing one (it 400s with
  # 'runner_id is missing') — that wrong endpoint produced exactly that.
  RUNNER_RESP=$(curl -s -X POST "$GITLAB_API/user/runners" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"runner_type\":\"project_type\",\"project_id\":$PID,\"description\":\"lab-runner\",\"tag_list\":\"lab\",\"paused\":false,\"locked\":false}")
  RUNNER_REG=$(echo "$RUNNER_RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("token",""))' 2>/dev/null || true)
  if [ -z "$RUNNER_REG" ]; then
    echo "[seed] ERROR: could not create project runner token. GitLab API said:" >&2
    echo "$RUNNER_RESP" >&2
    exit 1
  fi
  docker exec kit-gitlab-runner-1 gitlab-runner register \
    --non-interactive --url http://gitlab --token "$RUNNER_REG" \
    --executor docker --docker-image python:3.12-slim \
    --docker-network-mode kit_labnet --docker-pull-policy if-not-present \
    --env FF_NETWORK_PER_BUILD=0
  # Belt and braces: some runner versions ignore the env at register time.
  # network_mode must be set in config.toml AND the per-build feature flag
  # off, or jobs land on an isolated network where 'gitlab' doesn't resolve.
  docker exec kit-gitlab-runner-1 sh -c \
    "grep -q 'FF_NETWORK_PER_BUILD' /etc/gitlab-runner/config.toml || \
     sed -i 's|^\[runners.docker\]|[runners.docker]\n    network_mode = \"kit_labnet\"\n    environment = [\"FF_NETWORK_PER_BUILD=0\"]|' /etc/gitlab-runner/config.toml"
  # The esp32-firmware job uses the locally prefetched espressif/idf image
  # (the lab is airgapped: a 'never' policy would kill EVERY job on a cold
  # cache, so 'if-not-present' is the offline-correct setting).
  docker exec kit-gitlab-runner-1 sh -c \
    "grep -q 'PullPolicy' /etc/gitlab-runner/config.toml || \
     sed -i 's|^\[runners.docker\]|[runners.docker]\n    pull_policy = [\"if-not-present\"]|' /etc/gitlab-runner/config.toml"
  docker restart kit-gitlab-runner-1 >/dev/null
  say "project runner registered"
fi

# 4. vendor's PUBLIC hal repo: the HAL source is developed in the open
# (like espressif/esp-idf): the player/attacker clones it in P2 to build a
# plausible 2.x. The internal index serves the vendor's own 1.4.2 WHEEL.
# The GROUP must be public first: GitLab refuses public projects in a
# private namespace ('public is not allowed in a private namespace').
curl -s -X PUT "$GITLAB_API/groups/$GID" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H 'Content-Type: application/json' -d '{"visibility":"public"}' >/dev/null
HPID=$(curl -s -X POST "$GITLAB_API/projects" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=doorbellino-hal&namespace_id=$GID&visibility=public" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$HPID" ]; then
  HPID=$(curl -s "$GITLAB_API/projects?search=doorbellino-hal" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null || true)
fi
[ -z "$HPID" ] && { echo "[seed] ERROR: could not resolve project doorbellino-hal id" >&2; exit 1; }
say "public hal repo doorbellino/doorbellino-hal id=$HPID"

# 4. push firmware source
# git's root-ownership check ('dubious ownership') kills every command on
# fresh installs where the kit was rsync'd/copied as another user: mark the
# repo safe first (idempotent), and don't swallow push failures silently.
cd vendor/firmware
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
# Normalize to 'main': git's init default branch differs per machine
# (master upstream, main if the user configured it) and the CI + e2e tests
# pin ref=main. -b main needs git >=2.28; fall back to rename.
git init -q -b main 2>/dev/null || { git init -q && git branch -M main; }
git add -A && git -c user.email=vendor@doorbellino -c user.name=vendor commit -qm "v1.4.2" 2>/dev/null || true
git remote add origin "http://root:$GITLAB_ROOT_PW@$GIT_IP/doorbellino/firmware.git" 2>/dev/null || \
  git remote set-url origin "http://root:$GITLAB_ROOT_PW@$GIT_IP/doorbellino/firmware.git"
# NB: push ONLY main, never fall back to master. A `git init -b main` on an
# EXISTING repo (re-seed on a kit that already has vendor/firmware/.git from an
# older seed) is a NO-OP and keeps whatever branch the old checkout sits on,
# so a master fallback here would silently ship master instead of main, then
# the cleanup below would delete that same master from the remote, leaving
# the repo with no main at all: the step-7 pipeline trigger (ref=main) then
# fails with 'Reference not found'. Force-create/switch to main explicitly.
git checkout -q -B main || { echo "[seed] ERROR: cannot switch vendor/firmware to main" >&2; exit 1; }
# Re-seed: main is already protected with force-push DISALLOWED by default.
# Lift it BEFORE the push (the old order un-protected after pushing, so every
# re-seed died here with 'You are not allowed to force push'). PUT updates
# allow_force_push on the existing rule; POST creates it on a fresh project.
IP_FW=$(first_ip kit-gitlab-1)
curl -s -X PUT "http://$IP_FW:80/api/v4/projects/$PID/protected_branches/main" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H 'Content-Type: application/json' -d '{"allow_force_push":true}' >/dev/null 2>&1 || true
curl -s -X POST "http://$IP_FW:80/api/v4/projects/$PID/protected_branches" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=main&push_access_level=30&merge_access_level=30&allow_force_push=true" >/dev/null 2>&1 || true
if ! git push -qfu origin main; then
  echo "[seed] ERROR: firmware git push failed (see git output above)" >&2
  exit 1
fi
# remove a stray 'master' from seeds made before the main-normalization:
# unprotect it first (GitLab protects the project default branch), then
# delete; then make sure main is protected with force-push allowed.
IP_OLD=$(first_ip kit-gitlab-1)
curl -s -X DELETE "http://$IP_OLD:80/api/v4/projects/$PID/protected_branches/master" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" >/dev/null 2>&1 || true
git push -qfu origin --delete master 2>/dev/null || true
curl -s -X POST "http://$IP_OLD:80/api/v4/projects/$PID/protected_branches" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=main&push_access_level=30&merge_access_level=30&allow_force_push=true" >/dev/null 2>&1 || true
cd ../..
say "firmware source pushed"

# 4b. push the public HAL source (same pattern as the firmware repo push:
# fresh init, remote baked with root auth, force-push, main normalized).
# No CI/CD on this repo: it's the vendor's library mirror, releases ride
# the firmware pipeline.
cd vendor/doorbellino-hal
git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
git init -q -b main 2>/dev/null || { git init -q && git branch -M main; }
git add doorbellino_hal pyproject.toml
git -c user.email=vendor@doorbellino.lab -c user.name="DoorBellino Vendor" \
  commit -qm "doorbellino-hal v1.4.2" 2>/dev/null || true
git remote remove origin 2>/dev/null || true
git remote add origin "http://root:$GITLAB_ROOT_PW@$GIT_IP/doorbellino/doorbellino-hal.git"
# same re-seed ordering fix as the firmware repo: allow force-push first
IP_HAL=$(first_ip kit-gitlab-1)
curl -s -X PUT "http://$IP_HAL:80/api/v4/projects/$HPID/protected_branches/main" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H 'Content-Type: application/json' -d '{"allow_force_push":true}' >/dev/null 2>&1 || true
curl -s -X POST "http://$IP_HAL:80/api/v4/projects/$HPID/protected_branches" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=main&push_access_level=30&merge_access_level=30&allow_force_push=true" >/dev/null 2>&1 || true
if ! git push -qfu origin main 2>/dev/null; then
  echo "[seed] ERROR: doorbellino-hal git push failed" >&2
  exit 1
fi
git remote remove origin
cd ../..
say "public hal source pushed to doorbellino/doorbellino-hal"

# 4c. push the ESP32 DEVICE source (the real firmware the hardware tier
# flashes: CMake project, main/, partitions, sanitized sdkconfig template)
# as a third repo, private doorbellino/esp32-firmware. The local
# doorbellino/sdkconfig carries the REAL WiFi/keys/venue IPs: identity,
# never pushed, only sdkconfig.defaults goes. Git-init happens on a /tmp
# COPY, never in the kit tree: a nested .git inside firmware-esp32/ would
# land in the workshop repo on the next `git add -A` (same rule as
# kit/vendor/firmware/.git).
DPID=$(curl -s -X POST "$GITLAB_API/projects" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=esp32-firmware&namespace_id=$GID&visibility=private" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$DPID" ]; then
  DPID=$(curl -s "$GITLAB_API/projects?search=esp32-firmware" -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null || true)
fi
[ -z "$DPID" ] && { echo "[seed] ERROR: could not resolve project esp32-firmware id" >&2; exit 1; }
say "device repo doorbellino/esp32-firmware id=$DPID"

rm -rf /tmp/esp32-fw-seed && mkdir -p /tmp/esp32-fw-seed/doorbellino
cp firmware-esp32/Makefile /tmp/esp32-fw-seed/
cp firmware-esp32/.gitlab-ci.yml firmware-esp32/pad_and_verify.py /tmp/esp32-fw-seed/
# the sign/deploy jobs cp vendor/firmware/{sign_fw,ota_push}.py from the repo:
# without these two the board pipeline dies at the sign job ('No such file or
# directory') and the board channel stays empty forever
mkdir -p /tmp/esp32-fw-seed/vendor/firmware
cp vendor/firmware/sign_fw.py vendor/firmware/ota_push.py /tmp/esp32-fw-seed/vendor/firmware/
cp firmware-esp32/doorbellino/CMakeLists.txt \
   firmware-esp32/doorbellino/partitions.csv \
   firmware-esp32/doorbellino/sdkconfig.defaults /tmp/esp32-fw-seed/doorbellino/
cp -r firmware-esp32/doorbellino/main /tmp/esp32-fw-seed/doorbellino/main
cd /tmp/esp32-fw-seed
git init -q -b main 2>/dev/null || { git init -q && git branch -M main; }
git add -A
git -c user.email=vendor@doorbellino.lab -c user.name="DoorBellino Vendor" \
  commit -qm "doorbellino esp32 device firmware" || true
git remote add origin "http://root:$GITLAB_ROOT_PW@$GIT_IP/doorbellino/esp32-firmware.git"
if ! git push -qfu origin main 2>/dev/null; then
  echo "[seed] ERROR: esp32-firmware git push failed" >&2
  exit 1
fi
cd "$KIT_ROOT"
# protect main with force-push allowed, or the NEXT re-seed's force-push
# dies on the default protected-branch policy (same as the firmware repo).
# POST 400s when GitLab already auto-protected the default branch, so fall
# through to PUT which updates allow_force_push on the existing rule.
curl -s -X POST "$GITLAB_API/projects/$DPID/protected_branches" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "name=main&push_access_level=30&merge_access_level=30&allow_force_push=true" >/dev/null 2>&1 || true
curl -s -X PUT "$GITLAB_API/projects/$DPID/protected_branches/main" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -H 'Content-Type: application/json' -d '{"allow_force_push":true}' >/dev/null 2>&1 || true
rm -rf /tmp/esp32-fw-seed
# verify the push landed (a quiet push failure must not read as success)
NB=$(curl -s "$GITLAB_API/projects/$DPID/repository/branches" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else 0)' 2>/dev/null || echo 0)
if [ "${NB:-0}" -lt 1 ]; then
  echo "[seed] ERROR: esp32-firmware has no branch after push" >&2
  exit 1
fi
say "esp32 device source pushed to doorbellino/esp32-firmware (branch verified)"

# 5. CI variables
# NB: GITLAB_TRIGGER_TOKEN is NOT created here. It used to be seeded as
# "${GITLAB_TRIGGER_TOKEN:-}" — an empty value when unset — and that empty
# husk then made seed-deploy-hijack.sh's POST fail with 400 'already been
# taken' (silently: its output went to /dev/null), so build jobs saw
# tok=False forever. The hijack script owns this variable: it creates or
# UPDATES it with the real project-access token.
for kv in "SIGNING_KEY:$SIGNING_KEY" "SIGNING_PUB:$SIGNING_PUB" \
          "OTA_PUSH_TOKEN:$OTA_PUSH_TOKEN" \
          "EXTRA_INDEX_URL:http://devpi-public:3141/root/pub" \
          "INTERNAL_PYPI:http://devpi-internal:3141/root/doorbellino" \
          "OTA_URL:http://ota:8080" \
          "COLLECTOR_URL:http://collector:9000"; do
  K="${kv%%:*}"; V="${kv#*:}"
  curl -s -X POST "$GITLAB_API/projects/$PID/variables" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    -d "key=$K&value=$V&masked=$([ $K = SIGNING_KEY -o $K = OTA_PUSH_TOKEN ] && echo true || echo false)" >/dev/null
done
say "CI variables set (SIGNING_KEY + OTA_PUSH_TOKEN masked)"

# 5b. esp32-firmware CI variables — the hardware tier's pipeline needs the
# REAL device config (WiFi credentials, OTA/collector base URLs) that lives
# in the presenter's LOCAL, gitignored sdkconfig. Extract it here so the
# board pipeline builds a image that joins the actual lab WiFi and polls
# the actual OTA server — no manual CI-variable typing.
CFG=firmware-esp32/doorbellino/sdkconfig
cfg_val() {  # $1 = CONFIG_ name -> prints the quoted value or empty
  [ -f "$CFG" ] || return 0
  sed -n "s/^${1}=\"\(.*\)\"$/\1/p" "$CFG" | tail -n1
}
BOARD_SSID=$(cfg_val CONFIG_DOORBELLINO_WIFI_SSID)
BOARD_PASS=$(cfg_val CONFIG_DOORBELLINO_WIFI_PASS)
BOARD_OTA=$(cfg_val CONFIG_DOORBELLINO_OTA_URL)
BOARD_COLLECTOR=$(cfg_val CONFIG_DOORBELLINO_COLLECTOR_URL)
MISSING=""
[ -n "$BOARD_SSID" ] || MISSING="$MISSING CONFIG_DOORBELLINO_WIFI_SSID"
[ -n "$BOARD_PASS" ] || MISSING="$MISSING CONFIG_DOORBELLINO_WIFI_PASS"
[ -n "$BOARD_OTA" ] || MISSING="$MISSING CONFIG_DOORBELLINO_OTA_URL"
[ -n "$BOARD_COLLECTOR" ] || MISSING="$MISSING CONFIG_DOORBELLINO_COLLECTOR_URL"
if [ -n "$MISSING" ]; then
  echo "[seed] ERROR: esp32-firmware CI variables missing:$MISSING" >&2
  echo "  add them to firmware-esp32/doorbellino/sdkconfig (copy from sdkconfig.defaults" >&2
  echo "  and edit), or set DOORBELLINO_WIFI_SSID/WIFI_PASS/OTA_URL/COLLECTOR_URL in .env." >&2
  exit 1
fi
# masked=false on WiFi_PASS: masking breaks on short values and this is a
# lab-only credential; the .env already carries the same secret in cleartext.
for kv in "DOORBELLINO_WIFI_SSID:$BOARD_SSID" \
          "DOORBELLINO_WIFI_PASS:$BOARD_PASS" \
          "DOORBELLINO_OTA_URL:$BOARD_OTA" \
          "DOORBELLINO_COLLECTOR_URL:$BOARD_COLLECTOR" \
          "EXTRA_INDEX_URL:http://devpi-public:3141/root/pub" \
          "INTERNAL_PYPI:http://devpi-internal:3141/root/doorbellino" \
          "COLLECTOR_URL:http://collector:9000"; do
  K="${kv%%:*}"; V="${kv#*:}"
  curl -s -X POST "$GITLAB_API/projects/$DPID/variables" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    -d "key=$K&value=$V&masked=false" >/dev/null
done
# OTA_PUSH_TOKEN: the deploy job pushes to the OTA server with the SAME
# bearer token the vendor project uses (one OTA server, one push token).
# Without it the deploy job 401s and the board channel stays empty.
curl -s -X POST "$GITLAB_API/projects/$DPID/variables" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "key=OTA_PUSH_TOKEN&value=$OTA_PUSH_TOKEN&masked=true" >/dev/null
# BOARD_CI_OTA_URL: where the CI deploy job pushes the signed image. This is
# the OTA server's address ON THE COMPOSE NETWORK, resolved fresh at seed
# time. It is deliberately separate from DOORBELLINO_OTA_URL (that one is
# compiled into the board image as the URL the physical board polls from its
# own WiFi, typically the presenter's LAN); using the same value made the
# deploy job try to reach 192.168.x.x from a runner container and die with
# 'Network is unreachable'.
OTA_LABIP=$(first_ip kit-ota-1)
curl -s -X POST "$GITLAB_API/projects/$DPID/variables" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "key=BOARD_CI_OTA_URL&value=http://$OTA_LABIP:8080&masked=false" >/dev/null
# SIGNING_PUB rides along so the CI build can stamp the vendor anchor into
# the image's sdkconfig (structural parity with the USB-flashed image; the
# C firmware itself never verifies ed25519 — see .gitlab-ci.yml header).
curl -s -X POST "$GITLAB_API/projects/$DPID/variables" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  -d "key=SIGNING_PUB&value=$SIGNING_PUB&masked=false" >/dev/null
say "esp32-firmware CI variables set from local sdkconfig (WiFi/OTA/collector)"

# 6. deploy-gate trigger token (the hook's way back in)
TRIG=$(curl -s -X POST "$GITLAB_API/projects/$PID/pipeline_schedule_trigger" 2>/dev/null >/dev/null; \
  curl -s -X POST "$GITLAB_API/projects/$PID/access_tokens" 2>/dev/null || true)
bash "$SEED_DIR/seed-deploy-hijack.sh"

# 7. first release, end to end: the vendor's pipeline #1 runs green and the
# manual deploy gate is played ONCE, so the OTA server serves 1.4.2 and the
# virtual device applies it before the player ever opens the guide. Without
# this the device sits silent on a fresh stack (nothing on the manifest),
# which reads as a broken lab. This is the vendor's own honest click (root
# PAT, the human in the loop): the ATTACKER play with the looted
# GITLAB_TRIGGER_TOKEN stays Task 2.4's move, on a pipeline the player
# triggers. Idempotent: if the OTA server already serves a manifest (re-seed
# or a previous run got through the play), the whole step is skipped.
ALREADY=$(curl -s "http://$(first_ip kit-ota-1):8080/manifest.json")
M="$ALREADY"
FRESH_DEPLOY=0
if echo "$M" | grep -q '"version"'; then
  say "OTA manifest already present ($(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo '?')), skipping first-release deploy"
  say "  (the device already runs it; the NEXT deploy ships served+1 via the sign_fw.py version ladder and the device applies it)"
else
  FRESH_DEPLOY=1
  say "triggering the vendor's first pipeline (build -> test -> sign)..."
  PCODE=$(curl -s -o /tmp/seed-pipe.json -w '%{http_code}' -X POST \
    "$GITLAB_API/projects/$PID/pipeline" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" -d "ref=main")
  [ "$PCODE" = 201 ] || [ "$PCODE" = 200 ] || {
    echo "[seed] ERROR: pipeline trigger failed (HTTP $PCODE):" >&2
    cat /tmp/seed-pipe.json >&2
    exit 1
  }
  PIPE_ID=$(python3 -c 'import json;print(json.load(open("/tmp/seed-pipe.json"))["id"])')
  say "pipeline #$PIPE_ID created, waiting for sign to go green (runner cold start can take a few minutes)..."
  for i in $(seq 1 60); do
    sleep 10
    ST=$(curl -s "$GITLAB_API/projects/$PID/pipelines/$PIPE_ID" \
      -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" | python3 -c \
      'import sys,json;print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
    case "$ST" in
      running|pending|manual|created|waiting_for_resource|preparing) : ;;
      *) break ;;
    esac
  done
  if [ "$ST" != "success" ]; then
    echo "[seed] ERROR: first pipeline ended '$ST' (wanted success). Inspect it:" >&2
    echo "  curl -s \"$GITLAB_API/projects/$PID/pipelines/$PIPE_ID/jobs\" -H \"PRIVATE-TOKEN: \$GITLAB_ROOT_TOKEN\"" >&2
    exit 1
  fi
  say "pipeline #$PIPE_ID green; playing the manual deploy gate (the vendor's own click)"
  JDATA=$(curl -s "$GITLAB_API/projects/$PID/pipelines/$PIPE_ID/jobs" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN")
  JOB_ID=$(echo "$JDATA" | python3 -c '
import sys, json
try:
    jobs = json.load(sys.stdin)
    print(next(j["id"] for j in jobs if j["name"] == "deploy"))
except Exception:
    sys.exit("no deploy job in pipeline response")')
  PLAY=$(curl -s -o /tmp/seed-play.json -w '%{http_code}' -X POST \
    "$GITLAB_API/projects/$PID/jobs/$JOB_ID/play" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN")
  [ "$PLAY" = 201 ] || [ "$PLAY" = 200 ] || {
    echo "[seed] ERROR: deploy play failed (HTTP $PLAY):" >&2
    cat /tmp/seed-play.json >&2
    exit 1
  }
  # the deploy job runs ~seconds (push to the OTA server); wait for the job
  # AND for the manifest to actually land before declaring victory.
  for i in $(seq 1 12); do
    sleep 5
    M=$(curl -s "http://$(first_ip kit-ota-1):8080/manifest.json")
    echo "$M" | grep -q '"version"' && break
  done
  echo "$M" | grep -q '"version"' || {
    echo "[seed] ERROR: deploy job played but no manifest on the OTA server after 60s:" >&2
    echo "  docker logs kit-ota-1 ; check the deploy job log (job $JOB_ID)" >&2
    exit 1
  }
  say "first release deployed: $(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')"
fi

# 8. confirm the device APPLIED it (this is the line the guide promises).
# Only meaningful on a FRESH deploy: on a re-seed the deploy above is
# skipped and the device already runs that exact version (its apply rule
# is version-change-only, so re-checking would fail on our own skip).
if [ "$FRESH_DEPLOY" = 1 ]; then
  # Version-change-only rule: a same-version manifest would sit invisible, so
  # assert the applied VERSION matches the manifest, not just any log line.
  say "waiting for the virtual device to apply the release (poll cycle is 30s)..."
  APPLIED=""
  WANT="[ota] applied $(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')"
  for i in $(seq 1 12); do
    sleep 10
    APPLIED=$(docker logs kit-virtual-device-1 2>&1 | grep -o '\[ota\] applied [0-9.]*' | tail -n1 || true)
    [ "$APPLIED" = "$WANT" ] && break
  done
  [ "$APPLIED" = "$WANT" ] || {
    echo "[seed] ERROR: device never logged '$WANT' (last seen: '${APPLIED:-nothing}')." >&2
    echo "  docker logs kit-virtual-device-1 ; if it is stuck, docker restart kit-virtual-device-1" >&2
    exit 1
  }
  say "virtual device applied the release: $APPLIED"
fi

# 9a. the board pipeline needs a runner. The runner was registered as a
# PROJECT runner scoped to the vendor repo only; GitLab will NOT offer it
# to esp32-firmware, whose build job then sits 'Pending / no active
# runners' forever. ENABLE the same runner on the esp32 project here
# (POST /projects/:id/runners with runner_id; idempotent: 409/400 when
# already enabled is fine). This is exactly what had to be done in the
# GitLab UI by hand on the first hardware-tier run.
RID_LIST=$(curl -s "$GITLAB_API/projects/$PID/runners" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null || true)
if [ -n "$RID_LIST" ]; then
  curl -s -X POST "$GITLAB_API/projects/$DPID/runners" \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"runner_id\":$RID_LIST}" >/dev/null 2>&1 || true
  # runner caches its project list per poll cycle: restart so the board
  # job is picked up immediately instead of after the next check_interval
  docker restart kit-gitlab-runner-1 >/dev/null 2>&1 || true
  say "runner #$RID_LIST enabled on esp32-firmware"
else
  say "WARNING: no vendor runner found to enable on esp32-firmware; its jobs will stay pending"
fi

# 9. board channel bootstrap: the seed already serves the shared channel,
# so the board ladder's floor is settled. KICK the esp32-firmware pipeline
# once, right here, so the board channel gets its first REAL 0xE9 image
# without the presenter ever running kit/ota-esp32-push.sh by hand. The
# wait is bounded: the esp-idf build takes minutes, but a FAILURE here
# must not fail the seed (the manual push script remains the fallback and
# the virtual-tier lab is fully playable without the hardware tier).
say "triggering the esp32-firmware pipeline (real board image -> board channel)..."
BCODE=$(curl -s -o /tmp/seed-bpipe.json -w '%{http_code}' -X POST \
  "$GITLAB_API/projects/$DPID/pipeline" \
  -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" -d "ref=main")
if [ "$BCODE" = 201 ] || [ "$BCODE" = 200 ]; then
  BPIPE_ID=$(python3 -c 'import json;print(json.load(open("/tmp/seed-bpipe.json"))["id"])')
  say "  board pipeline #$BPIPE_ID created; waiting up to 25 min for espressif/idf build..."
  BST="unknown"
  for i in $(seq 1 150); do
    sleep 10
    BST=$(curl -s "$GITLAB_API/projects/$DPID/pipelines/$BPIPE_ID" \
      -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" | python3 -c \
      'import sys,json;print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)
    case "$BST" in
      running|pending|created|waiting_for_resource|preparing) : ;;
      *) break ;;
    esac
  done
  if [ "$BST" = "success" ]; then
    BM=$(curl -s "http://$(first_ip kit-ota-1):8080/board/manifest.json")
    if echo "$BM" | grep -q '"version"'; then
      say "board channel live: $(echo "$BM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])') (the physical board takes it on its next poll)"
    else
      say "WARNING: board pipeline green but no board manifest yet (check the deploy job)"
    fi
  else
    say "WARNING: board pipeline ended '$BST' — board channel not seeded."
    say "  The physical board keeps rejecting the shared blob; fallback:"
    say "  ./ota-esp32-push.sh (host-side manual push) or inspect the pipeline:"
    say "  curl -s \"$GITLAB_API/projects/$DPID/pipelines/$BPIPE_ID/jobs\" -H \"PRIVATE-TOKEN: \\$GITLAB_ROOT_TOKEN\""
  fi
else
  say "WARNING: board pipeline trigger failed (HTTP $BCODE) — run ./ota-esp32-push.sh manually for the board channel."
fi

say "P0 SEED COMPLETE — pipeline ran green, the deploy gate was played once, and
the device runs the honest release. Trigger the NEXT pipeline in P2 (GitLab UI
or: curl -X POST $GITLAB_API/projects/$PID/pipeline -H 'PRIVATE-TOKEN: <token>' -d 'ref=main')"
