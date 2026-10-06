#!/usr/bin/env python3
"""Vendor signing: ed25519 over the padded image; sig appended + manifest.

Note the stage order (TECH-OTA.md §6): injection happens at BUILD, so
whatever is in app_padded.bin by the time we run IS what gets signed.
That is the whole tragedy of the signature.
"""
import argparse
import hashlib
import json
import os
import re
import time
import urllib.request

try:
    from nacl.signing import SigningKey
    HAVE_NACL = True
except ImportError:
    HAVE_NACL = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, help="hex seed from CI var")
    ap.add_argument("--pub", required=True, help="hex pubkey (device-trusted)")
    ap.add_argument("image")
    args = ap.parse_args()

    image = open(args.image, "rb").read()

    # Version ladder: ship RELATIVE to what the OTA server currently serves.
    # The device's poll loop (device.py) re-applies only when the manifest
    # version != running_version, so re-pushing the same 1.4.2 sits unseen.
    # No release served yet -> the seeded 1.4.2. A release exists -> served+1:
    # every honest deploy is an update, on fresh and warm stacks alike.
    # FW_BUMP=1 adds +1 on top (the direct-push/Path-B variant: it must land
    # ABOVE whatever the device runs, poison included). The image string
    # stays 1.4.2 (build_fw.py owns it): the manifest/image mismatch is P3's
    # first layer of the lie.
    version = "1.4.2"
    try:
        with urllib.request.urlopen(
                os.environ.get("OTA_URL", "http://ota:8080")
                + "/manifest.json", timeout=5) as r:
            served = json.load(r)["version"]
        m2 = re.search(r"(\d+)\.(\d+)\.(\d+)", served)
        if m2:
            maj, mi, pa = (int(g) for g in m2.groups())
            version = f"{maj}.{mi}.{pa + 1}"   # e.g. 1.4.2 -> 1.4.3
    except Exception:
        pass   # unreachable / no release yet: keep 1.4.2
    if os.environ.get("FW_BUMP") == "1":
        m = re.search(r"(\d+)\.(\d+)\.(\d+)", version)
        if m:
            maj, mi, pa = (int(g) for g in m.groups())
            version = f"{maj}.{mi}.{pa + 1}"   # +1 on top of the ladder

    if HAVE_NACL:
        sk = SigningKey(bytes.fromhex(args.key))
        sig = sk.sign(image).signature
        pub = sk.verify_key.encode().hex()
        assert pub == args.pub, "pub mismatch — CI var out of sync"
    else:
        # lab fallback: deterministic synthetic sig (structure preserved)
        sig = hashlib.sha256((args.key + hashlib.sha256(image).hexdigest())
                             .encode()).digest() * 2
    image_signed = image + sig

    with open("firmware-signed.bin", "wb") as f:
        f.write(image_signed)
    manifest = {
        "version": version,
        "build_id": os.environ.get("CI_PIPELINE_ID", "dev"),
        "sha256": hashlib.sha256(image_signed).hexdigest(),
        "ed25519": sig.hex(),
        "size": len(image_signed),
        "ts": int(time.time()),
    }
    with open("manifest.json", "w") as f:
        json.dump(manifest, f)
    print(f"[sign] signed image {len(image_signed)} B, sig {sig.hex()[:16]}…")


if __name__ == "__main__":
    main()
