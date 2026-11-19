#!/usr/bin/env python3
"""Check DJQueue source split, state ownership, and subscription cap fallback."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[2]
player = root/'tweak/Sources/Shared/Player'
main = (player/'DJQueue.x').read_text()
parts = ('DJQueueState.inc', 'DJQueuePlayback.inc', 'DJQueueTransitions.inc', 'DJQueueHistory.inc')
assert len(main.splitlines()) < 1200, 'queue hooks grew too large'
for part in parts:
    assert f'#include "{part}"' in main
    code = (player/part).read_text()
    assert '%hook' not in code and '%orig' not in code and '%ctor' not in code
    assert len(code.splitlines()) > 200
assert 'SGDJQueueNextSetTapped' in main
assert 'SGDJNativeDrawNextSet' in main and 'SGRDJQueueDrawNextSet' in main
code = '\n'.join([main]+[(player/p).read_text() for p in parts])
assert len(re.findall(r'^static void sampleDJCapCost\(.*\) \{',code,re.M)) == 1
assert 'if (uri.length && ![uri isEqualToString:kDJContext])' in code
assert 'state.future.count > 2' in code and 'state.reverse.count > 2' in code
assert '@"nonDJExtraNextPeak"' in code
assert 'playerStateDidReport:' in code
print('DJ Queue split, cap accounting and hook ownership: PASS')
