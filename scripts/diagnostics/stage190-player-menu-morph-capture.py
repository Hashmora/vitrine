#!/usr/bin/env python3
"""Stage 190: capture restored *native* iOS 26 Spotify player popup and More.

Read-only capture: no hooks, menu replacement, Spotify settings, package installs,
or iOS 18 changes. Uses the Stage188r AVFoundation decoder and SG_DRIVER.

Examples:
  python3 scripts/diagnostics/stage190-player-menu-morph-capture.py --trials 3 --layers-pass --zip
  python3 scripts/diagnostics/stage190-player-menu-morph-capture.py --compare --trials 2 --zip
  python3 scripts/diagnostics/stage190-player-menu-morph-capture.py --self-test
"""
from __future__ import annotations
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from zipfile import ZipFile, ZIP_DEFLATED

HERE = Path(__file__).resolve().parent
PLAYER_CASES = ('root-open', 'root-close', 'more-open', 'more-close')
BASE_FILE = HERE / 'stage188-ios26-menu-morph-capture.py'


def load_stage188():
    if not BASE_FILE.exists():
        raise RuntimeError(f'Missing Stage 188r: {BASE_FILE}')
    spec = importlib.util.spec_from_file_location('stage188_morph', BASE_FILE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


S = load_stage188()


def native_visible(driver):
    """An actual UIKit popup, not a Legacy panel or just Spotify bottom sheet."""
    matches = driver.call('find', **{'class': '_UIContextMenuView'}).get('views', [])
    legacy = driver.call('find', **{'class': 'SGRDropdownPanel'}).get('views', [])
    return bool([v for v in matches if v.get('shown') is True]) and not bool([v for v in legacy if v.get('shown') is True])


def wait_started(proc, logfile, timeout):
    """Wait for an actual simctl startup acknowledgement, not an assumed 380 ms."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise S.EvidenceError(f'simctl recordVideo exited {proc.returncode}: {logfile.read_text(errors="replace")[-1200:]}')
        text = logfile.read_text(errors='replace') if logfile.is_file() else ''
        if 'Recording started' in text:
            return S.clock()
        time.sleep(.055)
    raise S.EvidenceError(f'simctl recordVideo did not acknowledge startup after {timeout:.1f}s; log={logfile.read_text(errors="replace")[-1000:]}')


def capture(udid, output, event, preroll, tail):
    """Native compositor screenshots bracket the recording. Never start tap before recorder ack."""
    output.parent.mkdir(parents=True, exist_ok=True)
    log = output.with_suffix('.capture.log')
    cmd = ['xcrun', 'simctl', 'io', udid, 'recordVideo', '--codec=h264', '--force', str(output)]
    with log.open('wb') as err:
        proc = subprocess.Popen(cmd, stdout=err, stderr=subprocess.STDOUT, start_new_session=True)
        detail = {'recording_command': cmd, 'process_started': S.clock(),
                  'preroll_requested_seconds': preroll, 'tail_requested_seconds': tail}
        try:
            detail['recording_acknowledged'] = wait_started(proc, log, 12)
            # This is the real compositor, unlike drawViewHierarchyInRect SG_DRIVER screenshots.
            baseline = output.with_name('baseline-compositor.png')
            S.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(baseline)], timeout=20)
            detail['baseline_capture'] = S.clock()
            # Give the recorder a generous established baseline after acknowledgement.
            time.sleep(preroll)
            detail['start_expected_before'] = S.clock()
            try:
                detail['action_result'] = event()
                detail['action_error'] = None
            except Exception as exc:
                detail['action_result'] = None
                detail['action_error'] = repr(exc)
            detail['action_returned'] = S.clock()
            time.sleep(tail)
            detail['end_capture_requested'] = S.clock()
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        if not output.is_file() or output.stat().st_size < 4096:
            raise S.EvidenceError(f'recording missing/too short: {output}; log={log.read_text(errors="replace")[-1000:]}')
    return detail


def ensure_native_before(driver, case, label):
    state = driver.call('state')
    if not state.get('player'):
        raise S.EvidenceError('player was not open at trigger time')
    if label == 'ios26' and case != 'root-open' and not native_visible(driver):
        raise S.EvidenceError('native _UIContextMenuView absent before the transition; refusing to capture bottom sheet')
    if label == 'ios26' and case == 'root-open' and state.get('menu'):
        raise S.EvidenceError('native popup already open before root-open')
    return state


def ensure_after(driver, case, label):
    state = driver.call('state')
    expect = S.expect_menu(case)
    if bool(state.get('menu')) != expect:
        raise S.EvidenceError(f'{case}: menu={state.get("menu")}, expected={expect}, top={state.get("top")}')
    if label == 'ios26' and expect and not native_visible(driver):
        raise S.EvidenceError(f'{case}: SG_DRIVER reports menu but visible UIKit popup is missing (bottom sheet?)')
    return state


def take(driver, device, label, case, dest, trial, exporter, preroll, tail, layers):
    folder = dest/label/case/f'trial-{trial:02d}'
    folder.mkdir(parents=True, exist_ok=True)
    out = {'device': device, 'port': driver.port, 'case': case, 'trial': trial,
           'status': 'INCOMPLETE', 'began': S.clock(), 'native_expected': label == 'ios26'}
    try:
        out['prepared'] = S.prepare(driver, case)
        out['precondition'] = ensure_native_before(driver, case, label)
        S.collect_snapshot(driver, folder/'before')
        out['recording'] = capture(device['udid'], folder/'capture.mp4',
                                   lambda: S.event(driver, case), preroll, tail)
        if out['recording']['action_error']:
            raise S.EvidenceError(out['recording']['action_error'])
        S.collect_snapshot(driver, folder/'after')
        out['final_state'] = ensure_after(driver, case, label)
        # Export EVERY recorded frame at native size with actual video PTS.
        out['video'] = S.extract_frames(folder/'capture.mp4', folder/'frames', 0, exporter)
        out['image_proxies'] = S.analyze(folder/'frames', folder/'analysis')
        out['warnings'] = [
            'simctl can omit static compositor refreshes: baseline-compositor.png is the definitive BEFORE state',
            'Frame PTS are video-relative, not synchronized to SG_DRIVER monotonic timestamps',
            'The video is evidence for optics, not a direct measurement of Metal shader values',
        ]
        out['status'] = 'RECORDED_NOT_YET_MATCHED'
        if layers and trial == 1:
            try:
                out['secondary_layer_pass'] = S.layer_probe(driver, case, folder/'secondary-take')
            except Exception as exc:
                out['secondary_layer_pass_error'] = repr(exc)
    except Exception as exc:
        out['error'] = repr(exc)
        try:
            S.collect_snapshot(driver, folder/'failure')
        except Exception as nested:
            out['failure_snapshot_error'] = repr(nested)
    out['finished'] = S.clock()
    S.save_json(folder/'report.json', out)
    print(f'  {label}/{case}/trial-{trial:02}: {out["status"]}' +
          (' ' + out.get('error', '')[:140] if 'error' in out else ''), flush=True)
    return out


def self_test():
    assert len(PLAYER_CASES) == 4
    assert all(c in S.CASES for c in PLAYER_CASES)
    assert S.expect_menu('root-open')
    assert S.expect_menu('more-open')
    assert not S.expect_menu('more-close')
    assert BASE_FILE.exists()
    assert BASE_FILE.with_name('stage188-avfoundation-extract.m').exists()
    print('PASS Stage190: player case routing, Stage188r dependency and case visibility')


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port26', type=int, default=8088)
    p.add_argument('--udid26', default='B8E2A0A5-3BE4-4B47-BBAE-095D64219EBA')
    p.add_argument('--port18', type=int, default=8087)
    p.add_argument('--udid18', default=S.DEFAULT_18)
    p.add_argument('--compare', action='store_true', help='also record Legacy iOS 18 without modifying either renderer')
    p.add_argument('--cases', choices=PLAYER_CASES, nargs='+', default=list(PLAYER_CASES))
    p.add_argument('--trials', type=int, default=3)
    p.add_argument('--preroll', type=float, default=1.5, help='extra warm-up AFTER simctl confirms recording started')
    p.add_argument('--tail', type=float, default=1.25, help='extra time after the tap completes')
    p.add_argument('--layers-pass', action='store_true', help='separate UI layer pass, not part of timing measurement')
    p.add_argument('--out', type=Path, default=Path('out'))
    p.add_argument('--zip', action='store_true')
    p.add_argument('--self-test', action='store_true')
    args = p.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not 1 <= args.trials <= 10 or not 0.4 <= args.preroll <= 5 or not 0.5 <= args.tail <= 5:
        p.error('trials must be 1..10, preroll 0.4..5 sec, tail 0.5..5 sec')
    exporter = S.build_native_extractor(args.out)
    devices = S.sim_devices()
    targets = [('ios26', S.resolve_sim(devices, 26, args.udid26), S.Driver(args.port26))]
    if args.compare:
        targets.append(('ios18', S.resolve_sim(devices, 18, args.udid18), S.Driver(args.port18)))
    root = args.out / f'stage190-player-menu-{dt.datetime.now():%Y%m%d-%H%M%S}'
    root.mkdir(parents=True, exist_ok=True)
    S.save_json(root/'configuration.json', {
        'cases':args.cases, 'trials':args.trials, 'preroll_seconds':args.preroll,
        'tail_seconds':args.tail, 'layers_pass':args.layers_pass,
        'targets':[{'label': label,'device':device,'port':driver.port} for label,device,driver in targets],
        'changed_app_renderer':False, 'host':sys.platform, 'began':S.clock()})
    reports = []
    for label,device,driver in targets:
        print(f'=== {label}: {device["runtime"]}, port {driver.port} ===',flush=True)
        try:
            S.save_json(root/label/'preflight.json', driver.call('state'))
            for case in args.cases:
                for trial in range(1, args.trials+1):
                    reports.append({'label':label,**take(driver,device,label,case,root,trial,
                                                        exporter,args.preroll,args.tail,args.layers_pass)})
        except Exception as exc:
            reports.append({'label':label,'status':'INCOMPLETE','error':repr(exc)})
    passed = all(item.get('status') == 'RECORDED_NOT_YET_MATCHED' for item in reports)
    S.save_json(root/'report.json', {
        'reports':reports, 'finished':S.clock(), 'ready_for_matching':passed,
        'native_popup_required_on_ios26':True, 'renderer_changed':False})
    print('REPORT:', (root/'report.json').resolve(), flush=True)
    if args.zip:
        archive=root.with_suffix('.zip')
        with ZipFile(archive,'w', ZIP_DEFLATED, compresslevel=4) as z:
            for file in root.rglob('*'):
                if file.is_file():
                    z.write(file,file.relative_to(root.parent))
        print('ARCHIVE:',archive.resolve(),flush=True)
    return 0 if passed else 2


if __name__ == '__main__':
    sys.exit(main())
