#!/usr/bin/env python3
"""Stage 44: read-only runtime and pixel-shape comparison for Lyrics stickers.

Requires the Stage 44 native SG_DRIVER patch and rebuild. Never changes UI.
A low pixel score is only treated as a possible resource match if it is unique;
Swift runtime ivar names remain unavailable until actually proved otherwise.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen
from zipfile import ZipFile, ZIP_DEFLATED

UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'

def request(port, cmd, **args):
    uri = f'http://127.0.0.1:{port}/{cmd}'
    if args:
        uri += '?' + urlencode(args, quote_via=quote)
    with urlopen(Request(uri, headers={'X-Phone-Driver': '1'}), timeout=35) as response:
        payload = response.read().decode('utf-8', 'replace')
    return payload if cmd == 'tree' else json.loads(payload)


def interpret(response):
    if not isinstance(response, dict) or response.get('ok') is not True:
        return 'INCOMPLETE_DRIVER', 'encore.trace unavailable or failed', []
    matches = response.get('matches')
    if response.get('label') != 'Lyric stickers' or not isinstance(matches, list) or len(matches) != 1:
        return 'INCOMPLETE_TARGET', 'Expected one visible Lyric stickers icon', []
    detail = matches[0]
    if not isinstance(detail, dict) or 'icon' not in detail:
        return 'INCOMPLETE_TARGET', 'Native view missing', []
    candidates = [c for c in detail.get('candidateScores', []) if isinstance(c, dict) and
                  isinstance(c.get('meanAbsRGBA'), (int, float)) and isinstance(c.get('selector'), str) and
                  c.get('ink', 0) > 20]
    candidates.sort(key=lambda c: c['meanAbsRGBA'])
    if detail.get('originalInk', 0) <= 20:
        return 'INCOMPLETE_EMPTY_RASTER', 'Original view could not be rendered to pixels', candidates
    if not candidates:
        return 'INCOMPLETE_NO_CANDIDATES', 'No icon factories rendered nonempty pixels', []
    best = candidates[0]
    next_score = candidates[1]['meanAbsRGBA'] if len(candidates) > 1 else 255
    if best['meanAbsRGBA'] <= 1.0 and next_score - best['meanAbsRGBA'] >= 5.0:
        return 'CANDIDATE_UNIQUE_PIXEL_MATCH', ('Pixel-identical or extremely close candidate; verify on the real player'), candidates
    return 'INCOMPLETE_RASTER_MATCH', 'No uniquely pixel-identical original asset in candidate selector scan', candidates


def self_test():
    base = {'ok': True, 'label': 'Lyric stickers', 'matches': [{'icon': {'frame': [0, 0, 24, 24]},
             'originalInk': 200, 'ivarLayout': [], 'candidateScores': [
                 {'selector': 'quoteSquare', 'meanAbsRGBA': 0.1, 'ink': 200},
                 {'selector': 'lyrics', 'meanAbsRGBA': 25.0, 'ink': 200}]}]}
    assert urlencode({'label': 'Lyric stickers'}, quote_via=quote) == 'label=Lyric%20stickers'
    assert interpret(base)[0] == 'CANDIDATE_UNIQUE_PIXEL_MATCH'
    assert interpret({**base, 'matches': []})[0] == 'INCOMPLETE_TARGET'
    assert interpret({**base, 'matches': [{**base['matches'][0], 'originalInk': 0}]})[0] == 'INCOMPLETE_EMPTY_RASTER'
    dup = {'ok': True, 'label': 'Lyric stickers', 'matches': [{**base['matches'][0],
        'candidateScores': [{'selector': 'a', 'meanAbsRGBA': .1, 'ink': 200},
                            {'selector': 'b', 'meanAbsRGBA': .2, 'ink': 200}]}]}
    assert interpret(dup)[0] == 'INCOMPLETE_RASTER_MATCH'
    assert interpret({'ok': False})[0] == 'INCOMPLETE_DRIVER'
    print('PASS: Stage 44 pixel matching and incomplete-result checks')


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
        input('Открой попап с «Lyric stickers» и «GIF», нажми Enter... ')
    root = Path(args.out).resolve() / ('stage44-lyrics-visual-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    root.mkdir(parents=True, exist_ok=False)
    report = {'status': 'INCOMPLETE', 'target': 'Lyric stickers', 'port': args.port}
    try:
        result = request(args.port, 'encore.trace', label='Lyric stickers')
        (root / 'native-trace.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        status, reason, candidates = interpret(result)
        report.update(status=status, reason=reason,
                      topCandidates=candidates[:15],
                      originalInk=(result.get('matches') or [{}])[0].get('originalInk', None))
        if status == 'CANDIDATE_UNIQUE_PIXEL_MATCH':
            report['possibleSelector'] = candidates[0]['selector']
    except Exception as exc:
        report.update(status='INCOMPLETE_DRIVER', reason=repr(exc))
    try:
        (root / 'tree.txt').write_text(request(args.port, 'tree'), encoding='utf-8')
    except Exception as exc:
        report['treeError'] = repr(exc)
    try:
        p = subprocess.run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', '--type=png',
                            str(root / 'screen.png')], capture_output=True, text=True, timeout=30)
        report['screenshotExit'] = p.returncode
        if p.returncode != 0:
            report['screenshotError'] = p.stderr[-1500:]
    except Exception as exc:
        report['screenshotError'] = repr(exc)
    (root / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    archive = root.with_suffix('.zip')
    with ZipFile(archive, 'w', ZIP_DEFLATED) as z:
        for file in root.rglob('*'):
            if file.is_file():
                z.write(file, file.relative_to(root.parent))
    print('STATUS:', report['status'])
    print('Reason:', report['reason'])
    if report.get('possibleSelector'):
        print('Possible Spotify selector:', report['possibleSelector'])
    print('Evidence ZIP:', archive)

if __name__ == '__main__':
    main()
