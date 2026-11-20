#!/usr/bin/env python3
"""Stage 83 | Native 60Hz evidence for interrupted NPV and Legacy lens (after Stage 82).

One standalone, Python-standard-library-only file. NO patch, build, uninstall,
login, GUI clicks, or user prompts. The SG_DRIVER on port 8087 must include Stage 83 native nav.trace.* commands,
and Stage 77's navbar.mini-state, navbar.minimize and swipe.reverse.

Scenarios:
 npv    interrupted NPV drag, reverse-and-hold and fast reverse in minimized bar
 lens   edge refraction, left/right overtravel and released-glass -> substrate
 accent dual highlighting with accent ON vs OFF (optional)

The report distinguishes a *valid recording* from proven reproduction of a bug.
When the target is absent or a gesture/state cannot be verified, it is INCOMPLETE.
The script restores its three changed prefs and the initial minimized state.
It verifies UITabBarButton hit-testing rather than trusting /tab success.
It can restart Spotify *without uninstalling or clearing user data* when a popup
obscures the tab bar; that recovery uses xcrun simctl terminate + launch.
It may navigate within Spotify and open the Spotify Codes popup; it never scans
or sends a code, changes music playback, or modifies source files.

Run:
  python3 scripts/diagnostics/stage83-native-legacy-nav.py
  python3 scripts/diagnostics/stage83-native-legacy-nav.py --self-test
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

DEFAULT_UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
HIDE = 'spotifyglass.redesign.navbar.hideLabels'
ACCENT = 'spotifyglass.redesign.tabbar.accent'
CODES = 'spotifyglass.redesign.search.spotifyCodes'
PREFS = (HIDE, ACCENT, CODES)
CASES = ('npv', 'lens', 'accent')
WATCH_CLASSES = (
    'SGRLegacyTabBar', 'SGRLegacyLens', 'SGLegacyGlassView',
    'UITabBarButton', 'SGRNowPlayingBar', 'SGRNowPlayingCard',
    'UIImageView', 'SPTEncoreIconView', 'UIStackView',
)
FOCUS = re.compile(
    r'SGRLegacy|Glass|Lens|TabBar|TabButton|NPV|NowPlaying|Artwork|'
    r'PlayerMorph|Refraction|Portal|Scannables|SearchToolBar|Search|'
    r'Avatar|Profile|Backdrop|Gradient|Glow|Rim|Shadow|Accent|Capsule|'
    r'UIStackView|SwiftUI|UIViewController', re.I)
SOURCE_FILES = (
    'tweak/Sources/Redesigned/Navbar/TabBarLens.m',
    'tweak/Sources/Redesigned/Navbar/TabBarLegacy.x',
    'tweak/Sources/Redesigned/Navbar/TabBarMinimize.x',
    'tweak/Sources/Redesigned/Navbar/LegacyNowPlayingTouch.x',
    'tweak/Sources/Redesigned/Player/PlayerMorph.x',
    'tweak/Sources/Redesigned/NowPlayingBar/BarTransition.x',
    'tweak/Sources/Redesigned/Search/SearchPage.x',
    'tweak/Sources/Redesigned/Search/Search.h',
    'tweak/Sources/Diagnostics/Driver.m',
    'scripts/diagnostics/stage83-native-legacy-nav.py',
)


def dump(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, default=str) + '\n', encoding='utf-8')


def command(argv, timeout=35):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=timeout, check=False)
        return {'args': argv, 'returncode': p.returncode,
                'stdout': p.stdout[-6000:], 'stderr': p.stderr[-6000:]}
    except Exception as exc:
        return {'args': argv, 'returncode': -1, 'error': repr(exc)}


def check_mp4(path):
    path = Path(path)
    report = {'ok': False, 'path': str(path), 'bytes': path.stat().st_size if path.exists() else 0}
    if report['bytes'] < 4096:
        report['reason'] = 'missing or too small'; return report
    try:
        pos, kinds = 0, []
        with path.open('rb') as stream:
            while pos + 8 <= report['bytes']:
                stream.seek(pos)
                size, code = struct.unpack('>I4s', stream.read(8))
                kind = code.decode('ascii', 'replace')
                if size == 1:
                    size = struct.unpack('>Q', stream.read(8))[0]
                    header_size = 16
                else:
                    header_size = 8
                    if size == 0: size = report['bytes'] - pos
                if size < header_size or size > report['bytes'] - pos:
                    raise ValueError('invalid MP4 box at %d: %s' % (pos, kind))
                kinds.append(kind)
                pos += size
        if pos != report['bytes'] or not {'ftyp', 'mdat', 'moov'} <= set(kinds):
            raise ValueError('missing MP4 boxes or truncated')
        report['boxes'] = kinds
        report['ok'] = True
        if shutil.which('ffprobe'):
            info = command(['ffprobe', '-v', 'error', '-show_entries',
                            'format=duration:stream=codec_name,width,height,avg_frame_rate',
                            '-select_streams', 'v:0', '-of', 'json', str(path)], timeout=18)
            if info['returncode'] == 0:
                report['ffprobe'] = json.loads(info['stdout'])
                streams = report['ffprobe'].get('streams') or []
                if not streams or streams[0].get('codec_name') != 'h264':
                    report.update(ok=False, reason='video stream not H264')
            else:
                report['ffprobe_warning'] = info
    except Exception as exc:
        report['reason'] = repr(exc)
    return report


def rect(v):
    f = v.get('frame') if isinstance(v, dict) else None
    return [float(x) for x in f] if isinstance(f, list) and len(f) == 4 else None


def center(frame):
    return [round(frame[0] + frame[2] / 2, 2), round(frame[1] + frame[3] / 2, 2)]


def loc(point):
    return '%.2f,%.2f' % tuple(point)


def visible_buttons(result):
    items = [v for v in result.get('views', []) if v.get('shown') is not False and
             rect(v) and rect(v)[1] > 400 and rect(v)[2] >= 30 and rect(v)[3] >= 28]
    items.sort(key=lambda v: center(rect(v))[0])
    dedup = []
    for v in items:
        if not dedup or abs(center(rect(v))[0] - center(rect(dedup[-1]))[0]) > 2:
            dedup.append(v)
    if len(dedup) != 4:
        raise EvidenceError('Expected 4 visible bottom UITabBarButtons, got %d (%s)' %
                            (len(dedup), str(items)[:600]))
    return {name: dict(view=v, frame=rect(v), point=center(rect(v)))
            for name, v in zip(('Home', 'Search', 'Your Library', 'Create'), dedup)}


def active_camera(result):
    views = [v for v in result.get('views', []) if v.get('shown') is True and rect(v) and
             rect(v)[2] > 20 and rect(v)[3] > 20]
    return views[0] if len(views) == 1 else None


def tree_coordinates(tree, terms=('SearchToolBar', 'Avatar', 'Scannables')):
    """Return exact raw tree matches, not invented absolute coordinates."""
    return [{'line': i, 'value': line.strip()} for i, line in enumerate(tree.splitlines(), 1)
            if any(term.lower() in line.lower() for term in terms)]


def safe_tree(tree):
    """Mask known private token-bearing settings while retaining view structure."""
    masked = []
    for line in tree.splitlines():
        if re.search(r'(?i)(token|secret|password|auth|cookie|sessionKey)\s*[=:]', line):
            line = re.sub(r'([=:])\s*(\S+)', r'\1 [REDACTED]', line, count=1)
        masked.append(line)
    return '\n'.join(masked) + '\n'


class EvidenceError(Exception):
    pass


class Driver:
    def __init__(self, port):
        self.url = 'http://127.0.0.1:%d/' % port

    def call(self, name, **params):
        query = urllib.parse.urlencode({k: str(v) for k, v in params.items()},
                                        quote_via=urllib.parse.quote)
        url = self.url + urllib.parse.quote(name) + ('?' + query if query else '')
        request = urllib.request.Request(url, headers={'X-Phone-Driver': '1'})
        with urllib.request.urlopen(request, timeout=36) as response:
            body = response.read().decode('utf-8', 'replace')
        if name == 'tree':
            if len(body) < 100: raise EvidenceError('too short tree')
            return body
        try: reply = json.loads(body)
        except Exception as exc: raise EvidenceError('non-JSON driver response: %s' % exc)
        if not isinstance(reply, dict) or reply.get('ok') is not True:
            raise EvidenceError('%s: %s' % (name, repr(reply)[:800]))
        return reply


class Collector:
    def __init__(self, args):
        self.args = args
        self.driver = Driver(args.port)
        self.repo = Path(args.repo).expanduser().resolve()
        self.root = (self.repo / args.output /
                     ('stage83-native-nav-' + datetime.now().strftime('%Y%m%d-%H%M%S')))
        self.root.mkdir(parents=True, exist_ok=True)
        self.warnings = []
        self.prefs = {}
        self.original_minimize = None
        self.restart_count = 0
        self.codes_tapped = False
        self.scene_recoveries = 0
        self.report = {
            'status': 'INCOMPLETE', 'requested': args.scenarios, 'scenarios': {},
            'started': datetime.now().isoformat(), 'udid': args.udid, 'port': args.port,
            'requires': 'Installed Stage 83 SG_DRIVER with native nav.trace.*',
            'note': 'EVIDENCE_CAPTURED means reproducible recordings, NOT confirmed bug or fix',
        }
        self.index = 0

    def log(self, message):
        print(message, flush=True)

    def warn(self, tag, exc):
        message = tag + ': ' + repr(exc)
        self.warnings.append(message)
        self.log('  [INCOMPLETE] ' + message)

    def strict(self, tag, name, **params):
        reply = self.driver.call(name, **params)
        if self.args.verbose:
            self.log('  command ' + tag + ' -> ' + name + ' OK')
        dump(self.root / 'driver-commands' / ('%03d-%s.json' % (self.index, re.sub('[^a-zA-Z0-9_-]', '-', tag))),
             {'name': name, 'params': params, 'response': reply})
        self.index += 1
        return reply

    def optional(self, name, **params):
        try: return self.driver.call(name, **params)
        except Exception as exc:
            # Nil animationKeys on a resting layer is an expected value.
            if name == 'get' and params.get('path') == 'layer.animationKeys' and 'animationKeys is nil' in str(exc):
                return {'ok': True, 'value': None, 'note': 'no active animations'}
            return {'ok': False, 'error': repr(exc)}

    def screen(self, path):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        reply = command(['xcrun', 'simctl', 'io', self.args.udid, 'screenshot',
                         '--type=png', str(dest)], timeout=26)
        if reply.get('returncode') != 0 or not dest.exists() or dest.stat().st_size < 1500:
            raise EvidenceError('cannot capture screenshot %s: %s' % (path, repr(reply)))
        return dest

    def snapshot(self, tag, deep=False):
        self.log('  capture ' + tag)
        target = self.root / tag
        target.mkdir(parents=True, exist_ok=True)
        state = self.strict(tag+'-state', 'state')
        rawtree = self.driver.call('tree')
        text = safe_tree(rawtree)
        (target / 'tree.txt').write_text(text, encoding='utf-8')
        (target / 'focused-tree.txt').write_text(
            '\n'.join('%d: %s' % (n+1, line) for n, line in enumerate(text.splitlines())
                      if FOCUS.search(line)) + '\n', encoding='utf-8')
        self.screen(tag+'/screen.png')
        dump(target / 'state.json', state)
        if deep:
            for cls in WATCH_CLASSES:
                result = self.optional('find', **{'class': cls})
                dump(target / 'find' / (cls+'.json'), result)
                if result.get('ok') is not True or not result.get('count'): continue
                if cls not in ('SGRLegacyTabBar', 'SGRLegacyLens', 'SGLegacyGlassView',
                               'SGRNowPlayingBar', 'SGRNowPlayingCard'): continue
                for n in range(min(2, result['count'])):
                    dump(target / 'layers' / ('%s-%d.json' % (cls, n)),
                         self.optional('layers', **{'class': cls, 'index': n, 'depth': 11}))
                    props = {}
                    for path in ('frame', 'hidden', 'alpha', 'layer.zPosition',
                                 'layer.opacity', 'layer.sublayers', 'layer.filters',
                                 'layer.mask', 'layer.cornerRadius', 'layer.animationKeys',
                                 'layer.presentationLayer.transform'):
                        props[path] = self.optional('get', **{'class': cls, 'index': n, 'path': path})
                    dump(target / 'properties' / ('%s-%d.json' % (cls, n)), props)
            dump(target / 'scannables-button.json', self.optional('find',
                 id='SearchToolBar.AccessoryItem.ScannablesButton'))
        return state

    def sources(self):
        meta = {'python': sys.version, 'platform': platform.platform(),
                'repo': str(self.repo), 'script': 'standalone-stage83-native-observer'}
        for cmd in (['git', 'rev-parse', 'HEAD'], ['git', 'branch', '--show-current'],
                    ['git', 'status', '--porcelain=v1'], ['git', 'log', '-8', '--oneline']):
            meta[' '.join(cmd)] = command(cmd, timeout=12)
        dump(self.root / 'repo-source' / 'metadata.json', meta)
        for path in SOURCE_FILES:
            src = self.repo / path
            if src.is_file():
                dst = self.root / 'repo-source' / path
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)

    def backup(self):
        for key in PREFS:
            self.prefs[key] = self.strict('original-'+key.split('.')[-1], 'pref', key=key).get('now')
        state = self.strict('original-mini-state', 'navbar.mini-state')
        if not state.get('legacy'):
            raise EvidenceError('Current installed build is not Legacy Glass (navbar.mini-state legacy=false)')
        self.original_minimize = bool(state['minimized'])
        dump(self.root / 'original-preferences.json', self.prefs)
        dump(self.root / 'original-mini-state.json', state)

    def change_pref(self, key, val):
        return self.strict('set-'+key.split('.')[-1]+'-'+str(val), 'pref', key=key, value=int(bool(val)))

    def restart_spotify(self, tag):
        """Recover normal navigation when a Spotify modal hides the actual bar.

        A simctl process restart does not uninstall Spotify or erase its data.
        The native driver is compiled into the app and reconnects on the same port.
        Limit retries so a persistent UI problem is reported, never masked.
        """
        if self.restart_count >= 8:
            raise EvidenceError('navigation recovery exceeded eight restarts; leave INCOMPLETE')
        self.restart_count += 1
        self.log('  recovery: relaunching Spotify without uninstalling (' + tag + ')')
        destination = self.root / 'recovery' / ('%02d-%s' %
            (self.restart_count, re.sub('[^a-zA-Z0-9_-]', '-', tag)))
        destination.mkdir(parents=True, exist_ok=True)
        stopped = command(['xcrun', 'simctl', 'terminate', self.args.udid,
                           'com.spotify.client'], timeout=20)
        dump(destination / 'terminate.json', stopped)
        # Already-terminated is not a failure; the launch result is authoritative.
        time.sleep(.55)
        started = command(['xcrun', 'simctl', 'launch', self.args.udid,
                           'com.spotify.client'], timeout=30)
        dump(destination / 'launch.json', started)
        if started['returncode'] != 0:
            raise EvidenceError('simctl launch failed: ' + repr(started))
        errors=[]
        for _ in range(45):
            try:
                state = self.driver.call('state')
                if state.get('top') and state.get('top') != 'NSNull':
                    dump(destination / 'recovered-state.json', state)
                    time.sleep(.8)
                    return state
            except Exception as exc:
                errors.append(str(exc)[:220])
            time.sleep(.35)
        dump(destination / 'connection-errors.json', errors[-15:])
        raise EvidenceError('SG_DRIVER did not return after Spotify relaunch on port %s' % self.args.port)

    def capture_navigation_blocker(self, tag):
        """Preserve why /tab failed before attempting recovery."""
        folder = self.root / 'recovery' / ('blocked-' + tag)
        folder.mkdir(parents=True, exist_ok=True)
        for name, args in (('state', {}), ('navbar.mini-state', {}),
                           ('find', {'class':'SGRLegacyTabBar'}),
                           ('find', {'class':'UITabBarButton'})):
            dump(folder / (name.replace('.', '-') + '.json'), self.optional(name, **args))
        try:
            (folder / 'tree.txt').write_text(safe_tree(self.driver.call('tree')), encoding='utf-8')
        except Exception as exc:
            dump(folder / 'tree-error.json', repr(exc))
        try: self.screen('recovery/blocked-' + tag + '/screen.png')
        except Exception as exc: dump(folder / 'screenshot-error.json', repr(exc))

    @staticmethod
    def modal_reason(state):
        """Only a *top* modal is conclusive; an idle scanner view may remain in tree."""
        top = str(state.get('top') or '')
        if 'SGModPage' in top or top == 'SGPage':
            return 'Vitrine settings top=' + top
        if re.search(r'scannable.*(finder|camera)|camerafinderview|scanner', top, re.I):
            return 'Spotify scanner top=' + top
        presented = state.get('presented') or []
        if isinstance(presented, list) and any(
                re.search(r'scannable.*(finder|camera)|camerafinderview', str(x), re.I)
                for x in presented):
            return 'Spotify scanner presented=' + str(presented)
        return None

    def inspect_scene(self, tag):
        state = self.strict(tag+'-scene-state', 'state')
        reason = self.modal_reason(state)
        dump(self.root / 'scene-preflight' / (re.sub(r'[^A-Za-z0-9_-]','-',tag)+'.json'),
             {'state':state, 'blocker':reason})
        return state, reason

    def clear_modals(self, tag):
        """Recover from a stale Vitrine settings page or Spotify Codes camera.

        A tab control can still be discoverable under a fullscreen modal. We do
        not accept /tab succeeding until the actual touch hits a tab button.
        """
        state, reason = self.inspect_scene(tag+'-before')
        if not reason:
            return state
        self.log('  stale overlay detected: '+reason)
        self.capture_navigation_blocker(tag+'-modal')
        if 'settings' in reason:
            try:
                self.strict(tag+'-dismiss-mod-settings', 'settings.dismiss')
                time.sleep(.3)
                state, reason = self.inspect_scene(tag+'-after-settings-dismiss')
                if not reason:
                    return state
            except Exception as exc:
                dump(self.root / 'recovery' / (tag+'-settings-dismiss-error.json'),repr(exc))
        self.restart_spotify(tag+'-modal')
        time.sleep(.35)
        state, reason = self.inspect_scene(tag+'-after-restart')
        if reason:
            raise EvidenceError('modal persisted after clean process relaunch: '+reason)
        return state

    @staticmethod
    def actual_tab_hit(response):
        """UITabBarButton hit, NOT merely an ok response from /tab."""
        hit = str(response.get('hit','')).lower()
        return ('tabbarbutton' in hit or 'tabbutton' in hit) and not ('scannable' in hit)

    def navigate_tab(self, name, tag='navigation'):
        """Navigate with a verified real tap and automatic modal recovery.

        A covered UITabBarButton still counts as visible in SG_DRIVER's tree.
        Calling /tab can therefore return ok even when its touch hits the
        Spotify Codes camera. Always inspect hit and verify the active scene.
        """
        self.clear_modals(tag)
        last_error = None
        for attempt in range(2):
            self.strict(tag+'-expand-%d'%attempt,'navbar.minimize',on=0,animated=0)
            self.strict(tag+'-refresh-%d'%attempt,'navbar.refresh')
            time.sleep(.35)
            try:
                answer=self.strict(tag+'-tab-%s-%d'%(name,attempt),'tab',arg=name)
                if not self.actual_tab_hit(answer):
                    raise EvidenceError('/tab hit %r instead of UITabBarButton' % answer.get('hit'))
                time.sleep(.3)
                scene, reason=self.inspect_scene(tag+'-after-tab-'+str(attempt))
                if reason:
                    raise EvidenceError('tab press followed by overlay: '+reason)
                return answer
            except Exception as exc:
                last_error=exc
                self.capture_navigation_blocker(tag+'-attempt-'+str(attempt))
                if attempt==0:
                    self.restart_spotify(tag+'-bad-tab-hit')
                    scene,reason=self.inspect_scene(tag+'-after-bad-hit-restart')
                    if reason:
                        raise EvidenceError('cannot clear modal after relaunch: '+reason)
        raise EvidenceError('cannot navigate to %s with real tab touch: %r' % (name,last_error))

    def restore(self):
        issues = []
        for key, val in self.prefs.items():
            try:
                if val is None:
                    self.strict('restore-'+key.split('.')[-1], 'pref', key=key, remove=1)
                elif isinstance(val, (bool, int, float)):
                    self.strict('restore-'+key.split('.')[-1], 'pref', key=key, value=int(val))
                else:
                    self.strict('restore-'+key.split('.')[-1], 'pref', key=key, text=str(val))
            except Exception as exc:
                issues.append(key + ' ' + repr(exc))
        try:
            if self.prefs: self.strict('restore-navbar-refresh', 'navbar.refresh')
            self.strict('restore-settings-dismiss', 'settings.dismiss')
            # The Spotify Codes SwiftUI popup may not be dismissible through
            # settings.dismiss (that command only pops Vitrine SGPage screens).
            # Close it by relaunching, preserving the installed app and login.
            if self.codes_tapped:
                self.restart_spotify('restore-after-codes-popup')
            if self.original_minimize is not None:
                self.strict('restore-minimized', 'navbar.minimize',
                            on=int(self.original_minimize), animated=0)
        except Exception as exc: issues.append(repr(exc))
        dump(self.root / 'restore-report.json', {'issues': issues, 'prefs': self.prefs,
                                                'minimized': self.original_minimize})
        if issues:
            self.report['restore'] = 'INCOMPLETE'
            self.warn('restore', issues)

    def home(self, minimized=False):
        self.clear_modals('home-preflight')
        state = self.driver.call('state')
        if state.get('player'):
            self.strict('player-close', 'player.close')
            time.sleep(.65)
        # settings.dismiss only pops SGPage; it does not close Spotify Codes.
        self.strict('dismiss-settings', 'settings.dismiss')
        # IMPORTANT: move out of minimized mode BEFORE trying /tab.
        self.navigate_tab('Home', tag='home')
        self.strict('set-minimized-'+str(minimized), 'navbar.minimize',
                    on=int(minimized), animated=0)
        time.sleep(.7)
        mini = self.strict('verify-navbar-state', 'navbar.mini-state')
        if not mini.get('legacy') or bool(mini.get('minimized')) != bool(minimized):
            raise EvidenceError('failed to set Legacy minimized=%s: %s' % (minimized, mini))
        return mini

    def expanded_buttons(self):
        self.home(False)
        result = self.strict('locate-tab-buttons', 'find', **{'class': 'UITabBarButton'})
        return visible_buttons(result)

    def native_trace_read(self, tag, stopped, expected_s):
        """Retrieve live main-thread samples in small pages AFTER the touch.

        Crucial: no HTTP /get or /tree during injection, because the driver can
        serialize those until the touch has been released. The CADisplayLink
        observer records without driver requests while the gesture is running.
        """
        folder=self.root/tag/'native'
        folder.mkdir(parents=True,exist_ok=True)
        dump(folder/'stop.json',stopped)
        if not stopped.get('ok') or stopped.get('capped'):
            raise EvidenceError('%s: native trace not complete: %s' % (tag, stopped))
        total=stopped.get('frames')
        if not isinstance(total,int) or total<max(15,int(expected_s*10)):
            raise EvidenceError('%s: native trace too short, frames=%s' % (tag,total))
        frames=[]
        for offset in range(0,total,25):
            page=self.strict(tag+'-trace-page-'+str(offset),'nav.trace.read',offset=offset,limit=25)
            if int(page.get('offset',-1))!=offset or int(page.get('total',-1))!=total:
                raise EvidenceError('%s: native trace lost pages at offset %d' % (tag,offset))
            chunk=page.get('frames')
            if not isinstance(chunk,list) or len(chunk)!=min(25,total-offset):
                raise EvidenceError('%s: wrong native page size at offset %d' % (tag,offset))
            frames+=chunk
        times=[float(f['t']) for f in frames]
        if any(b<a for a,b in zip(times,times[1:])):
            raise EvidenceError('%s: out-of-order native frames' % tag)
        if times[-1]-times[0]<expected_s*.8:
            raise EvidenceError('%s: native trace ends before gesture should end' % tag)
        if not any(isinstance(f.get('barTransition'),dict) and
                   isinstance(f.get('playerMorph'),dict) and
                   isinstance(f.get('objects'),list) for f in frames):
            raise EvidenceError('%s: native transition/lens payload missing' % tag)
        dump(folder/'frames.json',frames)
        # A compact chronology allows fast auditing without processing full JSON.
        dump(folder/'chronology.json',[
            {'t':f['t'],'phase':f.get('phase'),'minimized':f.get('minimized'),
             'held':f.get('held'),'card':f.get('card'),'slot':f.get('slot'),
             'barHidden':f.get('barTransition',{}).get('hiddenHostCount'),
             'barFollowers':f.get('barTransition',{}).get('followerCount'),
             'morphActive':f.get('playerMorph',{}).get('active'),
             'morphProgress':f.get('playerMorph',{}).get('lastProgress'),
             'lens': [{'screen':v.get('screen'),'touching':v.get('touching'),
                       'refracting':v.get('refracting')}
                      for v in f.get('objects',[])
                      if 'SGRLegacyLens' in v.get('class','')]}
            for f in frames])
        return {'frames':len(frames),'seconds':round(times[-1]-times[0],3),
                'barFollowersPeak':max((f.get('barTransition',{}).get('followerCount',0)
                                        for f in frames),default=0),
                'morphEverActive':any(f.get('playerMorph',{}).get('active') for f in frames),
                'lensSamples':sum(any('SGRLegacyLens' in v.get('class','')
                                      for v in f.get('objects',[])) for f in frames)}

    def record(self, tag, action, samples, expected_s, verify_hit=None, after_s=1.2):
        """Movie first, trigger driver on worker; never query layers during a touch."""
        folder = self.root / tag
        folder.mkdir(parents=True, exist_ok=True)
        video = folder / 'motion.mp4'
        log_file = (folder / 'recording.log').open('w', encoding='utf-8')
        recorder = None
        started_at = None
        event = {'action': action, 'samples': [], 'response': None,
                 'error': None, 'release_s': None}
        native_active = False
        native_stop = None
        result = {}
        try:
            recorder = subprocess.Popen(['xcrun', 'simctl', 'io', self.args.udid,
                                         'recordVideo', '--codec=h264', '--force', str(video)],
                                        stdout=log_file, stderr=subprocess.STDOUT)
            deadline = time.monotonic()+14
            while time.monotonic() < deadline:
                log_file.flush()
                if recorder.poll() is not None: raise EvidenceError('recordVideo exited early')
                if 'Recording started' in (folder/'recording.log').read_text(errors='replace'):
                    break
                time.sleep(.12)
            else: raise EvidenceError('recordVideo never became ready')
            time.sleep(.12)
            started_at = time.monotonic()
            # Start the native display-link sampler BEFORE the injected touch.
            # Never issue live HTTP property queries during the gesture.
            trace_started = self.strict(tag+'-start-native-trace','nav.trace.start')
            native_active = bool(trace_started.get('capturing'))
            if not native_active:
                raise EvidenceError('native trace could not start before '+tag)

            def worker():
                try:
                    result['reply'] = self.driver.call(action['cmd'], **action.get('args', {}))
                except Exception as exc:
                    result['error'] = repr(exc)
                finally:
                    result['finished_s'] = round(time.monotonic()-started_at, 3)
                    if action.get('probe_mini_after'):
                        result['immediate_mini'] = self.optional('navbar.mini-state')
                        result['mini_sample_s'] = round(time.monotonic()-started_at, 3)

            thread = threading.Thread(target=worker, daemon=True)
            thread.start()
            live_probe = {}
            live_thread = None
            if action.get('live_mini_at_s') is not None:
                def sample_live_mini():
                    when = started_at+float(action['live_mini_at_s'])-time.monotonic()
                    if when > 0: time.sleep(when)
                    live_probe['started_s'] = round(time.monotonic()-started_at,3)
                    live_probe['state'] = self.optional('navbar.mini-state')
                    live_probe['finished_s'] = round(time.monotonic()-started_at,3)
                live_thread = threading.Thread(target=sample_live_mini, daemon=True)
                live_thread.start()
            for index, requested_s in enumerate(samples):
                remaining = started_at+requested_s-time.monotonic()
                if remaining > 0: time.sleep(remaining)
                before = round(time.monotonic()-started_at, 3)
                output = 'samples/%02d-%04dms.png' % (index, int(requested_s*1000))
                try:
                    self.screen(tag+'/'+output)
                    sample = {'requested_s': requested_s, 'capture_begin_s': before,
                              'capture_end_s': round(time.monotonic()-started_at,3),
                              'path': output}
                except Exception as exc:
                    sample = {'requested_s': requested_s, 'capture_begin_s': before,
                              'error': repr(exc)}
                event['samples'].append(sample)
            thread.join(timeout=expected_s+18)
            if thread.is_alive(): raise EvidenceError('driver gesture timed out')
            if live_thread:
                live_thread.join(timeout=2)
                event['live_mini_during_touch'] = live_probe
                event['live_mini_was_held'] = bool(
                    live_probe.get('state',{}).get('ok') and
                    live_probe.get('finished_s',float('inf')) < result.get('finished_s',0)-.08)
                # If the native driver serialized the request until after lift,
                # keep the actual timestamps; never call that a held-state sample.
            time.sleep(after_s)
            event['response'] = result.get('reply')
            event['error'] = result.get('error')
            event['release_s'] = result.get('finished_s')
            if 'immediate_mini' in result:
                event['immediate_mini'] = result['immediate_mini']
                event['mini_sample_s'] = result['mini_sample_s']
        finally:
            if native_active:
                try:
                    native_stop=self.strict(tag+'-stop-native-trace','nav.trace.stop')
                except Exception as exc:
                    event['native_stop_error']=repr(exc)
            if recorder is not None and recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try: recorder.wait(timeout=14)
                except subprocess.TimeoutExpired: recorder.kill(); recorder.wait(timeout=5)
            log_file.close()
        if native_active:
            if native_stop is None:
                raise EvidenceError(tag+': native trace stop failed: '+str(event.get('native_stop_error')))
            event['native']=self.native_trace_read(tag,native_stop,expected_s)
            if tag.startswith('lens/') and event['native']['lensSamples'] < 3:
                raise EvidenceError(tag+': native lens not visible in observation frames')
        dump(folder / 'timeline-and-gesture.json', event)
        chk = check_mp4(video)
        dump(folder / 'video-check.json', chk)
        if not chk['ok']:
            raise EvidenceError('invalid video at %s: %s' % (tag, chk.get('reason')))
        if event['error'] or not isinstance(event['response'], dict) or not event['response'].get('ok'):
            raise EvidenceError('%s: SG_DRIVER gesture failed: %s' % (tag, event['error'] or event['response']))
        # A controller may make background tabs discoverable while a full-screen
        # scanner is intercepting the injected touch. Never call that evidence.
        actual_hit = str(event['response'].get('hit','')).lower()
        if 'scannablecamerafinderview' in actual_hit:
            raise EvidenceError('%s: gesture landed on Spotify Codes camera overlay (%s)' %
                                (tag, actual_hit))
        if verify_hit:
            hit = actual_hit
            if not any(phrase in hit for phrase in verify_hit):
                raise EvidenceError('%s: touch hit %r instead of %r' % (tag, hit, verify_hit))
        # Every held gesture must have an on-screen sample while touch is still down.
        a = action.get('args', {})
        hold_for = float(a.get('hold', 0) or 0)
        held_from = (float(a.get('duration', 0) or 0) if action['cmd']=='swipe'
                     else float(a.get('up', 0) or 0)+float(a.get('back', 0) or 0))
        if hold_for > 0:
            held = [p for p in event['samples'] if not p.get('error') and
                    p['capture_begin_s'] >= held_from+.08 and
                    p['capture_end_s'] <= held_from+hold_for-.08]
            if not held:
                raise EvidenceError('%s: no verifiable screenshot while touch held' % tag)
        # Record FFmpeg-decoded sample frames from the raw 60 Hz MP4 where available.
        # This is optional; validation never depends on a Homebrew installation.
        if shutil.which('ffmpeg'):
            for ms in action.get('video_marks_ms', []):
                output = folder / 'video-frames' / ('frame-%04dms.png' % ms)
                output.parent.mkdir(parents=True, exist_ok=True)
                command(['ffmpeg','-hide_banner','-loglevel','error','-ss',str(ms/1000),
                         '-i',str(video),'-frames:v','1','-y',str(output)],timeout=16)
        return event

    def npv(self):
        self.log('\n== NPV: minimized interruption, continuous UITouch ==')
        has_all = True
        for label, up, back, hold in (
            ('reverse-hold', .72, .68, 3.35),
            ('reverse-quick', .37, .34, 0),
        ):
            try:
                mini = self.home(True)
                card = rect({'frame': mini.get('cardFrame')})
                slot = rect({'frame': mini.get('inlineSlot')})
                if not card or not slot or card[2] < 70 or card[3] < 25:
                    raise EvidenceError('mini-player card/inline slot missing: %r' % mini)
                pt = center(card)
                if not (slot[0]-16 <= pt[0] <= slot[0]+slot[2]+16 and
                        abs(pt[1] - center(slot)[1]) <= 24):
                    raise EvidenceError('mini-player is NOT docked in minimized bar before touch: %r' % mini)
                state = self.driver.call('state')
                if state.get('player') or not state.get('nowPlaying'):
                    raise EvidenceError('no playable mini NPV baseline: '+repr(state)[:300])
                tag = 'npv/'+label
                dump(self.root / tag / 'baseline.json', mini)
                self.snapshot(tag+'/before', deep=True)
                via = [pt[0], max(135.0, pt[1]-145.0)]
                args = {'from': loc(pt), 'via': loc(via), 'to': loc(pt),
                        'up': str(up), 'back': str(back), 'hold': str(hold)}
                samples = ([.15,.55,1.05,1.68,2.55,3.35,4.10,4.52,4.95,5.50]
                           if hold else [.12,.39,.75,.95,1.22,1.65,2.25])
                event = self.record(tag, {'cmd':'swipe.reverse','args':args,
                                         'probe_mini_after':True,
                                         # Native trace replaces serialized HTTP live_mini requests.
                                         'live_mini_at_s':None,
                                         'video_marks_ms':[250,750,1300,1900,2900,3800,4500,5000]},
                                    samples, up+back+hold, after_s=.45)
                actual = event['response'].get('via')
                if not (isinstance(actual, list) and len(actual)==2 and
                        all(abs(float(a)-float(b)) < .2 for a,b in zip(actual, via))):
                    raise EvidenceError('driver did not confirm turning point: '+repr(actual))
                if hold:
                    held_samples = [x for x in event['samples'] if not x.get('error') and
                                    up+back+.20 <= x['capture_begin_s'] and
                                    x['capture_end_s'] <= up+back+hold-.10]
                    if not held_samples:
                        raise EvidenceError('no verified screenshot during return-and-hold interval')
                self.snapshot(tag+'/after', deep=True)
                time.sleep(.9)
                self.snapshot(tag+'/settled', deep=True)
                after_mini = self.strict('mini-after-'+label, 'navbar.mini-state')
                dump(self.root/tag/'settled-mini-state.json', after_mini)
                if not after_mini.get('minimized') or self.driver.call('state').get('player'):
                    raise EvidenceError('NPV did not finish docked in minimized bar')
                if not event.get('immediate_mini',{}).get('ok'):
                    raise EvidenceError('immediate postrelease mini-state unavailable')
            except Exception as exc:
                has_all = False
                self.warn('npv/'+label, exc)
        return has_all

    def set_tabs(self, hide, accent):
        self.change_pref(HIDE, hide)
        self.change_pref(ACCENT, accent)
        self.strict('tabbar-apply-pref', 'navbar.refresh')
        time.sleep(.25)
        return self.expanded_buttons()

    def accent(self):
        self.log('\n== Tab highlight: Accent ON vs OFF, two simultaneous icons ==')
        good = True
        for title, hide, acc in (('icons-accent-on', True, True),
                                 ('icons-accent-off', True, False),
                                 ('labels-accent-off', False, False)):
            try:
                tabs = self.set_tabs(hide, acc)
                tag='accent/'+title
                self.snapshot(tag+'/rest',deep=True)
                pts={n:v['point'] for n,v in tabs.items()}
                dump(self.root/tag/'tab-centers.json',pts)
                self.record(tag+'/home-to-search-held',
                            {'cmd':'swipe','args':{'from':loc(pts['Home']),
                             'to':loc(pts['Search']),'duration':'1.15','hold':'1.25'},
                             'video_marks_ms':[180,490,850,1200,1580,2070,2480]},
                            [.2,.62,1.04,1.35,1.8,2.15,2.55],2.4,
                            verify_hit=('tabbarbutton',))
                self.snapshot(tag+'/after-drag',deep=True)
                self.navigate_tab('Home', tag='reset-home-accent')
                time.sleep(.35)
                # Hold exactly between two tab centers: identify any double lit icons.
                between=[(pts['Home'][0]+pts['Search'][0])/2, pts['Home'][1]]
                self.record(tag+'/between-buttons',
                            {'cmd':'swipe','args':{'from':loc(pts['Home']),
                             'to':loc(between),'duration':'.85','hold':'1.35'},
                             'video_marks_ms':[450,850,1150,1700,2200]},
                            [.25,.7,1.05,1.5,1.95,2.4],2.2,
                            verify_hit=('tabbarbutton',))
                self.snapshot(tag+'/settled',deep=True)
            except Exception as exc:
                good=False; self.warn('accent/'+title,exc)
        return good

    def codes(self):
        self.log('\n== Search: Spotify Codes control & popup ==')
        try:
            # Never open settings *before* Search: settings.dismiss may leave
            # SGModPage on top and /tab can tap behind it.
            self.clear_modals('codes-initial-clean-scene')
            self.change_pref(CODES, True)
            self.strict('search-opt-in-refresh', 'navbar.refresh')
            self.navigate_tab('Home', tag='search-go-home')
            time.sleep(.35)
            self.navigate_tab('Search', tag='search-go-search')
            time.sleep(.8)
            state=self.snapshot('codes/search-before-tap',deep=True)
            top=str(state.get('top') or '')
            ctrl=' '.join(map(str,state.get('controllers') or []))
            reason=self.modal_reason(state)
            if reason:
                raise EvidenceError('Search covered by modal: '+reason)
            if 'Browse' not in top and 'Browse' not in ctrl:
                raise EvidenceError('Search controller absent, top=%s controllers=%s' % (top,ctrl))
            raw=self.driver.call('tree')
            matches=tree_coordinates(raw)
            found=self.strict('find-scannables', 'find',
                              id='SearchToolBar.AccessoryItem.ScannablesButton')
            camera=active_camera(found)
            profile_found=self.optional('find', id='Components.UI.SideDrawerButton')
            avatars=[v for v in profile_found.get('views',[]) if v.get('shown') is True and rect(v)]
            avatar=avatars[0] if len(avatars)==1 else None
            gap=None
            if camera and avatar:
                cf,af=rect(camera),rect(avatar)
                gap=round(af[0]-(cf[0]+cf[2]),2) if center(cf)[0]<center(af)[0] else round(cf[0]-(af[0]+af[2]),2)
            dump(self.root/'codes/button-layout.json',{
                'camera':camera, 'avatar':avatar, 'gap_pt':gap,
                'gap_note':'Negative = overlap; compare button glass extents in screenshot',
                'all_candidates':found.get('views',[]), 'header_nodes':matches,
            })
            if not camera:
                raise EvidenceError('Spotify Codes camera not uniquely visible after setting ON')
            point=center(rect(camera))
            self.codes_tapped = True
            self.record('codes/first-popup-opening',
                        {'cmd':'tap','args':{'at':loc(point)},
                         'video_marks_ms':[120,230,400,630,950,1430]},
                        [.15,.34,.59,.88,1.35],.08,after_s=.4)
            popup_state=self.snapshot('codes/popup-after-first-tap',deep=True)
            time.sleep(.65)
            self.snapshot('codes/popup-settled',deep=True)
            if (popup_state.get('top')==state.get('top') and
                not popup_state.get('presented') and
                popup_state.get('menu') is False):
                # Some popups are presented via embedded SwiftUI without changing
                # controllers: tree/view delta is evidence, but cannot automatically
                # assert that *the correct* popup opened.
                before=(self.root/'codes/search-before-tap/tree.txt').read_text()
                after=(self.root/'codes/popup-after-first-tap/tree.txt').read_text()
                if before==after:
                    raise EvidenceError('Camera tapped but popup did not change controller, menu, or tree')
            # Save settings-page evidence last. Codes popup deliberately stays
            # open until this point, so it cannot obstruct other scenarios.
            try:
                self.restart_spotify('codes-before-settings-evidence')
                self.clear_modals('codes-settings-preflight')
                self.strict('codes-settings-open', 'settings.open')
                self.strict('codes-settings-search-page', 'settings.page', title='Search')
                self.snapshot('codes/preferences-search-page',deep=False)
            except Exception as exc:
                self.warn('codes/preferences-page (optional)',exc)
            finally:
                try:self.strict('codes-settings-dismiss-end','settings.dismiss')
                except Exception:pass
            return True
        except Exception as exc:
            self.warn('codes',exc)
            return False

    def lens(self):
        self.log('\n== Optical edge & glass-to-substrate release ==')
        good=True
        try:
            tabs=self.set_tabs(False,True)
            self.snapshot('lens/normal-rest',deep=True)
            pts={n:v['point'] for n,v in tabs.items()}
            dump(self.root/'lens/tab-centers.json',pts)
        except Exception as exc:
            self.warn('lens/preflight',exc); return False
        # Both directions catch directional substrate deformation and late rim.
        for label, start, finish in (('home-to-library','Home','Your Library'),
                                     ('library-to-home','Your Library','Home')):
            try:
                self.navigate_tab(start, tag='lens-start-'+label)
                time.sleep(.4)
                tag='lens/release-'+label
                self.snapshot(tag+'/rest',deep=False)
                self.record(tag,{'cmd':'swipe','args':{
                    'from':loc(pts[start]),'to':loc(pts[finish]),
                    'duration':'.85','hold':'.55'},
                    'video_marks_ms':[350,700,950,1160,1400,1530,1690,1900,2220]},
                    [.25,.62,.98,1.25,1.45,1.68,1.94,2.30],1.40,
                    verify_hit=('tabbarbutton',))
                self.snapshot(tag+'/after',deep=True)
            except Exception as exc:
                good=False; self.warn('lens/release-'+label,exc)
        # Look for refraction near capsule edges and excess left overtravel.
        try:
            self.navigate_tab('Home',tag='lens-select-home')
            time.sleep(.4)
            self.record('lens/left-outward-held', {'cmd':'swipe','args':{
                'from':loc(pts['Home']), 'to':loc([max(12,pts['Home'][0]-38),pts['Home'][1]]),
                'duration':'1.1','hold':'2.2'},
                'video_marks_ms':[250,650,1080,1550,2300,2900,3400]},
                [.42,.98,1.46,2.2,2.85,3.48],3.3,
                verify_hit=('tabbarbutton',))
            self.snapshot('lens/left-outward-after',deep=True)
        except Exception as exc:
            good=False; self.warn('lens/left-outward-held',exc)
        try:
            self.navigate_tab('Your Library',tag='lens-select-library')
            time.sleep(.4)
            # End close to the rightmost boundary without hitting Create,
            # which may open a creation menu.
            right_x=max(pts['Your Library'][0]+18,pts['Create'][0]-20)
            self.record('lens/right-edge-held', {'cmd':'swipe','args':{
                'from':loc(pts['Your Library']),
                'to':loc([right_x,pts['Your Library'][1]]),
                'duration':'1.12','hold':'2.1'},
                'video_marks_ms':[290,670,1130,1650,2350,2900]},
                [.4,1.02,1.50,2.3,2.88,3.45],3.22,
                verify_hit=('tabbarbutton',))
            self.snapshot('lens/right-edge-after',deep=True)
        except Exception as exc:
            good=False; self.warn('lens/right-edge-held',exc)
        return good

    def finish(self):
        self.report['warnings']=self.warnings
        self.report['finished']=datetime.now().isoformat()
        self.report['status']='EVIDENCE_CAPTURED' if (
            all(self.report['scenarios'].get(name)=='CAPTURED' for name in self.args.scenarios)
            and self.report.get('restore')!='INCOMPLETE') else 'INCOMPLETE'
        dump(self.root/'summary.json',self.report)
        archive=self.root.with_suffix('.zip')
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=5) as z:
            for path in self.root.rglob('*'):
                if path.is_file(): z.write(path,arcname=str(path.relative_to(self.root.parent)))
        self.log('\nSTATUS: '+self.report['status'])
        self.log('Evidence ZIP: '+str(archive))
        return self.report['status']=='EVIDENCE_CAPTURED'


def self_test():
    assert center([10,20,80,40])==[50,40]
    assert rect({'frame':[10,20,80,40]})==[10,20,80,40]
    assert active_camera({'views':[{'shown':True,'frame':[14,20,40,48]}]}) is not None
    assert active_camera({'views':[{'shown':False,'frame':[14,20,40,48]}]}) is None
    raw={'views':[{'shown':True,'frame':[i*82+10,810,70,54],'index':i} for i in range(4)]}
    assert len(visible_buttons(raw))==4
    assert 'Scannables' in tree_coordinates('a Scannables b')[0]['value']
    assert 'REDACTED' in safe_tree('spotifyglass.motion.token = supersecret')
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        fake=Path(folder)/'test.mp4'
        assert not check_mp4(fake)['ok']
        fake.write_bytes(b'\x00\x00\x00\x08ftyp' + b'\x00\x00\x00\x08moov' +
                         b'\x00\x00\x10\x08mdat' + b'\x00'*4096)
        assert check_mp4(fake)['ok']
    assert '%20' in urllib.parse.urlencode({'label':'Spotify Codes'},quote_via=urllib.parse.quote)
    # A scanner overlay and an SGModPage must block navigation until cleared.
    assert Collector.modal_reason({'top':'SGModPage'}) is not None
    assert Collector.modal_reason({'top':'_TtC25Scannables_ScannablesImpl25ScannableCameraFinderView'})
    assert Collector.modal_reason({'top':'BrowsePageViewController'}) is None
    assert Collector.actual_tab_hit({'hit':'UITabBarButton'})
    assert not Collector.actual_tab_hit({'hit':'_TtC25scannables_scannablesimpl25ScannableCameraFinderView'})
    # The tab target may be present but behind the scanner: an "ok" must fail.
    import types
    fake=Collector.__new__(Collector)
    calls=[]
    fake.clear_modals=lambda tag:calls.append('clear')
    fake.capture_navigation_blocker=lambda tag:calls.append('blocker')
    fake.restart_spotify=lambda tag:calls.append('relaunch')
    fake.inspect_scene=lambda tag:({'ok':True,'top':'BrowsePageViewController'},None)
    response_hits=iter(['_TtC25scannables_scannablesimpl25ScannableCameraFinderView',
                        'UITabBarButton'])
    def fake_strict(tag,cmd,**kw):
        calls.append(cmd)
        if cmd=='tab':return {'ok':True,'hit':next(response_hits)}
        return {'ok':True}
    fake.strict=fake_strict
    real_sleep=time.sleep
    try:
        time.sleep=lambda _:None
        fake.navigate_tab('Home',tag='test-overlaid-tab')
        assert calls.count('tab')==2 and calls.count('relaunch')==1
        assert calls[0]=='clear' and calls.index('relaunch')>calls.index('tab')
    finally:time.sleep=real_sleep
    # A second wrong hit must be a hard failure, never marked CAPTURED.
    fake.strict=lambda tag,cmd,**kw: ({'ok':True,'hit':'ScannableCameraFinderView'}
             if cmd=='tab' else {'ok':True})
    real_sleep=time.sleep
    try:
        time.sleep=lambda _:None
        try:
            fake.navigate_tab('Search',tag='always-blocked')
            raise AssertionError('expected an INCOMPLETE condition')
        except EvidenceError as e:
            assert 'cannot navigate' in str(e)
    finally:time.sleep=real_sleep
    with tempfile.TemporaryDirectory() as folder:
        test=Collector.__new__(Collector)
        test.root=Path(folder)
        native_frames=[{'t':i/60,'phase':'displayLink','minimized':True,
                        'barTransition':{'hiddenHostCount':1,'followerCount':1},
                        'playerMorph':{'active':True,'lastProgress':.4},
                        'objects':[{'class':'SGRLegacyLens','screen':{}}]}
                       for i in range(100)]
        test.strict=lambda tag,cmd,**kw:{'ok':True,'offset':int(kw['offset']),
            'total':len(native_frames),
            'frames':native_frames[kw['offset']:kw['offset']+kw['limit']]}
        info=test.native_trace_read('test',{'ok':True,'frames':100,'capped':False},1.2)
        assert info['frames']==100 and info['lensSamples']==100 and info['morphEverActive']
        try:
            test.native_trace_read('bad',{'ok':True,'frames':100,'capped':True},1.2)
            raise AssertionError('capped trace must be INCOMPLETE')
        except EvidenceError: pass
    print('SELF-TEST: OK (native-trace client, no macOS / simulator required)')


def main():
    ap=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo',default='.',help='repository root; run from ~/Downloads/spoti-fork')
    ap.add_argument('--output',default='out')
    ap.add_argument('--port',type=int,default=8087)
    ap.add_argument('--udid',default=DEFAULT_UDID)
    ap.add_argument('--scenarios',nargs='+',choices=CASES,default=list(CASES))
    ap.add_argument('--verbose',action='store_true')
    ap.add_argument('--self-test',action='store_true')
    args=ap.parse_args()
    if args.self_test:
        self_test();return 0
    if not shutil.which('xcrun'):
        ap.error('requires macOS xcrun; run this script on the Mac with booted iOS 18 simulator')
    c=Collector(args)
    try:
        c.strict('preflight-state','state')
        c.strict('preflight-native-trace','nav.trace.status')
        c.backup()
        c.sources()
        for name in [x for x in args.scenarios if x != 'codes'] + (['codes'] if 'codes' in args.scenarios else []):
            try:
                ok=getattr(c,name)()
                c.report['scenarios'][name]='CAPTURED' if ok else 'INCOMPLETE'
            except Exception as exc:
                c.report['scenarios'][name]='INCOMPLETE'
                c.warn(name,exc)
    except Exception as exc:
        c.warn('preflight',exc)
        for name in args.scenarios: c.report['scenarios'].setdefault(name,'INCOMPLETE')
    finally:
        c.restore()
    return 0 if c.finish() else 2


if __name__=='__main__':
    sys.exit(main())
