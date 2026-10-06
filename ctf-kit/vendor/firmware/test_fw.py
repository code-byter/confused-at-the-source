#!/usr/bin/env python3
"""Vendor release tests: run against app_padded.bin BEFORE signing."""
import sys


def main():
    img = open("app_padded.bin", "rb").read()
    assert len(img) == 0x1F0000, "image not padded to partition size"
    assert b"DOORBELLINO|1.4.2" in img[:32], "version header missing"
    # The implant slot must be zero in an honest release.
    assert img[0x1E0000:0x1E0100] == bytes(0x100), "implant slot not clean"
    print("[test] 3/3 passed — image is clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
