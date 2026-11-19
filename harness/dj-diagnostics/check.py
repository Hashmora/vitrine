#!/usr/bin/env python3
"""Quick offline regression for DJ diagnostic wiring, scrubbing and report creation."""
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import types
from urllib.parse import urlsplit

root = Path(__file__).resolve().parents[2]
source = root / 'scripts/dj-diagnose.py'
spec = importlib.util.spec_from_file_location('dj_diagnose', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Catch a missing symbol/driver entry point without the much heavier Theos build.
core = (root / 'tweak/Sources/Core/SGDJProbe.m').read_text()
header = (root / 'tweak/Sources/Core/SGDJProbe.h').read_text()
driver = (root / 'tweak/Sources/Diagnostics/Driver.m').read_text()
queue = (root / 'tweak/Sources/Shared/Player/DJQueue.x').read_text()
for symbol in ('SGDJProbeRecord', 'SGDJProbeRead', 'SGDJProbeTag', 'SGDJProbeArtworkDecision'):
    assert symbol in core and symbol in header, f'missing exported {symbol}'
assert '@"dj.trace"' in driver and 'SGDJProbeRead(since, limit)' in driver
assert '@"dj.ui"' in driver and 'SGForEachView(window' in driver
assert 'SGDJ_TRACE(@"button.tap"' in queue
assert 'SGDJ_TRACE(@"queue.set"' in queue
assert 'SGDJ_TRACE(@"skip.internal"' in (root / 'tweak/Sources/Shared/Player/DJQueuePlayback.inc').read_text()
assert 'SGDJ_TRACE(@"previous.target"' in queue
assert '#if SG_DRIVER' in core and '#define SGDJ_TRACE(kind, fields) do {} while (0)' in header

raw_track = {'uri': 'spotify:track:SECRET123', 'uid': 'SECRET_UID', 'logicalUID': 'LOGICAL',
             'title': 'PRIVATE SONG', 'queued': True, 'played': False, 'hidden': False}
raw = {'active': True, 'sessionDetected': True, 'context': module.DJ_CONTEXT,
       'future': [raw_track], 'current': raw_track, 'shown': raw_track, 'muted': False,
       'queueRows': 4, 'injectedRows': 3, 'pageVisible': True}
secret = b'TEST-SALT'
sanitized = module.scrub_dj(raw, secret)
assert sanitized['contextKind'] == 'dj'
serialized = json.dumps(sanitized)
for forbidden in ('PRIVATE SONG', 'SECRET_UID', 'SECRET123', 'LOGICAL', module.DJ_CONTEXT):
    assert forbidden not in serialized, f'privacy leak: {forbidden}'

class FakeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        command = urlsplit(self.path).path.strip('/')
        if command == 'dj.trace':
            response = {'ok': True, 'events': [], 'last': 0, 'trimmed': 0,
                        'artCandidates': 12, 'artConfirmed': 9, 'artPlaylistLabels': 3}
        elif command == 'dj.state':
            response = {'ok': True, **raw}
        elif command == 'state':
            response = {'ok': True, 'player': True, 'nowPlaying': {'title': 'PRIVATE SONG',
                        'uri': 'spotify:track:SECRET123', 'paused': False, 'playing': True}}
        elif command == 'dj.ui':
            response = {'ok': True, 'controls': {'edit': {'total': 1, 'shown': 1, 'enabled': 1},
                                                 'nextSet': {'total': 1, 'shown': 1, 'enabled': 1}}}
        else:
            response = {'ok': False, 'error': 'unknown'}
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

with ThreadingHTTPServer(('127.0.0.1', 0), FakeHandler) as server, tempfile.TemporaryDirectory() as tmp:
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    output = Path(tmp) / 'capture'
    args = types.SimpleNamespace(port=server.server_port, seconds=0.85, interval=0.3,
                                 timeout=2, ui_every=1, output=str(output))
    assert module.capture(args) == 0
    assert (output / 'REPORT.md').exists()
    assert output.with_suffix('.zip').exists()
    assert len((output / 'samples.jsonl').read_text().splitlines()) >= 2
    for file in output.iterdir():
        text = file.read_text()
        for forbidden in ('PRIVATE SONG', 'SECRET_UID', 'SECRET123', module.DJ_CONTEXT):
            assert forbidden not in text, f'privacy leak in {file.name}: {forbidden}'
    server.shutdown()

samples = [
    {'t': 1, 'dj': {'active': True, 'pageVisible': True, 'future': [{'kind': 'song'}],
                     'queueRows': 0, 'muted': True, 'handover': False}},
    {'t': 2, 'dj': {'active': True, 'pageVisible': True, 'future': [{'kind': 'song'}],
                      'queueRows': 0, 'muted': True, 'handover': True}},
    {'t': 12, 'dj': {'active': True, 'pageVisible': True, 'future': [{'kind': 'song'}],
                      'queueRows': 0, 'muted': True, 'handover': True}},
    {'t': 25, 'dj': {'active': True, 'pageVisible': True, 'future': [{'kind': 'song'}],
                      'queueRows': 0, 'muted': True, 'handover': True}},
]
findings = module.interpret(samples, [{'event': 'previous.fallback', 'data': {}}], [])
codes = {x['code'] for x in findings}
assert {'mute_long', 'handover_long', 'empty_queue', 'previous_fallback'} <= codes
burst = [{'seq': i + 1, 'event': 'player.state', 't': i / 10.0,
          'data': {'track': f'{i:08x}', 'arrived': True, 'position': 0.0}} for i in range(10)]
findings = module.interpret([], burst, [], {'artCandidates': 76, 'artConfirmed': 0})
assert {'rapid_track_changes', 'artwork_unconfirmed'} <= {x['code'] for x in findings}
assert not any(x['code'] == 'rapid_track_changes' for x in
               module.interpret([], burst[:4], [])), 'false positive on small skips'
print('DJ diagnostic driver wiring, redaction, offline capture and heuristics: PASS')
