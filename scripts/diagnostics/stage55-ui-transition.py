#!/usr/bin/env python3
"""Stage 55: read-only Legacy Glass Home/NMF, Library, Genres, navbar and Share audit.

User opens each page manually. Never infer success from an incomplete view tree.
Uses only Python 3 and xcrun, no ffprobe/ffmpeg needed. No source modification.
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
SCENARIOS = [
    ('home-before', 'Открой Home → Music, НЕ открывай New Music Friday'),
    ('nmf-open', 'Открой New Music Friday целиком (экран с проблемной шапкой / большим gap)'),
    ('home-after', 'Вернись назад на Home → Music, где фон тоже ломается'),
    ('library', 'Открой Your Library и оставь Recents под чипсами, ничего не скролль'),
    ('tab-bar-settings', 'Открой настройки Tab bar с овальным заголовком и кнопкой Back'),
    ('genres', 'Открой Genres с заголовком и стеклянной кнопкой Back'),
    ('share', 'Открой Share у трека и дождись второго ряда с More'),
]
WATCH = ('SGRHomeTintView', 'New Music Friday', 'FullBleedBanner', 'HomePageView',
         'SGRLegacy', 'SGRMirrorButton', 'YourLibrary', 'Genres', 'Tab bar',
         'Share_MenuImpl', 'PlatformGroupContainer', 'SwiftUI._UIGraphicsView',
         'SGLegacyGlassView', 'Gradient', 'UINavigationBar', 'Recents')


def request(port, endpoint, args=None, timeout=25):
    query = urllib.parse.urlencode(args or {}, quote_via=urllib.parse.quote)
    url = 'http://127.0.0.1:%s/%s' % (port, endpoint)
    if query:
        url += '?' + query
    req = urllib.request.Request(url, headers={'X-Phone-Driver': '1'})
    with urllib.request.urlopen(req, timeout=timeout) as res:
        raw = res.read().decode('utf-8', 'replace')
    return raw if endpoint == 'tree' else json.loads(raw)


def write_json(path, val):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(val, ensure_ascii=False, indent=2, default=str) + '\n')


def cmd(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return {'exit': p.returncode, 'out': p.stdout[-8000:], 'err': p.stderr[-8000:]}
    except Exception as err:
        return {'exit': -1, 'error': repr(err)}


def subviews(tree, key, before=0, after=15):
    lines = tree.splitlines()
    blocks = []
    for i, line in enumerate(lines):
        if key in line:
            blocks.append({'line': i + 1, 'context': lines[max(0, i - before):i + after]})
    return blocks[:30]


def snap(port, udid, dest, scenario):
    folder = dest / scenario
    folder.mkdir(parents=True, exist_ok=True)
    failed = []
    tree = ''
    try:
        tree = request(port, 'tree')
        (folder / 'tree.txt').write_text(tree)
        (folder / 'optical-lines.txt').write_text('\n'.join(
            '%5d: %s' % (i + 1, s) for i, s in enumerate(tree.splitlines())
            if any(w in s for w in WATCH)) + '\n')
    except Exception as err:
        failed.append('tree: ' + repr(err))
    try:
        write_json(folder / 'state.json', request(port, 'state'))
    except Exception as err:
        failed.append('state: ' + repr(err))
    screenshot = folder / 'screen.png'
    c = cmd(['xcrun', 'simctl', 'io', udid, 'screenshot', '--type=png', str(screenshot)])
    write_json(folder / 'screenshot-command.json', c)
    if c['exit'] or not screenshot.exists() or screenshot.stat().st_size < 2000:
        failed.append('simulator screenshot unavailable')
    for cls in ('YourLibrary_CommonKit.YourLibraryCollectionView',
                'SGRHomeTintView', 'SGLegacyGlassView',
                'Share_MenuImpl.BottomAutoScrollingScrollView',
                'SwiftUI._UIGraphicsView'):
        tag = re.sub('[^A-Za-z0-9]+', '-', cls)
        try:
            response = request(port, 'find', {'class': cls})
            write_json(folder / 'find' / (tag + '.json'), response)
        except Exception as err:
            write_json(folder / 'find' / (tag + '.json'), {'ok': False, 'error': repr(err)})
    if scenario == 'library':
        cls = 'YourLibrary_CommonKit.YourLibraryCollectionView'
        for prop in ('frame', 'contentInset', 'adjustedContentInset', 'contentOffset',
                     'contentSize', 'safeAreaInsets', 'bounds', 'layer.position'):
            try:
                response = request(port, 'get', {'class': cls, 'index': 0, 'path': prop})
            except Exception as err:
                response = {'ok': False, 'error': repr(err)}
            write_json(folder / 'library-properties' / (prop + '.json'), response)
        for name in ('YourLibraryContent.collectionView', 'YourLibraryHeaderContentFiltersView', 'Recents'):
            write_json(folder / ('context-' + re.sub('[^A-Za-z0-9]', '-', name) + '.json'),
                       subviews(tree, name, 5, 8))
    if scenario.startswith('home') or scenario == 'nmf-open':
        for marker in ('HomePageView', 'SGRHomeTintView', 'New Music Friday',
                       'FullBleedBanner', 'Gradient', 'NavigationBar'):
            write_json(folder / ('context-' + re.sub('[^A-Za-z0-9]', '-', marker) + '.json'),
                       subviews(tree, marker, 3, 9))
    if scenario == 'share':
        write_json(folder / 'context-share-actions.json', subviews(tree, 'PlatformGroupContainer', 2, 28))
        write_json(folder / 'context-share-more.json', subviews(tree, '{{256, 8}, {56, 56}}', 3, 6))
    return {'scenario': scenario, 'tree_lines': len(tree.splitlines()),
            'screenshot_bytes': screenshot.stat().st_size if screenshot.exists() else 0,
            'errors': failed,
            'anchors': {x: tree.count(x) for x in WATCH},
            'status': 'EVIDENCE_COLLECTED_REVIEW_REQUIRED' if not failed else 'INCOMPLETE'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8087)
    parser.add_argument('--udid', default=UDID)
    parser.add_argument('--scenarios', nargs='+', choices=[a for a, b in SCENARIOS],
                        default=[a for a, b in SCENARIOS])
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        assert urllib.parse.urlencode({'label': 'New Music Friday'}, quote_via=urllib.parse.quote) == 'label=New%20Music%20Friday'
        assert len(SCENARIOS) == len(set(k for k, _ in SCENARIOS))
        print('SELF_TEST: PASS')
        return
    try:
        state = request(args.port, 'state')
        if not state.get('ok'):
            raise RuntimeError(state)
    except Exception as err:
        print('STATUS: INCOMPLETE (SG_DRIVER unavailable):', repr(err))
        return
    repo = pathlib.Path(__file__).resolve().parents[2]
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    root = repo / 'out' / ('stage55-legacy-ui-transitions-' + stamp)
    root.mkdir(parents=True, exist_ok=True)
    result = {'status': 'INCOMPLETE', 'scenarios': []}
    for key, instruction in SCENARIOS:
        if key not in args.scenarios:
            continue
        print('\n[' + key + '] ' + instruction + '. Затем Enter:', flush=True)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            print('Interrupted: missing mandatory scenarios')
            break
        info = snap(args.port, args.udid, root, key)
        print('  ' + info['status'] + ', lines=%d, errors=%s' % (info['tree_lines'], info['errors']))
        result['scenarios'].append(info)
    expected = len(args.scenarios)
    result['status'] = ('EVIDENCE_COLLECTED_REVIEW_REQUIRED'
                        if len(result['scenarios']) == expected and
                        all(x['status'] == 'EVIDENCE_COLLECTED_REVIEW_REQUIRED' for x in result['scenarios'])
                        else 'INCOMPLETE')
    result['note'] = 'Successful capture is NOT a visual fix verification. Verify timing, geometry and reuse manually.'
    write_json(root / 'report.json', result)
    write_json(root / 'repository.json', cmd(['git', '-C', str(repo), 'rev-parse', 'HEAD']))
    zip_path = root.with_suffix('.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in root.rglob('*'):
            if f.is_file():
                z.write(f, f.relative_to(root.parent))
    print('\nSTATUS:', result['status'])
    print('Evidence ZIP:', zip_path)

if __name__ == '__main__':
    main()
