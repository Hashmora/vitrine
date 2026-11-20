#!/usr/bin/env python3
"""Stage 73 — unattended SG_DRIVER diagnostics for Legacy Glass (iOS 18).

Requires a Stage 73 SG_DRIVER build on 127.0.0.1:8087. Uses a single continuous
UITouch via /swipe.reverse to recreate mini-player up/down/hold without manual
interaction; uses /pref + /navbar.refresh to vary tab settings, then restores
both original preferences even on failure. /tab opens Search and finds Scannables.
Validates targeted UI states and actual gesture responses; an MP4 alone never
means a scenario passed. Does not change production UI or app data.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

MODULE = Path(__file__).with_name('stage72-legacy-navigation.py')
spec = importlib.util.spec_from_file_location('stage72_readonly_capture', MODULE)
if spec is None or spec.loader is None:
    raise RuntimeError('Stage 72 capture library not found alongside Stage 73')
stage72 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage72)

HIDE_LABELS = 'spotifyglass.redesign.navbar.hideLabels'
ACCENT = 'spotifyglass.redesign.tabbar.accent'


def suitable_point(v):
    f = v.get('frame') or []
    if len(f) != 4 or f[2] < 120 or f[3] < 30 or v.get('shown') is False:
        return None
    return (round(float(f[0]) + float(f[2]) * .30, 2),
            round(float(f[1]) + float(f[3]) / 2, 2))


class Collector(stage72.Collector):
    def __init__(self, args):
        super().__init__(args)
        self.root = self.repo / args.output / ('stage73-auto-legacy-navigation-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
        self.root.mkdir(parents=True, exist_ok=True)
        self.report['automation'] = 'SG_DRIVER only; zero manual prompts'
        self.saved_prefs = {}

    def call(self, tag, command, **kwargs):
        # /get reports nil for animationKeys when a layer is at rest. That is
        # an expected optional value, not an error in the captured UI state.
        if command == 'get' and kwargs.get('path') == 'layer.animationKeys':
            try:
                return self.driver.call(command, **kwargs)
            except RuntimeError as exc:
                if 'animationKeys is nil' in str(exc):
                    return {'ok': True, 'value': None,
                            'note': 'no active layer animations (expected at rest)'}
                raise
        return super().call(tag, command, **kwargs)

    def strict(self, what, cmd, **kw):
        response = self.driver.call(cmd, **kw)
        stage72.dump(self.root / 'commands' / (what + '.json'), {'command':cmd,'args':kw,'response':response})
        return response

    def save_prefs(self):
        for key in (HIDE_LABELS, ACCENT):
            self.saved_prefs[key] = self.strict('pref-original-'+key.split('.')[-1], 'pref', key=key).get('now')
        stage72.dump(self.root / 'repo-source/original-preferences.json', self.saved_prefs)

    def set_prefs(self, hide_labels, accent):
        for key, value in ((HIDE_LABELS, hide_labels), (ACCENT, accent)):
            self.driver.call('pref', key=key, value=(1 if value else 0))
        self.strict('navbar-refresh-'+str(hide_labels)+'-'+str(accent), 'navbar.refresh')
        time.sleep(.35)
        self.strict('settings-dismiss-'+str(hide_labels)+'-'+str(accent), 'settings.dismiss')
        self.strict('select-home-'+str(hide_labels)+'-'+str(accent), 'tab', arg='Home')
        self.strict('refresh-after-home-'+str(hide_labels)+'-'+str(accent), 'navbar.refresh')
        time.sleep(.65)
        state=self.strict('navbar-state-'+str(hide_labels)+'-'+str(accent),'state')
        if state.get('top') in ('SGRNavbarPage','SGModPage'):
            raise RuntimeError('Settings remained on screen after automatic dismissal')

    def restore_prefs(self):
        for key, val in self.saved_prefs.items():
            if val is None:
                self.driver.call('pref', key=key, remove=1)
            elif isinstance(val, bool) or isinstance(val, (int, float)):
                self.driver.call('pref', key=key, value=int(val))
            else:
                self.driver.call('pref', key=key, text=str(val))
        if self.saved_prefs:
            self.driver.call('navbar.refresh')
            time.sleep(.2)

    def reset_npv(self):
        state = self.strict('npv-preflight-state', 'state')
        if state.get('player'):
            self.strict('npv-close-before', 'player.close')
            time.sleep(.8)
        self.strict('npv-dismiss-settings', 'settings.dismiss')
        self.strict('npv-home', 'tab', arg='Home')
        time.sleep(.65)
        # This test is specifically for the *minimized* player between
        # compact tab circles. Never accept the full-width bar as baseline.
        self.strict('npv-expand-reset', 'navbar.minimize', on=0, animated=0)
        self.strict('npv-force-minimized', 'navbar.minimize', on=1, animated=0)
        time.sleep(.65)
        layout = self.strict('npv-minimized-baseline', 'navbar.mini-state')
        stage72.dump(self.root/'npv/minimized-baseline.json',layout)
        if not layout.get('legacy') or not layout.get('minimized'):
            raise RuntimeError('Cannot enter actual Legacy minimized tab bar: '+repr(layout))
        card=layout.get('cardFrame')
        slot=layout.get('inlineSlot')
        if not isinstance(card,list) or len(card)!=4 or card[2]<70 or card[3]<24:
            raise RuntimeError('Mini NPV is not visible at valid size: '+repr(layout))
        if not isinstance(slot,list) or len(slot)!=4:
            raise RuntimeError('Mini-player inline slot is absent: '+repr(layout))
        cx,cy=card[0]+card[2]/2,card[1]+card[3]/2
        if not(slot[0]-12<=cx<=slot[0]+slot[2]+12 and abs(cy-(slot[1]+slot[3]/2))<24):
            raise RuntimeError('Mini-player card is not docked in minimized row: '+repr(layout))
        rest=self.strict('npv-rest-state','state')
        if rest.get('player'):
            raise RuntimeError('Full NPV is already open before reverse gesture')
        return [cx,cy]

    def record_gesture(self, tag, hold):
        folder = self.root / tag
        folder.mkdir(parents=True, exist_ok=True)
        at = self.reset_npv()
        start = f'{at[0]:.2f},{at[1]:.2f}'
        via = f'{at[0]:.2f},{max(130, at[1]-145):.2f}'
        self.snapshot(tag+'/before',deep=False)
        movie = folder / 'motion.mp4'
        logf = (folder/'recording.log').open('w',encoding='utf-8')
        import signal
        proc = subprocess.Popen(['xcrun','simctl','io',self.args.udid,'recordVideo','--codec=h264','--force',str(movie)],
                                stdout=logf,stderr=subprocess.STDOUT)
        output = {}
        timeline = []
        try:
            deadline = time.monotonic()+12
            while time.monotonic()<deadline:
                logf.flush()
                if proc.poll() is not None:raise RuntimeError('video recorder died')
                if 'Recording started' in (folder/'recording.log').read_text(errors='replace'):break
                time.sleep(.1)
            else:raise RuntimeError('video recorder never started')
            began = time.monotonic()
            args={'from':start,'via':via,'to':start,'up':'.65','back':'.75','hold':str(3.0 if hold else 0.0)}
            def gesture():
                try:output['response']=self.driver.call('swipe.reverse',**args)
                except Exception as e:output['error']=repr(e)
            worker=threading.Thread(target=gesture,daemon=True)
            worker.start()
            # Sample while UITouch is down and during the settle after release.
            for index, sec in enumerate((.12,.37,.72,1.05,1.42,1.80,2.35,3.10,4.15,4.65,5.35)):
                time.sleep(max(0,began+sec-time.monotonic()))
                when=time.monotonic()-began
                target=f'{tag}/samples/frame{index:02d}-{int(sec*1000)}ms.png'
                self.screenshot(target)
                timeline.append({'requested_s':sec,'began_s':round(when,3),
                                 'ended_s':round(time.monotonic()-began,3),'file':target})
            worker.join(timeout=12)
            if worker.is_alive():raise RuntimeError('native reverse gesture stalled')
            if 'error' in output:raise RuntimeError(output['error'])
            if not output.get('response',{}).get('ok'):
                raise RuntimeError('gesture failed '+repr(output))
            actual_via=output['response'].get('via')
            intended_via=[float(n) for n in via.split(',')]
            if not isinstance(actual_via, list) or len(actual_via)!=2 or any(abs(a-b)>.11 for a,b in zip(actual_via,intended_via)):
                raise RuntimeError('driver did not confirm continuous reverse path')
            stage72.dump(folder/'gesture.json',{'arguments':args,**output})
            stage72.dump(folder/'sampling-timeline.json',timeline)
            time.sleep(.9)
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)
                try:proc.wait(timeout=15)
                except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
            logf.close()
        video = stage72.check_mp4(movie)
        stage72.dump(folder/'video-check.json',video)
        if not video['ok']:raise RuntimeError('invalid MP4 '+repr(video))
        after = self.snapshot(tag+'/after',deep=True)
        time.sleep(1.1)
        settled = self.snapshot(tag+'/settled',deep=True)
        mini=self.strict(tag.replace('/', '-')+'-final-mini-state', 'navbar.mini-state')
        stage72.dump(folder/'final-mini-state.json', mini)
        # A player left open or an expanded bar cannot prove a minimized-bar
        # defect. Keep the evidence, but do not label such runs CAPTURED.
        if settled.get('player') or not mini.get('minimized'):
            raise RuntimeError('reverse gesture did not return to minimized bar: '+repr(mini))
        return True

    def npv(self):
        good=True
        for name,held in (('reverse-and-hold',True),('reverse-quick',False)):
            try:self.record_gesture('npv/'+name,hold=held)
            except Exception as exc:
                good=False
                self.warn('npv/'+name+': '+repr(exc))
        return good

    def tabbar(self):
        states=(('labels-accent-on',False,True),('icons-only-accent-on',True,True),('icons-only-accent-off',True,False))
        for name,hide,accent in states:
            self.set_prefs(hide,accent)
            base='tabbar/'+name
            self.snapshot(base+'/rest',deep=True)
            found=self.driver.call('find',**{'class':'UITabBarButton'})
            buttons=[v for v in found.get('views',[]) if v.get('shown') and (v.get('frame') or [0,0,0,0])[1]>400]
            if len(buttons)<4:
                raise RuntimeError(name+' insufficient visible tab buttons '+repr(found)[:500])
            buttons.sort(key=lambda x:x['frame'][0])
            selected=buttons[0]['frame']
            at=f'{selected[0]+selected[2]/2:.1f},{selected[1]+selected[3]/2:.1f}'
            # A held finger is sampled while live, unlike the old after-tap snapshot.
            self.gesture_hold(base+'/held-selected',at)
        self.geometry()
        return True

    def gesture_hold(self,tag,at):
        folder=self.root/tag
        folder.mkdir(parents=True,exist_ok=True)
        logf=(folder/'recording.log').open('w',encoding='utf-8')
        import signal
        proc=subprocess.Popen(['xcrun','simctl','io',self.args.udid,'recordVideo','--codec=h264','--force',str(folder/'motion.mp4')],
                              stdout=logf,stderr=subprocess.STDOUT)
        out={}
        try:
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                logf.flush()
                if proc.poll() is not None:raise RuntimeError('recordVideo stopped')
                if 'Recording started' in (folder/'recording.log').read_text(errors='replace'):break
                time.sleep(.1)
            else:raise RuntimeError('recordVideo not ready')
            begin=time.monotonic()
            def work():
                try:out['response']=self.driver.call('longpress',at=at,duration='2.25')
                except Exception as e:out['error']=repr(e)
            worker=threading.Thread(target=work,daemon=True);worker.start()
            for index,sec in enumerate((.20,.52,1.03,1.65,2.00,2.48)):
                time.sleep(max(0,begin+sec-time.monotonic()))
                self.screenshot(f'{tag}/frame{index:02d}-{int(sec*1000)}ms.png')
            worker.join(timeout=12)
            if worker.is_alive() or 'error' in out or not out.get('response',{}).get('ok'):
                raise RuntimeError('held tab gesture failed '+repr(out))
            stage72.dump(folder/'gesture.json',{'at':at,**out})
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)
                try:proc.wait(timeout=15)
                except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
            logf.close()
        chk=stage72.check_mp4(folder/'motion.mp4')
        stage72.dump(folder/'video-check.json',chk)
        if not chk['ok']:raise RuntimeError('tabbar video invalid')

    def codes(self):
        if self.driver.call('state').get('player'):
            self.driver.call('player.close');time.sleep(.55)
        self.strict('codes-dismiss-settings','settings.dismiss')
        self.strict('codes-select-search','tab',arg='Search')
        time.sleep(1.0)
        state=self.snapshot('codes/search',deep=True)
        found=self.strict('codes-search-button','find',id='SearchToolBar.AccessoryItem.ScannablesButton')
        if 'Browse' not in str(state.get('top','')):
            raise RuntimeError('Not on Browse Search page: '+str(state.get('top')))
        if not found.get('views'):
            raise RuntimeError('Scannables button absent, cannot classify hidden vs removed')
        stage72.dump(self.root/'codes/search-analysis.json',{'native':False,'top':state['top'],
                     'original_button':found['views'], 'hidden':not any(v.get('shown') for v in found['views'])})
        return True

    def finish(self):
        self.report['finished']=datetime.now().isoformat(timespec='seconds')
        wanted=list(self.args.scenarios)
        self.report['status']='EVIDENCE_CAPTURED' if all(self.report['scenarios'].get(s)=='CAPTURED' for s in wanted) else 'INCOMPLETE'
        stage72.dump(self.root/'summary.json',self.report)
        archive=self.root.with_suffix('.zip')
        with stage72.zipfile.ZipFile(archive,'w',compression=stage72.zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for f in self.root.rglob('*'):
                if f.is_file(): z.write(f,str(f.relative_to(self.root.parent)))
        print('\nSTATUS:',self.report['status'],'\nEvidence ZIP:',archive)
        return self.report['status']=='EVIDENCE_CAPTURED'


def self_test():
    assert suitable_point({'shown':True,'frame':[10,700,280,56]}) == (94.0,728.0)
    assert suitable_point({'shown':False,'frame':[10,700,280,56]}) is None
    assert suitable_point({'shown':True,'frame':[10,700,0,0]}) is None
    assert HIDE_LABELS != ACCENT
    class NilAnimationDriver:
        def call(self, command, **kwargs):
            raise RuntimeError("get: {'error': 'animationKeys is nil', 'ok': False}")
    test_capture = Collector.__new__(Collector)
    test_capture.driver = NilAnimationDriver()
    optional = test_capture.call('rest', 'get', **{'class': 'SGRLegacyTabBar', 'path': 'layer.animationKeys'})
    assert optional['ok'] and optional['value'] is None
    driver_source = Path(__file__).resolve().parents[2] / 'tweak/Sources/Diagnostics/Driver.m'
    if driver_source.is_file():
        source = driver_source.read_text(encoding='utf-8')
        assert 'legacyGlassTabItems(titles)' in source
        assert '@"navbar.minimize"' in source
        assert '@"navbar.mini-state"' in source
        assert 'UITabBarButton' in source
        assert 'Legacy tab bar is visible but has' in source
    print('SELF-TEST: OK')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo',default='.')
    p.add_argument('--output',default='out')
    p.add_argument('--udid',default=stage72.UDID)
    p.add_argument('--port',type=int,default=8087)
    p.add_argument('--scenarios',nargs='+',choices=('npv','tabbar','codes'),default=['npv','tabbar','codes'])
    p.add_argument('--self-test',action='store_true')
    args=p.parse_args()
    if args.self_test:
        self_test();return 0
    c=Collector(args)
    try:
        c.strict('preflight','state')
        c.sources()
        c.save_prefs()
        for scenario in args.scenarios:
            try:
                ok=getattr(c,scenario)()
                c.report['scenarios'][scenario]='CAPTURED' if ok else 'INCOMPLETE'
            except Exception as e:
                c.warn(scenario+': '+repr(e))
                c.report['scenarios'][scenario]='INCOMPLETE'
    except Exception as e:
        c.warn('preflight: '+repr(e))
    finally:
        try:c.restore_prefs()
        except Exception as e:c.warn('restore preferences: '+repr(e));c.report['scenarios']['preferences']='INCOMPLETE'
    return 0 if c.finish() else 2

if __name__=='__main__':sys.exit(main())
