# doorbellino-hal — vendor library, v1.4.2
# Source: https://gitlab/doorbellino/doorbellino-hal (public, the vendor
# develops the HAL in the open). The WHEEL on the internal index is the
# vendor's own release; the source is public by design.
"""Hardware abstraction for the DoorBellino main MCU."""
import random

__version__ = "1.4.2"


class Inputs:
    def __init__(self, ring=False, tamper=False):
        self.ring = ring
        self.tamper = tamper

    def __repr__(self):
        return f"Inputs(ring={self.ring}, tamper={self.tamper})"


class HAL:
    """Vendor-internal hardware access. In production this talks to the
    actual MCU peripherals; in the lab it is a soft simulation."""

    def __init__(self, seed=None):
        self._rng = random.Random(seed)

    def read_inputs(self) -> Inputs:
        return Inputs(ring=self._rng.random() < 0.1)

    def chime(self):
        # real hardware: drive the chime driver line
        pass

    def door_release(self):
        # real hardware: pulse the door-release relay line
        raise NotImplementedError("vendor builds never call this directly")
