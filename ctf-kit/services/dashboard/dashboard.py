# Lab status dashboard — one page: every component, live/dead, links.
# Probes the services from inside labnet (container DNS), reads container
# states from the docker socket, and watches /dev for the physical ESP32.
# Read-only everywhere: docker.sock mounted ro, /dev mounted ro.
import datetime
import glob
import http.client
import json
import os
import socket
import termios
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASHBOARD_PORT", "7000"))
COLLECTOR = os.environ.get("COLLECTOR_URL", "http://collector:9000")
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")

# host_url: what the presenter's browser opens (host-side loopback ports).
# probe: how the dashboard checks liveness from inside labnet.
SERVICES = [
    {"name": "GitLab (vendor CI/CD)", "host_url": "http://127.0.0.1:8088",
     "link_label": "http://127.0.0.1:8088",
     "note": "login root / kit/.env:GITLAB_ROOT_PW",
     "probe": ("gitlab", 80, "/users/sign_in")},
    {"name": "public registry (devpi, attacker index)", "host_url": "http://127.0.0.1:3141/root/pub",
     "link_label": "http://127.0.0.1:3141/root/pub",
     "note": "root/pub: players publish doorbellino-hal here (pw DEVPI_PW)",
     "probe": ("devpi-public", 3141, "/root/pub")},
    {"name": "internal registry (devpi, vendor index)", "host_url": None,
     "link_label": "http://devpi-internal:3141/root/doorbellino (inside labnet only)",
     "note": "root/doorbellino: doorbellino-hal 1.4.2, never public",
     "probe": ("devpi-internal", 3141, "/root/doorbellino")},
    {"name": "OTA server", "host_url": "http://127.0.0.1:8080",
     "link_label": "http://127.0.0.1:8080",
     "note": "/manifest.json + /history (404 'no release' = up, just unseeded)",
     "probe": ("ota", 8080, "/manifest.json")},
    {"name": "C2 collector", "host_url": "http://127.0.0.1:9000/log",
     "link_label": "http://127.0.0.1:9000/log",
     "note": "GET /log = loot + beacons; POST /loot, /beacon",
     "probe": ("collector", 9000, "/log")},
]

# name-fragment -> (label, host_url, note) for docker-socket-only components
CONTAINER_COMPONENTS = [
    ("gitlab-runner", "GitLab runner", None, "executes the vendor pipeline"),
    ("virtual-device", "virtual device", None, "flash.img: OTA poll, verify, beacon"),
]


def probe_http(host, port, path, timeout=2.0):
    """Any HTTP answer counts as up; the code goes in the detail."""
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("GET", path)
        r = conn.getresponse()
        r.read(512)
        conn.close()
        return True, f"HTTP {r.status}"
    except Exception as e:
        return False, str(e)[:80]


