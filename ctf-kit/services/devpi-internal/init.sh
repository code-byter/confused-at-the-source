#!/bin/sh
set -e
PW="${DEVPI_PW:-devpi}"
devpi-init --root-passwd "$PW"
devpi-server --host 0.0.0.0 --port 3141 &
SRV=$!
# wait for server, then create the non-volatile index
for i in $(seq 1 30); do
  curl -sf http://localhost:3141/ >/dev/null && break
  sleep 1
done
# auth: devpi allows root with password via HTTP basic auth
curl -sf -u "root:$PW" -X PUT "http://localhost:3141/root/pypi" \
  -H 'Content-Type: application/json' -d '{"volatile":false}' >/dev/null 2>&1 || true
# index the players publish to (created here so the host needs no devpi client)
# NB: JSON body required; newer devpi-server 400s on form-encoded config
curl -sf -u "root:$PW" -X PUT "http://localhost:3141/root/doorbellino" \
  -H 'Content-Type: application/json' -d '{"bases":"","volatile":false}' >/dev/null 2>&1 || true
wait $SRV
