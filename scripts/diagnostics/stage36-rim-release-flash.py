#!/usr/bin/env python3
"""Stage 36 — targeted rim-placement and landing-to-platter release diagnostic.

Read-only comparison of native iOS 26 vs the installed Legacy iOS 18:
(1) determine whether the brightest curved rim occupies the upper LEFT and
lower RIGHT shoulders, rather than predominantly the top and bottom rails;
(2) identify the time between arrival/settle on the selected tab and the
immediate change from a glass lens to the light selected-tab platter.
H.264 recordings, timestamped screenshots, and an optional per-video
luminance spike audit of glass-to-platter transitions are evidence, not
proof of visual correctness. The output is NEVER labelled PASSED without
subsequent interpretation of both clips. Detect potentially stale binaries.
Does not install, build or change source code.

Both simulators must have their SG_DRIVER running (ports 8086 and 8087).
Screen changes are prompted. Mandatory videos are validated; incomplete data
are always marked INCOMPLETE, never PASSED.
"""
import argparse
import json
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

DEFAULT_UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
TABS = ('Home', 'Search', 'Your Library', 'Create')
LABELS = ('Plain checkmark', 'Full bleed covers', 'Legacy Liquid Glass')
NUM = r'-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?'
FRAME = re.compile(r'^\s*(\S+)\s+\{\{\s*('+NUM+r')\s*,\s*('+NUM+r')\s*\},\s*\{\s*('+NUM+r')\s*,\s*('+NUM+r')\s*\}\}')
FOCUS = re.compile(r'Glass|Lens|Platter|TabBar|TabButton|Accent|SelectedContent|ContentView|Backdrop|SDF|Portal|Capsule|Glare|Rim|Thumb|Switch|UIImage|UILabel|Refraction|MiniPlayer|SGRLegacyCircle|Mask|Shadow|Glow', re.I)

class MissingEvidence(Exception):
    pass


def save_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, default=str)+'\n', encoding='utf-8')


def save_text(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding='utf-8')


def cmd_capture(argv, timeout=20):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return {'argv': argv, 'exit': p.returncode, 'stdout': p.stdout[-20000:], 'stderr': p.stderr[-20000:]}
    except Exception as exc:
        return {'argv': argv, 'exit': -1, 'error': repr(exc)}


def parse_nodes(tree):
    stack, nodes = [], []
    for line in tree.splitlines():
        m = FRAME.match(line)
        if not m:
            continue
        x, y, w, h = map(float, m.groups()[1:])
        indent = len(line) - len(line.lstrip(' '))
        while stack and stack[-1]['indent'] >= indent:
            stack.pop()
        parent = stack[-1] if stack else None
        node = {'name': m.group(1), 'raw': line.strip(), 'indent': indent,
                'frame': [x,y,w,h], 'parent': parent}
        nodes.append(node)
        stack.append(node)
    return nodes


def ancestor(node, condition):
    p = node.get('parent')
    while p:
        if condition(p):
            return p
        p = p.get('parent')
    return None


def match_switch(tree, found, label, expected_on=None):
    """Strict screen coordinates from /find UISwitch, NEVER summing tree frames.

    The old Stage 27 bug hit Accent color preset because it computed (319,178)
    rather than the actual (331,278) for Plain checkmark.
    """
    nodes = parse_nodes(tree)
    entries = []
    for name in LABELS:
        labels = [n for n in nodes if n['name'] in ('UILabel', 'SPTEncoreLabel')
                  and ('"'+name+'"') in n['raw']]
        if not labels:
            continue
        row = ancestor(labels[0], lambda p: p['name']=='UITableViewCell')
        if not row:
            continue
        if any(n['name']=='UISwitch' and ancestor(n, lambda p: p is row) for n in nodes):

            position=0.0
            parent=row
            while parent:
                position+=parent['frame'][1]
                parent=parent['parent']
            entries.append((position, name, labels[0]['raw']))
    entries.sort(key=lambda v:v[0])
    views = found.get('views', []) if isinstance(found, dict) else []
    visible = [v for v in views if v.get('shown') is not False and
               isinstance(v.get('frame'), list) and len(v['frame'])==4 and
               v['frame'][2]>=30 and v['frame'][3]>=18]
    # The tree traverses rows in visual order, whereas driver /find can return
    # switches in reverse object-registration order.
    visible.sort(key=lambda v:v['frame'][1])
    if label not in [r[1] for r in entries] or len(entries)!=len(visible):
        raise MissingEvidence(f'Switch row mismatch for {label}: tree={[r[1] for r in entries]}, '
                              f'live={[(v.get("frame"),v.get("on")) for v in visible]}')
    entry_idx = [r[1] for r in entries].index(label)
    sw = visible[entry_idx]
    if expected_on is None:
        expected_on = label=='Full bleed covers'
    if bool(sw.get('on'))!=expected_on:
        raise MissingEvidence(f'{label} must be {"ON" if expected_on else "OFF"}; '
                              f'/find UISwitch reports {sw.get("on")}')
    x,y,w,h = map(float, sw['frame'])
    # iOS 18 standard 51x31 toggle; thumb lies to left when OFF, right when ON.
    px = x+(w-20.5 if expected_on else 20.5)
    py = y+h/2
    if not(x+7<=px<=x+w-7 and y<=py<=y+h):
        raise MissingEvidence('Computed switch point outside actual /find frame')
    return {'label': label, 'expected_on': expected_on, 'screen_frame': [x,y,w,h],
            'point':[round(px,2),round(py,2)], 'driver_index':sw.get('index'),
            'source':'/find UISwitch frame (screen coordinates)',
            'tree_row':entries[entry_idx][2], 'all_live_switches':visible}


def tab_centers(found):
    views = found.get('views', []) if isinstance(found,dict) else []
    live = [v for v in views if v.get('shown') is not False and
            isinstance(v.get('frame'),list) and len(v['frame'])==4 and
            v['frame'][2]>35 and v['frame'][3]>35 and v['frame'][1]>400]
    live.sort(key=lambda v:v['frame'][0])
    dedup=[]
    for v in live:
        if not dedup or abs(v['frame'][0]-dedup[-1]['frame'][0])>2:
            dedup.append(v)
    if len(dedup)!=4:
        raise MissingEvidence(f'Expected four live tab buttons; got {len(dedup)}: {live}')
    ycenters = [v['frame'][1]+v['frame'][3]/2 for v in dedup]
    if max(ycenters)-min(ycenters)>10:
        raise MissingEvidence('Tab buttons do not share same vertical baseline')
    return {name:[round(v['frame'][0]+v['frame'][2]/2,2),
                  round(v['frame'][1]+v['frame'][3]/2,2)]
            for name,v in zip(TABS,dedup)}


class Driver:
    def __init__(self, port):
        self.url = f'http://127.0.0.1:{port}'

    def call(self, cmd, **kwargs):
        url = self.url+'/'+urllib.parse.quote(cmd)
        if kwargs:
            url += '?' + urllib.parse.urlencode(
                {k:str(v) for k,v in kwargs.items()},
                quote_via=urllib.parse.quote, safe='')
        req = urllib.request.Request(url, headers={'X-Phone-Driver':'1'})
        try:
            with urllib.request.urlopen(req, timeout=35) as resp:
                raw=resp.read().decode('utf-8','replace')
        except urllib.error.HTTPError as exc:
            raw=exc.read().decode('utf-8','replace')
        if cmd=='tree':
            return raw
        return json.loads(raw)


