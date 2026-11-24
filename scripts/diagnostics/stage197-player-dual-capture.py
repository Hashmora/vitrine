#!/usr/bin/env python3
"""Stage 197: paired native iOS26 / Legacy iOS18 player root-menu evidence.
Uses existing SG_DRIVER, simctl and AVFoundation. No renderer changes or installs.
"""
from __future__ import annotations
import argparse
import datetime as dt
import importlib.util
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('stage197_compact', HERE/'stage192-legacy-player-morph-capture.py')
G = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = G
spec.loader.exec_module(G)
N, S = G.N, G.S
CASES = ('root-open', 'root-close')


def verified(driver, label, menu, timeout=8):
    deadline = time.monotonic() + timeout
    while True:
        state = driver.call('state')
        legacy = G.shown(driver, **{'class':'SGRDropdownPanel'})
        native = G.shown(driver, **{'class':'_UIContextMenuView'})
        back = G.shown(driver, id='Vitrine.Dropdown.Back')
        expected = (bool(legacy) == (menu and label == 'ios18') and
                    bool(native) == (menu and label == 'ios26'))
        observed = {'state':state, 'legacy':legacy, 'native':native, 'back':back}
        if state.get('player') and bool(state.get('menu')) == menu and expected and not back:
            return observed
        if time.monotonic() >= deadline:
            raise S.EvidenceError(f'{label}: expected root menu={menu}; observed={observed}')
        time.sleep(.15)


def track(state):
    return state.get('nowPlaying') or {}


def prepare(driver, label, case):
    deadline = time.monotonic() + 35
    last = None
    while time.monotonic() < deadline:
        try:
            state = driver.call('state')
            if state.get('menu'):
                S.safe_external_tap(driver)
            if not driver.call('state').get('player'):
                driver.call('player.open')
                time.sleep(.6)
            closed = verified(driver, label, False, timeout=3)
            # Avoid progress-bar changes and track transitions during recording.
            now = track(closed['state'])
            if not now.get('uri'):
                raise S.EvidenceError('no loaded track URI')
            if not now.get('paused'):
                driver.call('pause')
                time.sleep(.4)
            closed = verified(driver, label, False, timeout=3)
            if not track(closed['state']).get('paused'):
                raise S.EvidenceError('playback did not pause')
            if case == 'root-close':
                driver.call('player.more')
                verified(driver, label, True, timeout=5)
                time.sleep(.8)
            return verified(driver, label, case == 'root-close')
        except S.EvidenceError as exc:
            last = str(exc)
            time.sleep(.5)
    raise S.EvidenceError(f'{label}: preparation failed: {last}')


def take(driver, device, label, case, root, trial, exporter, args):
    dest = root/label/case/f'trial-{trial:02d}'
    dest.mkdir(parents=True, exist_ok=True)
    report = {'label':label,'case':case,'trial':trial,'device':device,'port':driver.port,
              'status':'INCOMPLETE','began':S.clock()}
    try:
        report['before_verified'] = prepare(driver, label, case)
        S.collect_snapshot(driver, dest/'before')
        report['recording'] = N.capture(device['udid'], dest/'capture.mp4',
                                        lambda: S.event(driver, case), args.preroll, args.tail)
        if report['recording'].get('action_error'):
            raise S.EvidenceError(report['recording']['action_error'])
        S.run(['xcrun','simctl','io',device['udid'],'screenshot',dest/'settled-compositor.png'],timeout=20)
        report['after_verified'] = verified(driver,label,case == 'root-open')
        S.collect_snapshot(driver, dest/'after')
        # Read the existing SG_DRIVER ring after capture, not during it.
        # Stage 199 logs one aggregate per root morph; native already logs
        # its menu lifecycle. A missing line is not evidence of completion.
        try:
            since = report['before_verified']['state'].get('logSeq', 0)
            lines = driver.call('log', since=since).get('lines', [])
            lifecycle = [line for line in lines if any(tag in line.get('text', '') for tag in ('stage199 player root:', 'stage200 player root:'))
                         or 'system menu:' in line.get('text', '')]
            S.save_json(dest/'morph-lifecycle.json', {'since':since,'lines':lifecycle})
            report['morph_lifecycle_lines'] = len(lifecycle)
        except Exception as exc:
            report['morph_lifecycle_error'] = repr(exc)
        before, after = (track(report[k]['state']) for k in ('before_verified','after_verified'))
        report['track_stable'] = bool(before.get('uri')) and before.get('uri') == after.get('uri') and bool(after.get('paused'))
        report['track_uri'] = before.get('uri')
        try:
            report['video'] = G.metadata_only(dest/'capture.mp4', dest/'frames', exporter)
        except Exception as exc:
            report['metadata_error'] = repr(exc)
        report['status'] = 'RECORDED_NOT_YET_MATCHED'
    except Exception as exc:
        report['error'] = repr(exc)
        try:
            S.collect_snapshot(driver, dest/'failure')
        except Exception as nested:
            report['failure_snapshot_error'] = repr(nested)
    report['finished'] = S.clock()
    S.save_json(dest/'report.json',report)
    print(f'{label}/{case}/{trial:02}: {report["status"]} {report.get("error", "")[:200]}',flush=True)
    return report


