#!/usr/bin/env python3
"""Regression: art overrides need a positive DJ identity, not a name."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
identity = (root/'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()
assert 'kSpotifyDJURI' in identity
assert 'playlistLabel(card.accessibilityLabel)' in identity
assert 'containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0)' in identity
assert 'return djTitle(card.accessibilityLabel);' not in identity
for look in ('Native', 'Redesigned'):
    text = (root/f'tweak/Sources/{look}/Home/DJArtwork.x').read_text()
    assert 'SGDJArtworkIsConfirmedCard(row)' in text
    assert 'SGDJLabel(' not in text and 'SGRDJLabel(' not in text
print('DJ artwork identity gates: PASS')
