# Confused at the Source
Take-home dependency-confusion challenge · v0.7 (2026-09-11)
Take-home dependency-confusion challenge

## The attack

The victim "vendor" (DoorBellino) runs a complete CI/CD pipeline in GitLab:
firmware source code, an internal dependency (`doorbellino-hal`), build +
test stages, and an OTA update server that devices poll for new firmware.
A release is signed in CI and pushed to the OTA server; the device applies
it automatically.

But the build's index configuration falls back to a PUBLIC registry ,
the classic misconfiguration, the exact pattern Alex Birsan used against
35+ real companies in 2021.

The player publishes `doorbellino-hal 2.0.7`, a name the vendor never
owned, to the public registry. Semver prefers 2.0.7 over the internal
1.4.2, and the vendor's own CI chooses the attacker's package.

The evil package's build hook does two things ON THE RUNNER, during the
vendor's own build:

1. Injects an implant into the firmware image (appended payload + config).
2. Hijacks the deployment pipeline: it steals the OTA push token from the
   CI variables and triggers the deploy stage automatically, so the
   backdoored firmware is signed by the vendor's own key and PUSHED OVER
   OTA with zero human clicks. The device updates itself.

The demo payoff: the compromised firmware phones home, it sends beacon
data over the NETWORK to a C2 collector. The green pipeline that shipped
the implant also arms it.

Everything runs on the player's machine:

- `docker compose up` brings up GitLab, a FAKE public registry (local
  devpi container, no real PyPI/npm is ever contacted), the OTA update
  server, the C2 collector, and the virtual device.
- Nothing leaves localhost.

## Kit

- Docker compose stack: GitLab (needs ~4 GB RAM) + fake public registry
  + OTA server + C2 collector + virtual device
- Seed script: creates the DoorBellino group, firmware repo, CI pipeline
  (build → test → sign → OTA deploy, deploy gated), internal
  `doorbellino-hal 1.4.2`, signing key + OTA push token as masked CI
  variables
- Device, two tiers:
  - Virtual board (default): one container that polls the OTA server,
    verifies the signature, applies updates to a flash image file, and
    runs the firmware, beacons land in the collector. Zero hardware.
  - Real device (optional, ~EUR 6): one ESP32-C3 as the DoorBellino main
    MCU, OTA-updated over WiFi to the lab net; its beacon hits the same
    collector. (Village bonus: add the second ESP32 + relay on UART for
    the talk's DOOR-OPEN twist, same implant, physical payload.)
- Evil-package skeleton
- Printable CTF guide (see guide/

## Phases

### P0, Stand up the vendor (15 min)

Compose up, run the seed script, watch CI build the v1.4.2 firmware, run
the tests, sign it, and push it to the OTA server. Watch the virtual
device poll, verify the signature, and apply the update.

You are now a firmware vendor with a fully automatic release train.

### P1, Recon (20 min)

Read `.gitlab-ci.yml` and the pip config. Find the ONE line that lets
public win over internal. Bonus: find the OTA deploy stage and its manual
gate, the pipeline's last line of defense.

Flag: hash of the config line.

Teaching beat: the resolution order, not malware, is the vulnerability.

### P2, Poison (30 min)

Craft `doorbellino-hal 2.0.7` from the skeleton: an innocent API plus a
build hook (a setup.py command that runs ON THE RUNNER at build time).
The hook: (1) appends the implant payload to the firmware image, (2)
exfiltrates the signing key AND the OTA push token to the collector, (3)
fires the deploy stage so the poisoned image is pushed to the OTA server
automatically. Publish it to the fake public registry and trigger a
build, then watch the pipeline deploy WITHOUT touching anything.

Flag: the build-log line showing `doorbellino-hal 2.0.7` resolved from
PUBLIC while the internal 1.4.2 sat right there, plus the auto-deploy
evidence (deploy job firing with no human in the loop).

Screenshot both lines, resolution + auto-deploy is the whole attack in
two sentences.

### P3, Own (20 min)

The device updates itself over OTA, signature verification PASSES (the
vendor's own key signed the implant), and the implant starts beaconing
to the C2 collector over the network: device ID, firmware version, and
the exfiltrated signing key, on a timer.

Flag: the C2 beacon in the collector (device ID + beacon payload).

Realism beat: every software signal is green, pipeline green, signature
valid, OTA verified, while the device is attacker-controlled. (Village
bonus tier: same moment, but the payload crosses the UART bus instead ,
relay clicks, nothing on the network at all.)

### P4, Analyze (30 min)

Forensics on your own incident:

- dump the flash (virtual tier: the device's flash image file; real tier:
  chip clip) and diff against the signed release artifact, the payload
  is physically there, byte-for-byte
- decode the implant's C2 config from the dump (find the beacon target,
  interval, and frame format in the binary)
- catch the beacon on the wire (collector access log / tcpdump; real
  tier: same from the lab net)
- reconstruct the kill-chain timeline from build logs + collector:
  resolve → hook → key exfil → sign → auto-deploy → OTA apply → beacon

Flag: the timeline in the correct causal order.

This phase IS the talk's Part 2, take-home: the flash chip doesn't lie ,
and the network log tells you what the implant DOES.

### P5, Defend (30 min)

Fix the vendor so P2 fails. Any one of five accepted fixes:

1. Exact index pinning, remove the public fallback from the resolution config
2. Internal-names allowlist at the proxy
3. Vendor the internal library (commit it, no registry resolution)
4. Runner egress filter (build reaches only allowlisted hosts)
5. Provenance check in CI (refuse packages not signed by the vendor key)

Re-run the P2 attack: CI must REJECT.

Flag: the rejection log line. The device never gets owned again, you
watched your own fix work.

## Difficulty and audience

- Solo, ~2.5 hours total
- Needs: Docker, basic pip/npm literacy, a laptop
- Village: run in pairs; P2 becomes a race ("first team to flip the build")
- Home: fully offline-capable after the initial image pull

## Why this is the right challenge for the talk


## Build order

1. Compose stack + seed script (GitLab project, registry, CI variables,
   OTA server with signed manifests, C2 collector)
2. Virtual device container (OTA poller + signature verify + flash image)
3. Evil-package skeleton with build hook (implant injection + deploy
   hijack + beacon payload)
4. Rejection-mode configs (the five fixes, for P5 verification)
5. Worksheet, guide, spoiler repo
