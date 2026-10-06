#!/usr/bin/env python3
"""Vendor deploy: push signed image + manifest to the OTA server."""
import argparse
import hashlib
import json
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ota", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--target", choices=["shared", "board"], default="shared",
                    help="shared = virtual-tier channel (default), "
                         "board = physical ESP32 channel (real 0xE9 image)")
    ap.add_argument("image")
    ap.add_argument("manifest")
    args = ap.parse_args()

    image = open(args.image, "rb").read()
    manifest = json.load(open(args.manifest))
    assert hashlib.sha256(image).hexdigest() == manifest["sha256"], "sha mismatch"
    body = json.dumps({"manifest": manifest, "image_hex": image.hex()}).encode()
    req = urllib.request.Request(
        args.ota + "/push", data=body,
        headers={"Authorization": f"Bearer {args.token}",
                 "Content-Type": "application/json",
                 "X-Target": args.target})
    with urllib.request.urlopen(req, timeout=30) as r:
        print("[deploy] OTA server:", r.read().decode())


if __name__ == "__main__":
    main()
