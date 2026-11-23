#!/usr/bin/env python3
"""Stage 188: unattended, frame-by-frame evidence for iOS 26 Spotify menu morphs.

No monkey patches, no private SDK downloads, no menu renderer changes.
Driver: SG_DRIVER 8088 for iOS 26, 8087 for iOS 18 (optional comparison).
Video: xcrun simctl io ... recordVideo, every *recorded* frame exported with ffmpeg.
Independent layers pass: driven on a separate take to avoid impacting video timing.

Usage:
  python3 scripts/diagnostics/stage188-ios26-menu-morph-capture.py --port26 8088
  python3 scripts/diagnostics/stage188-ios26-menu-morph-capture.py --compare --port26 8088 --port18 8087
  python3 scripts/diagnostics/stage188-ios26-menu-morph-capture.py --self-test

Requires macOS Xcode Simulator, ffmpeg, ffprobe, and a Spotify SG_DRIVER build.
Optional numpy + opencv-python enable rough *image-derived proxies*, not shader recovery.
Does NOT control the native Photos app; that requires a separate XCUITest driver.
"""
from __future__ import annotations

import argparse
import base64
import csv
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from zipfile import ZipFile, ZIP_DEFLATED

DEFAULT_18 = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
CASES = ('root-open', 'root-close', 'more-open', 'more-close', 'home-open', 'home-close')
ROOT = Path(__file__).resolve().parents[2]


class EvidenceError(RuntimeError):
    pass


def save_json(p, data):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2, default=str) + '\n', encoding='utf-8')


def save_text(p, value):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(value, encoding='utf-8')


def run(cmd, timeout=60, check=True):
    proc = subprocess.run([str(x) for x in cmd], text=True, capture_output=True, timeout=timeout)
    result = {'argv': [str(x) for x in cmd], 'returncode': proc.returncode,
              'stdout': proc.stdout[-8000:], 'stderr': proc.stderr[-8000:]}
    if check and proc.returncode != 0:
        raise EvidenceError(f'command failed: {cmd}: {result}')
    return result


def stamp():
    return dt.datetime.now().astimezone().isoformat(timespec='milliseconds')


def clock():
    return {'iso8601': stamp(), 'monotonic_ns': time.monotonic_ns()}


class Driver:
    def __init__(self, port):
        self.port = port

    def call(self, command, **params):
        suffix = urllib.parse.urlencode({k: str(v) for k, v in params.items()}, quote_via=urllib.parse.quote)
        url = f'http://127.0.0.1:{self.port}/{urllib.parse.quote(command)}' + ('?' + suffix if suffix else '')
        request = urllib.request.Request(url, headers={'X-Phone-Driver': '1'})
        try:
            with urllib.request.urlopen(request, timeout=35) as response:
                raw = response.read()
        except Exception as exc:
            raise EvidenceError(f'SG_DRIVER port {self.port}, {command}: {exc}') from exc
        if command == 'tree':
            text = raw.decode('utf-8', 'replace')
            if len(text) < 80:
                raise EvidenceError(f'empty or incomplete tree from port {self.port}')
            return text
        try:
            obj = json.loads(raw)
        except ValueError as exc:
            raise EvidenceError(f'invalid {command} response on port {self.port}: {raw[:240]!r}') from exc
        if not isinstance(obj, dict) or obj.get('ok') is not True:
            raise EvidenceError(f'SG_DRIVER {self.port} {command} failed: {str(obj)[:600]}')
        return obj

    def menu(self):
        return bool(self.call('state').get('menu'))


def sim_devices():
    data = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json'])['stdout'])
    found = []
    for runtime, items in data.get('devices', {}).items():
        for d in items:
            if d.get('state') == 'Booted':
                found.append({'udid': d['udid'], 'name': d.get('name'), 'runtime': runtime})
    return found


