#!/usr/bin/env python3
"""Regression assertions for safe DJ cover fallback after review #227."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = (root / 'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()

# A playlist with a DIFFERENT Spotify playlist URI must not use our DJ art.
assert 'static BOOL otherPlaylistURIInString(' in src
assert 'cardHasOtherPlaylistURI(card, 0)' in src
assert 'BOOL foreignPlaylist = confirmed && cardHasOtherPlaylistURI(card, 0);' in src
assert 'if (foreignPlaylist) confirmed = NO;' in src
assert '[uri caseInsensitiveCompare:kSpotifyDJURI] != NSOrderedSame' in src
# A real native bitmap wins, including nested Encore wrappers and layer contents.
assert 'static BOOL hasNativeBitmap(' in src
assert 'nativeArtwork = hasNativeBitmap(holder, 0, coverExtent, &foundBitmapSlot)' in src
assert 'BOOL coverSize = MIN(slot.bounds.size.width, slot.bounds.size.height) >= minimumExtent;' in src
assert 'if (slot.image || slot.layer.contents) return YES;' in src
assert '!nativeArtwork && placeholder' in src
# Reused same-card views reset their wait when the identity label changes.
assert 'kMissingArtLabelKey' in src
assert '![previousLabel isEqualToString:card.accessibilityLabel]' in src
assert 'card.accessibilityLabel, OBJC_ASSOCIATION_COPY_NONATOMIC' in src
# No title-only fast path that overwrites a loaded custom playlist cover.
assert 'return djTitle(card.accessibilityLabel);' not in src
print('DJ artwork conservative fallback and reused-holder guards: PASS (static)')
