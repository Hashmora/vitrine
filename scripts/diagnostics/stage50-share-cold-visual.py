#!/usr/bin/env python3
"""Stage 50 — strict first-open Share vs warm presentation and More layer audit.

Read-only; does not install/reset Spotify, change UI/preferences, or trigger taps.
The operator opens Share only after recording has started and the GO prompt.
A video without a verified closed->Share window transition is INCOMPLETE,
not evidence of the first-presentation animation. Standard library only.
"""
from __future__ import annotations
import argparse
import csv
import datetime as dt
import json
import math
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zipfile

UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
ROW = re.compile(r'^\s*_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer\s+\{\{[^}]+\},\s*\{\s*([\d.]+),\s*([\d.]+)\}\}')
GRAPHIC = re.compile(r'^\s*SwiftUI\._UIGraphicsView\s+\{\{\s*([\d.]+),\s*([\d.]+)\s*\},\s*\{\s*([\d.]+),\s*([\d.]+)\s*\}\}')
SHARE_CLASS = 'Share_MenuImpl.NativeShareMenuViewController'


def run(args, timeout=30):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return {'cmd':args, 'code':p.returncode, 'stdout':p.stdout[-8000:], 'stderr':p.stderr[-8000:]}
    except Exception as e:
        return {'cmd':args, 'code':-1, 'error':repr(e)}


def save(path, value):
    path=Path(path);path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2,default=str)+'\n',encoding='utf-8')


def share_visible(state):
    # A controller merely listed in the hierarchy isn't enough; it must be top.
    return isinstance(state,dict) and state.get('ok') is not False and state.get('top')==SHARE_CLASS


def analyze_more(tree):
    """Extract the actual off-platform row, not the similarly named first row."""
    lines=tree.splitlines()
    starts=[i for i,l in enumerate(lines) if 'OffPlatformSectionElement' in l]
    if len(starts)!=1:
        return {'ok':False,'reason':'Expected exactly one OffPlatformSectionElement','count':len(starts)}
    start=starts[0]; n=len(lines[start])-len(lines[start].lstrip())
    block=[lines[start]]
    for line in lines[start+1:]:
        if line.strip() and len(line)-len(line.lstrip())<=n:break
        block.append(line)
    rows=[list(map(float,m.groups())) for s in block if (m:=ROW.match(s))]
    graphics=[list(map(float,m.groups())) for s in block if (m:=GRAPHIC.match(s))]
    graphics=[g for g in graphics if abs(g[1]-8)<3 and abs(g[2]-56)<3 and abs(g[3]-56)<3]
    graphics.sort()
    result={'ok':False, 'rowSizes':rows,'graphicFrames':graphics,
            'glassViews':sum('SGLegacyGlassView' in s for s in block),
            'lineCount':len(block), 'source':'SG_DRIVER /tree, local coordinates'}
    if len(rows)!=1 or len(graphics)<4:
        result['reason']='Off-platform row or four 56pt graphics not visible';return result
    if rows[0][0]<300 or rows[0][1]<90:
        result['reason']='Off-platform row geometry unexpected';return result
    expected=[16,96,176,256]
    if any(abs(graphics[i][0]-expected[i])>3 for i in range(4)):
        result['reason']='More cannot be unambiguously located; compare all candidate graphics';return result
    result['ok']=True
    result['moreFrame']=graphics[3]
    result['moreGlassVisibleInTree']=result['glassViews']>=2
    result['note']='At least two SGLegacyGlassView children suggest Copy link + More, but only the video confirms optical glass.'
    return result