def resolve_sim(devices, major, explicit):
    if explicit:
        matches = [d for d in devices if d['udid'] == explicit]
        if not matches:
            raise EvidenceError(f'--udid{major} {explicit} is not booted: {devices}')
        found = matches[0]
    else:
        matches = [d for d in devices if re.search(rf'iOS[-_]{major}(?:[-_.]|$)', d['runtime'])]
        if len(matches) != 1:
            raise EvidenceError(f'expected exactly one booted iOS {major} simulator, found {matches}. Pass --udid{major}.')
        found = matches[0]
    if not re.search(rf'iOS[-_]{major}(?:[-_.]|$)', found['runtime']):
        raise EvidenceError(f'UDID {found["udid"]} is NOT iOS {major}: {found["runtime"]}')
    return found


def safe_external_tap(driver):
    # At the far LEFT of the screen (outside the player popup at the upper right).
    # Never target a menu row, play/pause, or the tabbar. Verify dismissal afterwards.
    for p in ('7,360', '7,515', '7,260'):
        driver.call('tap', at=p)
        time.sleep(.20)
        if not driver.menu():
            return
    raise EvidenceError('menu still visible after outside taps; refusing to continue or pick random actions')


def prepare(driver, case):
    state = driver.call('state')
    if state.get('menu'):
        safe_external_tap(driver)
    if case.startswith('home-'):
        driver.call('tab', arg='0')
        time.sleep(.40)
        buttons = driver.call('find', label='Filter Home').get('views', [])
        buttons = [b for b in buttons if b.get('shown') is not False]
        if not buttons:
            raise EvidenceError('Home Filter button not visible; cannot reproduce Home menu')
        if case == 'home-close':
            driver.call('tap', label='Filter Home')
            time.sleep(.65)
            if not driver.menu():
                raise EvidenceError('Home menu failed to open during preparation')
    else:
        if not driver.call('state').get('player'):
            driver.call('player.open')
            time.sleep(.40)
        if not driver.call('state').get('player'):
            raise EvidenceError('player not open; a loaded Spotify track may be required')
        if case != 'root-open':
            driver.call('player.more')
            time.sleep(.65)
            if not driver.menu():
                raise EvidenceError('root menu failed to open during preparation')
        if case == 'more-close':
            driver.call('menu.pick', title='More')
            time.sleep(.65)
            if not driver.menu():
                raise EvidenceError('submenu not visible during preparation')
    time.sleep(.30)
    return driver.call('state')


def event(driver, case):
    if case == 'root-open':
        return driver.call('player.more')
    if case == 'root-close':
        return driver.call('tap', at='7,360')
    if case == 'more-open':
        return driver.call('menu.pick', title='More')
    if case == 'more-close':
        return driver.call('tap', at='7,360')
    if case == 'home-open':
        return driver.call('tap', label='Filter Home')
    if case == 'home-close':
        return driver.call('tap', at='7,360')
    raise ValueError(case)


def expect_menu(case):
    return case.endswith('-open')


def collect_snapshot(driver, directory):
    directory.mkdir(parents=True, exist_ok=True)
    failures = {}
    for name, params in [('state', {}), ('tree', {}), ('find', {'id': 'Context menu'}),
                         ('find', {'label': 'Filter Home'}),
                         ('find', {'class': '_UIContextMenuView'}),
                         ('find', {'class': 'SGRDropdownPanel'})]:
        dest = 'tree.txt' if name == 'tree' else (name + ('-'+(params.get('id') or params.get('label') or params.get('class') or '').replace(' ','-') if params else '')+'.json')
        try:
            result = driver.call(name, **params)
            if name == 'tree':
                save_text(directory / dest, result)
            else:
                save_json(directory / dest, result)
        except Exception as exc:
            failures[dest] = str(exc)
    for selector in ({'id': 'Context menu'}, {'label': 'Filter Home'},
                     {'class': '_UIContextMenuView'}, {'class': 'SGRDropdownPanel'}):
        tag = '-'.join(selector.values()).replace(' ', '-')
        try:
            result = driver.call('find', **selector)
            if result.get('views'):
                save_json(directory / ('layers-'+tag+'.json'), driver.call('layers', depth=8, **selector))
        except Exception as exc:
            failures['layers-'+tag] = str(exc)
    try:
        png = driver.call('screenshot').get('png')
        if png:
            (directory/'screenshot.png').write_bytes(base64.b64decode(png))
    except Exception as exc:
        failures['screenshot'] = str(exc)
    if failures:
        save_json(directory/'probe-failures.json', failures)


