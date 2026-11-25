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
import re
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('stage197_compact', HERE/'stage192-legacy-player-morph-capture.py')
G = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = G
spec.loader.exec_module(G)
N, S = G.N, G.S
CASES = ('root-open', 'root-close', 'more-open', 'more-close',
         'root-drag-x', 'root-drag-y', 'more-drag-x', 'more-drag-y', 'root-flash', 'speed-open', 'speed-close',
         'more-back', 'more-flash', 'more-scroll-up', 'more-hold-scroll-up', 'home-open', 'home-close', 'home-drag-x', 'home-drag-y', 'home-flash')
SPEED = 'Speed, Pitch & Reverb'


def front_frame(observed, label):
    views = observed['legacy' if label == 'ios18' else 'native']
    frames = [v['frame'] for v in views if isinstance(v.get('frame'), list) and len(v['frame']) == 4]
    if not frames:
        raise S.EvidenceError('no visible menu frame')
    # More is lower and normally larger; ignore the exposed strip of the root.
    return max(frames, key=lambda f: (f[1], f[2]*f[3]))


def hosted_views(driver):
    return G.shown(driver, **{'class':'SGSpeedPitchView'})



def verified(driver, label, menu, timeout=8, more=False, hosted=False, root_frame=None, player=True):
    deadline = time.monotonic() + timeout
    while True:
        state = driver.call('state')
        legacy = G.shown(driver, **{'class':'SGRDropdownPanel'})
        native = G.shown(driver, **{'class':'_UIContextMenuView'})
        back = G.shown(driver, id='Vitrine.Dropdown.Back')
        speed = hosted_views(driver) if hosted else []
        expected = (bool(legacy) == ((menu or hosted) and label == 'ios18') and
                    bool(native) == (menu and label == 'ios26'))
        observed = {'state':state, 'legacy':legacy, 'native':native, 'back':back, 'speed':speed}
        more_ok = bool(back) == more if label == 'ios18' else True
        if label == 'ios26' and more and native and root_frame:
            # Native exposes no Vitrine back identifier. A distinct visible
            # panel geometry after selecting More is a necessary proxy.
            more_ok = front_frame(observed,label) != root_frame
        state_menu = (menu or hosted) if label == 'ios18' else menu
        if bool(state.get('player')) == player and bool(state.get('menu')) == state_menu and expected and more_ok and (not hosted or speed):
            return observed
        if time.monotonic() >= deadline:
            raise S.EvidenceError(f'{label}: expected menu={menu}, more={more}, hosted={hosted}; observed={observed}')
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
            elif hosted_views(driver):
                driver.call('tap',at='7,360')
                time.sleep(.6)
            if case.startswith('home-'):
                if driver.call('state').get('player'):
                    driver.call('player.close')
                    time.sleep(.6)
                driver.call('tab',arg='0')
                time.sleep(.5)
                closed = verified(driver,label,False,player=False)
                if case == 'home-open': return closed
                driver.call('tap',label='Filter Home')
                verified(driver,label,True,player=False)
                time.sleep(1)
                return verified(driver,label,True,player=False)
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
            if case == 'root-open':
                return closed
            driver.call('player.more')
            root = verified(driver, label, True, timeout=5)
            time.sleep(1.2)
            root = verified(driver,label,True)
            if case in ('more-close','more-back','more-drag-x','more-drag-y','more-flash','more-scroll-up','more-hold-scroll-up'):
                frame = front_frame(root,label)
                driver.call('menu.pick',title='More')
                verified(driver,label,True,more=True,root_frame=frame)
                time.sleep(1.0)
                result = verified(driver,label,True,more=True,root_frame=frame)
                result['root_frame'] = frame
                return result
            if case == 'speed-close':
                driver.call('menu.pick',title=SPEED)
                verified(driver,label,False,hosted=True)
                time.sleep(1.0)
                return verified(driver,label,False,hosted=True)
            return root
        except S.EvidenceError as exc:
            last = str(exc)
            time.sleep(.5)
    raise S.EvidenceError(f'{label}: preparation failed: {last}')