def mp4_container_check(path):
    """Strict read-only MP4 atom and H.264 sample-description fallback.

    macOS may not have ffprobe. This confirms only that an MP4 with a
    nonempty mdat and an avc1/avc3 track description was recorded; visual
    smoothness still requires reviewing the video. A truncated atom is
    INCOMPLETE, not a successful capture.
    """
    result = {'ok': False, 'verification': 'MP4 atom structure (no decoder)'}
    try:
        path = Path(path)
        size = path.stat().st_size
        if size < 4096:
            raise ValueError('MP4 is too small')
        found = {}
        offset = 0
        with path.open('rb') as f:
            while offset + 8 <= size:
                f.seek(offset)
                size32, kind = struct.unpack('>I4s', f.read(8))
                length = size32
                minimum = 8
                if size32 == 1:
                    length = struct.unpack('>Q', f.read(8))[0]
                    minimum = 16
                elif size32 == 0:
                    length = size - offset
                if length < minimum or length > size - offset:
                    raise ValueError('Truncated/invalid MP4 atom at offset %d' % offset)
                if kind in (b'ftyp', b'moov', b'mdat'):
                    found[kind.decode()] = (offset, length)
                offset += length
            if offset != size:
                raise ValueError('Trailing invalid MP4 bytes')
            if not {'ftyp', 'moov', 'mdat'} <= set(found):
                raise ValueError('Missing required MP4 atoms')
            if found['mdat'][1] < 4096:
                raise ValueError('No usable encoded frames in mdat')
            moov_offset, moov_size = found['moov']
            if moov_size > 32 * 1024 * 1024:
                raise ValueError('Excessively large moov atom')
            f.seek(moov_offset)
            moov = f.read(moov_size)
            if b'avc1' not in moov and b'avc3' not in moov:
                raise ValueError('No H.264 sample description in moov')
        result.update({'ok': True, 'atoms': sorted(found), 'bytes': size,
                       'note': 'Structural verification only; motion and image quality not certified'})
    except Exception as error:
        result['reason'] = repr(error)
    return result


class Driver:
    def __init__(self,port):self.url=f'http://127.0.0.1:{port}'
    def call(self,cmd,**kwargs):
        url=self.url+'/'+urllib.parse.quote(cmd)
        if kwargs:url+='?'+urllib.parse.urlencode(kwargs,quote_via=urllib.parse.quote)
        with urllib.request.urlopen(urllib.request.Request(url,headers={'X-Phone-Driver':'1'}),timeout=20) as r:
            data=r.read().decode('utf-8','replace')
        return data if cmd=='tree' else json.loads(data)