class Collector:
    def __init__(self, root, port, udid):
        self.root=Path(root)
        self.driver=Driver(port)
        self.udid=udid
        self.port=port
        self.videos=[]
        self.warnings=[]
        self.must=[]
        self.ok=[]
        self.recorder=None
        self.recorder_log=None
        self.recorder_path=None
        self.t0=time.monotonic()

    def call(self, tag, cmd, optional=False, **kwargs):
        try:
            data=self.driver.call(cmd, **kwargs)
            if isinstance(data,dict) and data.get('ok') is False:
                if not optional:
                    raise MissingEvidence(f'{tag} {cmd} failed: {data.get("error",data)}')
                self.warnings.append(f'{tag}: optional {cmd} returned {data.get("error",data)}')
            return data
        except Exception as exc:
            if not optional:
                raise
            self.warnings.append(f'{tag}: optional {cmd}: {exc!r}')
            return {'ok':False,'error':repr(exc)}

    def snapshot(self, tag, heavy=False):
        folder=self.root/tag
        print('  snapshot:', tag, flush=True)
        tree=self.call(tag,'tree')
        save_text(folder/'tree.txt',tree)
        save_text(folder/'optical-lines.txt', '\n'.join(
            f'{i+1:5}: {s}' for i,s in enumerate(tree.splitlines()) if FOCUS.search(s))+'\n')
        self.screenshot(folder/'screen.png',required=True)
        save_json(folder/'state.json',self.call(tag,'state'))
        if heavy:
            self.deep(tag)

    def screenshot(self, path, required=False):
        path=Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        result=cmd_capture(['xcrun','simctl','io',self.udid,'screenshot','--type=png',str(path)], timeout=30)
        if result.get('exit')!=0 or not path.is_file() or path.stat().st_size<2000:
            if required:
                raise MissingEvidence(f'simctl screenshot failed: {result}')
            self.warnings.append(f'screenshot failed: {result}')
        return result

    def deep(self, tag):
        """Read-only layer ancestry, zPosition, filters, masks & parent ownership."""
        out=self.root/tag/'deep'
        if tag.startswith('switches/'):
            cls_list=('SGGlassThumbView','SGGlassSwitchView',
                      'SGLegacyGlassView','UISwitch')
        else:
            cls_list=('SGRLegacyLens','SGRLegacyTabBar','SGLegacyGlassView',
                      'UITabBarButton','UIImageView')
        for cls in cls_list:
            found=self.call(tag,'find',optional=True,**{'class':cls})
            save_json(out/'find'/f'{cls}.json',found)
            if not found.get('ok',False):
                continue
            count=min(int(found.get('count',0)), 3 if cls not in ('UIImageView','UISwitch') else (3 if cls=='UISwitch' else 0))
            for idx in range(count):
                base=out/'instances'/cls/f'index{idx}'
                save_json(base/'layers.json',self.call(tag,'layers',optional=True,**{'class':cls,'index':idx,'depth':10}))
                save_json(base/'ancestors.json',self.call(tag,'layers',optional=True,**{'class':cls,'index':idx,'up':1}))
                # KVC from the view, including sublayer-specific optical evidence.
                props=('frame','alpha','hidden','layer.zPosition','layer.opacity',
                       'layer.mask','layer.filters','layer.sublayers','layer.cornerRadius',
                       'layer.masksToBounds','layer.compositingFilter','layer.backgroundColor',
                       'layer.animationKeys','layer.presentationLayer.transform',
                       'layer.shadowOpacity','layer.shadowRadius')
                if cls=='SGLegacyGlassView':
                    props+=('layer.sublayers.0.zPosition','layer.sublayers.0.filters',
                            'layer.sublayers.0.mask','layer.sublayers.0.opacity',
                            'layer.sublayers.1.zPosition','layer.sublayers.1.filters')
                if cls in ('SGGlassThumbView','SGRLegacyLens','SGRLegacyTabBar'):
                    props+=('layer.sublayers.0.zPosition','layer.sublayers.1.zPosition',
                            'layer.sublayers.2.zPosition','layer.sublayers.3.zPosition',
                            'layer.sublayers.0.mask','layer.sublayers.1.mask',
                            'layer.sublayers.2.mask','layer.sublayers.3.mask')
                results={}
                for prop in props:
                    results[prop]=self.call(tag,'get',optional=True,**{'class':cls,'index':idx,'path':prop})
                save_json(base/'properties.json',results)

    def start_record(self, tag):
        path=self.root/tag/'motion.mp4'
        path.parent.mkdir(parents=True,exist_ok=True)
        logpath=path.parent/'recording.log'
        log=open(logpath,'w',encoding='utf-8')
        self.recorder_log=log
        self.recorder_path=path
        args=['xcrun','simctl','io',self.udid,'recordVideo','--codec=h264','--force',str(path)]
        save_json(path.parent/'recorder-args.json',args)
        try:
            self.recorder=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
        except Exception as exc:
            log.close();self.recorder_log=None;self.recorder=None
            raise MissingEvidence(f'Cannot start MP4 recorder: {exc}')
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            log.flush()
            if self.recorder.poll() is not None:
                self.stop_record(validate=False)
                raise MissingEvidence(f'simctl recordVideo exited before recording started: {logpath}')
            if logpath.exists() and 'Recording started' in logpath.read_text(errors='replace'):
                time.sleep(0.18)
                return
            time.sleep(0.2)
        self.stop_record(validate=False)
        raise MissingEvidence(f'simctl recordVideo did not start within 15 seconds: {logpath}')

    def stop_record(self, validate=True):
        p=self.recorder
        self.recorder=None
        if p and p.poll() is None:
            p.send_signal(signal.SIGINT)
            try: p.wait(timeout=13)
            except subprocess.TimeoutExpired:
                p.terminate()
                try: p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill();p.wait(timeout=5)
        if self.recorder_log:
            self.recorder_log.close()
            self.recorder_log=None
        path=self.recorder_path
        self.recorder_path=None
        if validate and path:
            report=verify_mp4(path)
            self.videos.append(report)
            save_json(path.parent/'video-check.json', report)
            if not report['ok']:
                raise MissingEvidence(f'MP4 invalid: {report}')
            print(f'  MP4 valid: {path.relative_to(self.root)}, {report["bytes"]//1024} KiB',flush=True)

    def live_optical_state(self, tag, started, command, args):
        """Observe live view/layer stack while SG_DRIVER is holding or dragging.

        Some builds serialize /tree behind touch actions. Record elapsed time so
        a late post-release answer cannot be mistaken for a held-state sample.
        """
        began=time.monotonic()
        folder=self.root/tag/'during'/'driver-held'
        samples={}
        try:
            samples['tree']=self.call(tag+'/live','tree',optional=True)
            for cls in ('SGGlassThumbView','SGLegacyGlassView','SGRLegacyLens'):
                samples[cls+'-layers']=self.call(tag+'/live','layers',optional=True,
                                                 **{'class':cls,'index':0,'depth':9})
                for prop in ('layer.zPosition','layer.mask','layer.sublayers','layer.filters'):
                    samples[cls+'-'+prop]=self.call(tag+'/live','get',optional=True,
                                               **{'class':cls,'index':0,'path':prop})
        except Exception as exc:
            samples['error']=repr(exc)
        if isinstance(samples.get('tree'),str):
            save_text(folder/'tree.txt',samples.pop('tree'))
        samples['request_elapsed_s']=round(time.monotonic()-began,3)
        samples['request_started_s']=round(began-started,3)
        samples['request_finished_s']=round(time.monotonic()-started,3)
        samples['gesture_args']={'cmd':command,**args}
        save_json(folder/'layers-and-order.json',samples)

    def gesture_video(self, tag, cmd, args, sample_seconds, gesture_min_hit=None):
        """MP4 first, screenshots *during* gesture; no mutation of app layers."""
        print('  video:',tag,flush=True)
        self.start_record(tag)
        output={}
        started=time.monotonic()
        def work():
            try: output['response']=self.call(tag,cmd,**args)
            except Exception as exc: output['error']=repr(exc)
        worker=threading.Thread(target=work,daemon=True)
        worker.start()
        live_worker=None
        timeline=[]
        try:
            for number,sec in enumerate(sample_seconds):
                delay=started+sec-time.monotonic()
                if delay>0:time.sleep(delay)
                capture_started=time.monotonic()-started
                f=self.root/tag/'during'/f'frame{number:02d}-{int(sec*1000)}ms.png'
                self.screenshot(f,required=True)
                timeline.append({'frame':number,'requested_s':sec,
                                'capture_started_s':round(capture_started,3),
                                'capture_finished_s':round(time.monotonic()-started,3)})
                if number==1 and cmd in ('swipe','longpress'):
                    live_worker=threading.Thread(target=self.live_optical_state,
                       args=(tag,started,cmd,args),daemon=True)
                    live_worker.start()
            worker.join(timeout=18)
            if worker.is_alive():
                raise MissingEvidence(f'Gesture {tag} still running; driver stalled')
            time.sleep(0.72)
            if live_worker:
                live_worker.join(timeout=7)
                if live_worker.is_alive():
                    self.warnings.append(f'{tag}: held layer query did not complete')
        except Exception:
            self.stop_record(validate=False)
            raise
        self.stop_record()
        save_json(self.root/tag/'sampling-timeline.json',
                  {'requested_frames':timeline,'gesture_args':{'cmd':cmd,**args},
                   'note':'Actual screenshot capture times allow determining if frame was during touch.'})
        output['arguments']={'cmd':cmd,**args}
        output['elapsed_s']=round(time.monotonic()-started,3)
        save_json(self.root/tag/'gesture.json',output)
        if output.get('error'):
            raise MissingEvidence(f'Gesture failed: {tag}: {output["error"]}')
        response=output.get('response') or {}
        if not response.get('ok'):
            raise MissingEvidence(f'Gesture driver failed: {tag}: {response}')
        if gesture_min_hit:
            hit=response.get('hit')
            if not isinstance(hit,str) or not any(t in hit.lower() for t in gesture_min_hit):
                raise MissingEvidence(f'{tag}: hit {hit!r}, expected {gesture_min_hit}; invalid diagnostics')
        self.snapshot(tag+'/after',heavy=False)
        return response

    def switch_phase(self, label, expected_on=None):
        if expected_on is None:
            expected_on = label=='Full bleed covers'
        tag='switches/'+('on-' if expected_on else 'off-')+label.lower().replace(' ','-')
        tree=self.call(tag,'tree')
        live=self.call(tag,'find',**{'class':'UISwitch'})
        save_text(self.root/tag/'baseline-tree.txt',tree)
        save_json(self.root/tag/'live-switches.json',live)
        target=match_switch(tree,live,label,expected_on=expected_on)
        save_json(self.root/tag/'target.json',target)
        print(f'  target {label}: {target["point"]} in actual UISwitch {target["screen_frame"]}',flush=True)
        self.snapshot(tag+'/rest',heavy=True)
        pt=','.join(f'{n:.2f}' for n in target['point'])
        self.gesture_video(tag+'/hold','longpress',{'at':pt,'duration':'3.0'},
                           [0.45,1.12,1.80,2.48], gesture_min_hit=('switch','thumb','glass'))
        self.snapshot(tag+'/after-rest',heavy=True)
        self.ok.append(tag)

    def tab_phase(self):
        self.set_tab('Search')
        self.snapshot('tabbar/rest-search',heavy=True)
        live=self.call('tabbar/centers','find',**{'class':'UITabBarButton'})
        save_json(self.root/'tabbar/centers/find-buttons.json',live)
        centers=tab_centers(live)
        save_json(self.root/'tabbar/centers/centers.json',centers)
        xy=lambda p: f'{p[0]:.2f},{p[1]:.2f}'
        self.gesture_video('tabbar/hold-search','longpress',
                           {'at':xy(centers['Search']),'duration':'3.0'},[0.45,1.10,1.85,2.47])
        self.snapshot('tabbar/after-hold-search-layer-state',heavy=True)
        self.set_tab('Search')
        self.gesture_video('tabbar/drag-search-to-library','swipe',
                           {'from':xy(centers['Search']),'to':xy(centers['Your Library']),
                            'duration':'2.35','hold':'0.90'},[0.40,0.95,1.50,2.05,2.62])
        self.snapshot('tabbar/after-drag-layer-state',heavy=True)
        self.set_tab('Your Library')
        self.gesture_video('tabbar/drag-library-to-search','swipe',
                           {'from':xy(centers['Your Library']),'to':xy(centers['Search']),
                            'duration':'2.35','hold':'0.90'},[0.40,0.95,1.50,2.05,2.62])
        self.set_tab('Search')
        point=[centers['Search'][0]+14,centers['Search'][1]-3]
        self.gesture_video('tabbar/offcenter-selected-search','tap',
                           {'at':xy(point)},[0.12,0.22,0.42])
        self.snapshot('tabbar/after-offcenter-layer-state',heavy=True)
        self.ok.append('tabbar/ordinary')
        return centers

    def rapid_retaps(self, centers):
        """Capture the released white-flash / retained bright overlay regression.

        Do not add UI-tree queries between taps: they would change the timing.
        Take a post-sequence snapshot and a settled optical layer dump.
        """
        self.set_tab('Search')
        base='tabbar/rapid-selected-search'
        at=f'{centers["Search"][0]:.2f},{centers["Search"][1]:.2f}'
        self.snapshot(base+'/before',heavy=True)
        self.start_record(base+'/twelve-taps')
        responses=[]
        try:
            for i in range(12):
                r=self.call(base,'tap',at=at)
                if not isinstance(r,dict) or not r.get('ok'):
                    raise MissingEvidence(f'rapid tap {i+1}/12 failed: {r}')
                responses.append({'tap':i+1,'result':r,'time':round(time.monotonic()-self.t0,3)})
                time.sleep(0.085)
            # Capture the entire fade-out in the same MP4.
            time.sleep(1.45)
        except Exception:
            self.stop_record(validate=False)
            raise
        self.stop_record()
        save_json(self.root/base/'responses.json',responses)
        self.snapshot(base+'/immediate-after',heavy=True)
        time.sleep(0.75)
        self.snapshot(base+'/settled',heavy=True)
        self.ok.append(base)

    def release_flash(self, centers):
        """One long hold and clean release video to inspect the white brightening."""
        self.set_tab('Search')
        tag='tabbar/release-flash'
        p=centers['Search']
        at=f'{p[0]:.2f},{p[1]:.2f}'
        self.snapshot(tag+'/before',heavy=False)
        self.gesture_video(tag+'/hold-then-release', 'longpress',
                           {'at':at,'duration':'2.0'}, [0.42,0.95,1.48,1.85,2.13,2.30])
        self.snapshot(tag+'/settled',heavy=True)
        self.ok.append(tag)

    def create_phase(self, centers):
        """Retained/Create drag checked separately: selecting Create may pop a menu."""
        tag='tabbar/create-retained'
        self.snapshot(tag+'/before',heavy=True)
        current=self.call(tag,'find',**{'class':'UITabBarButton'})
        save_json(self.root/tag/'live-buttons.json',current)
        now=tab_centers(current)
        # Never blindly press the button; this must capture the user's active-Create state.
        point=lambda n: f'{now[n][0]:.2f},{now[n][1]:.2f}'
        self.gesture_video(tag+'/drag-create-to-library','swipe',
                           {'from':point('Create'),'to':point('Your Library'),
                            'duration':'2.5','hold':'0.9'},[0.4,0.95,1.5,2.1,2.72])
        self.snapshot(tag+'/after-layer-state',heavy=True)
        self.ok.append(tag)

    def set_tab(self,name):
        r=self.call('setup-'+name,'tab',arg=name)
        save_json(self.root/'setup'/f'select-{name.lower().replace(" ","-")}.json',r)
        if not r.get('ok'):
            raise MissingEvidence(f'Cannot select {name}: {r}')
        time.sleep(0.35)


