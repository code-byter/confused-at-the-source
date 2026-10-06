#!/usr/bin/env bash
# ota-esp32-push.sh — serve a REAL ESP32 image to the hardware tier.
#
# Why this exists: the seed pipeline builds the VIRTUAL tier image, a padded
# text blob ('DOORBELLINO|1.4.x' + zero fill). A board's esp_ota_write checks
# the esp_image header magic on the first byte and rejects that blob with
#   E esp_ota_ops: OTA image has invalid magic byte (expected 0xE9, saw 0x44)
# (0x44 = 'D'). The virtual device's mmap flash has no such check, so only
# the hardware tier hits this.
#
# Fix: take the compiled board image (firmware-esp32/doorbellino/build/
# doorbellino.bin, first byte 0xE9), pad it to the app-partition size,
# sign it with the lab vendor key (sign_fw.py, same version ladder as CI)
# and push it with the vendor deploy token (ota_push.py). The board then
# applies a real, bootable OTA instead of garbage: same app as the USB
# flash, same attack story (injection at 0x1E0000 happens BEFORE signing,
# so the signature story is unchanged).
#
# Usage:
#   ./ota-esp32-push.sh                       # use the default build image
#   ./ota-esp32-push.sh path/to/doorbellino.bin
#
# Requires: kit/.env (SIGNING_KEY, SIGNING_PUB, OTA_PUSH_TOKEN) and a built
# image (make build in firmware-esp32/). Run on the stack host; the OTA
# server is reached on loopback by default (stack ports are 127.0.0.1-only).
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$KIT_ROOT/firmware-esp32/doorbellino"
VENDOR="$KIT_ROOT/vendor/firmware"
PART_SIZE=$((0x1F0000 - 64))  # app_a/app_b minus the 64-byte ed25519 sig that
                              # sign_fw.py appends AFTER padding; the final signed
                              # image must fit the 0x1F0000 partition or the board's
                              # esp_ota_write fails on the last chunk
PUSH_URL="${OTA_PUSH_URL:-http://127.0.0.1:8080}"

# shellcheck disable=SC1091
[ -f "$KIT_ROOT/.env" ] && source "$KIT_ROOT/.env"
: "${SIGNING_KEY:?kit/.env must define SIGNING_KEY}"
: "${SIGNING_PUB:?kit/.env must define SIGNING_PUB}"
: "${OTA_PUSH_TOKEN:?kit/.env must define OTA_PUSH_TOKEN}"

IMG="${1:-$FW_DIR/build/doorbellino.bin}"
[ -f "$IMG" ] || { echo "ERROR: no image at $IMG (run: cd firmware-esp32 && make build)" >&2; exit 1; }

# Refuse anything that is not a real esp_image: this script exists because
# the fake padded blob must never reach a board again.
MAGIC=$(python3 - "$IMG" <<'PY'
import sys
print(open(sys.argv[1], "rb").read(1).hex())
PY
)
if [ "$MAGIC" != "e9" ]; then
  echo "ERROR: $IMG does not start with the esp_image magic 0xE9 (got 0x${MAGIC})." >&2
  echo "That looks like the virtual-tier padded blob, not a compiled board image." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$IMG" "$TMP/app_padded.bin" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
size = int("0x1F0000", 16) - 64  # reserve sig space, see PART_SIZE above
assert len(data) <= size, f"image {len(data)} B exceeds partition size {size}"
# zero-fill to the app-partition size, same layout as the virtual image:
# everything past the compiled app (incl. the implant slot at 0x1E0000)
# stays clean unless a hook put something there.
open(sys.argv[2], "wb").write(data.ljust(size, b"\x00"))
print(f"[pad] {len(data)} B -> {size} B (zero fill)")
PY

cd "$TMP"
# sign_fw.py owns the version ladder (served+1, FW_BUMP aware) and writes
# firmware-signed.bin + manifest.json into the CWD. The ladder reads the
# SHARED channel (the seed always serves it); the push goes to the BOARD
# channel (X-Target: board), so CI triggers re-serving the shared channel
# can never clobber the board's real image again.
OTA_URL="$PUSH_URL" python3 "$VENDOR/sign_fw.py" \
  --key "$SIGNING_KEY" --pub "$SIGNING_PUB" "$TMP/app_padded.bin"
python3 "$VENDOR/ota_push.py" --ota "$PUSH_URL" --token "$OTA_PUSH_TOKEN" \
  --target board firmware-signed.bin manifest.json

VERSION=$(python3 -c 'import json;print(json.load(open("manifest.json"))["version"])')
echo "[ota-esp32] serving real board image as $VERSION on the BOARD channel ($PUSH_URL/board/...)"
echo "[ota-esp32] the board applies it on its next poll (default 30 s):"
echo "[ota-esp32]   expect 'manifest [board channel]' then 'applying $VERSION'"
echo "[ota-esp32]   then the boot banner at offset 0x200000 (bank B)."