class Capture:
    def __init__(self,args):
        self.args=args; self.root=Path(args.output)
        self.root.mkdir(parents=True,exist_ok=True)
        self.driver=Driver(args.port)
        self.issues=[];self.warnings=[];self.phases=[]

    def maybe(self,name,command,**kwargs):
        try:return self.driver.call(command,**kwargs)
        except Exception as e:
            self.warnings.append(f'{name}: {e!r}')
            return {'ok':False,'error':repr(e)}

    def screenshot(self,dest):
        dest.parent.mkdir(parents=True,exist_ok=True)
        r=run(['xcrun','simctl','io',self.args.udid,'screenshot','--type=png',str(dest)],40)
        save(dest.with_suffix('.cmd.json'),r)
        if r['code']!=0 or not dest.is_file() or dest.stat().st_size<2500:
            self.issues.append('Screenshot failed: '+str(dest));return False
        return True

    def snapshot(self,phase,label):
        p=self.root/phase/label;p.mkdir(parents=True,exist_ok=True)
        state=self.maybe(label,'state');save(p/'state.json',state)
        tree=self.maybe(label,'tree')
        if isinstance(tree,str):
            (p/'tree.txt').write_text(tree,encoding='utf-8')
            save(p/'more-geometry.json',analyze_more(tree) if share_visible(state) else {'ok':False,'reason':'Share is not top controller'})
        else:save(p/'tree-error.json',tree)
        self.screenshot(p/'screen.png')
        for cl in ('_TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer',
                   'SwiftUI._UIGraphicsView','SGLegacyGlassView',
                   'Share_MenuImpl.BottomAutoScrollingScrollView'):
            found=self.maybe(label+'/find','find',**{'class':cl})
            save(p/'find'/f'{cl}.json',found)
            if 'PlatformGroupContainer' in cl and found.get('ok') and found.get('count'):
                for i in range(min(3,int(found['count']))):
                    save(p/'layers'/f'row-{i}.json',self.maybe(label+'/layers','layers',**{'class':cl,'index':i,'depth':10}))
        save(p/'app-log.json',self.maybe(label+'/log','log',since=0))
        return state

    def video(self,phase):
        folder=self.root/phase;folder.mkdir(parents=True,exist_ok=True)
        f=folder/'motion.mp4';log=(folder/'recording.log').open('w')
        args=['xcrun','simctl','io',self.args.udid,'recordVideo','--codec=h264','--force',str(f)]
        proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
        try:
            started=time.monotonic()
            while time.monotonic()-started<15:
                log.flush()
                if proc.poll() is not None:raise RuntimeError('simctl video recorder exited before starting')
                if (folder/'recording.log').exists() and 'Recording started' in (folder/'recording.log').read_text(errors='replace'):
                    return proc,log,f
                time.sleep(.15)
            raise RuntimeError('simctl recordVideo never reported Recording started')
        except Exception:
            if proc.poll() is None:proc.send_signal(signal.SIGINT);proc.wait(timeout=10)
            log.close();raise

    def stop(self,proc,log,video):
        if proc.poll() is None:
            proc.send_signal(signal.SIGINT)
            try:proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.terminate();proc.wait(timeout=10)
        log.close()
        result={'path':str(video),'bytes':video.stat().st_size if video.exists() else 0}
        if result['bytes']<4096:result['ok']=False;result['reason']='MP4 missing or too short'
        else:
            ffprobe=run(['ffprobe','-v','error','-select_streams','v:0',
                         '-show_entries','stream=codec_name,width,height,nb_frames:format=duration',
                         '-of','json',str(video)],35)
            save(video.with_suffix('.ffprobe-command.json'),ffprobe)
            if ffprobe['code']==0:
                try:
                    data=json.loads(ffprobe['stdout']);stream=(data.get('streams') or [{}])[0]
                    result['duration']=float(data.get('format',{}).get('duration') or 0)
                    result['codec']=stream.get('codec_name')
                    result['ok']=result['codec']=='h264' and result['duration']>=1
                except (ValueError,KeyError,TypeError) as e:result['ok']=False;result['reason']=repr(e)
            else:
                # ffprobe is not bundled with macOS. Validate the MP4 atoms
                # structurally and record that no visual decode was performed.
                structural = mp4_container_check(video)
                result.update(structural)
                if structural.get('ok'):
                    self.warnings.append('ffprobe missing: H.264 container structurally valid, visual review required')
        save(video.with_suffix('.verified.json'),result)
        if not result.get('ok'):self.issues.append('Video cannot be verified: '+str(result))
        return result

    def brightness(self,phase,video):
        # Video motion/brightness series supports offline comparison but is not
        # a classifier for UX jerk or a guarantee that Share actually opened.
        if not shutil.which('ffmpeg'):
            self.warnings.append('No ffmpeg: frame brightness comparison omitted');return
        width,height,fps=64,128,12
        cmd=['ffmpeg','-nostdin','-v','error','-i',str(video),'-vf',f'fps={fps},scale={width}:{height},format=gray',
             '-f','rawvideo','-']
        try:
            p=subprocess.run(cmd,capture_output=True,timeout=90)
            if p.returncode!=0:raise RuntimeError(p.stderr.decode(errors='replace')[-2000:])
            raw=p.stdout;size=width*height;prev=None;records=[]
            for i in range(len(raw)//size):
                frame=raw[i*size:(i+1)*size]
                lum=round(sum(frame)/size,3)
                delta=round(sum(abs(a-b) for a,b in zip(frame,prev))/size,3) if prev else 0
                records.append([round(i/fps,4),lum,delta]);prev=frame
            out=self.root/phase/'frame-metrics.csv'
            with out.open('w',newline='') as f:
                w=csv.writer(f);w.writerow(['seconds_from_video_start','average_gray','frame_change']);w.writerows(records)
            save(self.root/phase/'frame-metrics-summary.json',{'frames':len(records),
                    'maxChange':max((x[2] for x in records),default=0),
                    'notice':'Frame-change spikes indicate motion, not necessarily animation bugs.'})
        except Exception as e:self.warnings.append('Frame metrics unavailable: '+repr(e))

    def capture(self,phase,fresh=False):
        tag='cold' if fresh else ('first-after-launch' if phase=='share-first-after-launch' else 'warm')
        print(f'\n[{tag}] Close Share and leave the song context menu with the Share action visible.',flush=True)
        input('Press Enter after the song menu is open, BEFORE tapping Share: ')
        before=self.snapshot(phase,'before')
        if share_visible(before):
            self.issues.append(f'{phase}: Share was already visible BEFORE recording')
            return
        proc=log=video=None; after=None
        try:
            proc,log,video=self.video(phase)
            print('RECORDING STARTED. GO: tap Share, allow the presentation to complete, KEEP Share visible.',flush=True)
            input('Press Enter ONLY AFTER Share is fully visible: ')
            # Verify the *actual* top controller before stopping; old Stage 38
            # recorded a complete cold MP4 without ever opening Share.
            after=self.maybe(phase+'/after','state')
            save(self.root/phase/'state-at-stop.json',after)
            time.sleep(.25)
        finally:
            if proc is not None:
                check=self.stop(proc,log,video)
                self.brightness(phase,video)
            else:check={'ok':False,'reason':'Recorder failed'}
        last=self.snapshot(phase,'after')
        if not share_visible(after) or not share_visible(last):
            self.issues.append(f'{phase}: INCOMPLETE_TRANSITION — Share controller was not top when recording stopped')
        if fresh and not self.args.fresh_install:
            self.issues.append('INCOMPLETE_COLD_NOT_CERTIFIED — first-ever opening not user-confirmed (--fresh-install)')
        geom_path=self.root/phase/'after'/'more-geometry.json'
        geom=json.loads(geom_path.read_text()) if geom_path.exists() else {'ok':False}
        if not geom.get('ok'):
            self.issues.append(f'{phase}: INCOMPLETE_MORE_GEOMETRY — {geom.get("reason", "missing")}' )
        self.phases.append({'phase':tag,'closedBefore':not share_visible(before),
                            'shareAtStop':share_visible(after),'shareAfter':share_visible(last),
                            'videoVerified':check.get('ok',False),
                            'moreGeometryConfirmed':geom.get('ok',False),
                            'moreGlassViewsInTree':geom.get('glassViews',0),
                            'claimedFreshInstall':self.args.fresh_install if fresh else None})

    def finish(self):
        status='INCOMPLETE' if self.issues else 'CAPTURED_REQUIRES_VISUAL_REVIEW'
        result={'status':status,'phases':self.phases,'missing_evidence':self.issues,
                'warnings':self.warnings,'scope':'native Share sheet (Legacy Glass), not OS share sheet',
                'interpretation':'Optical glass and jerk require reviewing videos; a verified transition alone is not a pass.'}
        save(self.root/'report.json',result)
        archive=self.root.with_suffix('.zip')
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=3,allowZip64=True) as z:
            for file in self.root.rglob('*'):
                if file.is_file():z.write(file,file.relative_to(self.root.parent))
        print('\nSTATUS:',status,'\nEvidence ZIP:',archive,flush=True)
        return not self.issues