def verify_mp4(path):
    path=Path(path)
    result={'path':str(path),'ok':False,'bytes':0,'atoms':[]}
    if not path.exists():
        result['error']='missing video'
        return result
    result['bytes']=path.stat().st_size
    if result['bytes']<4096:
        result['error']='video too small'
        return result
    try:
        p=0
        with path.open('rb') as f:
            while p+8<=result['bytes']:
                f.seek(p)
                header=f.read(8)
                size,kind=struct.unpack('>I4s',header)
                kind=kind.decode('ascii','replace')
                if size==1:
                    size=struct.unpack('>Q',f.read(8))[0]
                    minimum=16
                else:
                    minimum=8
                    if size==0:size=result['bytes']-p
                if size<minimum or size>result['bytes']-p:
                    raise ValueError(f'invalid MP4 atom {kind} at {p}')
                result['atoms'].append(kind)
                p+=size
        if not {'moov','mdat','ftyp'}<=set(result['atoms']):
            raise ValueError('ftyp, mdat or moov missing')
        if shutil.which('ffprobe'):
            probe=cmd_capture(['ffprobe','-v','error','-select_streams','v:0',
                               '-show_entries','stream=codec_name,width,height:format=duration',
                               '-of','json',str(path)],timeout=25)
            if probe.get('exit')!=0:
                raise ValueError('ffprobe failed: '+str(probe))
            obj=json.loads(probe['stdout'])
            streams=obj.get('streams') or []
            duration=float((obj.get('format') or {}).get('duration') or 0)
            if not streams or streams[0].get('codec_name')!='h264' or duration<0.45:
                raise ValueError('not usable H264 stream / video too short')
            result['probe']={'duration':duration,'stream':streams[0]}
        result['ok']=True
    except Exception as exc:
        result['error']=repr(exc)
    return result


def read_sources(root, repo):
    """Version evidence: local *actual* source rather than guessing from another branch."""
    info={}
    for name,args in {'head':['git','rev-parse','HEAD'],
                      'branch':['git','branch','--show-current'],
                      'status':['git','status','--porcelain=v1'],
                      'last_commits':['git','log','-6','--oneline']}.items():
        info[name]=cmd_capture(args,timeout=15)
    save_json(root/'repo-source/metadata.json',info)
    paths=['tweak/Sources/Core/SGGlass.m','tweak/Sources/Core/SGGlassThumb.m',
           'tweak/Sources/Core/SGLegacyGlass.m',
           'tweak/Sources/Redesigned/Navbar/TabBarLens.m',
           'tweak/Sources/Redesigned/Navbar/TabBarLegacy.x',
           'tweak/Sources/Redesigned/Navbar/NavbarSettings.m']
    for relative in paths:
        path=repo/relative
        if path.is_file():
            copy=root/'repo-source'/relative
            copy.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(path,copy)
        else:
            info.setdefault('missing_source',[]).append(relative)
    save_json(root/'repo-source/metadata.json',info)
    return info


def prompt(msg):
    print('\n'+msg+'\n',flush=True)
    return input('Press Enter when ready (type s to STOP and mark INCOMPLETE): ').strip().lower()!='s'


def package(root):
    zpath=root.with_suffix('.zip')
    with zipfile.ZipFile(zpath,'w',zipfile.ZIP_DEFLATED,compresslevel=5) as out:
        for p in sorted(root.rglob('*')):
            if p.is_file():out.write(p,p.relative_to(root))
    return zpath



UDID26 = 'B8E2A0A5-3BE4-4B47-BBAE-095D64219EBA'
UDID18 = DEFAULT_UDID


