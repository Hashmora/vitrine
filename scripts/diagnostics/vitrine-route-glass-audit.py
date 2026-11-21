#!/usr/bin/env python3
"""Stage 127: automatically visit Spotify URI screens and record runtime glass evidence.

Requires the Stage 126 SG_DRIVER=1 build on localhost:8087 and Xcode Simulator.
No arbitrary UI tapping, no destructive actions, no playback changes.

    cd ~/Downloads/spoti-fork
    python3 scripts/diagnostics/vitrine-route-glass-audit.py \
        --inventory ~/Downloads/ipa-glass-audit-20261121-171440.zip

    # Additional Spotify deep links, one per line or JSON/CSV:
    python3 scripts/diagnostics/vitrine-route-glass-audit.py \
        --routes out/glass-routes.txt --inventory ~/Downloads/ipa-glass-audit-20261121-171440.zip

By default, takes the real 17 page URIs from NavbarSettings.m (not made-up
routes). A class name or a Mach-O address is NOT a routable Spotify URI.
A controller recorded without glass is flagged for review, not diagnosed broken.
"""
from __future__ import annotations
import argparse
import base64
import collections
import csv
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib import parse, request
from zipfile import ZipFile, ZIP_DEFLATED

DEFAULT_DEVICE = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
DEFAULT_PORT = 8087
PRESET_RE = re.compile(r'SGTabTitle:\s*@"([^"]+)"\s*,\s*SGTabURI:\s*@"([^"]+)"')
GLASS_CLASSES = ('SGLegacyGlassView', 'SGGlassView', 'UIVisualEffectView', 'SGRLegacyLens')
MAX_SAVED_TREE = 15 * 1024 * 1024


def save_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False, default=str) + '\n', encoding='utf-8')


