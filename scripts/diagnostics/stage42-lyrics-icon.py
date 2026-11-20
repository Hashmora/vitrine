#!/usr/bin/env python3
"""Stage 42 read-only native glyph probe (requires its SG_DRIVER patch + rebuild).

Open the bottom Lyric stickers / GIF picker in Spotify, then press Enter. This
queries /encore.inspect, which reads the real Encore icon's Objective-C ivars on
the main thread. Missing/ambiguous data is INCOMPLETE, never a guessed name.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from zipfile import ZipFile, ZIP_DEFLATED

UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'


def request(port, path, **kwargs):
    url = f'http://127.0.0.1:{port}/{path}'
    if kwargs:
        # SG_DRIVER parses query items with NSURLComponents, where '+' stays a
        # literal plus. Encode spaces as %20, not application/x-www-form-urlencoded '+'.
        url += '?' + urlencode(kwargs, quote_via=quote)
    with urlopen(Request(url, headers={'X-Phone-Driver': '1'}), timeout=20) as resp:
        data = resp.read().decode('utf-8', 'replace')
    return data if path == 'tree' else json.loads(data)


def validated(result):
    """Never mark a plausible but unverified icon name as a successful match."""
    if not isinstance(result, dict) or result.get('ok') is not True:
        return 'INCOMPLETE_DRIVER', 'Native command missing or failed'
    status = result.get('status', 'INCOMPLETE_NO_STATUS')
    if status != 'COMPLETE_ICON_NAME':
        return status if isinstance(status, str) and status.startswith('INCOMPLETE') else 'INCOMPLETE_STATUS', 'Native glyph unresolved'
    matches = result.get('matches')
    if not isinstance(matches, list) or len(matches) != 1:
        return 'INCOMPLETE_TARGET', 'Expected exactly one visible Lyric stickers tab'
    record = matches[0]
    named = record.get('namedIvars', [])
    name = result.get('exactIconName')
    if (result.get('label') != 'Lyric stickers' or not isinstance(name, str) or not name or
            not isinstance(record.get('iconFrame'), list) or
            not isinstance(named, list) or not named or
            any(x.get('name') != name or not x.get('ivar') for x in named if isinstance(x, dict)) or
            any(not isinstance(x, dict) for x in named) or
            len(named) != len([x for x in named if x.get('name') == name])):
        return 'INCOMPLETE_INCONSISTENT', 'Native response does not prove one exact glyph'
    return 'COMPLETE_ICON_NAME', 'Resolved from the matched native icon view'


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, default=str) + '\n', encoding='utf-8')


def self_test():
    # Regression: /encore.inspect?label=Lyric+stickers silently matched zero
    # views even when the label was visible (Stage 42 evidence, 2026-11-20).
    assert urlencode({'label': 'Lyric stickers'}, quote_via=quote) == 'label=Lyric%20stickers'
    good = {'ok': True, 'status': 'COMPLETE_ICON_NAME', 'label': 'Lyric stickers',
            'exactIconName': 'quotesSquare', 'matches': [
                {'iconFrame': [90, 700, 24, 24],
                 'namedIvars': [{'ivar': 'icon', 'name': 'quotesSquare'}]}]}
    assert validated(good)[0] == 'COMPLETE_ICON_NAME'
    assert validated({**good, 'matches': []})[0] == 'INCOMPLETE_TARGET'
    assert validated({**good, 'exactIconName': 'lyrics'})[0] == 'INCOMPLETE_INCONSISTENT'
    assert validated({'ok': False, 'error': 'unknown command'})[0] == 'INCOMPLETE_DRIVER'
    assert validated({'ok': True, 'status': 'INCOMPLETE_AMBIGUOUS_ICON'})[0] == 'INCOMPLETE_AMBIGUOUS_ICON'
    print('PASS: Stage 42 strict result validation')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8087)
    parser.add_argument('--udid', default=UDID)
    parser.add_argument('--out', default='out')
    parser.add_argument('--no-prompt', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.no_prompt:
        input('Открой попап с вкладками «Lyric stickers» и «GIF», затем нажми Enter... ')
    root = Path(args.out).resolve() / ('stage42-lyrics-native-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    root.mkdir(parents=True, exist_ok=False)
    report = {'status': 'INCOMPLETE', 'port': args.port, 'udid': args.udid,
              'target': 'Lyric stickers'}
    try:
        result = request(args.port, 'encore.inspect', label='Lyric stickers')
        save_json(root / 'native-glyph.json', result)
        status, reason = validated(result)
        report['status'], report['reason'] = status, reason
        if status == 'COMPLETE_ICON_NAME':
            report['exactIconName'] = result['exactIconName']
            report['sourceIvars'] = result['sourceIvars']
    except (URLError, HTTPError, ValueError, KeyError, TimeoutError) as e:
        report['reason'] = 'Native driver unavailable: ' + str(e)
    try:
        (root / 'tree.txt').write_text(request(args.port, 'tree'), encoding='utf-8')
    except Exception as e:
        report['treeError'] = repr(e)
    try:
        cp = subprocess.run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', '--type=png',
                             str(root / 'screen.png')], capture_output=True, text=True, timeout=30)
        report['screenshotExit'] = cp.returncode
        if cp.returncode != 0:
            report['screenshotError'] = cp.stderr[-1000:]
    except Exception as e:
        report['screenshotError'] = repr(e)
    save_json(root / 'report.json', report)
    archive = root.with_suffix('.zip')
    with ZipFile(archive, 'w', ZIP_DEFLATED) as z:
        for path in root.rglob('*'):
            if path.is_file():
                z.write(path, path.relative_to(root.parent))
    print('STATUS:', report['status'])
    print('Reason:', report.get('reason', 'unknown'))
    if 'exactIconName' in report:
        print('Native Spotify icon:', report['exactIconName'])
    print('Evidence ZIP:', archive)


if __name__ == '__main__':
    main()