def capture_video(udid, output, action, head=.38, tail=1.0):
    output.parent.mkdir(parents=True, exist_ok=True)
    cmd = ['xcrun', 'simctl', 'io', udid, 'recordVideo', '--codec=h264', '--force', str(output)]
    stderr = output.with_suffix('.capture.log')
    with stderr.open('wb') as err:
        proc = subprocess.Popen(cmd, stdout=err, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            time.sleep(head)
            if proc.poll() is not None:
                raise EvidenceError(f'recordVideo exited early {proc.returncode}: {stderr.read_text(errors="replace")[-900:]}')
            trigger = clock()
            try:
                result = action()
                action_error = None
            except Exception as exc:
                result = None
                action_error = repr(exc)
            done = clock()
            time.sleep(tail)
            return {'start_expected_before': trigger, 'action_returned': done,
                    'action_result': result, 'action_error': action_error,
                    'recording_command': cmd}
        finally:
            if proc.poll() is None:
                # Simulator CLI finalizes the MP4 on SIGINT.
                try:
                    os.killpg(proc.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait(timeout=5)
            if not output.exists() or output.stat().st_size < 4096:
                raise EvidenceError(f'recordVideo output absent/truncated: {output}; log: {stderr.read_text(errors="replace")[-1000:]}')


def extract_frames(video, dest, max_frames):
    dest.mkdir(parents=True, exist_ok=True)
    probe = run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                 'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames:format=duration',
                 '-of', 'json', str(video)])
    detail = json.loads(probe['stdout'])
    report = {'ffprobe': detail, 'video_bytes': video.stat().st_size}
    frame_data = run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_frames',
                      '-show_entries', 'frame=best_effort_timestamp_time,pkt_duration_time',
                      '-of', 'json', str(video)], timeout=120)
    frame_list = json.loads(frame_data['stdout']).get('frames', [])
    save_json(dest/'timestamps.json', {'note': 'PTS is relative to recording; not aligned to SG_DRIVER host monotonic clock',
                                      'frames': frame_list})
    # -vsync 0 preserves variable-rate frames. Never use an fps filter: it duplicates/drops frames.
    limit = ['-frames:v', str(max_frames)] if max_frames else []
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(video),
           '-map', '0:v:0', '-vsync', '0', *limit, '-start_number', '0', str(dest/'frame_%06d.png')]
    run(cmd, timeout=240)
    n = len(list(dest.glob('frame_*.png')))
    report.update(decoded_frames=n, timestamps_in_video=len(frame_list),
                  note='Frames are every frame that simctl RECORDS, not guaranteed every 120-Hz compositor refresh')
    if not n:
        raise EvidenceError(f'no extracted frames: {video}')
    save_json(dest/'video-metadata.json', report)
    return report