def self_test():
    assert mp4_container_check(Path('/not/a/real/video.mp4'))['ok'] is False
    sample='''Root {{0, 0}, {402, 874}}
  WrappingSwiftUIViewVV27Share_ShareMenuElementsImpl25OffPlatformSectionElement5State {{0, 0}, {402, 116}}
    _TtCC7SwiftUI17HostingScrollView22PlatformGroupContainer {{0, 0}, {328, 116}}
      SwiftUI._UIGraphicsView {{16, 8}, {56, 56}}
      SwiftUI._UIGraphicsView {{96, 8}, {56, 56}}
      SwiftUI._UIGraphicsView {{176, 8}, {56, 56}}
      SwiftUI._UIGraphicsView {{256, 8}, {56, 56}}
      SGLegacyGlassView {{0, 0}, {56, 56}}
      SGLegacyGlassView {{0, 0}, {56, 56}}
'''
    assert analyze_more(sample)['ok']
    assert analyze_more(sample)['moreFrame'][0]==256
    assert analyze_more(sample.replace('256, 8','336, 8'))['ok'] is False
    assert not share_visible({'top':'NowPlaying'})
    assert share_visible({'top':SHARE_CLASS,'ok':True})
    assert not share_visible({'top':SHARE_CLASS,'ok':False})
    assert urllib.parse.urlencode({'label':'Lyric stickers'},quote_via=urllib.parse.quote)=='label=Lyric%20stickers'
    assert 'INCOMPLETE_FIRST_AFTER_LAUNCH_NOT_CONFIRMED'.startswith('INCOMPLETE')
    print('Self-test: PASSED — row parsing, transition gate, URL encoding')


