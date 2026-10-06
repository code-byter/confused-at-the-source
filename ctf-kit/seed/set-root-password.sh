#!/usr/bin/env bash
# set-root-password.sh — (re)set the GitLab root password from .env
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PW=$(grep '^GITLAB_ROOT_PW=' "$KIT/.env" | cut -d= -f2)
sudo -n docker exec kit-gitlab-1 gitlab-rails runner /tmp/setpw.rb 2>/dev/null || {
  cat > /tmp/setpw.rb <<EOF
u = User.find_by(username: 'root')
u.password = '${PW}'
u.password_confirmation = '${PW}'
u.save!
puts 'PW-SET'
EOF
  sudo -n docker cp /tmp/setpw.rb kit-gitlab-1:/tmp/setpw.rb
  sudo -n docker exec kit-gitlab-1 gitlab-rails runner /tmp/setpw.rb 2>&1 | grep -E 'PW-SET|ERROR' || true
}
