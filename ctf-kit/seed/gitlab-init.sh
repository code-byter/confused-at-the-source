#!/usr/bin/env bash
# gitlab-init.sh — create root password + PAT inside a fresh GitLab.
# Runs INSIDE the gitlab container context (rails runner), so it can
# bootstrap credentials that no API call could create yet.
#
# Runner registration is NOT here anymore: it used to create an instance
# runner, but newer gitlab-ce images restrict instance-runner creation
# ("token is missing" / 403 via the API). seed.sh now registers a PROJECT
# runner scoped to doorbellino/firmware, right after it creates the project.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

# The PAT value must be a real secret: if .env still has up.sh's placeholder
# (or nothing), generate one. Reusing the constant placeholder would give
# every kit install the same root PAT string and trip seed.sh's preflight.
case "${GITLAB_ROOT_TOKEN:-}" in
  ""|placeholder-set-by-init)
    GITLAB_ROOT_TOKEN=$(openssl rand -hex 20)
    echo "[gitlab-init] generated fresh PAT value"
    ;;
esac

# 1. set root password via rails runner (idempotent)
# NB: docker exec NEEDS -i or stdin is not attached: the heredoc never reaches
# the container, 'gitlab-rails runner -' sees an empty script, exits 0, and
# this whole script no-ops while reporting success (the fresh-install 401 bug).
sudo -n docker exec -i kit-gitlab-1 gitlab-rails runner - <<EOF
u = User.find_by(username: 'root')
u.password = '$GITLAB_ROOT_PW'
u.password_confirmation = '$GITLAB_ROOT_PW'
u.save!
puts 'root password set'
EOF

# 2. create personal access token for the seed script
TOKEN=$(sudo -n docker exec -i kit-gitlab-1 gitlab-rails runner - <<EOF
t = User.find_by(username: 'root').personal_access_tokens.create(
  name: 'seed', scopes: [:api], expires_at: 30.days.from_now)
t.set_token('$GITLAB_ROOT_TOKEN')
t.save!
puts '$GITLAB_ROOT_TOKEN'
EOF
)
# Persist the actual token value used (may be a freshly generated one).
if grep -q '^GITLAB_ROOT_TOKEN=' .env; then
  sed -i "s|^GITLAB_ROOT_TOKEN=.*|GITLAB_ROOT_TOKEN=$GITLAB_ROOT_TOKEN|" .env
else
  printf 'GITLAB_ROOT_TOKEN=%s\n' "$GITLAB_ROOT_TOKEN" >> .env
fi
echo "[gitlab-init] PAT ready (written to .env)"
# Verify the PAT actually authenticates; rails-runner "success" alone proved
# nothing in the past (empty stdin => silent no-op). Brief retry: puma can
# still be settling on a freshly booted GitLab.
PAT_OK=""
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "PRIVATE-TOKEN: $GITLAB_ROOT_TOKEN" "http://127.0.0.1:8088/api/v4/user" || echo 000)
  [ "$CODE" = "200" ] && { PAT_OK=1; break; }
  sleep 3
done
if [ -z "$PAT_OK" ]; then
  echo "[gitlab-init] ERROR: new PAT failed GET /api/v4/user (HTTP $CODE)." >&2
  echo "  The rails runner blocks above MUST have printed 'root password set'" >&2
  echo "  and the token echo. If they printed nothing, docker exec lost the" >&2
  echo "  heredoc (needs -i) or gitlab-rails is still booting; retry in a minute." >&2
  exit 1
fi
echo "[gitlab-init] PAT verified against the API"
echo "[gitlab-init] next: ./seed/seed.sh (registers the project runner too)"
