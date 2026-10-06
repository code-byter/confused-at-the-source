#!/usr/bin/env python3
"""Pad a compiled ESP32 app image to the app-partition size and verify it.

CI twin of kit/ota-esp32-push.sh's inline pad step:
  - input  MUST start with the esp_image magic 0xE9 (a real compiled image;
    the virtual-tier padded text blob starts with 'D' and is refused here,
    so the board channel can never be poisoned by the wrong artifact)
  - output = input zero-filled to 0x1F0000 (partitions.csv app_a/app_b),
    same layout the OTA server serves and the board writes into a bank
  - the implant slot at +0x1E0000 must be zero in an honest build: if a
    later lab variant injects at build time, this check catches an
    accidental injection before it ever reaches a board.
"""
import hashlib
import sys

PART_SIZE = 0x1F0000 - 64  # the 64-byte ed25519 sig is appended AFTER padding (sign_fw); the final
                           # signed image must still fit the 0x1F0000 app partition or esp_ota_write
                           # fails on the physical board at the last chunk
IMPLANT_OFFSET = 0x1E0000


def main(src, dst):
    data = open(src, "rb").read()
    if not data or data[0] != 0xE9:
        sys.exit(f"ERROR: {src} does not start with the esp_image magic "
                 f"0xE9 (got 0x{data[0]:02x}). That is not a compiled "
                 "board image; refusing to serve it to the hardware tier.")
    if len(data) > PART_SIZE:
        sys.exit(f"ERROR: image {len(data)} B exceeds partition size "
                 f"{PART_SIZE}")
    padded = data.ljust(PART_SIZE, b"\x00")
    slot = padded[IMPLANT_OFFSET:IMPLANT_OFFSET + 0x100]
    if slot != bytes(0x100):
        sys.exit("ERROR: implant slot at +0x1E0000 is not clean in this "
                 "build — refusing to publish it as an honest board image")
    open(dst, "wb").write(padded)
    print(f"[pad] {len(data)} B -> {len(padded)} B, sha256 "
          f"{hashlib.sha256(padded).hexdigest()[:16]}…, magic 0xE9 OK, "
          "implant slot clean")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <image.bin> <padded.bin>")
    main(sys.argv[1], sys.argv[2])
