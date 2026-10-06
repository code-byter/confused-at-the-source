# DoorBellino ESP32 firmware — build & flash
#
# Requires esp-idf (v5.x): `make idf-env` clones it into ./esp-idf and
# installs the toolchain. Flash target: /dev/ttyUSB0 (usbip from the
# presenter laptop; see README "real tier").
#
# The virtual tier (services/virtual-device) needs no idf at all and is
# the default CTF experience; this firmware is the hardware tier.
#
# All idf.py targets run from doorbellino/ — that is where the project
# lives (CMakeLists.txt). Do not run idf.py from this directory.
#
# SDKCONFIG SAFETY: doorbellino/sdkconfig holds your real WiFi, lab IPs
# and the vendor trust anchor. It is YOURS and gitignored. `make build`
# never rewrites it: set-target runs once (guarded), and a REPLACE
# placeholder in the vendor key fails the build with a clear message.
# Lab defaults for fresh clones live in doorbellino/sdkconfig.defaults;
# copy it to sdkconfig and edit in your own values.

# recipes source esp-idf/export.sh, which needs BASH_SOURCE: run them under bash,
# not make's default /bin/sh (dash) which fails with 'Could not detect IDF_PATH'
SHELL := /bin/bash
.DEFAULT_GOAL := build

IDF_VER ?= v5.2.2
PORT ?= /dev/ttyUSB0
BAUD ?= 460800

PROJECT_DIR := doorbellino
SDKCONFIG := $(PROJECT_DIR)/sdkconfig
IDF := . ./esp-idf/export.sh && cd $(PROJECT_DIR) && idf.py

.PHONY: idf-env build flash monitor erase wipe-idf check-config

idf-env:
	@echo "[idf] cloning esp-idf $(IDF_VER) (one-time, ~1.5 GB)"
	git clone -b $(IDF_VER) --recursive \
	  https://github.com/esphome/espidf-supplemental-build ir-once 2>/dev/null || \
	git clone -b $(IDF_VER) --recursive \
	  https://github.com/espressif/esp-idf.git esp-idf
	cd esp-idf && ./install.sh

# First provisioning only: no sdkconfig yet -> start from the lab template.
# Never runs again once sdkconfig exists, so your edits are never clobbered.
$(SDKCONFIG):
	@echo "[sdkconfig] none yet: creating from doorbellino/sdkconfig.defaults"
	@echo "[sdkconfig] EDIT IT (WiFi, OTA/collector IPs, VENDOR_PUB) before flashing"
	@cp $(PROJECT_DIR)/sdkconfig.defaults $(SDKCONFIG)

check-config:
	@if [ ! -f "$(SDKCONFIG)" ]; then \
	  echo "[sdkconfig] MISSING: 'make build' will create it from defaults."; \
	  echo "            Edit WiFi/OTA IPs/VENDOR_PUB, then build again."; exit 1; \
	fi
	@if grep -q "REPLACE" "$(SDKCONFIG)"; then \
	  echo "[sdkconfig] REFUSING to build: DOORBELLINO_VENDOR_PUB still contains"; \
	  echo "            the REPLACE placeholder. Set the vendor key (see kit/.env"; \
	  echo "            SIGNING_PUB -> PEM, or idf.py menuconfig -> DoorBellino)."; exit 1; \
	fi

build: $(SDKCONFIG) check-config
	@if [ ! -f "$(PROJECT_DIR)/build/CMakeCache.txt" ]; then \
	  echo "[idf] first build here: pinning target esp32 (one-time)"; \
	  $(IDF) set-target esp32; \
	else \
	  grep -q "^CONFIG_IDF_TARGET=\"esp32\"" $(SDKCONFIG) || { \
	    echo "[idf] target mismatch in $(SDKCONFIG)"; exit 1; }; \
	fi
	@$(IDF) build
	@echo "[idf] done: $(PROJECT_DIR)/build/doorbellino.bin"

flash: check-config
	@$(IDF) -p $(PORT) -b $(BAUD) flash

monitor:
	@$(IDF) -p $(PORT) monitor

erase:
	@$(IDF) -p $(PORT) erase-flash

# Pull the espressif/idf image the esp32-firmware CI job uses ONCE, while
# the box still has internet, so the lab's offline runner can build the
# board image from its local docker cache after the network is gone.
prefetch-idf:
	docker pull espressif/idf:v5.2.2

wipe-idf:
	rm -rf esp-idf $(PROJECT_DIR)/build $(SDKCONFIG) $(PROJECT_DIR)/sdkconfig.old
