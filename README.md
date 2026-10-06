# Confused at the Source

**A firmware supply-chain attack CTF. Poison the vendor pipeline, ship the implant, prove it from the flash.**

One Docker stack turns your laptop into a complete firmware vendor: GitLab CI/CD, an internal
Python package index, a signing pipeline, an OTA update server, a C2 collector, and a virtual
IoT device that applies signed updates.

The vendor has the classic dependency-confusion misconfiguration: its build resolves the
internal `doorbellino-hal` package with a PUBLIC registry fallback. Publish a higher version of
that name and the vendor's own pipeline downloads YOUR code, runs it ON THE RUNNER, and hands
you the keys to the release train:

- inject an implant into the firmware image
- exfiltrate the signing key
- fire the deploy gate so the backdoored firmware ships to the device, validly signed, with zero human clicks

The device updates itself. Every software signal stays green. The beacon lands in your
collector. Then P4 hands you the flash chip, and **the flash chip doesn't lie**.

---

## The phases

Five phases, roughly 2.5 hours solo:

| Phase | Name | You do |
|:-----:|------|--------|
| **P0** | Stand up the vendor | compose up + seed, watch the first honest release |
| **P1** | Recon | find the ONE line that lets public win over internal |
| **P2** | Poison | weaponize a package, publish, watch the pipeline deploy it |
| **P3** | Own | the device applies the poisoned update and beacons |
| **P4** | Analyze | flash forensics: dump, diff, decode the implant config |
| **P5** | Defend | apply one of five fixes, re-run your own attack, watch it fail |

## Quick start

```bash
git clone https://github.com/code-byter/confused-at-the-source.git
cd confused-at-the-source/ctf-kit

./up.sh                      # generate .env, start the stack, wait for GitLab
./seed/gitlab-init.sh        # root PAT + runner registration (once)
./seed/seed.sh               # vendor repo, internal package, CI variables

# then play P1-P5, see CHALLENGE.md
```

Status dashboard during play: `http://127.0.0.1:7000`

## Requirements

| need | detail |
|------|--------|
| Docker | with compose, ~4 GB RAM free (GitLab is hungry) |
| Python | 3.9+ on the host (for twine) |
| Hardware | none. A real ESP32 tier is optional, see `ctf-kit/firmware-esp32/` |

Everything is localhost: a fake public registry (devpi), a local OTA server, a local C2 log
sink. No real registry, OTA host, or C2 is ever contacted, and nothing leaves your machine.

## Materials

| | |
|---|---|
| [**The slides**](https://code-byter.com/confused-at-the-source/slides/) | the talk deck, 31 slides |
| [**The CTF guide**](https://code-byter.com/confused-at-the-source/ctf-guide.html) | printable player manual: phases, flags, troubleshooting |
| [`CHALLENGE.md`](CHALLENGE.md) | phase design, flags, difficulty |
| [`TECH-OTA.md`](TECH-OTA.md) | how the OTA mechanism and the implant slot work |

The guide lives in this repo as `ctf-guide.html` (build it yourself from
`guide/ctf-guide.template.html` with `guide/make-ctf-guide-html.py`).

## Repository layout

```
index.html            landing page (GitHub Pages)
slides/               the talk deck
guide/                guide source: template + builder
ctf-guide.html        the printable player guide (built artifact)
ctf-kit/              the lab: compose stack, seed scripts, services,
                      vendor repos, ESP32 firmware
CHALLENGE.md          phase design, flags, difficulty
TECH-OTA.md           how the OTA mechanism and the implant slot work
```

The CTF is designed so the attack is fully buildable from what the repo ships: players clone
the vendor's PUBLIC repo inside the lab and arm it themselves. No solution package is included
in this repository.
