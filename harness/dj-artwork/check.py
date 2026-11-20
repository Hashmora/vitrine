#!/usr/bin/env python3
"""Regression: art overrides need a positive DJ identity, not a name."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
identity = (root/'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()
assert 'kSpotifyDJURI' in identity
assert 'playlistLabel(card.accessibilityLabel)' in identity
assert 'containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0)' in identity
assert 'editorialDJIdentity' in identity and 'isDedicatedDJComponent' in identity
assert 'return confirmed;' in identity
assert 'return djTitle(card.accessibilityLabel);' not in identity
for look in ('Native', 'Redesigned'):
    text = (root/f'tweak/Sources/{look}/Home/DJArtwork.x').read_text()
    assert 'SGDJArtworkIsConfirmedCard(row)' in text
    assert 'SGDJArtworkNeedsPlaceholder(row, holder, &retry)' in text
    assert 'SGDJArtworkEnclosingCard(holder)' in text
    assert 'if (retry)' in text and 'dispatch_after(' in text
    assert 'SGDJLabel(' not in text and 'SGRDJLabel(' not in text
print('DJ artwork identity gates: PASS')

identity_missing = identity
assert 'BOOL missing = candidate && (!nativeArtwork || placeholder);' in identity_missing
assert 'sgScanArt(holder, 0, &nativeArtwork, &placeholder)' in identity_missing
assert 'foundBitmapSlot && !nativeArtwork && placeholder' not in identity_missing
assert 'now - firstSeen.doubleValue >= 0.8' in identity_missing
assert 'SGDJ_TRACE(@"artwork.placeholder"' in identity_missing
print('DJ blank-placeholder fallback: PASS (requires device verification)')

assert 'SGDJArtworkCardCache' in identity
assert 'cache.parent == parent && cache.window == window' in identity
assert 'cache.card || now - cache.checkedAt < 0.25' in identity
print('Artwork enclosing-card cache: PASS')
