# OTA update server — DoorBellino lab
# Serves /manifest.json + /firmware/<ver>.bin; accepts signed pushes at
# /push with a bearer token. Append-only manifest history (forensics).
#
# BOARD CHANNEL: the same OTA server also serves a board-scoped release at
# /board/manifest.json + /board/firmware/<ver>.bin. Why: the CI pipeline
# builds the VIRTUAL-tier image (padded text blob, no esp_image header), and
# every pipeline trigger re-serves it at served+1 — a physical board pulling
# the shared channel rejects it at esp_ota_write ('invalid magic byte,
# expected 0xE9'). A push with header X-Target: board writes the board
# channel instead (kit/ota-esp32-push.sh is the tool that produces it);
# the virtual device and the board then update independently and CI noise
# never reaches the board. A /board/* GET with no board release serves 404,
# and the board firmware falls back to the shared channel (old images keep
# working; the physical tier upgrades once ota-esp32-push.sh ran once).
import hashlib
import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUSH_TOKEN = os.environ["OTA_PUSH_TOKEN"].encode()
DATA_DIR = os.environ.get("OTA_DATA", "/data")
HISTORY = os.path.join(DATA_DIR, "manifest-history.jsonl")
BOARD_HISTORY = os.path.join(DATA_DIR, "manifest-history-board.jsonl")
MANIFEST = {"manifest": None, "board": None}
LOCK = threading.Lock()


def load_history(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        lines = [json.loads(x) for x in f if x.strip()]
    return lines[-1] if lines else None


def load_state():
    os.makedirs(os.path.join(DATA_DIR, "firmware"), exist_ok=True)
    os.makedirs(os.path.join(DATA_DIR, "firmware-board"), exist_ok=True)
    m = load_history(HISTORY)
    if m:
        MANIFEST["manifest"] = m
    b = load_history(BOARD_HISTORY)
    if b:
        MANIFEST["board"] = b


def handler_factory(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            with open(os.path.join(DATA_DIR, "access.log"), "a") as lg:
                lg.write(f"{self.client_address[0]} {fmt % args}\n")

        def _json(self, obj, code=200):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def _serve_bin(self, fname, fwdir):
            fname = os.path.basename(fname)          # e.g. "1.4.2.bin"
            if not fname.endswith(".bin"):
                fname += ".bin"
            p = os.path.join(DATA_DIR, fwdir, fname)
            if not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(p)))
            self.end_headers()
            with open(p, "rb") as f:
                while chunk := f.read(65536):
                    self.wfile.write(chunk)

        def do_GET(self):
            if self.path == "/manifest.json":
                m = state["manifest"]
                if not m:
                    return self._json({"error": "no release"}, 404)
                return self._json(m)
            if self.path == "/board/manifest.json":
                m = state["board"]
                if not m:
                    return self._json({"error": "no board release"}, 404)
                return self._json(m)
            if self.path.startswith("/firmware/"):
                return self._serve_bin(self.path[len("/firmware/"):],
                                       "firmware")
            if self.path.startswith("/board/firmware/"):
                return self._serve_bin(self.path[len("/board/firmware/"):],
                                       "firmware-board")
            if self.path == "/history":
                if not os.path.exists(HISTORY):
                    return self._json({"history": []})
                with open(HISTORY) as f:
                    return self._json({"history": [json.loads(x) for x in f if x.strip()]})
            return self._json({"error": "nope"}, 404)

        def do_POST(self):
            if self.path != "/push":
                return self._json({"error": "nope"}, 404)
            auth = self.headers.get("Authorization", "")
            if not hmac.compare_digest(auth, f"Bearer {PUSH_TOKEN.decode()}"):
                return self._json({"error": "unauthorized"}, 401)
            to_board = self.headers.get("X-Target", "") == "board"
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                payload = json.loads(body)
                image = bytes.fromhex(payload["image_hex"])
                manifest = payload["manifest"]
                sha = hashlib.sha256(image).hexdigest()
                assert sha == manifest["sha256"], "sha mismatch"
            except Exception as e:
                return self._json({"error": str(e)}, 400)
            entry = dict(manifest, pushed_ts=int(time.time()),
                         pushed_by=self.headers.get("X-Pushed-By", "ci"))
            with LOCK:
                ver = entry["version"]
                if to_board:
                    fwdir, hist, key = "firmware-board", BOARD_HISTORY, "board"
                else:
                    fwdir, hist, key = "firmware", HISTORY, "manifest"
                with open(os.path.join(DATA_DIR, fwdir, f"{ver}.bin"), "wb") as f:
                    f.write(image)
                with open(hist, "a") as f:
                    f.write(json.dumps(entry) + "\n")
                state[key] = entry
            return self._json({"ok": True, "serving": ver,
                               "target": "board" if to_board else "shared"})

    return H


if __name__ == "__main__":
    load_state()
    port = int(os.environ.get("OTA_PORT", "8080"))   # override for tests
    srv = ThreadingHTTPServer(("0.0.0.0", port), handler_factory(MANIFEST))
    srv.serve_forever()
