#!/usr/bin/env python3
"""Build ctf-guide.html: the DoorBellino CTF manual, self-contained single
file (fonts embedded as base64 data URIs).

Font files are optional: if not found, the guide falls back to system
fonts. Set NEXA_FONT_DIR to a directory containing NexaBold.otf and
NexaLight.otf to brand the guide.

Style rules: no em dashes in copy. Plain hyphens or colons only.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "ctf-guide.html")

html = open(os.path.join(HERE, "ctf-guide.template.html")).read()

font_dir = os.environ.get("NEXA_FONT_DIR", "")
if font_dir and os.path.isdir(font_dir):
    import base64

    def b64(p):
        return base64.b64encode(open(p, "rb").read()).decode()

    html = html.replace("{{NEXA_BOLD}}", b64(os.path.join(font_dir, "NexaBold.otf")))
    html = html.replace("{{NEXA_LIGHT}}", b64(os.path.join(font_dir, "NexaLight.otf")))
else:
    # no fonts available: drop the @font-face blocks, keep system fallbacks
    html = re.sub(r"@font-face \{[^}]*\}\n?", "", html)

leftovers = re.findall(r"\{\{[A-Z_]+\}\}", html)
if leftovers:
    raise SystemExit(f"unresolved placeholders: {sorted(set(leftovers))}")

open(OUT, "w").write(html)
print("wrote", OUT, len(html), "bytes")