def csv_write(path, headers, rows):
    with path.open('w', encoding='utf-8-sig', newline='') as f:
        writer = csv.DictWriter(f, headers, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def safe_route(uri):
    """Restrict navigation to Spotify's own URIs/share links."""
    u = parse.urlsplit(uri)
    if u.scheme.lower() == 'spotify' and uri.startswith('spotify:') and len(uri) <= 2048:
        return True
    return u.scheme == 'https' and u.hostname == 'open.spotify.com' and len(uri) <= 2048


def normalized_route(row, fallback='custom'):
    if isinstance(row, str):
        return {'name': row[:65], 'uri': row.strip(), 'source': fallback}
    return {'name': str(row.get('name') or row.get('title') or row.get('uri') or 'custom')[:90],
            'uri': str(row.get('uri') or row.get('url') or '').strip(),
            'source': fallback}


def load_routes(path):
    path = Path(path)
    text = path.read_text(encoding='utf-8-sig')
    if path.suffix.lower() == '.json':
        doc = json.loads(text)
        if isinstance(doc, dict):
            doc = doc.get('routes', [])
        if not isinstance(doc, list):
            raise ValueError('JSON manifest must be an array or {"routes": [...]}')
        return [normalized_route(item, str(path)) for item in doc]
    if path.suffix.lower() == '.csv':
        return [normalized_route(row, str(path)) for row in csv.DictReader(io.StringIO(text))]
    return [normalized_route(line, str(path)) for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def built_in_routes(repo):
    source = repo / 'tweak/Sources/Native/Navbar/NavbarSettings.m'
    if not source.exists():
        raise FileNotFoundError(f'Could not find real Spotify route presets: {source}')
    matches = PRESET_RE.findall(source.read_text(encoding='utf-8'))
    if len(matches) < 10:
        raise ValueError('Could not parse Spotify URI presets from NavbarSettings.m')
    return [{'name': name, 'uri': uri, 'source': 'Vitrine NavbarSettings.m'} for name, uri in matches]


def all_routes(repo, extra, only_extra):
    routes = [] if only_extra else built_in_routes(repo)
    if extra:
        routes.extend(load_routes(extra))
    unique, seen = [], set()
    for route in routes:
        uri = route['uri']
        if not safe_route(uri):
            raise ValueError(f'Unsafe/invalid route in manifest: {uri!r}. Only spotify: or https://open.spotify.com links permitted')
        if uri not in seen:
            seen.add(uri)
            unique.append(route)
    if not unique:
        raise ValueError('No routes to visit')
    return unique


class Driver:
    def __init__(self, port):
        self.base = f'http://127.0.0.1:{port}'

    def call(self, command, **kwargs):
        query = parse.urlencode({key: str(v) for key, v in kwargs.items()})
        url = self.base + '/' + parse.quote(command) + ('?' + query if query else '')
        req = request.Request(url, headers={'X-Phone-Driver': '1'})
        with request.urlopen(req, timeout=40) as response:
            raw = response.read()
        if command == 'tree':
            tree = raw.decode('utf-8', 'replace')
            if '== window' not in tree:
                raise RuntimeError('Driver returned unexpected /tree data: ' + tree[:150])
            return tree
        payload = json.loads(raw)
        if not isinstance(payload, dict) or payload.get('ok') is not True:
            raise RuntimeError(f'SG_DRIVER /{command}: {payload!r}'[:500])
        return payload


class SimNavigator:
    def __init__(self, device):
        self.device = device

    def open(self, uri):
        result = subprocess.run(['xcrun', 'simctl', 'openurl', self.device, uri],
                                capture_output=True, text=True, timeout=35)
        if result.returncode:
            raise RuntimeError(f'simctl openurl returned {result.returncode}: {result.stderr.strip()}')
        return (result.stdout + '\n' + result.stderr).strip()

    def screenshot(self, destination):
        result = subprocess.run(['xcrun', 'simctl', 'io', self.device, 'screenshot',
                                 '--type=png', str(destination)],
                                capture_output=True, text=True, timeout=45)
        if result.returncode or not destination.exists() or destination.stat().st_size < 1500:
            raise RuntimeError('simctl screenshot failed: ' + result.stderr.strip())
        return 'simctl'


def capture(driver, navigator, folder, with_layers):
    folder.mkdir(parents=True, exist_ok=True)
    info = {'timestamp': datetime.now().isoformat(timespec='seconds'), 'errors': []}
    for command, name in (('state', 'state.json'), ('audit.controllers', 'controllers.json')):
        try:
            result = driver.call(command)
            save_json(folder / name, result)
            if command == 'state':
                info['top'] = result.get('top')
                info['title'] = result.get('topTitle')
            else:
                info['runtimeControllers'] = len(result.get('controllers', []))
        except Exception as exc:
            info['errors'].append(f'{command}: {exc}')
    try:
        tree = driver.call('tree')
        if len(tree.encode('utf-8')) > MAX_SAVED_TREE:
            raise ValueError('Tree exceeds 15 MiB; skipped to avoid huge archive')
        (folder / 'tree.txt').write_text(tree, encoding='utf-8')
        info['treeSHA256'] = hashlib.sha256(tree.encode('utf-8')).hexdigest()
    except Exception as exc:
        info['errors'].append(f'tree: {exc}')
    try:
        info['screenshot'] = navigator.screenshot(folder / 'screen.png')
    except Exception as exc:
        try:
            payload = driver.call('screenshot', scale=1)
            (folder / 'screen.png').write_bytes(base64.b64decode(payload['png']))
            info['screenshot'] = 'SG_DRIVER fallback'
        except Exception as exc2:
            info['errors'].append(f'screenshot: {exc}; fallback: {exc2}')
    if with_layers:
        try:
            snapshot = json.loads((folder / 'controllers.json').read_text(encoding='utf-8'))
            classes = []
            for controller in snapshot.get('controllers', []):
                if not controller.get('visible'):
                    continue
                for example in controller.get('glass', {}).get('examples', []):
                    if example.get('kind') in ('vitrine', 'system-effect'):
                        cls = example.get('class')
                        if cls and cls not in classes:
                            classes.append(cls)
            classes = classes[:5] or list(GLASS_CLASSES[:2])
            for classname in classes:
                try:
                    matched = driver.call('find', **{'class': classname})
                    if matched.get('count', 0):
                        index = next((v['index'] for v in matched.get('views', [])
                                      if v.get('shown') and 'index' in v), None)
                        if index is None:
                            continue
                        layers = driver.call('layers', **{'class': classname, 'index': index, 'depth': 7})
                        index_name = f'{len(list((folder / "layers").glob("*.json"))):02d}' if (folder / 'layers').exists() else '00'
                        save_json(folder / 'layers' / (index_name + '.json'),
                                  {'class': classname, 'find': matched, 'layers': layers})
                except Exception as exc:
                    info['errors'].append(f'layers:{classname}: {exc}')
        except Exception as exc:
            info['errors'].append(f'layers: {exc}')
    save_json(folder / 'capture.json', info)
    return info


def load_inventory(path):
    if path is None:
        return []
    path = Path(path)
    if path.suffix.lower() == '.zip':
        with ZipFile(path) as z:
            found = [name for name in z.namelist() if name.endswith('/screen_candidates.csv') or name == 'screen_candidates.csv']
            if len(found) != 1:
                raise ValueError('Inventory ZIP must contain exactly one screen_candidates.csv')
            payload = z.read(found[0]).decode('utf-8-sig')
    else:
        payload = path.read_text(encoding='utf-8-sig')
    return list(csv.DictReader(io.StringIO(payload)))


def write_coverage(root, inventory, results):
    seen = collections.defaultdict(lambda: {'routes': set(), 'visibleRoutes': set(), 'vitrineGlass': 0,
                                           'systemEffect': 0, 'backdrop': 0, 'controls': 0, 'count': 0})
    instances = []
    for result in results:
        if not result.get('opened'):
            continue
        for phase in ('top', 'scrolled'):
            file = root / result['folder'] / phase / 'controllers.json'
            if not file.exists():
                continue
            data = json.loads(file.read_text(encoding='utf-8'))
            for vc in data.get('controllers', []):
                cls = vc.get('class', '')
                if not cls:
                    continue
                g = vc.get('glass', {})
                entry = seen[cls]
                entry['routes'].add(result['uri'])
                if vc.get('visible'):
                    entry['visibleRoutes'].add(result['uri'])
                entry['vitrineGlass'] = max(entry['vitrineGlass'], int(g.get('vitrineGlass', 0)))
                entry['systemEffect'] = max(entry['systemEffect'], int(g.get('systemEffect', 0)))
                entry['backdrop'] = max(entry['backdrop'], int(g.get('backdropViews', 0)))
                entry['controls'] = max(entry['controls'], int(g.get('buttons', 0)) + int(g.get('headerCandidates', 0)))
                entry['count'] += 1
                instances.append({'route':result['name'], 'uri':result['uri'], 'phase':phase,
                    'class':cls, 'visible':vc.get('visible'), 'top':vc.get('top'), 'loaded':vc.get('loaded'),
                    'vitrineGlass':g.get('vitrineGlass', 0), 'systemEffect':g.get('systemEffect', 0),
                    'backdropViews':g.get('backdropViews', 0), 'namedCandidates':g.get('namedGlassCandidates', 0),
                    'buttons':g.get('buttons', 0), 'headerCandidates':g.get('headerCandidates', 0)})
    csv_write(root / 'observed_controllers.csv',
        ['route','uri','phase','class','visible','top','loaded','vitrineGlass','systemEffect','backdropViews','namedCandidates','buttons','headerCandidates'], instances)
    # Runtime NSStringFromClass normally demangles Swift; inventory has both
    # display_name and raw_class, so match against both forms.
    mapped = {}
    for cls, item in seen.items():
        mapped[cls] = item
        mapped[cls.replace('.', '_')] = item
    matches = []
    for row in inventory:
        key = next((v for v in (row.get('display_name'), row.get('raw_class')) if v in mapped), None)
        item = mapped.get(key) if key else None
        vis = bool(item and item['visibleRoutes'])
        matches.append({'class':row.get('display_name'), 'category':row.get('category'),
            'mentionedInVitrineWhenInventoryBuilt':row.get('mentioned_in_vitrine'),
            'observed': bool(item), 'visibleOnVisitedRoute':vis,
            'visitedRoutes':len(item['routes']) if item else 0,
            'vitrineGlassObserved':item['vitrineGlass'] if item else 0,
            'systemEffectObserved':item['systemEffect'] if item else 0,
            'backdropObserved':item['backdrop'] if item else 0,
            'review': ('not visited; cannot infer glass coverage' if not item
                else 'visible; no local glass evidence (manual review)' if vis and
                    not (item['vitrineGlass'] or item['systemEffect'] or item['backdrop'])
                else 'runtime evidence collected; visual review still needed')})
    csv_write(root / 'inventory_runtime_coverage.csv',
       ['class','category','mentionedInVitrineWhenInventoryBuilt','observed','visibleOnVisitedRoute',
        'visitedRoutes','vitrineGlassObserved','systemEffectObserved','backdropObserved','review'], matches)
    return {'inventoryCandidates':len(inventory),
            'inventoryControllerCandidates':sum(r.get('category') == 'controller' for r in inventory),
            'uniqueObservedControllers':len(seen),
            'observedInventoryCandidates':sum(bool(x['observed']) for x in matches),
            'pagesWithNoLocalGlass':sum(x['review'].startswith('visible; no') for x in matches),
            'notVisited':sum(not x['observed'] for x in matches)}


def archive(root):
    destination = root.with_suffix('.zip')
    with ZipFile(destination, 'w', ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(root.rglob('*')):
            if path.is_file():
                z.write(path, root.name + '/' + str(path.relative_to(root)))
    return destination


def run_audit(args, driver, navigator, repo):
    routes = all_routes(repo, args.routes, args.only_routes)
    inventory = load_inventory(args.inventory)
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    root = (Path(args.output) / ('vitrine-uri-audit-' + timestamp)).resolve()
    root.mkdir(parents=True, exist_ok=False)
    results = []
    save_json(root / 'planned_routes.json', routes)
    print(f'Routes: {len(routes)}; inventory candidates: {len(inventory)}')
    try:
        for index, route in enumerate(routes, 1):
            folder = root / 'screens' / f'{index:03d}'
            record = {**route, 'number': index, 'folder': str(folder.relative_to(root)),
                      'opened': False, 'errors': []}
            print(f'[{index}/{len(routes)}] {route["name"]}: {route["uri"]}', flush=True)
            try:
                before = driver.call('state')
                record['beforeTop'] = before.get('top')
                navigator.open(route['uri'])
                record['opened'] = True
                time.sleep(args.delay)
                top = capture(driver, navigator, folder / 'top', args.layers)
                record['afterTop'] = top.get('top')
                record['topTreeSHA256'] = top.get('treeSHA256')
                record['errors'].extend(top.get('errors', []))
                if args.scroll:
                    try:
                        record['scroll'] = driver.call('scroll', by=f'0,{args.scroll}', animated=0)
                        time.sleep(args.scroll_delay)
                        sub = capture(driver, navigator, folder / 'scrolled', args.layers)
                        record['errors'].extend('scrolled:' + err for err in sub.get('errors', []))
                    except Exception as exc:
                        record['errors'].append('scroll: ' + str(exc))
                record['possiblyUnchanged'] = bool(record['beforeTop'] == record.get('afterTop'))
                if record['possiblyUnchanged']:
                    record['note'] = 'Same top class; may be navigation within same controller, or URI unsupported.'
            except Exception as exc:
                record['errors'].append('open/capture: ' + str(exc))
            save_json(folder / 'route.json', record)
            results.append(record)
            save_json(root / 'progress.json', results)
    except KeyboardInterrupt:
        print('\nInterrupted. Packaging completed partial results…')
    summary = write_coverage(root, inventory, results)
    summary.update({'routesPlanned':len(routes), 'routesAttempted':len(results),
                    'routesOpenedBySimctl':sum(bool(r['opened']) for r in results),
                    'routesWithErrors':sum(bool(r['errors']) for r in results),
                    'notes':['simctl success is not proof of reaching a particular screen',
                             'glass detection is visual evidence, not a correctness test',
                             'class names are not Spotify URIs; non-routable classes remain unvisited']})
    save_json(root / 'summary.json', summary)
    (root / 'README.txt').write_text(
        'Vitrine Stage 126–127 automatic Spotify URI glass coverage audit\n'
        'screens/NNN/{top,scrolled}/: state, actual controller census, full tree, screenshot, selected glass layers.\n'
        'observed_controllers.csv: objects actually found by SG_DRIVER on visited routes.\n'
        'inventory_runtime_coverage.csv: ALL IPA controller candidates including never visited.\n'
        'A visible page with no local glass is NOT proof that glass is missing. Shared navbar glass is separate.\n'
        'Some URI handlers require a paid account or populated user library; openurl may open no page.\n'
        'Screen trees and screenshots may contain personal messages, usernames and listening history.\n',
        encoding='utf-8')
    dest = archive(root)
    print(f'\nArchive: {dest}\nSummary: {json.dumps(summary, ensure_ascii=False)}')
    return dest, summary


def self_test():
    class FakeDriver:
        route = 'first'
        def call(self, cmd, **kw):
            if cmd == 'state': return {'ok':True,'top':'Fake.' + self.route}
            if cmd == 'audit.controllers':
                return {'ok':True, 'controllers':[{'class':'Fake.' + self.route,
                       'visible':True, 'top':True, 'loaded':True, 'glass':{'vitrineGlass':1,
                       'systemEffect':0, 'backdropViews':0, 'buttons':2,'headerCandidates':1,
                       'examples':[]}}]}
            if cmd == 'tree': return '== window FakeWindow ==\nFake.View {{0, 0}, {400, 800}}'
            if cmd == 'scroll': return {'ok':True, 'after':[0,450]}
            if cmd == 'find': return {'ok':True, 'count':0, 'views':[]}
            if cmd == 'screenshot': return {'ok':True, 'png':base64.b64encode(b'\x89PNG' + b'x' * 2000).decode()}
            raise RuntimeError(cmd)
    class FakeNav:
        def __init__(self, driver): self.driver=driver
        def open(self, uri): self.driver.route='first' if 'home' in uri else 'second'
        def screenshot(self, dest): dest.write_bytes(b'\x89PNG' + b'x' * 2000); return 'fake'
    driver = FakeDriver()
    with tempfile.TemporaryDirectory() as temporary:
        repo = Path(temporary)
        f = repo / 'tweak/Sources/Native/Navbar/NavbarSettings.m'
        f.parent.mkdir(parents=True)
        f.write_text(' '.join(f'@{{SGTabTitle: @"{i}", SGTabURI: @"spotify:{i}"}}' for i in
                    ['home','search','collection','albums','artists','tracks','podcasts','concerts','browse','playlists']))
        inv = repo / 'screen_candidates.csv'
        inv.write_text('display_name,category,mentioned_in_vitrine\nFake.first,controller,False\nFake.unknown,controller,False\n')
        args = argparse.Namespace(routes=None, only_routes=False, inventory=str(inv),
             output=str(repo/'out'), delay=0, scroll=450, scroll_delay=0, layers=False)
        dest, summary = run_audit(args, driver, FakeNav(driver), repo)
        assert dest.exists() and summary['observedInventoryCandidates'] == 1, summary
        with ZipFile(dest) as z:
            assert any(s.endswith('inventory_runtime_coverage.csv') for s in z.namelist())
            assert any(s.endswith('/scrolled/controllers.json') for s in z.namelist())
    print('SELF-TEST PASSED: navigation, runtime snapshot, CSV merge, zip')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=int(os.environ.get('SIM_PORT', DEFAULT_PORT)))
    parser.add_argument('--device', default=DEFAULT_DEVICE)
    parser.add_argument('--repo', default='.', help='Vitrine source directory')
    parser.add_argument('--inventory', help='Previously generated IPA audit ZIP or screen_candidates.csv')
    parser.add_argument('--routes', help='Extra UTF-8 URI list (.txt), CSV with uri/name, or JSON routes array')
    parser.add_argument('--only-routes', action='store_true', help='Use only --routes, skip 17 builtin presets')
    parser.add_argument('--output', default='out', help='Output parent directory')
    parser.add_argument('--delay', type=float, default=1.5, help='Page settle time, seconds')
    parser.add_argument('--scroll', type=int, default=460, help='Scroll each page by Y points after top capture; 0 disables')
    parser.add_argument('--scroll-delay', type=float, default=0.5)
    parser.add_argument('--no-layers', action='store_false', dest='layers', help='Faster audit without CALayer samples')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.delay < 0 or args.scroll_delay < 0 or args.scroll < 0:
        parser.error('delay and scroll must be non-negative')
    if args.only_routes and not args.routes:
        parser.error('--only-routes needs --routes')
    if not shutil.which('xcrun'):
        parser.error('xcrun is missing: run this on the Mac with Xcode Simulator')
    driver = Driver(args.port)
    try:
        probe = driver.call('audit.controllers')
        if not isinstance(probe.get('controllers'), list):
            raise RuntimeError('audit.controllers did not return controllers array')
    except Exception as exc:
        parser.error('SG_DRIVER not ready or Stage 126 not compiled. Check port/build: '+str(exc))
    try:
        run_audit(args, driver, SimNavigator(args.device), Path(args.repo).expanduser().resolve())
    except Exception as exc:
        print('FAILED:', exc, file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
