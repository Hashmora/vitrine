#!/usr/bin/env python3
"""Stage 194: compact Legacy iOS18 player morphology evidence only.
No UI changes, no iOS26 requests, no frame PNGs, no third-party installs.
"""
from __future__ import annotations
import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
from zipfile import ZipFile, ZIP_DEFLATED, ZIP_STORED

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('stage190_capture', HERE/'stage190-player-menu-morph-capture.py')
N = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = N
spec.loader.exec_module(N)
S = N.S
LIMIT = 400 * 1024 * 1024


def shown(driver, **selector):
    return [v for v in driver.call('find', **selector).get('views', []) if v.get('shown') is True]


def verified(driver, menu, more=False, timeout=8):
    deadline = time.monotonic() + timeout
    observed = {}
    while True:
        observed = {'state': driver.call('state'),
                    'legacy': shown(driver, **{'class':'SGRDropdownPanel'}),
                    'native': shown(driver, **{'class':'_UIContextMenuView'}),
                    'back': shown(driver, id='Vitrine.Dropdown.Back')}
        ok = (bool(observed['state'].get('player')) and
              bool(observed['state'].get('menu')) == menu and
              bool(observed['legacy']) == menu and not observed['native'] and
              bool(observed['back']) == more)
        if ok:
            return observed
        if time.monotonic() >= deadline:
            raise S.EvidenceError(f'Legacy state expected menu={menu}, More={more}: {observed}')
        time.sleep(.12)


def metadata_only(video, folder, exporter):
    S.run([str(exporter), str(video), str(folder), '0', '--pts-only'], timeout=180)
    data = json.loads((folder/'native-extraction.json').read_text())
    # AVFoundation writes an integer count, not a JSON boolean.
    if data.get('png_written') != 0 or not data.get('decoded_frames') or data['decoded_frames'] != len(data['frames']):
        raise S.EvidenceError('invalid PTS-only result')
    if list(folder.glob('frame_*.png')):
        raise S.EvidenceError('unexpected PNG export in PTS-only mode')
    return {k:v for k,v in data.items() if k != 'frames'}


def prepare_legacy(driver, case):
    # Wait for a restored track and open the player only if it isn't open.
    # Retry preparation (not the recorded action); never toggle a known-open menu.
    deadline = time.monotonic() + 35
    last = None
    while time.monotonic() < deadline:
        try:
            state = driver.call('state')
            if state.get('menu'):
                S.safe_external_tap(driver)
                state = driver.call('state')
            if not state.get('player'):
                driver.call('player.open')
                time.sleep(.6)
            closed = verified(driver, False, timeout=2)
            if case == 'root-open':
                return closed['state']
            driver.call('player.more')
            opened = verified(driver, True, timeout=4)
            # The panel can be reported visible while it is still morphing.
            time.sleep(.65)
            if case == 'more-close':
                driver.call('menu.pick', title='More')
                opened = verified(driver, True, True, timeout=4)
                time.sleep(.65)
            return opened['state']
        except S.EvidenceError as exc:
            last = str(exc)
            time.sleep(.5)
    raise S.EvidenceError(f'player/menu preparation timed out: {last}')


def take(driver, device, case, root, trial, exporter, layers, preroll, tail):
    dest = root/'ios18'/case/f'trial-{trial:02d}'
    dest.mkdir(parents=True, exist_ok=True)
    report = {'case':case, 'trial':trial, 'status':'INCOMPLETE', 'began':S.clock()}
    try:
        report['prepared'] = prepare_legacy(driver, case)
        report['before_verified'] = verified(driver, case != 'root-open', case == 'more-close')
        S.collect_snapshot(driver, dest/'before')
        report['recording'] = N.capture(device['udid'], dest/'capture.mp4',
                                       lambda: S.event(driver, case), preroll, tail)
        if report['recording'].get('action_error'):
            raise S.EvidenceError(report['recording']['action_error'])
        # Preserve the compositor's end state as well as UIKit's own screenshots.
        S.run(['xcrun','simctl','io',device['udid'],'screenshot',dest/'settled-compositor.png'], timeout=20)
        S.collect_snapshot(driver, dest/'after')
        report['after_verified'] = verified(driver, S.expect_menu(case), case == 'more-open')
        try:
            report['video'] = metadata_only(dest/'capture.mp4', dest/'frames', exporter)
        except Exception as exc:
            report['metadata_error'] = repr(exc)
        report['status'] = 'RECORDED_NOT_YET_MATCHED'
        if layers and trial == 1:
            try:
                report['secondary_layer_pass'] = S.layer_probe(driver, case, dest/'secondary-take')
            except Exception as exc:
                report['secondary_layer_pass_error'] = repr(exc)
    except Exception as exc:
        report['error'] = repr(exc)
        try:
            S.collect_snapshot(driver, dest/'failure')
        except Exception as nested:
            report['failure_snapshot_error'] = repr(nested)
    report['finished'] = S.clock()
    S.save_json(dest/'report.json', report)
    print(f'{case}/{trial:02}: {report["status"]} {report.get("error", "")[:240]}', flush=True)
    return report


