#!/usr/bin/env python3
"""SG_DRIVER automatic audit of the owned dropdown renderer against iOS 26.

Uses two already booted simulators and ports; drives both without manual touches.
No destructive actions: opens the player, root dropdown, More, and a read-only
Speed/Pitch panel; captures UI trees, layers and screenshots, then closes menus.
"""
from __future__ import annotations
import argparse
import base64
from datetime import datetime
import json
from pathlib import Path
import re
import time
from urllib import parse, request
from zipfile import ZipFile, ZIP_DEFLATED


def call(port, name, **params):
    q = parse.urlencode({k: str(v) for k, v in params.items()})
    url = f'http://127.0.0.1:{port}/{parse.quote(name)}' + ('?' + q if q else '')
    req = request.Request(url, headers={'X-Phone-Driver': '1'})
    with request.urlopen(req, timeout=30) as res:
        raw = res.read()
    if name == 'tree':
        return raw.decode('utf-8', 'replace')
    result = json.loads(raw)
    if not result.get('ok'):
        raise RuntimeError(f'{name}: {result.get("error") or result}')
    return result


def save(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    elif isinstance(content, str):
        path.write_text(content, encoding='utf-8')
    else:
        path.write_text(json.dumps(content, ensure_ascii=False, indent=2), encoding='utf-8')


def collect(port, folder):
    tree = call(port, 'tree')
    save(folder/'tree.txt', tree)
    state = call(port, 'state')
    save(folder/'state.json', state)
    try:
        response = call(port, 'screenshot')
        raw = base64.b64decode(response.get('png', ''))
        if raw.startswith(b'\x89PNG'):
            save(folder/'screen.png', raw)
    except Exception as exc:
        save(folder/'screenshot-error.txt', str(exc))
    custom = list(re.finditer(r'Vitrine\.Dropdown\.Panel', tree))
    native = list(re.finditer(r'_UIContextMenuView', tree))
    return {'ownedPanelMentions': len(custom), 'nativeMenuMentions': len(native),
            'menuReported': state.get('menu'), 'owned': bool(custom)}


def stage(port, root):
    results = {}
    try:
        call(port, 'player.open')
        time.sleep(0.5)
        call(port, 'player.more')
        time.sleep(0.45)
        results['root'] = collect(port, root/'root')
        call(port, 'menu.pick', title='More')
        time.sleep(0.55)
        results['more'] = collect(port, root/'more')
        # Dismiss More with a harmless outside tap, then open another panel.
        call(port, 'tap', at='50,650')
        time.sleep(0.3)
        call(port, 'player.more')
        time.sleep(0.35)
        call(port, 'menu.pick', title='Speed, Pitch & Reverb')
        time.sleep(0.45)
        results['speedPanel'] = collect(port, root/'speed-panel')
        call(port, 'tap', at='40,630')
    except Exception as exc:
        results['error'] = str(exc)
        try:
            results['failure'] = collect(port, root/'failure')
        except Exception as nested:
            results['captureError'] = str(nested)
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port18', type=int, default=8087)
    ap.add_argument('--port26', type=int, default=8088)
    ap.add_argument('--out', type=Path, default=Path('out'))
    args = ap.parse_args()
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    folder = args.out/f'vitrine-owned-dropdown-{stamp}'
    folder.mkdir(parents=True, exist_ok=True)
    result = {}
    for label, port in [('ios26', args.port26), ('ios18', args.port18)]:
        print(f'=== {label}, port {port} ===', flush=True)
        result[label] = stage(port, folder/label)
        print(json.dumps(result[label], ensure_ascii=False, indent=2), flush=True)
    save(folder/'summary.json', result)
    archive = folder.with_suffix('.zip')
    with ZipFile(archive, 'w', ZIP_DEFLATED) as z:
        for file in folder.rglob('*'):
            if file.is_file():
                z.write(file, file.relative_to(folder.parent))
    print('ARCHIVE:', archive.resolve(), flush=True)


if __name__ == '__main__':
    main()