def recorded_event(driver, label, case, before):
    if case == 'more-back':
        if label == 'ios18': return driver.call('tap',id='Vitrine.Dropdown.Back')
        x,y,w,h = front_frame(before,label)
        # The native More header has its back chevron at the left.
        # Verify actual return geometry, rather than claiming a successful back on any tap.
        return driver.call('tap',at=f'{round(x+28)},{round(y+42)}')
    if case == 'speed-open':
        return driver.call('menu.pick',title=SPEED)
    if case == 'speed-close':
        return driver.call('tap',at='7,360')
    if case in ('more-scroll-up','more-hold-scroll-up'):
        x,y,w,h = front_frame(before,label)
        start = f'{round(x+w*.5)},{round(y+h*.76)}'
        end = f'{round(x+w*.5)},{round(y+h*.30)}'
        if case == 'more-hold-scroll-up':
            # Same uninterrupted UITouch: first leg stays at one point for
            # 650ms, then moves through the content. No driver rebuild.
            return driver.call('swipe.reverse', **{'from':start,'via':start,'to':end,
                                'up':.65,'back':.55,'hold':.15})
        return driver.call('swipe', **{'from':start,'to':end,'duration':.55,'hold':.15,'drag':1})
    if case.endswith(('-drag-x','-drag-y')) or case.endswith('-flash'):
        x,y,w,h = front_frame(before,label)
        # Start on the rim, not a row centre. Hold the stretched state and
        # lift there, so the spring return is observable in the capture.
        if case.endswith('-drag-x'):
            start = (x+5, y+h/2)
            via = (max(8,start[0]-95),start[1])
        else:
            start = (x+w/2, y+h-4)
            via = (start[0],start[1]+95)
        point = lambda p: f'{round(p[0])},{round(p[1])}'
        if case.endswith('-flash'):
            # Top rim avoids the actionable bottom row on native More/Home.
            return driver.call('longpress',at=point((x+w/2,y+3)),duration=.85)
        return driver.call('swipe',**{'from':point(start),'to':point(via),
            'duration':.55,'hold':.45,'drag':1})
    return S.event(driver,case)


def verify_after(driver,label,case,before):
    if case in ('root-close','more-close','speed-close','home-close'):
        result = verified(driver,label,False,player=not case.startswith('home-'))
        if case == 'speed-close' and hosted_views(driver):
            raise S.EvidenceError('Speed panel still visible after close')
        return result
    if case == 'speed-open':
        return verified(driver,label,False,hosted=True)
    if case == 'more-back':
        result = verified(driver,label,True)
        if any(abs(a-b)>2 for a,b in zip(front_frame(result,label),before['root_frame'])):
            raise S.EvidenceError('More back did not restore root geometry')
        return result
    more = case == 'more-open' or case.startswith('more-drag-') or case in ('more-flash','more-scroll-up','more-hold-scroll-up')
    result = verified(driver,label,True,more=more,
        root_frame=front_frame(before,label) if case == 'more-open' else before.get('root_frame'),
        player=not case.startswith('home-'))
    if case.endswith(('-drag-x','-drag-y')) or case.endswith('-flash') or case in ('more-scroll-up','more-hold-scroll-up'):
        prior, current = front_frame(before,label),front_frame(result,label)
        if any(abs(a-b)>2 for a,b in zip(prior,current)):
            raise S.EvidenceError(f'surface did not return to prior geometry: {prior} -> {current}')
    return result