def analyze(frames_dir, results_dir):
    """Image proxies: not a reconstruction of UIKit materials or Metal shader coefficients."""
    try:
        import cv2
        import numpy as np
    except ImportError as exc:
        save_text(results_dir/'analysis-dependency.txt',
                  f'{exc}\nVideo+frames+timestamps are complete. For optional metrics: python3 -m pip install numpy opencv-python\n')
        return {'available': False, 'reason': str(exc)}
    frames = sorted(frames_dir.glob('frame_*.png'))
    reference = cv2.imread(str(frames[0]))
    if reference is None:
        return {'available': False, 'reason': 'frame decode failed'}
    scale = min(1., 640./max(reference.shape[:2]))
    def resize(im):
        return cv2.resize(im, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else im
    reference = resize(reference)
    gray_ref = cv2.cvtColor(reference, cv2.COLOR_BGR2GRAY)
    h,w = gray_ref.shape
    previous_gray = gray_ref
    metrics = []
    for i, fn in enumerate(frames):
        frame = cv2.imread(str(fn))
        if frame is None: continue
        frame = resize(frame)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        diff = cv2.absdiff(frame, reference)
        diff_gray = cv2.cvtColor(diff, cv2.COLOR_BGR2GRAY)
        smooth = cv2.GaussianBlur(diff_gray, (5,5), 0)
        _, changed = cv2.threshold(smooth, 17, 255, cv2.THRESH_BINARY)
        changed = cv2.morphologyEx(changed, cv2.MORPH_CLOSE, np.ones((7,7), np.uint8))
        contours, _ = cv2.findContours(changed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        contours = [c for c in contours if cv2.contourArea(c) > w*h*.001]
        box = (0,0,0,0)
        area = 0
        shape_compactness = 0
        if contours:
            major = max(contours, key=cv2.contourArea)
            box = cv2.boundingRect(major)
            area = float(cv2.contourArea(major))
            perimeter = float(cv2.arcLength(major, True))
            shape_compactness = 4*3.14159265359*area/max(1.,perimeter*perimeter)
        x,y,bw,bh = box
        inner = gray[y:y+bh, x:x+bw] if bw>0 and bh>0 else gray
        # Bright rim/glow proxy from a 5px ring, minus an adjacent outside ring.
        edge_glow = 0.
        highlight_fraction = 0.
        chromatic_rim = 0.
        top_rim = bottom_rim = left_rim = right_rim = 0.
        if bw>14 and bh>14:
            rim = np.zeros_like(gray,dtype=np.uint8)
            cv2.rectangle(rim,(x,y),(min(w-1,x+bw-1),min(h-1,y+bh-1)),255,4)
            outer = cv2.dilate(rim, np.ones((13,13),np.uint8))
            ring = (outer>0) & (rim==0)
            edge_glow = float(np.mean(gray[rim>0])-np.mean(gray[ring])) if ring.any() else 0.
            rim_pixels = frame[rim>0].astype(np.float32)
            highlight_fraction = float(np.mean(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)[rim>0]>210))
            chromatic_rim = float(np.mean(np.max(rim_pixels, axis=1)-np.min(rim_pixels, axis=1)))
            th = max(1, min(4, bh//8)); tw = max(1, min(4, bw//8))
            top_rim = float(np.mean(gray[y:y+th,x:x+bw]))
            bottom_rim = float(np.mean(gray[y+bh-th:y+bh,x:x+bw]))
            left_rim = float(np.mean(gray[y:y+bh,x:x+tw]))
            right_rim = float(np.mean(gray[y:y+bh,x+bw-tw:x+bw]))
        # Pixel shift of background texture: optical-flow magnitude is merely a proxy.
        flow = cv2.calcOpticalFlowFarneback(previous_gray, gray, None, .5, 3, 15, 3, 5, 1.2, 0)
        magnitude = np.linalg.norm(flow, axis=2)
        if bw>0 and bh>0:
            roi_flow = magnitude[y:y+bh,x:x+bw]
            flow_median = float(np.median(roi_flow))
        else:
            flow_median = 0.
        entry = dict(frame=i, bbox_x=x, bbox_y=y, bbox_w=bw, bbox_h=bh,
                     relative_center_x=round((x+bw/2)/w,5),relative_center_y=round((y+bh/2)/h,5),
                     change_fraction=round(float(np.mean(changed>0)),5),
                     mask_area=round(area,2), shape_compactness_proxy=round(shape_compactness,5),
                     ref_difference_mean=round(float(np.mean(diff_gray)),4),
                     local_luminance=round(float(np.mean(inner)),4),
                     edge_glow_proxy=round(edge_glow,4),
                     highlight_fraction_proxy=round(highlight_fraction,5),
                     rim_chroma_proxy=round(chromatic_rim,4),
                     top_rim_luma=round(top_rim,4), bottom_rim_luma=round(bottom_rim,4),
                     left_rim_luma=round(left_rim,4), right_rim_luma=round(right_rim,4),
                     moving_texture_flow_proxy=round(flow_median,5))
        metrics.append(entry)
        previous_gray = gray
    if not metrics:
        return {'available': False, 'reason': 'no usable frames'}
    results_dir.mkdir(parents=True, exist_ok=True)
    with (results_dir/'frame-metrics.csv').open('w',newline='') as f:
        wtr=csv.DictWriter(f, fieldnames=list(metrics[0]))
        wtr.writeheader();wtr.writerows(metrics)
    save_json(results_dir/'frame-metrics.json', metrics)
    result = {'available': True, 'frames': len(metrics), 'scaled_dimensions': [w,h],
              'warning': 'Differences, bounding boxes, glow and optical flow are HEURISTICS, not the true glass contour, alpha, corner radius or physical refraction. Spotify content can animate underneath the menu.'}
    save_json(results_dir/'summary.json', result)
    return result


def layer_probe(driver, case, folder):
    """Second, intrusive take: only layer hierarchy; not used for visual timing."""
    prepare(driver, case)
    samples = []
    t0 = time.monotonic()
    outcome = {'case': case, 'samples': samples, 'take': 'secondary; may perturb UIKit timing'}
    # Trigger via a separate thread, so main thread is allowed to render between polls.
    import threading
    failure = []
    def trigger():
        try: event(driver, case)
        except Exception as exc: failure.append(repr(exc))
    t = threading.Thread(target=trigger, daemon=True)
    t.start()
    while time.monotonic()-t0 < .85:
        entry = {'ms': round((time.monotonic()-t0)*1000,3)}
        for label,selector in [('native',{'class':'_UIContextMenuView'}),('legacy',{'class':'SGRDropdownPanel'})]:
            try:
                found = driver.call('find', **selector).get('views', [])
                entry[label] = [{'class':v.get('class'), 'frame':v.get('frame'),
                                 'alpha':v.get('alpha'), 'shown':v.get('shown')} for v in found]
            except Exception as exc:
                entry[label+'Error'] = str(exc)[:160]
        samples.append(entry)
        time.sleep(.015)
    t.join(timeout=4)
    outcome['errors'] = failure
    save_json(folder/'layer-samples.json', outcome)
    return outcome


def take(driver, device, case, directory, trial, include_layer_probe=False, max_frames=0):
    where = directory/case/f'trial-{trial:02d}'
    where.mkdir(parents=True, exist_ok=True)
    report = {'case': case, 'trial': trial, 'device': device, 'port': driver.port,
              'status': 'INCOMPLETE', 'begin': clock()}
    try:
        report['prepared'] = prepare(driver, case)
        collect_snapshot(driver, where/'before')
        video = where/'capture.mp4'
        report['event'] = capture_video(device['udid'], video, lambda: event(driver, case))
        if report['event']['action_error']:
            raise EvidenceError(report['event']['action_error'])
        collect_snapshot(driver, where/'after')
        state = driver.call('state')
        report['final_state'] = state
        if bool(state.get('menu')) != expect_menu(case):
            raise EvidenceError(f'menu visibility unexpected: {state.get("menu")}, expected {expect_menu(case)}')
        report['frames'] = extract_frames(video, where/'frames', max_frames)
        report['analysis'] = analyze(where/'frames', where/'analysis')
        report['status'] = 'RECORDED_NOT_YET_MATCHED'
        if include_layer_probe and trial == 1:
            try:
                report['layer_probe'] = layer_probe(driver, case, where/'secondary-take')
            except Exception as exc:
                report['layer_probe_error'] = repr(exc)
    except Exception as exc:
        report['error'] = repr(exc)
        try:
            collect_snapshot(driver, where/'failure')
        except Exception as nested:
            report['snapshot_error'] = repr(nested)
    report['end'] = clock()
    save_json(where/'report.json', report)
    print(f'  {case}/trial-{trial:02}: {report["status"]}' + (' ' + report.get('error','')[:110] if report.get('error') else ''), flush=True)
    return report


def self_test():
    assert resolve_sim([{'udid':'a','runtime':'com.apple.CoreSimulator.SimRuntime.iOS-26-3','name':'x'}],26,None)['udid']=='a'
    assert resolve_sim([{'udid':'b','runtime':'com.apple.CoreSimulator.SimRuntime.iOS-18-6','name':'y'}],18,'b')['udid']=='b'
    try:
        resolve_sim([{'udid':'a','runtime':'com.apple.CoreSimulator.SimRuntime.iOS-26-3'}],18,None)
        raise AssertionError('major-version mismatch was accepted')
    except EvidenceError: pass
    assert expect_menu('home-open') is True
    assert expect_menu('more-close') is False
    assert len(CASES)==6
    print('PASS: argument, simulator runtime and case validation')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port26',type=int,default=8088)
    parser.add_argument('--port18',type=int,default=8087)
    parser.add_argument('--udid26',help='required if multiple iOS 26 simulators are booted')
    parser.add_argument('--udid18',default=DEFAULT_18)
    parser.add_argument('--compare',action='store_true',help='capture same cases on iOS 18; does not change renderer')
    parser.add_argument('--cases',nargs='+',choices=CASES,default=list(CASES))
    parser.add_argument('--trials',type=int,default=2)
    parser.add_argument('--layers-pass',action='store_true',help='secondary per-sample UI hierarchy pass, separate from primary video')
    parser.add_argument('--max-frames',type=int,default=0,help='0=all recorded frames, otherwise cap extraction (do not use for comparison)')
    parser.add_argument('--out',type=Path,default=Path('out'))
    parser.add_argument('--zip',action='store_true',help='zip every file after capture; can be large')
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args(argv)
    if args.self_test:
        self_test();return 0
    if args.trials<1 or args.trials>20:
        parser.error('--trials must be 1..20')
    for needed in ('xcrun','ffmpeg','ffprobe'):
        if not shutil.which(needed):
            parser.error(f'missing {needed}; install Xcode Command Line Tools and ffmpeg as appropriate')
    devices=sim_devices()
    targets=[('ios26',resolve_sim(devices,26,args.udid26),Driver(args.port26))]
    if args.compare:
        targets.append(('ios18',resolve_sim(devices,18,args.udid18),Driver(args.port18)))
    out=args.out/f'stage188-menu-morph-{dt.datetime.now():%Y%m%d-%H%M%S}'
    out.mkdir(parents=True,exist_ok=True)
    configuration={'cases':args.cases,'trials':args.trials,'secondary_layer_pass':args.layers_pass,
                   'targets':[{'label':label,'device':device,'port':d.port} for label,device,d in targets],
                   'host':sys.platform,'started':clock(),
                   'caveat':'video yields all *recorded* frames, not guaranteed 120Hz; no full shader derivation or iOS18 morph implementation'}
    save_json(out/'configuration.json',configuration)
    reports=[]
    for label,device,driver in targets:
        print(f'=== {label}: {device["name"]}, {device["udid"]}, SG_DRIVER {driver.port} ===',flush=True)
        try:
            save_json(out/label/'preflight.json',driver.call('state'))
            for case in args.cases:
                for trial in range(1,args.trials+1):
                    reports.append({'label':label,**take(driver,device,case,out/label,trial,args.layers_pass,args.max_frames)})
        except Exception as exc:
            reports.append({'label':label,'status':'INCOMPLETE','error':repr(exc)})
    save_json(out/'report.json',{'reports':reports,'finished':clock(),
                               'ready_for_matching':all(x.get('status')=='RECORDED_NOT_YET_MATCHED' for x in reports),
                               'renderer_changed':False})
    print('REPORT:',(out/'report.json').resolve(),flush=True)
    if args.zip:
        archive=out.with_suffix('.zip')
        with ZipFile(archive,'w',ZIP_DEFLATED,compresslevel=4) as z:
            for p in out.rglob('*'):
                if p.is_file(): z.write(p,p.relative_to(out.parent))
        print('ARCHIVE:',archive.resolve(),flush=True)
    return 0 if all(x.get('status')=='RECORDED_NOT_YET_MATCHED' for x in reports) else 2


if __name__=='__main__':
    sys.exit(main())