def new_tab_centers(found, native=False):
    """Live-screen coordinates from driver /find, not tree accumulation."""
    views=found.get('views',[]) if isinstance(found,dict) else []
    live=[v for v in views if v.get('shown') is not False and
          isinstance(v.get('frame'),list) and len(v['frame'])==4 and
          v['frame'][2]>=50 and v['frame'][3]>=45 and v['frame'][1]>380]
    live.sort(key=lambda v: v['frame'][0])
    dedup=[]
    for v in live:
        x,y,w,h=map(float,v['frame'])
        if not dedup or abs(x-dedup[-1]['frame'][0])>3:
            dedup.append(v)
    if len(dedup)!=4:
        raise MissingEvidence(f'Expected four visible full-tab buttons on {"native" if native else "Legacy"}, '
                              f'got {len(dedup)} (raw {live})')
    centers={name:[round(v['frame'][0]+v['frame'][2]/2,2),round(v['frame'][1]+v['frame'][3]/2,2)]
             for name,v in zip(TABS,dedup)}
    if not all(centers[a][0]<centers[b][0] for a,b in zip(TABS,TABS[1:])):
        raise MissingEvidence('Tab button ordering invalid: '+str(centers))
    return centers


def compact_centers(found, native):
    """iOS 26: 2 duplicate pairs of _UITabButton; iOS 18: 2 SGRLegacyCircle."""
    views=found.get('views',[]) if isinstance(found,dict) else []
    live=[v for v in views if v.get('shown') is not False and
          isinstance(v.get('frame'),list) and len(v['frame'])==4 and
          44<=v['frame'][2]<=75 and 44<=v['frame'][3]<=75 and v['frame'][1]>450]
    live.sort(key=lambda v:v['frame'][0])
    unique=[]
    for view in live:
        if not unique or abs(view['frame'][0]-unique[-1]['frame'][0])>3:
            unique.append(view)
    if len(unique)!=2:
        raise MissingEvidence(f'Minimized mode not active or circles not found on '
                              f'{"iOS 26" if native else "iOS 18"}: {live}')
    left,right=unique
    if right['frame'][0]-left['frame'][0]<130:
        raise MissingEvidence('Compact circles are not sufficiently separated')
    return {'left':[round(left['frame'][0]+left['frame'][2]/2,2),
                    round(left['frame'][1]+left['frame'][3]/2,2)],
            'right':[round(right['frame'][0]+right['frame'][2]/2,2),
                     round(right['frame'][1]+right['frame'][3]/2,2)]}


class Comparison(Collector):
    def __init__(self, root, name, port, udid, native):
        super().__init__(Path(root)/name,port,udid)
        self.name=name
        self.native=native
        self.completed=[]
        self.expected_videos=[]

    def deep(self, tag):
        folder=self.root/tag/'deep'
        if tag.startswith('switches/'):
            classes=['UISwitch','_UILiquidLensView','_UIPortalView'] if self.native else [
                'UISwitch','SGGlassThumbView','SGGlassSwitchView','SGLegacyGlassView']
        elif tag.startswith('compact/'):
            classes=['_UITabButton','_UILiquidLensView','_UITabBarPlatterView','_UIPortalView'] if self.native else [
                'SGRLegacyCircle','SGLegacyGlassView','SGRLegacyLens','SGRLegacyTabBar','UIImageView']
        else:
            classes=['_UITabButton','_UILiquidLensView','_UITabBarPlatterView','_UIPortalView'] if self.native else [
                'SGRLegacyLens','SGRLegacyTabBar','UITabBarButton','SGLegacyGlassView','UIImageView','UILabel']
        for cls in classes:
            found=self.call(tag,'find',optional=True,**{'class':cls})
            save_json(folder/'find'/f'{cls}.json',found)
            if not isinstance(found,dict) or not found.get('ok'):
                continue
            count=min(found.get('count',0),4)
            for index in range(count):
                base=folder/'instances'/cls/f'index{index}'
                save_json(base/'layers.json',self.call(tag,'layers',optional=True,
                    **{'class':cls,'index':index,'depth':8}))
                save_json(base/'ancestors.json',self.call(tag,'layers',optional=True,
                    **{'class':cls,'index':index,'up':1}))
                props={}
                for path in ('frame','alpha','hidden','layer.opacity','layer.zPosition',
                             'layer.mask','layer.filters','layer.cornerRadius',
                             'layer.backgroundColor','layer.sublayers','layer.animationKeys',
                             'layer.presentationLayer.bounds','layer.presentationLayer.position',
                             'layer.presentationLayer.transform','layer.masksToBounds',
                             'layer.shadowOpacity','layer.shadowRadius'):
                    props[path]=self.call(tag,'get',optional=True,
                                        **{'class':cls,'index':index,'path':path})
                save_json(base/'properties.json',props)


    def live_optical_state(self, tag, started, command, args):
        """Lightweight live view queries with timing; avoid stalling gesture."""
        began=time.monotonic()
        folder=self.root/tag/'during/driver-held'
        if tag.startswith('compact/'):
            classes=('_UITabButton','_UILiquidLensView') if self.native else (
                'SGRLegacyCircle','SGRLegacyLens')
        elif tag.startswith('switches/'):
            classes=('UISwitch','_UILiquidLensView') if self.native else (
                'UISwitch','SGGlassThumbView')
        else:
            classes=('_UITabButton','_UILiquidLensView') if self.native else (
                'UITabBarButton','SGRLegacyLens')
        samples={'gesture_cmd':command,'gesture_args':args}
        tree=self.call(tag+'/live','tree',optional=True)
        if isinstance(tree,str):save_text(folder/'tree.txt',tree)
        for cls in classes:
            samples[cls+'-find']=self.call(tag+'/live','find',optional=True,
                                            **{'class':cls})
        # One small set of CALayer samples. Heavy dumps are collected AFTER.
        lens=classes[-1]
        samples[lens+'-layers']=self.call(tag+'/live','layers',optional=True,
                                            **{'class':lens,'index':0,'depth':4})
        for prop in ('layer.presentationLayer.bounds','layer.presentationLayer.transform'):
            samples[lens+'-'+prop]=self.call(tag+'/live','get',optional=True,
                                     **{'class':lens,'index':0,'path':prop})
        samples['request_started_at_s']=round(began-started,3)
        samples['request_finished_at_s']=round(time.monotonic()-started,3)
        samples['note']='If request finished AFTER gesture duration+hold, this is post-release.'
        save_json(folder/'layers-and-order.json',samples)

    def preflight(self):
        state=self.call('preflight','state')
        save_json(self.root/'preflight/state.json',state)
        if not isinstance(state,dict) or not state.get('ok'):
            raise MissingEvidence(f'{self.name}: driver unreachable on {self.port}')
        self.start_record('preflight/h264')
        time.sleep(1.6)
        self.stop_record()
        self.require_video('preflight/h264')
        self.completed.append('preflight')

    def require_video(self,tag):
        self.expected_videos.append(tag)

    def point(self,p):
        return f'{p[0]:.2f},{p[1]:.2f}'

    def buttons(self):
        klass='_UITabButton' if self.native else 'UITabBarButton'
        found=self.call('regular/centers','find',**{'class':klass})
        save_json(self.root/'regular/centers'/'buttons.json',found)
        centers=new_tab_centers(found,self.native)
        save_json(self.root/'regular/centers'/'centers.json',centers)
        return centers

    def verified_gesture(self,tag,cmd,args,frames,hit_terms=None):
        """Continuous MP4 and SIMCTL screenshots, never simulated separate taps."""
        if hit_terms is None:hit_terms=()
        self.gesture_video(tag,cmd,args,frames,gesture_min_hit=hit_terms or None)
        self.require_video(tag)

    def regular(self):
        """Record growth and side-glyph double seam mid-gesture, both directions."""
        tag='regular'
        r=self.call(tag+'/setup','tab',arg='Search')
        save_json(self.root/tag/'setup-search.json',r)
        if not r.get('ok'):raise MissingEvidence(f'{self.name}: Search selection failed')
        time.sleep(0.5)
        self.snapshot(tag+'/rest-search',heavy=True)
        centers=self.buttons()
        search=centers['Search']; lib=centers['Your Library']
        self.verified_gesture(tag+'/hold-search','longpress',
            {'at':self.point(search),'duration':'3.2'},
            [0.32,0.70,1.25,2.25,2.96,3.20,3.52])
        self.snapshot(tag+'/after-held-release',heavy=True)
        self.verified_gesture(tag+'/drag-search-library','swipe',
            {'from':self.point(search),'to':self.point(lib),
             'duration':'2.9','hold':'1.05'},
            [0.36,1.00,1.68,2.36,2.90,3.38])
        self.snapshot(tag+'/after-right',heavy=True)
        self.verified_gesture(tag+'/drag-library-search','swipe',
            {'from':self.point(lib),'to':self.point(search),
             'duration':'2.9','hold':'1.05'},
            [0.36,1.00,1.68,2.36,2.90,3.38])
        r=self.call(tag+'/setup-before-offset','tab',arg='Search')
        if not r.get('ok'):raise MissingEvidence('Cannot reselect Search')
        time.sleep(0.35)
        self.verified_gesture(tag+'/offset-selected-search','tap',
            {'at':self.point([search[0]+12.0,search[1]-3.0])},
            [0.13,0.25,0.40])
        self.snapshot(tag+'/final',heavy=True)
        self.completed.append(tag)
        return centers

    def compact(self):
        """Measure native vs Legacy compact held growth and bubble following finger."""
        tag='compact'
        cls='_UITabButton' if self.native else 'SGRLegacyCircle'
        found=self.call(tag,'find',**{'class':cls})
        save_json(self.root/tag/'live-buttons.json',found)
        points=compact_centers(found,self.native)
        save_json(self.root/tag/'centers.json',points)
        self.snapshot(tag+'/baseline',heavy=True)
        for side in ('left','right'):
            center=points[side]
            hit=('tabbutton','liquidlens','lens') if self.native else ('legacycircle',)
            self.verified_gesture(f'{tag}/{side}/hold','longpress',
                {'at':self.point(center),'duration':'3.0'},
                [0.34,0.77,1.28,2.05,2.72,3.04,3.32],hit)
            self.snapshot(f'{tag}/{side}/after-hold',heavy=True)
            dx=17.0 if side=='left' else -17.0
            self.verified_gesture(f'{tag}/{side}/follow-inward','swipe',
                {'from':self.point(center),
                 'to':self.point([center[0]+dx,center[1]]),
                 'duration':'2.35','hold':'1.0'},
                [0.33,0.75,1.30,1.96,2.45,2.84],hit)
            self.snapshot(f'{tag}/{side}/after-follow',heavy=True)
            if side=='left':
                self.verified_gesture(f'{tag}/{side}/follow-outward','swipe',
                    {'from':self.point(center),
                     'to':self.point([center[0]-12.0,center[1]]),
                     'duration':'2.35','hold':'1.0'},
                    [0.33,0.75,1.30,1.96,2.45,2.84],hit)
        self.snapshot(tag+'/final',heavy=True)
        self.completed.append(tag)

    def toggle(self,label,expected_on):
        slug=('on-' if expected_on else 'off-')+label.lower().replace(' ','-')
        tag='switches/'+slug
        tree=self.call(tag,'tree')
        found=self.call(tag,'find',**{'class':'UISwitch'})
        save_text(self.root/tag/'label-tree.txt',tree)
        save_json(self.root/tag/'live-switches.json',found)
        target=match_switch(tree,found,label,expected_on)
        save_json(self.root/tag/'target.json',target)
        self.snapshot(tag+'/baseline',heavy=True)
        self.verified_gesture(tag+'/held','longpress',
            {'at':self.point(target['point']),'duration':'2.7'},
            [0.35,0.95,1.52,2.25,2.85],('switch','thumb','glass','lens'))
        self.snapshot(tag+'/settled',heavy=True)
        self.completed.append(tag)






