#!/usr/bin/env python3
"""Vendor build script: compile the app image, pad to partition size.

The version string baked in here is what the serial console will show —
and what the implant later lies about.
"""
import hashlib
import json
import os
import sys

FW_VERSION = "1.4.2"
APP_PARTITION_SIZE = 0x1F0000
IMPLANT_OFFSET = 0x1E0000  # fixed slot, see TECH-OTA.md


def build():
    code = f"DOORBELLINO|{FW_VERSION}".encode()
    image = bytearray(APP_PARTITION_SIZE)
    image[: len(code)] = code
    with open("app_padded.bin", "wb") as f:
        f.write(image)
    print(f"[build] app_padded.bin: {len(image)} bytes, fw {FW_VERSION}")
    print(f"[build] sha256 {hashlib.sha256(image).hexdigest()}")


if __name__ == "__main__":
    build()
