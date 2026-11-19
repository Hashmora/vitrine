#!/usr/bin/env python3
"""Read-only, anonymized DJ Queue getState cap capture via SG_DRIVER.

Never clicks, skips, toggles switches, pauses or touches playback. To compare
with DJ Queue disabled, change the setting in Spotify and restart the app.

    python3 scripts/dj-cap-capture.py --port 8086 --seconds 60
    python3 scripts/dj-cap-occupancy.py out/with.zip --baseline out/without.zip
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import secrets
import time
import urllib.request
import zipfile

DJ_URI = 'spotify:playlist:37i9dQZF1EYkqdzj48dyYq'


def pseudonym(value, salt):
    if not value:
        return '-'
    return hashlib.sha256(salt + str(value).encode('utf-8')).hexdigest()[:10]


def scrub_state(reply, salt):
    if not isinstance(reply, dict) or reply.get('note'):
        return None
    context = reply.get('context')
    kind = 'dj' if context == DJ_URI else ('other' if context else 'none')
    # Use per-run pseudonyms; do not store track titles, Spotify URIs,
    # artwork URLs or account metadata anywhere in the output archive.
    def track_id(item):
        if not isinstance(item, dict):
            return '-'
        return pseudonym(item.get('uid') or item.get('probeId'), salt)
    dj = {
        'contextKind': kind,
        'current': {'id': track_id(reply.get('current'))},
        'future': [{'id': track_id(item)} for item in reply.get('future', [])
                   if isinstance(item, dict)],
    }
    if isinstance(reply.get('reverseCount'), (int, float)) and not isinstance(reply['reverseCount'], bool):
        dj['reverseCount'] = max(0, int(reply['reverseCount']))
    return dj


def fetch_state(port, timeout=3.0):
    request = urllib.request.Request(
        f'http://127.0.0.1:{port}/dj.state',
        headers={'X-Phone-Driver': '1'},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        result = json.load(response)
    if not isinstance(result, dict) or not result.get('ok'):
        raise RuntimeError('DJ driver returned an unsuccessful response')
    return result


def capture(port, seconds, interval, fetch=fetch_state):
    salt = secrets.token_bytes(16)
    samples, errors = [], []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        started = time.monotonic()
        now = time.time()
        try:
            dj = scrub_state(fetch(port), salt)
            if dj:
                samples.append({'t': now, 'dj': dj})
        except Exception as exc:
            # Exception type only; error messages could include request content.
            errors.append({'t': now, 'type': type(exc).__name__})
        time.sleep(min(max(0, interval - (time.monotonic() - started)),
                       max(0, deadline - time.monotonic())))
    return samples, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8086)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--interval', type=float, default=0.8)
    parser.add_argument('--out', type=Path, help='ZIP output; default out/dj-cap-YYYYMMDD-HHMMSS.zip')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.seconds <= 3600 or not 0.1 <= args.interval <= 60:
        parser.error('Port, duration or interval outside the permitted range')
    samples, errors = capture(args.port, args.seconds, args.interval)
    path = args.out or Path('out') / ('dj-cap-' + time.strftime('%Y%m%d-%H%M%S') + '.zip')
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('samples.jsonl', ''.join(json.dumps(s) + '\n' for s in samples))
        archive.writestr('errors.jsonl', ''.join(json.dumps(e) + '\n' for e in errors))
        archive.writestr('summary.json', json.dumps({
            'snapshots': len(samples), 'errors': len(errors),
            'notes': 'Read-only counts, no song names, URIs or account details; repeated snapshots are not ESP requests'
        }, indent=2) + '\n')
    print(f'Wrote {path} ({len(samples)} samples, {len(errors)} driver errors)')
    if not samples:
        print('No player state was captured; check that Spotify and SG_DRIVER are running.')


if __name__ == '__main__':
    main()