class Stage36(Comparison):
    """Rim, landing latency, and release-flash capture; no touch-time KVC calls."""

    def start_record(self, tag):
        # Capture monotonic bounds for the MP4 start. The exact first PTS
        # cannot be inferred from simctl's 'Recording started' log line.
        self._record_launched_at = time.monotonic()
        super().start_record(tag)
        self._record_confirmed_at = time.monotonic()


    def gesture_video(self, tag, cmd, args, sample_seconds, gesture_min_hit=None):
        """Record touch without concurrent driver queries that might stall touch-up.

        simctl screenshots occur while recording; their actual begin/end times are
        logged. The continuous H.264 stream, not PNG timing, is the primary
        evidence. No /tree, /get, or /layers runs until after recording stops.
        """
        print('  focused video:', tag, flush=True)
        self.start_record(tag)
        result = {}
        began = time.monotonic()
        video_offset_bounds = [round(began - self._record_confirmed_at, 4),
                               round(began - self._record_launched_at, 4)]
        def touch():
            try:
                result['response'] = self.call(tag, cmd, **args)
            except Exception as exc:
                result['error'] = repr(exc)
            finally:
                result['driver_finished_after_s'] = round(time.monotonic() - began, 4)
        worker = threading.Thread(target=touch, daemon=True)
        worker.start()
        stamps = []
        try:
            for index, target_time in enumerate(sample_seconds):
                wait = began + target_time - time.monotonic()
                if wait > 0: time.sleep(wait)
                since = time.monotonic() - began
                path = self.root/tag/'during'/f'frame{index:02d}-{round(target_time*1000)}ms.png'
                self.screenshot(path, required=True)
                stamps.append({'requested_s': target_time,
                    'capture_begin_s': round(since, 4),
                    'capture_end_s': round(time.monotonic() - began, 4),
                    'driver_finished': not worker.is_alive()})
            worker.join(timeout=18)
            if worker.is_alive():
                raise MissingEvidence(f'Gesture worker timed out in {tag}')
            time.sleep(0.80)  # record glass/platter after the last screenshot
        except Exception:
            self.stop_record(validate=False)
            raise
        self.stop_record()
        save_json(self.root/tag/'sampling-timeline.json', {
            'gesture_start_t0': 'first /tap or /longpress HTTP request',
            'screenshots': stamps,
            'driver_finished_after_s': result.get('driver_finished_after_s'),
            'video_gesture_offset_bounds_s': video_offset_bounds,
            'release_estimate_note': 'simctl recording start is bracketed, not frame-exact; for /longpress the requested duration approximates touch-up, and the HTTP response is its upper bound',
            'note': 'MP4 pixel analysis is advisory. Simctl screenshots may stall but no driver KVC is queried during touch.'})
        save_json(self.root/tag/'gesture.json', dict(result, arguments={'cmd': cmd, **args}))
        if result.get('error'):
            raise MissingEvidence(f'{tag} driver error: {result["error"]}')
        response = result.get('response') or {}
        if not isinstance(response, dict) or not response.get('ok'):
            raise MissingEvidence(f'{tag} driver failed: {response}')
        if gesture_min_hit:
            hit = str(response.get('hit','')).lower()
            if not any(s in hit for s in gesture_min_hit):
                raise MissingEvidence(f'{tag}: wrong hit {hit!r}; expected {gesture_min_hit}')
        self.snapshot(tag+'/after', heavy=False)
        return response


    def select(self, name):
        response=self.call('setup/tab-'+name.lower().replace(' ','-'),'tab',arg=name)
        save_json(self.root/'setup'/f'select-{name.lower().replace(" ","-")}.json',response)
        if not response.get('ok'):
            raise MissingEvidence(f'{self.name}: cannot select {name}: {response}')
        # Start each recorded gesture only after any previous programmatic
        # tab pulse has had time to finish, even on the old slow-release build.
        time.sleep(1.7)

    def verified_video(self, tag, command, options, frames, hit_terms=None):
        expected_hit=hit_terms if hit_terms is not None else (
            ('tabbutton', 'lens') if self.native else ('tabbarbutton', 'lens'))
        self.gesture_video(tag,command,options,frames,gesture_min_hit=expected_hit)
        self.require_video(tag)

    def timed_tap(self, slug, origin, destination, offset_x=0):
        """Capture a REAL /tap, not longpress or a synthetic swipe.

        A quick touch is generally over before the first simctl screenshot.
        H.264 MP4 is the timing source; samples are still useful to compare
        material after contact, with actual timestamps alongside every PNG.
        """
        self.select(origin)
        centers=self.buttons()
        target=centers[destination].copy()
        target[0]+=offset_x
        tag='short-taps/'+slug
        save_json(self.root/tag/'target.json',{'origin':origin,'destination':destination,
            'offset_x':offset_x,'point':target,'centers':centers,
            'purpose':'native full-height lift vs legacy quick-tap height and material-settle delay'})
        self.snapshot(tag+'/before',heavy=False)
        self.verified_video(tag,'tap',{'at':self.point(target)},
            [0.08,0.17,0.29,0.44,0.62,0.86,1.16,1.54,1.93,2.35])
        self.snapshot(tag+'/settled',heavy=True)
        self.completed.append(tag)

    def tap_burst(self):
        self.select('Search')
        center=self.buttons()['Search']
        tag='short-taps/eight-rapid-selected-search'
        self.snapshot(tag+'/before',heavy=True)
        self.start_record(tag)
        responses=[]
        began=time.monotonic()
        try:
            for index in range(8):
                pre=time.monotonic()
                result=self.call(tag,'tap',at=self.point(center))
                hit=str(result.get('hit','')).lower() if isinstance(result,dict) else ''
                valid=('tabbutton' in hit or 'lens' in hit) if self.native else (
                    'tabbarbutton' in hit or 'lens' in hit)
                if not valid:
                    raise MissingEvidence(f'{self.name}: rapid tap {index+1} hit {hit!r}, not tab button')
                responses.append({'tap':index+1,'began_s':round(pre-began,4),
                                  'ended_s':round(time.monotonic()-began,4),
                                  'driver':result})
                time.sleep(0.085)
            time.sleep(2.35)
        except Exception:
            self.stop_record(validate=False)
            raise
        self.stop_record()
        self.require_video(tag)
        save_json(self.root/tag/'tap-sequence.json',responses)
        self.snapshot(tag+'/after',heavy=True)
        self.completed.append(tag)

    def held_rim(self, name):
        self.select(name)
        center=self.buttons()[name]
        slug=name.lower().replace(' ','-')
        tag='held-geometry/hold-'+slug
        self.snapshot(tag+'/before',heavy=True)
        self.verified_video(tag,'longpress',{'at':self.point(center),'duration':'2.7'},
            [0.16,0.29,0.43,0.75,1.23,1.90,2.45,2.74,2.96,3.17])
        self.snapshot(tag+'/after',heavy=True)
        self.completed.append(tag)

    def held_release(self):
        """Deliberate long press and release at an already selected tab.

        A quick tap has a forced upward pulse, so both scenarios are mandatory:
        tap-to-different-tab AND hold-release-on-selected-tab.
        """
        self.select('Search')
        pos=self.buttons()['Search']
        tag='release/hold-search-then-release'
        self.snapshot(tag+'/before',heavy=True)
        save_json(self.root/tag/'target.json', {'origin':'Search', 'destination':'Search',
            'point':pos, 'purpose':'glass-to-platter flash and material transition'})
        self.verified_video(tag,'longpress',{'at':self.point(pos),'duration':'2.4'},
            [0.18,0.44,1.15,2.07,2.32,2.46,2.58,2.75,2.95,3.30,3.70])
        self.snapshot(tag+'/settled',heavy=True)
        self.completed.append(tag)

    def anchor_test(self):
        self.select('Search')
        search=self.buttons()['Search']
        start=[search[0]+15,search[1]-2]
        end=[start[0]+44,start[1]]
        tag='anchoring/offcenter-search-drag-right'
        save_json(self.root/tag/'coords.json',{'start':start,'end':end,'center':search,
                   'note':'One continuous swipe; inspect filled glyph timing vs bubble center.'})
        self.verified_video(tag,'swipe',{'from':self.point(start),'to':self.point(end),
            'duration':'2.6','hold':'0.85'},[0.12,0.33,0.70,1.18,1.76,2.15,2.53,2.86,3.11])
        self.snapshot(tag+'/after',heavy=True)
        self.completed.append(tag)

    def run_all(self):
        self.select('Search')
        self.snapshot('baseline/search',heavy=True)
        for args in (
            ('selected-search-center','Search','Search',0),
            ('search-to-library','Search','Your Library',0),
            ('library-to-search','Your Library','Search',0),
        ):
            self.timed_tap(*args)
        self.held_release()
        self.held_rim('Search')
        self.held_rim('Your Library')
        self.snapshot('baseline/after-all',heavy=True)



