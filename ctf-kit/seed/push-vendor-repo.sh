#!/bin/bash
# push-vendor-repo.sh — commit + push the vendor firmware source to GitLab
set -euo pipefail
cd "$(dirname "$0")/../vendor/firmware"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PW=$(grep '^GITLAB_ROOT_PW=' "$KIT/.env" | cut -d= -f2)

git init -q 2>/dev/null || true
git add -A
git -c user.email=vendor@doorbellino.lab -c user.name="DoorBellino Vendor" commit -qm "DoorBellino firmware v1.4.2" || true
git remote remove origin 2>/dev/null || true
git remote add origin "http://root:${PW}@172.18.0.5/doorbellino/firmware.git"
git push -qfu origin main 2>&1 | tail -1 || git push -qfu origin master 2>&1 | tail -1
echo PUSHED