def main():
    ap=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port',type=int,default=8087);ap.add_argument('--udid',default=UDID)
    ap.add_argument('--output',default='')
    ap.add_argument('--fresh-install',action='store_true',help='Confirm Share has NOT been opened at all since reinstall')
    ap.add_argument('--warm-only',action='store_true',help='Only collect the already-warmed sheet and the More button')
    ap.add_argument('--first-after-launch',action='store_true',help='Record the FIRST Share opening after a full app relaunch, then the warm repeat; do not claim a fresh install')
    ap.add_argument('--self-test',action='store_true')
    args=ap.parse_args()
    if args.self_test:self_test();return 0
    if args.first_after_launch and (args.warm_only or args.fresh_install):
        ap.error('--first-after-launch is exclusive with --warm-only / --fresh-install')
    if not args.output:
        prefix='stage61-share-first-launch-' if args.first_after_launch else 'stage50-share-cold-more-'
        args.output='out/'+prefix+dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    cap=Capture(args)
    save(cap.root/'environment.json',{'head':run(['git','rev-parse','HEAD']),
         'branch':run(['git','branch','--show-current']),
         'time':dt.datetime.now().astimezone().isoformat(),'port':args.port,'udid':args.udid})
    try:
        if args.first_after_launch:
            print('Verify that you COMPLETELY QUIT and restarted Spotify, and have NOT opened Share since then.')
            answer=input('Type FIRST (not Enter) to certify this is the first opening after launch: ').strip()
            if answer != 'FIRST':
                cap.issues.append('INCOMPLETE_FIRST_AFTER_LAUNCH_NOT_CONFIRMED')
                return 0 if cap.finish() else 1
            save(cap.root/'launch-claim.json', {'kind':'first Share after app restart',
                 'confirmedByOperator':True, 'note':'This cannot independently certify a fresh install.'})
        state=cap.driver.call('state')
        if state.get('ok') is False:raise RuntimeError('SG_DRIVER /state returned failure')
        if args.first_after_launch: cap.capture('share-first-after-launch',fresh=False)
        elif not args.warm_only: cap.capture('share-cold',fresh=True)
        cap.capture('share-warm',fresh=False)
    except (KeyboardInterrupt,EOFError):cap.issues.append('Cancelled before completing all phases')
    except Exception as e:
        print('INCOMPLETE:',repr(e),file=sys.stderr)
        cap.issues.append('Fatal: '+repr(e))
    return 0 if cap.finish() else 1


if __name__=='__main__':sys.exit(main())