# --- Stage 36.1: isolated material-swap flash audit (standard Python + optional ffmpeg) ---
# No third-party Python packages are required. MP4s are ALWAYS saved, even when
# ffmpeg/ffprobe are unavailable; in that case an automated verdict is not made.
FLASH_TAGS = ('short-taps/selected-search-center',
              'short-taps/search-to-library',
              'short-taps/library-to-search',
              'release/hold-search-then-release')


def _window_screen_size(tree_path):
    if not tree_path.is_file():
        return None
    nodes=parse_nodes(tree_path.read_text(encoding='utf-8',errors='replace'))
    for n in nodes:
        name=n['name'].lower()
        x,y,w,h=n['frame']
        if ('window' in name or name in ('uiscreen','sgrlegacytabbar')) and w>290 and h>550:
            return (w,h) if h>w else None
    return None


def _ffprobe_video(path):
    completed=subprocess.run([
        'ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=width,height:frame=best_effort_timestamp_time',
        '-of','json',str(path)],capture_output=True,text=True,timeout=35)
    if completed.returncode:
        raise MissingEvidence('ffprobe cannot decode this MP4: '+completed.stderr[-1200:])
    obj=json.loads(completed.stdout)
    streams=obj.get('streams') or []
    if not streams:raise MissingEvidence('ffprobe found no video stream')
    width,height=int(streams[0]['width']),int(streams[0]['height'])
    timestamps=[]
    for item in obj.get('frames',[]):
        try: timestamps.append(float(item['best_effort_timestamp_time']))
        except (ValueError,TypeError,KeyError): continue
    if len(timestamps)<20 or not all(b>=a for a,b in zip(timestamps,timestamps[1:])):
        raise MissingEvidence('ffprobe frame timestamps are absent/unordered')
    return width,height,timestamps


def _crop_roi_pixels(center,video_shape,screen_shape,wp=58,hp=37):
    vw,vh=video_shape;sw,sh=screen_shape
    sx,sy=vw/sw,vh/sh
    width=max(8,min(vw,round(wp*sx)))
    height=max(8,min(vh,round(hp*sy)))
    left=max(0,min(vw-width,round(center[0]*sx-width/2)))
    top=max(0,min(vh-height,round(center[1]*sy-height/2)))
    return (int(left),int(top),int(width),int(height))