def take(driver, device, label, case, root, trial, exporter, args):
    dest = root/label/case/f'trial-{trial:02d}'
    dest.mkdir(parents=True, exist_ok=True)
    report = {'label':label,'case':case,'trial':trial,'device':device,'port':driver.port,
              'status':'INCOMPLETE','began':S.clock()}
    try:
        report['before_verified'] = prepare(driver, label, case)
        S.collect_snapshot(driver, dest/'before')
        report['recording'] = N.capture(device['udid'], dest/'capture.mp4',
                                        lambda: recorded_event(driver,label,case,report['before_verified']), args.preroll, args.tail)
        if report['recording'].get('action_error'):
            raise S.EvidenceError(report['recording']['action_error'])
        S.run(['xcrun','simctl','io',device['udid'],'screenshot',dest/'settled-compositor.png'],timeout=20)
        S.collect_snapshot(driver, dest/'after')
        # Read the existing SG_DRIVER ring after capture, not during it.
        # Stage 199 logs one aggregate per root morph; native already logs
        # its menu lifecycle. A missing line is not evidence of completion.
        try:
            since = report['before_verified']['state'].get('logSeq', 0)
            lines = driver.call('log', since=since).get('lines', [])
            lifecycle = [line for line in lines if any(tag in line.get('text', '') for tag in ('stage199 player root:', 'stage200 player root:', 'stage201 player root:', 'stage202 player root:', 'stage203 player root:', 'stage204 player ', 'stage205 popup ', 'stage206 popup ', 'stage207 popup ', 'stage208 popup ', 'stage209 popup '))
                         or 'system menu:' in line.get('text', '')]
            S.save_json(dest/'morph-lifecycle.json', {'since':since,'lines':lifecycle})
            report['morph_lifecycle_lines'] = len(lifecycle)
            if label == 'ios18' and case in ('more-scroll-up','more-hold-scroll-up'):
                report['legacy_scroll_evidence'] = scroll_evidence(lifecycle)
        except Exception as exc:
            report['morph_lifecycle_error'] = repr(exc)
        try:
            report['video'] = G.metadata_only(dest/'capture.mp4', dest/'frames', exporter)
        except Exception as exc:
            report['metadata_error'] = repr(exc)
        report['after_verified'] = verify_after(driver,label,case,report['before_verified'])
        if label == 'ios18' and case in ('more-scroll-up','more-hold-scroll-up'):
            if not report.get('legacy_scroll_evidence',{}).get('advanced'):
                raise S.EvidenceError('Legacy scroll not confirmed by offset telemetry (menu may fit without scrolling)')
        before, after = (track(report[k]['state']) for k in ('before_verified','after_verified'))
        report['track_stable'] = bool(before.get('uri')) and before.get('uri') == after.get('uri') and bool(after.get('paused'))
        report['track_uri'] = before.get('uri')
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


def scroll_evidence(lines):
    starts, ends = [], []
    for line in lines:
        m = re.search(r'stage209 popup scroll: (begin|end|settled) offset=(-?\d+(?:\.\d+)?)', line.get('text',''))
        if m and 'submenu=1' in line.get('text',''):
            (starts if m[1] == 'begin' else ends).append(float(m[2]))
    return {'start_offsets':starts,'end_offsets':ends,
            'advanced':bool(starts and ends and max(ends)-starts[0]>2)}


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
    class GestureDriver:
        def call(self,command,**kw): return (command,kw)
    before = {'legacy':[{'frame':[140,62,250,315]}], 'native':[]}
    command, gesture = recorded_event(GestureDriver(),'ios18','root-drag-x',before)
    assert command == 'swipe' and gesture['from'] != gesture['to'] and gesture['hold'] > 0
    assert recorded_event(GestureDriver(),'ios18','speed-open',before) == ('menu.pick',{'title':SPEED})
    assert recorded_event(GestureDriver(),'ios18','root-flash',before)[1]['duration'] >= .8
    assert recorded_event(GestureDriver(),'ios18','more-back',before) == ('tap',{'id':'Vitrine.Dropdown.Back'})
    assert recorded_event(GestureDriver(),'ios26','more-back',dict(before,native=before['legacy']))[0] == 'tap'
    command, gesture = recorded_event(GestureDriver(),'ios18','more-hold-scroll-up',before)
    assert command == 'swipe.reverse' and gesture['from']==gesture['via'] and gesture['to']!=gesture['from'] and gesture['up']>=.6
    assert recorded_event(GestureDriver(),'ios18','more-scroll-up',before)[0]=='swipe'
    assert scroll_evidence([{'text':'stage209 popup scroll: begin offset=0.00 max=42.00 submenu=1'},
                            {'text':'stage209 popup scroll: end offset=42.00 decelerate=0 submenu=1'}])['advanced']
    assert not scroll_evidence([{'text':'stage209 popup scroll: begin offset=0.00 max=0.00 submenu=1'},
                                {'text':'stage209 popup scroll: end offset=0.00 decelerate=0 submenu=1'}])['advanced']
    print('PASS paired report, strict renderer check, held-scroll routing, offset evidence and metadata gating')


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
    root = args.out/f'stage209-popup-lifecycle-{dt.datetime.now():%Y%m%d-%H%M%S}'
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
        'note':'Drag/flash video is evidence, not proof of visual similarity. Same URI is an artwork candidate, not proof of equal artwork or layout; compare video visually. No automated visual-match claim.'})
    G.compact_archives(root)
    return 0 if complete else 2


if __name__ == '__main__':
    sys.exit(main())
