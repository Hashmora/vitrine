#!/usr/bin/env python3
"""Behavioral reference tests for the 9.1.90 placeholder-continuity policy.

The runtime implementation remains Objective-C; check.py verifies its relevant
conditions. The reference cases spell out the expected transition behavior.
"""
from dataclasses import dataclass

@dataclass
class Slot:
    card: object = None
    start: float = 0.0
    image: object = None
    active: bool = False

    def step(self, card, candidate, image, placeholder, at):
        if not candidate:
            self.__dict__.update(card=None, start=0.0, image=None, active=False)
            return False
        if card is not self.card:
            self.__dict__.update(card=card, start=0.0, image=None, active=False)
        missing = image is None or placeholder
        unchanged = (not missing and self.start > 0 and
                     image is self.image and image is not None)
        if missing:
            if self.start == 0:
                self.start = at
                self.image = image
        elif not unchanged:
            self.start, self.active, self.image = 0.0, False, None
        if self.start > 0 and at - self.start >= 0.8 and (missing or unchanged):
            self.active = True
        return self.active and (missing or unchanged)

def verify():
    a, b = object(), object()
    bitmap, real = object(), object()
    slot = Slot()
    assert not slot.step(a, True, bitmap, True, 1.0)
    assert not slot.step(a, True, bitmap, False, 1.3)
    assert slot.step(a, True, bitmap, False, 1.9), 'same temporary bitmap must not reset the grace period'
    assert slot.step(a, True, bitmap, False, 2.3)
    assert not slot.step(a, True, real, False, 2.5), 'new real image must win'
    assert not slot.step(a, True, real, False, 4.0)
    assert not slot.step(b, True, None, True, 5.0), 'cell reuse must reset the timer'
    assert slot.step(b, True, None, False, 5.85)
    assert not slot.step(None, False, None, False, 6.0), 'non-DJ card must reset state'
    assert not slot.step(a, True, real, False, 7.0), 'a loaded ordinary playlist must be preserved'
    assert not slot.step(a, True, real, False, 8.0)
    print('DJ artwork continuity policy: 10 reference checks PASS')

if __name__ == '__main__':
    verify()
