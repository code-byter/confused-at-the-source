# DoorBellino CTF kit, build & play

Full design: `../CHALLENGE.md` (phases) · `../TECH-OTA.md` (OTA mechanism)

## Quick start (virtual tier)

```bash
./up.sh                      # generate .env, start stack, wait for GitLab
./seed/gitlab-init.sh        # root PAT + runner registration (once)
./seed/seed.sh               # vendor repo, internal package, CI variables

# P1-P5 per ../CHALLENGE.md
```

## Components

| path                  | role                                            |
|-----------------------|-------------------------------------------------|
| `services/ota/`       | OTA server: signed manifests, append-only history |
| `services/collector/` | C2 log sink: `/loot` (hook) + `/beacon` (device) |
| `services/devpi-internal/` | vendor-only package index (doorbellino-hal 1.4.2) |
| `services/devpi-public/`   | "public" index, the attacker publishes here |
| `services/virtual-device/` | flash.img device: OTA poller, verify, beacon |
| `services/dashboard/` | status page on 127.0.0.1:7000: every component live/dead, links, C2 log, physical ESP32 indicator |
| `vendor/firmware/`    | the victim's repo (CI config = the defect)      |
| `vendor/doorbellino-hal/` | vendor's HAL source, PUBLIC repo on GitLab (players clone it in P2); the 1.4.2 wheel rides the internal index |
| `firmware-esp32/`    | ESP32 device source (hardware tier); seeded to GitLab as PRIVATE `doorbellino/esp32-firmware` (Makefile, CMake project, sanitized sdkconfig.defaults; never your local sdkconfig) |

## Security invariants

- All services bind inside the compose network; host ports on 127.0.0.1 only
- Compose network is `internal: true`, no default route out
- Tokens in `.env` (0600), generated per install
- No real registry, OTA host, or C2 is ever contacted

## Useful paths at runtime

- GitLab UI: `http://127.0.0.1:8088` (root / `.env:GITLAB_ROOT_PW`)
- Flash forensics: `docker cp kit-virtual-device-1:/data/flash/flash.img .`