def pair_summary(left, right):
    complete = all(r.get('status') == 'RECORDED_NOT_YET_MATCHED' for r in (left,right))
    same = bool(left.get('track_uri')) and left.get('track_uri') == right.get('track_uri')
    stable = all(r.get('track_stable') for r in (left,right))
    pts = all(bool(r.get('video')) for r in (left,right))
    return {'case':left['case'],'trial':left['trial'],'both_recorded':complete,
            'same_track':same,'both_tracks_stable':stable,'both_pts_available':pts,
            'comparable_geometry':complete and pts,
            'same_artwork_candidate':complete and same and stable and pts,
            'tracks':{r['label']:r.get('track_uri') for r in (left,right)}}


def self_test():
    G.self_test()
    a = {'label':'ios26','case':'root-open','trial':1,'status':'RECORDED_NOT_YET_MATCHED',
         'track_uri':'x','track_stable':True,'video':{'decoded_frames':12}}
    b = dict(a,label='ios18')
    assert pair_summary(a,b)['same_artwork_candidate']
    assert not pair_summary(a,dict(b,track_uri='y'))['same_artwork_candidate']
    assert pair_summary(a,dict(b,track_uri='y'))['comparable_geometry']
    assert not pair_summary(a,dict(b,video=None))['comparable_geometry']
    assert not pair_summary(a,dict(b,status='INCOMPLETE'))['both_recorded']
    class FakeDriver:
        def __init__(self,label,menu): self.label,self.menu = label,menu
        def call(self,command,**kw):
            if command=='state': return {'player':True,'menu':self.menu}
            wanted = 'SGRDropdownPanel' if self.label=='ios18' else '_UIContextMenuView'
            return {'views':[{'shown':True}] if self.menu and kw.get('class')==wanted else []}
    for label in ('ios26','ios18'):
        for menu in (False,True): verified(FakeDriver(label,menu),label,menu,timeout=0)
    try: verified(FakeDriver('ios18',True),'ios26',True,timeout=0)
    except S.EvidenceError: pass
    else: raise AssertionError('accepted wrong renderer')
    print('PASS paired report, strict renderer check and metadata gating')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port26',type=int,default=8088)
    p.add_argument('--port18',type=int,default=8087)
    p.add_argument('--udid26',default='B8E2A0A5-3BE4-4B47-BBAE-095D64219EBA')
    p.add_argument('--udid18',default=S.DEFAULT_18)
    p.add_argument('--cases',choices=CASES,nargs='+',default=['root-open'])
    p.add_argument('--trials',type=int,default=3)
    p.add_argument('--preroll',type=float,default=1.5)
    p.add_argument('--tail',type=float,default=2.0)
    p.add_argument('--out',type=Path,default=Path('out'))
    p.add_argument('--self-test',action='store_true')
    args = p.parse_args()
    if args.self_test: self_test(); return 0
    if args.port26 == args.port18 or not 1<=args.trials<=5 or not .4<=args.preroll<=5 or not 1<=args.tail<=5:
        p.error('distinct ports, trials 1..5, preroll .4..5, tail 1..5')
    devices = S.sim_devices()
    targets = [('ios26',S.resolve_sim(devices,26,args.udid26),S.Driver(args.port26)),
               ('ios18',S.resolve_sim(devices,18,args.udid18),S.Driver(args.port18))]
    root = args.out/f'stage197-player-dual-{dt.datetime.now():%Y%m%d-%H%M%S}'
    root.mkdir(parents=True,exist_ok=False)
    exporter = S.build_native_extractor(args.out)
    S.save_json(root/'configuration.json',{'targets':[{'label':l,'device':d,'port':v.port} for l,d,v in targets],
        'cases':args.cases,'trials':args.trials,'preroll':args.preroll,'tail':args.tail,
        'git_head':S.run(['git','rev-parse','HEAD'])['stdout'].strip(),
        'note':'Checkout identity is not installed binary identity. Captures sequential, playback paused; no track switching. PTS video-relative, not driver clock.'})
    reports, pairs = [], []
    for case in args.cases:
        for trial in range(1,args.trials+1):
            pair = [take(driver,device,label,case,root,trial,exporter,args) for label,device,driver in targets]
            reports.extend(pair)
            pairs.append(pair_summary(*pair))
            S.save_json(root/'report.json',{'reports':reports,'pairs':pairs,'finished':S.clock()})
    complete = all(p['comparable_geometry'] for p in pairs)
    S.save_json(root/'report.json',{'reports':reports,'pairs':pairs,'complete':complete,'finished':S.clock(),
        'note':'Same URI is an artwork candidate, not proof of equal artwork or layout; compare video visually. No automated visual-match claim.'})
    G.compact_archives(root)
    return 0 if complete else 2


if __name__ == '__main__':
    sys.exit(main())