def tcp_open(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def docker_containers():
    """GET /containers/json over the mounted docker.sock (stdlib, read-only)."""
    conn = http.client.HTTPConnection("localhost", timeout=3.0)
    conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.sock.settimeout(3.0)
    conn.sock.connect(DOCKER_SOCK)
    conn.request("GET", "/containers/json?all=1")
    r = conn.getresponse()
    body = r.read()
    conn.close()
    if r.status != 200:
        raise RuntimeError(f"docker api {r.status}")
    return {c["Names"][0].lstrip("/"): c["State"] for c in json.loads(body)}


def esp32_status():
    """Physical board = a serial device node. Report whatever by-id says."""
    patterns = ["/dev/serial/by-id/*", "/dev/ttyUSB*", "/dev/ttyACM*"]
    found = []
    for pat in patterns:
        found.extend(sorted(glob.glob(pat)))
    dedup = sorted(set(found))
    return {"connected": bool(dedup), "devices": dedup}


def docker_container_logs(name_fragment, tail=200):
    """GET /containers/{id}/logs?tail=N over the docker.sock.

    Docker requires the stream-mode toggles even when a single stream is
    present, or the API answers 400; both containers log plain stdout.
    """
    states = docker_containers()
    hit = next((n for n in states if name_fragment in n), None)
    if not hit:
        return f"(container '{name_fragment}' not found)"
    conn = http.client.HTTPConnection("localhost", timeout=5.0)
    conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.sock.settimeout(5.0)
    conn.sock.connect(DOCKER_SOCK)
    conn.request("GET", f"/containers/{hit}/logs?tail={tail}&stdout=1&stderr=1")
    r = conn.getresponse()
    body = r.read()
    conn.close()
    if r.status != 200:
        return f"(docker logs API {r.status})"
    # stdout/stderr frames are prefixed with an 8-byte header:
    # [STREAM_TYPE, 0, 0, 0, size1..size4]
    out, buf = [], body
    while len(buf) >= 8:
        n = int.from_bytes(buf[4:8], "big")
        out.append(buf[8:8 + n].decode(errors="replace"))
        buf = buf[8 + n:]
    text = "".join(out)
    return text if text.strip() else "(log empty)"


def esp32_serial_log(devices, seconds=3.0, baud=115200):
    """Deprecated per-request tap: kept so old cached pages don't 500."""
    return serial_buffer_text()


# --- persistent serial tap -------------------------------------------------
# A background thread keeps the tty open (O_RDONLY|O_NOCTTY|O_NONBLOCK, no
# DTR/RTS fiddling -> no board reset) and appends every byte to a rolling
# buffer. /seriallog serves the buffer, so quiet periods don't wipe history
# and the page never toggles between 'listening' and 'quiet'.
SERIAL_MAX = 32768
_serial_buf = bytearray()
_serial_lock = threading.Lock()
_serial_note = "tap starting"


def _configure_raw(fd, baud=115200):
    """Set the tty to raw 8N1 at the ESP32 console baud, like idf.py monitor.

    The tap never writes, so no DTR/RTS toggling is needed to avoid a reset.
    Without this, a freshly opened tty carries the kernel default termios
    (often B9600 with echo/icanon), and every decoded byte is U+FFFD.
    """
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0                      # no parity/ framing translation
    oflag &= ~termios.OPOST        # raw output: no NL->CRNL rewriting
    lflag = 0                      # non-canonical, no echo: byte stream
    cflag = (cflag & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) \
        | termios.CS8 | termios.CLOCAL | termios.CREAD
    speed = getattr(termios, f"B{baud}", termios.B115200)
    cflag |= speed
    ispeed = ospeed = speed
    cc = cc[:]                     # copy before editing; VMIN/VTIME indices
    cc[termios.VMIN] = 0           # non-blocking read semantics
    cc[termios.VTIME] = 0
    termios.tcsetattr(
        fd, termios.TCSANOW,
        [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])


def _serial_tap():
    global _serial_note
    import select
    import time
    current_path = None
    fd = None
    while True:
        try:
            dev = esp32_status()
            if not dev["connected"]:
                if fd is not None:
                    os.close(fd)
                    fd = None
                with _serial_lock:
                    _serial_note = "no board connected"
                time.sleep(2.0)
                continue
            path = dev["devices"][0]
            if path != current_path and fd is not None:
                os.close(fd)          # device changed (replug) -> reopen
                fd = None
            if fd is None:
                current_path = path
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
                try:
                    _configure_raw(fd)  # 115200 8N1 raw: never rely on the
                except OSError:         # tty keeping settings from a prior
                    pass                # idf.py monitor run (default termios
                                        # garbles the stream into U+FFFD)
                with _serial_lock:
                    _serial_note = f"tapping {path}"
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                data = os.read(fd, 65536)
                if data:
                    with _serial_lock:
                        _serial_buf.extend(data)
                        del _serial_buf[:-SERIAL_MAX]
        except OSError as e:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                fd = None
            with _serial_lock:
                _serial_note = f"serial error: {e}"
            time.sleep(2.0)


def serial_buffer_text():
    with _serial_lock:
        text = _serial_buf.decode(errors="replace")
        note = _serial_note
    if not text:
        return (f"({note} — waiting for bytes. If the board was just "
                "flashed, press EN/RESET once: the boot log accumulates "
                "here and stays.)")
    return text


def _safe_container_logs(name_fragment):
    try:
        return docker_container_logs(name_fragment)
    except Exception as e:
        return f"(docker log unavailable: {str(e)[:120]})"


def collect_status():
    services = []
    for s in SERVICES:
        host, port, path = s["probe"]
        up, detail = probe_http(host, port, path)
        services.append({"name": s["name"], "host_url": s["host_url"],
                         "link_label": s["link_label"], "note": s["note"],
                         "up": up, "detail": detail})
    containers = {}
    try:
        states = docker_containers()
        for frag, label, host_url, note in CONTAINER_COMPONENTS:
            hit = next((n for n in states if frag in n), None)
            state = states.get(hit) if hit else None
            containers[label] = {"container": hit, "running": state == "running"}
    except Exception as e:
        containers = {"error": str(e)[:120]}
    for s in services:  # container cross-check for the probed ones too
        pass
    return {"ts": datetime.datetime.now(datetime.UTC).isoformat(),
            "services": services, "containers": containers,
            "esp32": esp32_status(),
            "vdev_log": _safe_container_logs("virtual-device"),
            "runner_log": _safe_container_logs("gitlab-runner")}


def collector_log(limit=8000):
    host = COLLECTOR.replace("http://", "").partition(":")[0]
    port = int(COLLECTOR.rstrip("/").rsplit(":", 1)[1]) if ":" in COLLECTOR else 9000
    up, _ = probe_http(host, port, "/log", timeout=2.0)
    if not up:
        return "(collector unreachable)"
    conn = http.client.HTTPConnection(host, port, timeout=2.0)
    conn.request("GET", "/log")
    r = conn.getresponse()
    return r.read(limit).decode(errors="replace") or "(log empty)"


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>DoorBellino lab status</title>
<style>
 :root {
  --bg:#0d0f12; --panel:#14171c; --panel2:#191d23; --line:#262c35;
  --txt:#c9ced6; --dim:#7d8490; --green:#3BAE35; --green-soft:#7fc97f;
  --red:#e5484d; --amber:#d9a53f;
 }
 * { box-sizing:border-box; }
 html { scrollbar-color:#333a44 var(--bg); }
 body {
  background:
   radial-gradient(900px 500px at 85% -10%, rgba(59,174,53,.08), transparent 60%),
   var(--bg);
  color:var(--txt);
  font:13px/1.55 ui-monospace,'Fira Code','Cascadia Code',Menlo,Consolas,monospace;
  margin:0; padding:26px 30px 56px;
 }
 .wrap { max-width:1180px; margin:0 auto; }

 /* --- header ----------------------------------------------------------- */
 header { display:flex; flex-wrap:wrap; gap:12px 24px; align-items:flex-end;
          justify-content:space-between; margin-bottom:18px; }
 h1 { margin:0; font-size:19px; letter-spacing:.5px; color:#e8ecef; display:flex; align-items:center; gap:10px; }
 h1 .dot { width:9px; height:9px; border-radius:50%; background:var(--green);
           box-shadow:0 0 8px rgba(59,174,53,.8); animation:pulse 2.2s infinite; }
 h1 .brand { color:var(--green); }
 @keyframes pulse { 0%,100% { opacity:1; } 50% { opacity:.35; } }
 .sub { color:var(--dim); font-size:12px; margin-top:4px; }
 .clock { text-align:right; font-size:12px; color:var(--dim); white-space:nowrap; }
 .clock b { color:var(--txt); font-weight:normal; }

 /* --- summary strip ---------------------------------------------------- */
 .summary { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:20px; }
 .stat { background:var(--panel); border:1px solid var(--line); border-radius:8px;
         padding:10px 16px; min-width:150px; }
 .stat .k { font-size:10px; text-transform:uppercase; letter-spacing:1.2px; color:var(--dim); }
 .stat .v { font-size:17px; margin-top:2px; color:#e8ecef; }
 .stat .v.ok { color:var(--green); }
 .stat .v.bad { color:var(--red); }

 /* --- cards ------------------------------------------------------------ */
 .card { background:var(--panel); border:1px solid var(--line); border-radius:10px;
         margin-bottom:18px; overflow:hidden; }
 .card > h2 { margin:0; padding:12px 18px; font-size:12px; font-weight:normal;
              text-transform:uppercase; letter-spacing:1.4px; color:var(--dim);
              background:var(--panel2); border-bottom:1px solid var(--line);
              display:flex; justify-content:space-between; align-items:center; gap:12px; }
 .card > h2 a { color:var(--green-soft); text-transform:none; letter-spacing:0; }
 .card .body { padding:14px 18px; }
 .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:18px; }
 @media (max-width:900px) { .grid2 { grid-template-columns:1fr; } }

 /* --- pills ------------------------------------------------------------ */
 .pill { display:inline-flex; align-items:center; gap:6px; padding:2px 10px;
         border-radius:999px; font-size:11px; letter-spacing:.8px; border:1px solid; }
 .pill::before { content:''; width:6px; height:6px; border-radius:50%; background:currentColor; }
 .pill.live  { color:var(--green); border-color:rgba(59,174,53,.45); background:rgba(59,174,53,.08); }
 .pill.down  { color:var(--red); border-color:rgba(229,72,77,.45); background:rgba(229,72,77,.08); }
 .pill.warn  { color:var(--amber); border-color:rgba(217,165,63,.45); background:rgba(217,165,63,.08); }

 /* --- tables ----------------------------------------------------------- */
 table { border-collapse:collapse; width:100%; }
 th { text-align:left; font-size:10px; font-weight:normal; text-transform:uppercase;
      letter-spacing:1.1px; color:var(--dim); padding:6px 12px; border-bottom:1px solid var(--line); }
 td { padding:8px 12px; border-bottom:1px solid rgba(38,44,53,.55); vertical-align:top; }
 tr:last-child td { border-bottom:none; }
 tbody tr:hover { background:rgba(59,174,53,.04); }
 td .name { color:#e8ecef; }
 td .note { color:var(--dim); font-size:12px; }
 a { color:var(--green-soft); text-decoration:none; border-bottom:1px dotted rgba(127,201,127,.4); }
 a:hover { color:#a5dfa0; border-bottom-style:solid; }

 /* --- log panels -------------------------------------------------------- */
 pre { margin:0; background:#0a0c0e; border:1px solid var(--line); border-radius:8px;
       padding:12px 14px; font-size:12px; line-height:1.5; overflow:auto;
       white-space:pre-wrap; word-break:break-word; color:#b9c2b9; }
 .logs { display:grid; grid-template-columns:1fr 1fr; gap:18px; }
 @media (max-width:900px) { .logs { grid-template-columns:1fr; } }
 #seriallog, #vdevlog { max-height:280px; }
 #c2log { max-height:340px; }
 .muted { color:var(--dim); }
 .footer { color:var(--dim); font-size:11px; text-align:center; margin-top:26px; }
</style></head><body>
<div class="wrap">
<header>
 <div>
  <h1><span class="dot"></span>DoorBellino <span class="brand">lab status</span></h1>
  <div class="sub">components, container state, the board and the loot, one page</div>
 </div>
 <div class="clock">auto-refresh 5s<br>updated <b id="ts">...</b></div>
</header>

<div class="summary">
 <div class="stat"><div class="k">services</div><div class="v" id="sum-services">...</div></div>
 <div class="stat"><div class="k">containers</div><div class="v" id="sum-containers">...</div></div>
 <div class="stat"><div class="k">esp32 board</div><div class="v" id="sum-board">...</div></div>
</div>

<div class="card">
 <h2>services</h2>
 <table id="services">
  <thead><tr><th>component</th><th>status</th><th>detail</th><th>link</th><th>note</th></tr></thead>
  <tbody></tbody>
 </table>
</div>

<div class="grid2">
 <div class="card">
  <h2>containers</h2>
  <table id="containers">
   <thead><tr><th>container</th><th>state</th></tr></thead>
   <tbody></tbody>
  </table>
 </div>
 <div class="card">
  <h2>physical ESP32</h2>
  <div class="body">
   <p id="esp32" style="margin:0 0 12px">...</p>
   <h3 style="margin:0 0 8px;font-size:10px;text-transform:uppercase;letter-spacing:1.2px;color:var(--dim);font-weight:normal">serial console <span class="muted">(read-only tap)</span></h3>
   <pre id="seriallog">no board</pre>
  </div>
 </div>
</div>

<div class="logs">
 <div class="card">
  <h2>virtual device log <span style="font-weight:normal;color:var(--dim)">(the implant logs nothing: beacons live in the C2 log)</span></h2>
  <div class="body"><pre id="vdevlog">loading...</pre></div>
 </div>
 <div class="card">
  <h2>C2 collector log <a href="http://127.0.0.1:9000/log" target="_blank" rel="noopener">open raw</a></h2>
  <div class="body"><pre id="c2log">loading...</pre></div>
 </div>
</div>

<div class="footer">DoorBellino firmware supply-chain lab &middot; read-only: docker.sock ro, /dev ro</div>
</div>
<script>
const esc = s => { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; };
async function row(t, cells) {
  const tr = document.createElement('tr');
  for (const c of cells) { const td = document.createElement('td'); td.innerHTML = c; tr.appendChild(td); }
  t.appendChild(tr);
}
const pill = (ok, upTxt, downTxt) =>
  `<span class="pill ${ok ? 'live' : 'down'}">${ok ? upTxt : downTxt}</span>`;
async function tick() {
  try {
    const st = await (await fetch('/status')).json();
    document.getElementById('ts').textContent = st.ts;
    const sv = document.getElementById('services').tBodies[0];
    sv.innerHTML = '';
    let upN = 0;
    for (const s of st.services) {
      if (s.up) upN++;
      const cell = s.host_url
        ? `<a href="${esc(s.host_url)}" target="_blank" rel="noopener">${esc(s.link_label)}</a>`
        : `<span class="muted">${esc(s.link_label)}</span>`;
      row(sv, [`<span class="name">${esc(s.name)}</span>`,
               pill(s.up, 'LIVE', 'DOWN'),
               `<span class="muted">${esc(s.detail)}</span>`, cell,
               `<span class="note">${esc(s.note)}</span>`]);
    }
    const sumS = document.getElementById('sum-services');
    sumS.textContent = `${upN}/${st.services.length} live`;
    sumS.className = 'v ' + (upN === st.services.length ? 'ok' : 'bad');
    const ct = document.getElementById('containers').tBodies[0];
    ct.innerHTML = '';
    let runN = 0, ctN = 0;
    for (const [label, c] of Object.entries(st.containers || {})) {
      if (c.container === undefined && c.running === undefined) continue;
      ctN++; if (c.running) runN++;
      row(ct, [`<span class="name">${esc(label)}</span>`,
               pill(c.running, 'running', 'STOPPED')]);
    }
    const sumC = document.getElementById('sum-containers');
    sumC.textContent = ctN ? `${runN}/${ctN} up` : 'n/a';
    sumC.className = 'v ' + (ctN && runN === ctN ? 'ok' : 'bad');
    const e = st.esp32;
    const sumB = document.getElementById('sum-board');
    sumB.textContent = e.connected ? 'connected' : 'absent';
    sumB.className = 'v ' + (e.connected ? 'ok' : '');
    const espEl = document.getElementById('esp32');
    espEl.innerHTML = e.connected
      ? pill(true, 'CONNECTED', '') + `<div class="note" style="margin-top:8px">${e.devices.map(esc).join('<br>')}</div>`
      : pill(false, '', 'NOT CONNECTED') + `<div class="note" style="margin-top:8px">no /dev/ttyUSB*, /dev/ttyACM*, /dev/serial/by-id/*</div>`;
    const serEl = document.getElementById('seriallog');
    if (e.connected) {
      serEl.textContent = await (await fetch('/seriallog')).text();
      serEl.scrollTop = serEl.scrollHeight;
    } else {
      serEl.textContent = 'no board connected';
    }
    document.getElementById('vdevlog').textContent = st.vdev_log || '(unavailable)';
    document.getElementById('c2log').textContent = await (await fetch('/log')).text();
  } catch (err) {
    document.getElementById('ts').textContent = 'status fetch failed: ' + err;
  }
}
setInterval(tick, 5000);
tick();
</script>
</body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, body, ctype, code=200):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/status":
            return self._send(json.dumps(collect_status()), "application/json")
        if self.path == "/log":
            return self._send(collector_log(), "text/plain")
        if self.path == "/seriallog":
            dev = esp32_status()
            if not dev["connected"]:
                return self._send("(no board connected)", "text/plain")
            return self._send(esp32_serial_log(dev["devices"]), "text/plain")
        if self.path == "/":
            return self._send(PAGE, "text/html")
        self._send("", "text/plain", 404)


if __name__ == "__main__":
    threading.Thread(target=_serial_tap, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
