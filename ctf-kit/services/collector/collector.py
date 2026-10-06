# C2 "collector" — lab-safe local log sink.
# Receives: loot exfil (keys) from the build hook, beacons from the device.
# Localhost only; the shipped kit must never point at a real host.
import datetime
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("COLLECTOR_DATA", "/data")


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # we do our own logging

    def _log(self, kind, body):
        os.makedirs(DATA_DIR, exist_ok=True)
        rec = {"ts": datetime.datetime.now(datetime.UTC).isoformat(),
               "kind": kind, "src": self.client_address[0], "body": body}
        with open(os.path.join(DATA_DIR, "collector.log"), "a") as f:
            f.write(json.dumps(rec) + "\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except Exception:
            body = raw.decode(errors="replace")
        kind = "loot" if self.path == "/loot" else "beacon"
        self._log(kind, body)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        if self.path == "/log":
            p = os.path.join(DATA_DIR, "collector.log")
            out = open(p).read() if os.path.exists(p) else ""
            b = out.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)
    port = int(os.environ.get("COLLECTOR_PORT", "9000"))   # override for tests
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
