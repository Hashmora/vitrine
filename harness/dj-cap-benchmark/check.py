#!/usr/bin/env python3
"""Regression tests: cap analyzer never mistakes repeated samples for ESP requests."""
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import zipfile

root = Path(__file__).resolve().parents[2]
module_path = root / 'scripts/dj-cap-occupancy.py'
spec = importlib.util.spec_from_file_location('cap_bench', module_path)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def sample(t, size, context='other', uid='A', prev=None):
    dj = {'contextKind': context, 'future': [{'id': str(i)} for i in range(size)],
          'current': {'id': uid}}
    if prev is not None:
        dj['reverseCount'] = prev
    return {'t': t, 'dj': dj}

on = [sample(1, 16), sample(2, 16), sample(3, 16), sample(4, 3, uid='B'),
      sample(5, 16, context='dj')]
result = bench.non_dj_cap_cost(iter(on))
assert result['snapshots'] == 4
assert result['distinctStateSignatures'] == 2  # not four separate ESP requests
assert result['observedStateTransitions'] == 1
assert result['peakExtraNext'] == 14
assert result['withExtraNext'] == 4
assert result['prevObserved'] if 'prevObserved' in result else True
assert 'avgExtraPrev' not in result  # missing is missing, not an assumed zero
assert bench.non_dj_cap_cost([sample(0, 2)])['avgExtraNext'] == 0
assert bench.non_dj_cap_cost([sample(0, 3, prev=8)])['avgExtraPrev'] == 6
baseline = bench.non_dj_cap_cost([sample(0, 2), sample(1, 2)])
assert bench.compare(result, baseline)['valid']
assert bench.compare(result, baseline)['deltaPeakFutureRefs'] == 14
assert not bench.compare(result, {'snapshots': 0})['valid']

with TemporaryDirectory() as tmp:
    path = Path(tmp) / 'trace.zip'
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('samples.jsonl', '\n'.join(json.dumps(x) for x in on))
    assert len(list(bench.read_samples(path))) == len(on)
print('DJ cap benchmark: PASS (snapshot dedup, missing previous data, baseline, ZIP input)')

# The standalone recorder must not copy URIs, titles or other account data
# into its capture, and it must make only the read-only driver call.
capture_path = root / 'scripts/dj-cap-capture.py'
spec = importlib.util.spec_from_file_location('cap_capture', capture_path)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)
raw = {
    'context': 'spotify:playlist:custom_private',
    'current': {'uid': 'private-song-uid', 'title': 'private title'},
    'future': [{'uid': 'other_private_uid', 'uri': 'spotify:track:private'}],
    'reverseCount': 7,
}
clean = recorder.scrub_state(raw, b'abcdefgh01234567')
assert clean['contextKind'] == 'other'
assert clean['reverseCount'] == 7
assert clean['future'][0]['id'] != 'other_private_uid'
assert 'private' not in json.dumps(clean).lower()
samples, errors = recorder.capture(8086, seconds=0.025, interval=0.01, fetch=lambda _: raw)
assert samples and not errors and all(s['dj']['reverseCount'] == 7 for s in samples)
print('DJ cap capture: PASS (read-only mock and redaction)')
