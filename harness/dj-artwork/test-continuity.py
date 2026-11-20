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
    resolved: bool = False

    def step(self, card, candidate, image, placeholder, at):
        if not candidate:
            self.__dict__.update(card=None, start=0.0, image=None, active=False, resolved=False)
            return False
        if card is not self.card:
            self.__dict__.update(card=card, start=0.0, image=None, active=False, resolved=False)
        if not self.resolved and self.start > 0 and image is not None and image is not self.image:
            self.resolved = True
            self.active = False
            self.start = 0.0
            self.image = None
        missing = image is None or placeholder
        if not self.resolved and missing and self.start == 0:
            self.start = at
            self.image = image
        same_temporary = self.start > 0 and image is not None and image is self.image
        if not self.resolved and not missing and not same_temporary:
            self.start, self.active, self.image = 0.0, False, None
        if not self.resolved and self.start > 0 and at - self.start >= 0.8 and (missing or same_temporary):
            self.active = True
        return not self.resolved and self.active and (missing or same_temporary)

def verify():
    a, b = object(), object()
    bitmap, real = object(), object()
    slot = Slot()
    assert not slot.step(a, True, bitmap, True, 1.0)
    assert not slot.step(a, True, bitmap, False, 1.3)
    assert slot.step(a, True, bitmap, False, 1.9), 'same temporary bitmap must not reset the grace period'
    assert slot.step(a, True, bitmap, False, 2.3)
    assert not slot.step(a, True, real, True, 2.5), 'new real image must win even if Spotify keeps its placeholder visible'
    assert not slot.step(a, True, real, True, 4.0), 'new native artwork must remain authoritative'
    assert not slot.step(b, True, None, True, 5.0), 'cell reuse must reset the timer'
    assert slot.step(b, True, None, False, 5.85)
    assert not slot.step(None, False, None, False, 6.0), 'non-DJ card must reset state'
    assert not slot.step(a, True, real, False, 7.0), 'a loaded ordinary playlist must be preserved'
    assert not slot.step(a, True, real, False, 8.0)
    # User playlist with a real cover arriving after its placeholder.
    user = Slot()
    assert not user.step('user-dj', True, bitmap, True, 10.0)
    assert user.step('user-dj', True, bitmap, True, 10.9)
    assert not user.step('user-dj', True, real, True, 11.0)
    assert not user.step('user-dj', True, real, True, 12.0), 'do not override its newly loaded cover'
    print('DJ artwork continuity policy: 10 reference checks PASS')

if __name__ == '__main__':
    verify()