def compact_archives(root, limit=LIMIT):
    # Conservative size bound before compression, plus room for ZIP headers.
    files = sorted(p for p in root.rglob('*') if p.is_file() and p.name != '.DS_Store')
    groups, batch, total = [], [], 0
    for p in files:
        if p.name.startswith('frame_') and p.suffix == '.png':
            continue
        cost = p.stat().st_size + 4096 + len(str(p))*4
        if cost > limit:
            raise S.EvidenceError(f'individual capture exceeds upload budget: {p}; original preserved')
        if batch and total + cost > limit:
            groups.append(batch)
            batch, total = [], 0
        batch.append(p)
        total += cost
    if batch:
        groups.append(batch)
    archives = []
    for i, batch in enumerate(groups, 1):
        suffix = '-upload.zip' if len(groups) == 1 else f'-upload-part{i:02d}-of-{len(groups):02d}.zip'
        dest = root.with_name(root.name + suffix)
        with ZipFile(dest,'w', ZIP_DEFLATED, compresslevel=4) as z:
            for p in batch:
                z.write(p, p.relative_to(root.parent), compress_type=ZIP_STORED if p.suffix in ('.mp4','.png') else ZIP_DEFLATED)
        if dest.stat().st_size > limit:
            raise S.EvidenceError(f'archive exceeds target limit: {dest}')
        archives.append(dest)
        print(f'UPLOAD: {dest.resolve()} ({dest.stat().st_size/1024**2:.1f} MiB)', flush=True)
    return archives


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)/'capture'
        root.mkdir()
        for i in range(3):
            (root/f'{i}.mp4').write_bytes(b'x'*1024)
        (root/'frame_000000.png').write_bytes(b'x'*1024)
        archives = compact_archives(root, 11000)
        assert len(archives) >= 2
        names = []
        for archive in archives:
            with ZipFile(archive) as z:
                assert z.testzip() is None
                names.extend(z.namelist())
        assert len(names) == 3 and all(n.endswith('.mp4') for n in names)
    print('PASS compact multipart archive and frame exclusion')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port18', type=int, default=8087)
    p.add_argument('--udid18', default=S.DEFAULT_18)
    p.add_argument('--cases', choices=N.PLAYER_CASES, nargs='+', default=list(N.PLAYER_CASES))
    p.add_argument('--trials', type=int, default=3)
    p.add_argument('--preroll', type=float, default=1.5)
    p.add_argument('--tail', type=float, default=2.0)
    p.add_argument('--layers-pass', action='store_true')
    p.add_argument('--out', type=Path, default=Path('out'))
    p.add_argument('--self-test', action='store_true')
    args = p.parse_args()
    if args.self_test:
        self_test(); return 0
    if not 1 <= args.trials <= 5 or not .4 <= args.preroll <= 5 or not 1 <= args.tail <= 5:
        p.error('trials 1..5, preroll .4..5, tail 1..5')
    device = S.resolve_sim(S.sim_devices(),18,args.udid18)
    driver = S.Driver(args.port18)
    root = args.out/f'stage194-legacy-player-{dt.datetime.now():%Y%m%d-%H%M%S}'
    root.mkdir(parents=True, exist_ok=False)
    exporter = S.build_native_extractor(args.out)
    S.save_json(root/'configuration.json', {'device':device,'port':driver.port,'cases':args.cases,
        'trials':args.trials,'preroll':args.preroll,'tail':args.tail,'layers_pass':args.layers_pass,
        'git_head':S.run(['git','rev-parse','HEAD'])['stdout'].strip(),
        'controller_status':S.run(['git','status','--short','--','tweak/Sources/Redesigned/ContextMenu/SGRDropdownController.m'])['stdout'],
        'note':'HEAD is checkout identity, not proof of binary installed; rebuild Stage193 first.'})
    reports = []
    try:
        S.save_json(root/'preflight.json',driver.call('state'))
        for case in args.cases:
            for trial in range(1,args.trials+1):
                reports.append(take(driver,device,case,root,trial,exporter,args.layers_pass,args.preroll,args.tail))
    except Exception as exc:
        reports.append({'status':'INCOMPLETE','error':repr(exc)})
    complete = len(reports) == len(args.cases)*args.trials and all(r['status']=='RECORDED_NOT_YET_MATCHED' for r in reports)
    S.save_json(root/'report.json',{'reports':reports,'complete':complete,'finished':S.clock(),
                                  'note':'PTS are video-relative; secondary layer pass can perturb timing.'})
    compact_archives(root)
    return 0 if complete else 2


if __name__ == '__main__':
    sys.exit(main())
