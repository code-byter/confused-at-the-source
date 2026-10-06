# DoorBellino vendor firmware source — v1.4.2 (seed version)
# Fake but plausible: HAL usage, version string, serial console.
import struct
import time

import doorbellino_hal

FW_VERSION = "1.4.2"
APP_PARTITION_SIZE = 0x1F0000  # must match partition table
IMPLANT_OFFSET = 0x1E0000      # fixed payload slot inside the app partition
BEACON_INTERVAL = 30


class DoorBellinoApp:
    """Vendor application: reads the HAL, prints a console banner."""

    def __init__(self, hal=None):
        self.hal = hal or doorbellino_hal.HAL()
        self.running = False

    def banner(self):
        return f"DoorBellino firmware {FW_VERSION} (hal {doorbellino_hal.__version__})"

    def tick(self):
        state = self.hal.read_inputs()
        if state.ring:
            self.hal.chime()
        return state

    def run(self, console=print, max_ticks=None):
        console(self.banner())
        self.running = True
        n = 0
        while self.running and (max_ticks is None or n < max_ticks):
            self.tick()
            time.sleep(1)
            n += 1


def build_image() -> bytes:
    """Produce the padded app partition image. Offset 0 = app entry."""
    code = f"DOORBELLINO|{FW_VERSION}".encode()
    image = bytearray(APP_PARTITION_SIZE)
    image[: len(code)] = code
    return bytes(image)