def _gray_roi_series(path, rect, frame_times):
    # Crop BEFORE decoding to rawvideo; the memory footprint is ~few KiB/frame.
    x,y,w,h=rect
    ww,hh=28,18
    vf=f'crop={w}:{h}:{x}:{y},scale={ww}:{hh}:flags=area,format=gray'
    argv=['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-i',str(path),
          '-map','0:v:0','-an','-sn','-vf',vf,'-vsync','0',
          '-f','rawvideo','-pix_fmt','gray','pipe:1']
    proc=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=55)
    if proc.returncode:
        raise MissingEvidence('ffmpeg failed ROI decode: '+proc.stderr.decode(errors='replace')[-1200:])
    blob=proc.stdout
    pixels=ww*hh
    if not blob or len(blob)%pixels:
        raise MissingEvidence('Unexpected rawvideo frame size from ffmpeg')
    framecount=len(blob)//pixels
    if abs(framecount-len(frame_times))>2:
        raise MissingEvidence('ffmpeg/ffprobe frame mismatch: '+str((framecount,len(frame_times))))
    times=frame_times[:framecount]
    measurements=[]
    for i,t in enumerate(times):
        vals=sorted(blob[i*pixels:(i+1)*pixels])
        # The median excludes isolated bright glyph/rim pixels. The upper
        # quartile still captures specular flashes; both are exported.
        measurements.append({'t_s':round(t,5),
            'median':float(vals[len(vals)//2]),
            'p75':float(vals[int(len(vals)*0.75)]),
            'mean':round(sum(vals)/len(vals),3)})
    return measurements


def _median(xs):
    s=sorted(xs)
    if not s:return None
    return (s[(len(s)-1)//2]+s[len(s)//2])/2


def _waveform_spike(region,control,timing,cmd,duration):
    # Approximate time range: simctl may start encoding before it writes its
    # log message; avoid inventing sub-frame precision when aligning video.
    offsets=timing.get('video_gesture_offset_bounds_s')
    if (not isinstance(offsets,list) or len(offsets)!=2 or
            not all(isinstance(v,(int,float)) for v in offsets)):
        return {'status':'INCOMPLETE','reason':'No video-to-gesture timing bounds'}
    completed=timing.get('driver_finished_after_s')
    if not isinstance(completed,(float,int)):
        return {'status':'INCOMPLETE','reason':'No touch-response completion time'}
    if cmd=='longpress':
        # Actual touch-up can fall within this range; it is NOT the instant
        # that glass changes into the resting platter.
        event_lo=offsets[0]+max(0,duration-0.12)
        event_hi=offsets[1]+completed+0.12
    else:
        event_lo=offsets[0]+max(0,completed-0.18)
        event_hi=offsets[1]+completed+0.2
    if event_hi-event_lo>0.9 or event_lo < 0:
        return {'status':'REVIEW_REQUIRED','reason':'Touch/release event time uncertain',
                'event_bounds_s':[round(event_lo,3),round(event_hi,3)]}
    last=region[-1]['t_s']
    baseline_lo=max(0,event_lo-0.80)
    baseline_hi=max(0,event_lo-0.18)
    after_lo=max(event_hi+0.90,last-0.65)
    # A quick /tap can immediately start its bubble animation; we report a
    # candidate peak only, not a proven swap flash, in that scenario.
    candidates=[(r,c) for r,c in zip(region,control)
                if event_lo-0.08<=r['t_s']<=min(last,event_hi+1.22)]
    prior=[r['median'] for r in region if baseline_lo<=r['t_s']<baseline_hi]
    stable=[r['median'] for r in region if after_lo<=r['t_s']<=last]
    ctrlprior=[r['median'] for r in control if baseline_lo<=r['t_s']<baseline_hi]
    ctrlstable=[r['median'] for r in control if after_lo<=r['t_s']<=last]
    if len(candidates)<5 or len(prior)<3 or len(stable)<3 or len(ctrlprior)<3 or len(ctrlstable)<3:
        return {'status':'REVIEW_REQUIRED',
                'reason':'Not enough captured pre-transition/post-transition frames',
                'event_bounds_s':[round(event_lo,3),round(event_hi,3)],
                'pre_count':len(prior),'post_count':len(stable)}
    before,after=_median(prior),_median(stable)
    ctrl_before,ctrl_after=_median(ctrlprior),_median(ctrlstable)
    peak,ctrl_peak=max(candidates,key=lambda it:it[0]['median'])
    peak_excess=peak['median']-max(before,after)
    ctrl_excess=ctrl_peak['median']-max(ctrl_before,ctrl_after)
    # Must be brief, localized, and overshoot BOTH glass and final platter.
    # This is a HEURISTIC candidate; icon/lighting changes require visual review.
    high_threshold=max(before,after)+max(8,peak_excess*0.5)
    bright=[r['t_s'] for r,c in candidates if r['median']>high_threshold]
    span=(max(bright)-min(bright)) if len(bright)>=2 else 0
    possible=(peak_excess>=14 and peak_excess-ctrl_excess>=9 and span<=0.35)
    return {'status':'POSSIBLE_LOCAL_FLASH' if possible else 'NO_CONFIRMED_SPIKE',
        'automated_result_is_definitive':False,
        'possible_flash':possible,
        'warning':'This tests brightness overshoot, NOT material identity or the exact glass-to-platter swap frame.',
        'release_window_estimated_s':[round(event_lo,3),round(event_hi,3)],
        'sampled_peak_time_s':peak['t_s'],
        'brightness_before_median':before,'brightness_after_median':after,
        'brightness_peak_median':peak['median'],
        'peak_over_both_states_8bit':round(peak_excess,3),
        'control_peak_over_both_states_8bit':round(ctrl_excess,3),
        'bright_excursion_duration_s':round(span,3),
        'criterion':'overshoot >=14 8-bit; local excess >=9; excursion <=350ms'}


def analyze_flash_video(session,tag):
    folder=session.root/tag
    report={'tag':tag,'status':'REVIEW_REQUIRED',
            'what_to_look_for':'At the moment the raised glass disappears, does a short white/light pulse occur at the same selected-tab location?',
            'video':str(folder/'motion.mp4'),
            'note':'Always inspect the MP4 around the actual material swap. A brightness spike alone cannot prove the swap happened.'}
    try:
        movie=folder/'motion.mp4'
        if not movie.is_file() or movie.stat().st_size<4096:
            raise MissingEvidence('Mandatory MP4 missing/too short')
        if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
            report['reason']='ffmpeg/ffprobe absent: video saved for manual frame-by-frame review; automatic brightness check unavailable'
            return report
        target=json.loads((folder/'target.json').read_text(encoding='utf-8'))
        timing=json.loads((folder/'sampling-timeline.json').read_text(encoding='utf-8'))
        if not isinstance(target.get('point'),list) or len(target['point'])!=2:
            raise MissingEvidence('Missing tab-center coordinate for flash ROI')
        screen=_window_screen_size(folder/'before/tree.txt')
        if not screen:
            raise MissingEvidence('Cannot determine simulator screen point bounds from UIWindow tree')
        vw,vh,times=_ffprobe_video(movie)
        # Center region: the selected capsule; reference directly ABOVE the
        # tab, outside the glass-to-platter surface.
        point=target['point']
        region_rect=_crop_roi_pixels(point,(vw,vh),screen)
        ctrl_point=[point[0],max(35,point[1]-88)]
        control_rect=_crop_roi_pixels(ctrl_point,(vw,vh),screen)
        region=_gray_roi_series(movie,region_rect,times)
        control=_gray_roi_series(movie,control_rect,times)
        if abs(len(region)-len(control))>2:
            raise MissingEvidence('Reference/target frame count mismatch')
        command='longpress' if tag.startswith('release/') else 'tap'
        duration=2.4 if command=='longpress' else 0.0
        signal=_waveform_spike(region,control,timing,command,duration)
        report.update({'status':signal['status'],'analysis':signal,
            'video_dimensions_px':[vw,vh], 'screen_dimensions_pt':list(screen),
            'selected_tab_point_pt':point,'selected_roi_xywh_px':region_rect,
            'control_roi_xywh_px':control_rect,'frames_analyzed':len(region),
            'decoder':'ffmpeg/ffprobe; frames decoded at native stream PTS'})
        import csv
        with (folder/'flash-luminance-series.csv').open('w',encoding='utf-8',newline='') as f:
            writer=csv.writer(f)
            writer.writerow(('video_pts_s','selected_median','selected_p75','selected_mean',
                             'control_median','control_p75','control_mean'))
            for r,c in zip(region,control):
                writer.writerow((r['t_s'],r['median'],r['p75'],r['mean'],
                                 c['median'],c['p75'],c['mean']))
    except Exception as exc:
        report['status']='REVIEW_REQUIRED'
        report['reason']=f'{type(exc).__name__}: {exc}'
    finally:
        save_json(folder/'flash-analysis.json',report)
    return report


def analyze_all_flash_videos(session):
    reports={tag:analyze_flash_video(session,tag) for tag in FLASH_TAGS}
    save_json(session.root/'flash-audit-summary.json',reports)
    return reports


def self_test_stage36():
    """Offline diagnostic sanity check: imports, class, and flash logic."""
    if not issubclass(Stage36, Comparison):
        raise RuntimeError('Stage36 class does not inherit Comparison')
    if not FLASH_TAGS or len(FLASH_TAGS) != 4:
        raise RuntimeError('Missing mandatory flash scenarios')
    t=[round(i/30,5) for i in range(120)]
    series=[{'t_s':v, 'median':220 if 2.70<=v<2.80 else 40} for v in t]
    ref=[{'t_s':v, 'median':40} for v in t]
    result=_waveform_spike(series,ref,
        {'video_gesture_offset_bounds_s':[0.28,0.42],
         'driver_finished_after_s':2.40},'longpress',2.4)
    if result.get('status')!='POSSIBLE_LOCAL_FLASH':
        raise RuntimeError('Synthetic 100ms pulse must be detected: '+str(result))
    no_pulse=[{'t_s':v, 'median':40} for v in t]
    quiet=_waveform_spike(no_pulse,ref,
        {'video_gesture_offset_bounds_s':[0.28,0.42],
         'driver_finished_after_s':2.40},'longpress',2.4)
    if quiet.get('status')!='NO_CONFIRMED_SPIKE':
        raise RuntimeError('Flat brightness trace must not produce a flash: '+str(quiet))
    print('SELF-TEST OK: Stage36 is defined, flash tests are present,',
          'brief pulse detected, flat baseline rejected.')



def digest_file(path, root):
    import hashlib
    path=Path(path)
    try:
        if not path.is_file():return {'path':str(path),'exists':False}
        h=hashlib.sha256()
        with path.open('rb') as f:
            while True:
                chunk=f.read(2**20)
                if not chunk:break
                h.update(chunk)
        s=path.stat()
        entry={'path':str(path),'exists':True,'size':s.st_size,
               'mtime_iso':datetime.fromtimestamp(s.st_mtime).isoformat(),
               'sha256':h.hexdigest()}
        if path.suffix=='.dylib':
            # Check a distinctive Stage 34 string *without* copying executable bytes.
            # A present string is not proof the corresponding dylib is loaded.
            token=b'vitrine.legacyFingerHighlight'
            try:
                with path.open('rb') as f:
                    data=f.read()
                entry['contains_stage34_press_animation_key']=token in data
                entry['contains_stage35_rim_layer_name']=b'Vitrine.LegacyLensLongSpecular' in data
                entry['contains_legacy_lens_finger_layer']=b'Vitrine.LegacyLensFingerHighlight' in data
            except Exception as exc:entry['probe_error']=repr(exc)
        return entry
    except Exception as exc:return {'path':str(path),'error':repr(exc)}


def binary_audit(root, repo, udid):
    """Non-mutating fingerprint of local object & installed sim app dylib.

    It can detect stale builds; no claim that a matching filesystem image
    establishes that the process loaded that exact dylib.
    """
    folders=[repo/'tweak/.theos/obj-sim/arm64',repo/'out/sim/9.1.90']
    candidates=[]
    for folder in folders:
        if not folder.exists():continue
        for p in folder.rglob('spotifyglass.dylib'):
            candidates.append(p)
        if len(candidates)>25:break
    detected={}
    get_app=cmd_capture(['xcrun','simctl','get_app_container',udid,
                         'com.spotify.client','app'],timeout=20)
    detected['app_container_query']=get_app
    if get_app.get('exit')==0:
        app=Path(get_app.get('stdout','').strip())
        if app.is_dir():
            for sub in ('Frameworks/spotifyglass.dylib','spotifyglass.dylib',
                        'Frameworks/libvitrinesim.dylib'):
                candidates.append(app/sub)
    seen=set();fingerprints=[]
    for p in candidates:
        if str(p) in seen:continue
        seen.add(str(p))
        entry=digest_file(p,root)
        if entry.get('exists'):fingerprints.append(entry)
    detected['fingerprints']=fingerprints
    hashes={e['sha256'] for e in fingerprints if e['path'].endswith('spotifyglass.dylib')}
    detected['spotifyglass_unique_sha256_count']=len(hashes)
    detected['note']='Hashes are evidence only. Source and on-disk binary match cannot prove currently running process loaded this image.'
    save_json(root/'repo-source/binary-audit.json',detected)
    return detected


def source_and_stage34_audit(root,repo,udid18):
    meta=read_sources(root,repo)
    branch=meta.get('branch',{}).get('stdout','').strip()
    if branch!='vitrine-legacy-glass-fixes':
        raise MissingEvidence('Expected vitrine-legacy-glass-fixes, got '+branch)
    src=repo/'tweak/Sources/Redesigned/Navbar/TabBarLens.m'
    body=src.read_text(errors='replace') if src.is_file() else ''
    checks={
       'stage34_setFingerHighlightPressed_present':'setFingerHighlightPressed:' in body,
       'stage34_animation_key_present':'vitrine.legacyFingerHighlight' in body,
       'finger_highlight_layer_present':'Vitrine.LegacyLensFingerHighlight' in body,
       'legacy_drop_playback_present':'dropGlassAfterPlayback' in body,
       'lens_pose_handler_present':'applyPose' in body,
       'stage35_rim_layer_present':'Vitrine.LegacyLensLongSpecular' in body,
       'stage35_drop_sample_threshold_present':'sawRaisedGlass' in body,
       'stage35_long_specular_path_present':'_longSpecular.path = specular.CGPath' in body,
    }
    sha=digest_file(src,root)
    state={'checks':checks,'source_fingerprint':sha,
           'stage34_source_present':all(checks[k] for k in (
               'stage34_setFingerHighlightPressed_present','stage34_animation_key_present')),
           'warning':'This checks git working sources, not the loaded iOS app.',
           'repo_git_metadata':meta}
    lines=body.splitlines()
    for label, start, end in [('rim-geometry',380,436),('drop-timer',456,494),
                              ('release-handler',721,753),('playback',1060,1194)]:
        save_text(root/'repo-source'/f'{label}-source.txt',
            ''.join(f'{i+1:4d}: {lines[i]}\n' for i in range(start-1,min(end,len(lines)))))
    save_json(root/'repo-source/stage34-source-audit.json',state)
    installed=binary_audit(root,repo,udid18)
    return {'source':state,'installed':installed}


def zip_outputs(root):
    archive=root.with_suffix('.zip')
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=5) as z:
        for p in sorted(root.rglob('*')):
            if p.is_file():z.write(p,p.relative_to(root))
    return archive


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test',action='store_true',
                   help='Run offline checks without a simulator or repo')
    p.add_argument('--port26',type=int,default=8086)
    p.add_argument('--port18',type=int,default=8087)
    p.add_argument('--udid26',default='B8E2A0A5-3BE4-4B47-BBAE-095D64219EBA')
    p.add_argument('--udid18',default=DEFAULT_UDID)
    args=p.parse_args()
    if args.self_test:
        self_test_stage36()
        return
    repo=Path.cwd()
    if not (repo/'scripts/phone.py').is_file():
        p.error('Run from ~/Downloads/spoti-fork, with scripts/phone.py available')
    root=repo/'out'/('stage36-rim-and-release-evidence-'+datetime.now().strftime('%Y%m%d-%H%M%S'))
    root.mkdir(parents=True,exist_ok=False)
    sessions=[Stage36(root,'ios26',args.port26,args.udid26,True),
              Stage36(root,'ios18',args.port18,args.udid18,False)]
    mandatory=['preflight/h264',
        'short-taps/selected-search-center',
        'short-taps/search-to-library',
        'short-taps/library-to-search',
        'release/hold-search-then-release',
        'held-geometry/hold-search',
        'held-geometry/hold-your-library']
    failure=None
    stage34=None
    try:
        stage34=source_and_stage34_audit(root,repo,args.udid18)
        for session in sessions:session.preflight()
        if not prompt('STEP 1/1: Open Spotify on BOTH simulators with the NORMAL FOUR-TAB bar (Home, Search, Your Library, Create) and the desired dark theme. Close Create menus. The script captures two rim holds, three taps, and a 2.4s hold/release with targeted flash analysis. Do not touch the simulators during the run.'):
            raise MissingEvidence('User stopped before capturing mandatory video.')
        for session in sessions:session.run_all()
        for session in sessions:
            session.flash_reports=analyze_all_flash_videos(session)
        for session in sessions:
            seen={str(Path(v['path']).relative_to(session.root).parent)
                  for v in session.videos if v.get('ok')}
            missing=[tag for tag in mandatory if tag not in seen]
            if missing:raise MissingEvidence(f'{session.name}: missing verified MP4: {missing}')
            for tag in mandatory[1:]:
                if tag!='preflight/h264':
                    folder=session.root/tag/'during'
                    if not folder.is_dir() or not list(folder.glob('frame*.png')):
                        raise MissingEvidence(f'{session.name}: no timed during frames for {tag}')
        if not (stage34['source']['stage34_source_present'] and
                stage34['source']['checks']['stage35_rim_layer_present'] and
                stage34['source']['checks']['stage35_drop_sample_threshold_present']):
            raise MissingEvidence('Expected Stage35 rim/drop source markers absent; review source before diagnosing')
        if not stage34['source']['stage34_source_present']:
            raise MissingEvidence('Stage 34 code markers absent from current source; possible wrong branch or patch not applied')
    except BaseException as exc:
        failure=f'{type(exc).__name__}: {exc}'
        print('DIAGNOSTIC INCOMPLETE:',failure,flush=True)
        save_text(root/'error-traceback.txt',traceback.format_exc())
    finally:
        for session in sessions:
            if session.recorder:session.stop_record(validate=False)
        summary={'status':'INCOMPLETE' if failure else 'CAPTURED_NEEDS_VISUAL_REVIEW',
                 'error':failure,'created':datetime.now().isoformat(),
                 'required_videos_per_system':mandatory,
                 'focus':['RIM: where is strongest light? left upper arc versus upper horizontal rail; right lower arc versus lower horizontal rail',
                          'RELEASE: first frame after glass bubble reaches final tab size and center',
                          'RELEASE: first frame after selected-tab light platter replaces raised glass',
                          'FLASH: check for a transient white pulse LOCALIZED at the same tab exactly during glass-to-platter material swap',
                          'FLASH: compare MP4 and flash-analysis.json/csv for short taps and long hold; a peak is only a candidate',
                          'Compare millisecond delay between those two events on iOS 26 and Legacy iOS 18'],
                 'metrics_requiring_visual_review': {
                     'ios26': {'rim_top_left_vs_top_rail':None, 'rim_bottom_right_vs_bottom_rail':None,
                         'arrival_to_platter_ms':None, 'flash_during_material_swap':None},
                     'ios18': {'rim_top_left_vs_top_rail':None, 'rim_bottom_right_vs_bottom_rail':None,
                         'arrival_to_platter_ms':None, 'flash_during_material_swap':None}},
                 'interpretation':'Captured artifacts are not PASS criteria. Upload archive for frame-level evaluation before any tweak patch.',
                 'stage34_source_present':stage34['source']['stage34_source_present'] if stage34 else None,
                 'flash_audit':{s.name:getattr(s,'flash_reports',{}) for s in sessions},
                 'sessions':{s.name:{'videos':s.videos,'completed':s.completed,'warnings':s.warnings}
                             for s in sessions}}
        save_json(root/'summary.json',summary)
        save_text(root/'README.txt',
          'Stage 36: three real /tap tests, two long-held rim tests and one held release per system.\n'
          'Rim: compare left-upper and right-lower shoulder brightness to the horizontal top/bottom rails.\n'
          'Release: mark arrival frame and glass-to-platter transition frame; calculate their gap in ms.\n'
          'Flash: inspect a short bright pulse at the selected tab EXACTLY when glass becomes the platter.\n'
          'If ffmpeg and ffprobe exist, flash-analysis.json and flash-luminance-series.csv provide\n'
          'an indicative per-frame brightness audit (not a confirmed event or automatic PASS).\n'
          'Installed dylib fingerprint is optional: mismatch may indicate stale deployment.\n'
          'If status INCOMPLETE, no tweak patch. Existing videos remain in archive.\n')
        archive=zip_outputs(root)
        print('\nUpload this ZIP:',archive,flush=True)
        print('CAPTURE STATUS:',summary['status'],flush=True)
        for session in sessions:
            flash=getattr(session,'flash_reports',{})
            print('  '+session.name+' flash candidates: '+', '.join(
                tag.split('/')[-1]+'='+item.get('status','?') for tag,item in flash.items()),flush=True)
    if failure:raise SystemExit(2)

if __name__=='__main__':main()
