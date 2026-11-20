#!/usr/bin/env python3
"""Stage 38: read-only Legacy Glass visual evidence, user-controlled navigation.

Only reads SG_DRIVER, simctl screens/video, source metadata. Never touches the UI,
changes preferences, installs Spotify, or assumes a page was opened successfully.
The user opens each screen and confirms when it is stable. For cold Share, record
before the user opens the sheet. Python stdlib only; ffprobe is optional.
"""
from __future__ import annotations
import argparse
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
import urllib.error
import urllib.parse
import urllib.request
import zipfile

DEFAULT_UDID = 'ED66415E-FC8E-44EA-B306-33BB985B9CE8'
SCENARIOS = (
    ('tabbar-settings', 'Open Mod Settings > Tab Bar > the screen missing the title oval.'),
    ('genres', 'Open Genres, where a title/control oval is missing.'),
    ('song-menu-share', 'Open a song menu > Share and leave the Share sheet fully visible; inspect the last More button on row two.'),
    ('lyrics', 'Open the player screen with the Lyrics control visible.'),
    ('mini-player', 'Close full-screen player; leave the compact now-playing bar and its device button visible.'),
    ('library-recents', 'Open Your Library at the very top, showing filter chips and the Recents/sort row.'),
    ('home-music', 'Open Home > Music on Friday at the area where New Music Friday ought to appear. DO NOT toggle previews yet.'),
    ('home-music-previews-on', 'If desired, switch ON Video and playlist previews in redesigned Home settings, reopen Home > Music, and show the same area.'),
)
VIEW_CLASSES = (
    'SGLegacyGlassView', 'SGGlassThumbView', 'SGRLegacyLens',
    'UITabBarButton', 'UIVisualEffectView', 'UILabel',
    'UICollectionView', 'UIImageView',
)
FOCUS = re.compile(r'glass|lens|pill|oval|chip|genre|sheet|share|More|music|friday|preview|recent|library|filter|lyrics|connect|device|backdrop|gradient|header|scroll|platter|navbar', re.I)


def write_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str) + '\n', encoding='utf-8')


def run(argv, timeout=25):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return {'args': argv, 'returncode': p.returncode, 'stdout': p.stdout[-25000:], 'stderr': p.stderr[-25000:]}
    except Exception as exc:
        return {'args': argv, 'returncode': -1, 'error': repr(exc)}


class Driver:
    def __init__(self, port):
        self.url = f'http://127.0.0.1:{port}'

    def call(self, command, **kwargs):
        url = self.url + '/' + urllib.parse.quote(command)
        if kwargs:
            url += '?' + urllib.parse.urlencode(kwargs, quote_via=urllib.parse.quote)
        request = urllib.request.Request(url, headers={'X-Phone-Driver': '1'})
        with urllib.request.urlopen(request, timeout=18) as response:
            data = response.read().decode('utf-8', 'replace')
        if command == 'tree':
            return data
        return json.loads(data)


class Evidence:
    def __init__(self, args):
        self.args = args
        self.root = Path(args.output).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.driver = Driver(args.port)
        self.results = []
        self.problems = []
        self.warnings = []
        self.videos = []
        self.rootTime = time.monotonic()

    def require_driver(self):
        try:
            tree = self.driver.call('tree')
            state = self.driver.call('state')
            if not isinstance(tree, str) or len(tree) < 300:
                raise RuntimeError('tree is empty or truncated')
            if not isinstance(state, dict) or state.get('ok') is False:
                raise RuntimeError(f'driver state not OK: {state!r}')
            write_json(self.root / 'driver-check.json', {'ok': True, 'treeLength': len(tree), 'state': state})
        except Exception as exc:
            write_json(self.root / 'driver-check.json', {'ok': False, 'error': repr(exc)})
            raise RuntimeError(f'SG_DRIVER port {self.args.port} is unavailable: {exc}') from exc

    def metadata(self):
        info = {name: run(['git', name, *extra]) for name, extra in (
            ('rev-parse', ['HEAD']), ('branch', ['--show-current']), ('status', ['--porcelain=v1']))}
        info['recentCommits'] = run(['git', 'log', '-12', '--oneline'])
        info['localTime'] = dt.datetime.now().astimezone().isoformat()
        info['port'] = self.args.port
        info['udid'] = self.args.udid
        write_json(self.root / 'source-and-environment.json', info)
        paths = [
            'tweak/Sources/Redesigned/Navbar/NavbarSettings.m',
            'tweak/Sources/Redesigned/Pages/ChatShareGlass.x',
            'tweak/Sources/Redesigned/Kit/SGRSheetPopups.x',
            'tweak/Sources/Redesigned/Library/LibraryHeader.x',
            'tweak/Sources/Redesigned/Home/HomeSections.x',
            'tweak/Sources/Redesigned/Player/PlayerFooter.x',
            'tweak/Sources/Redesigned/NowPlayingBar/NowPlayingBar.x',
        ]
        for p in paths:
            src = Path(p)
            if src.exists():
                dest = self.root / 'sources' / p
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)

    def optional(self, tag, cmd, required=False, **params):
        try:
            result = self.driver.call(cmd, **params)
            if isinstance(result, dict) and result.get('ok') is False:
                (self.problems if required else self.warnings).append(
                    f'{tag}: /{cmd} returned {result.get("error", result)}')
            return result
        except Exception as exc:
            (self.problems if required else self.warnings).append(f'{tag}: /{cmd} failed: {exc!r}')
            return {'ok': False, 'error': repr(exc)}

    def screenshot(self, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        result = run(['xcrun', 'simctl', 'io', self.args.udid, 'screenshot', '--type=png', str(dest)], 35)
        if result['returncode'] != 0 or not dest.exists() or dest.stat().st_size < 2000:
            self.problems.append(f'Screenshot failed {dest}: {result}')
            return False
        return True

    def snapshot(self, name, deep=True):
        dest = self.root / name
        dest.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        tree = self.optional(name, 'tree', required=True)
        if isinstance(tree, str):
            (dest / 'tree.txt').write_text(tree, encoding='utf-8')
            (dest / 'focus-lines.txt').write_text('\n'.join(
                f'{i+1:6} {line}' for i, line in enumerate(tree.splitlines()) if FOCUS.search(line)) + '\n', encoding='utf-8')
        picture = self.screenshot(dest / 'screen.png')
        state = self.optional(name, 'state', required=True)
        write_json(dest / 'state.json', state)
        logs = self.optional(name, 'log', required=name.startswith('home-music'), since=0)
        write_json(dest / 'log.json', logs)
        if isinstance(logs, dict):
            lines = logs.get('lines') or []
            (dest / 'important-log.txt').write_text('\n'.join(
                str(entry.get('text', '')) for entry in lines
                if FOCUS.search(str(entry.get('text', '')))) + '\n', encoding='utf-8')
            if name.startswith('home-music') and not any(
                    'redesign home section evidence' in str(entry.get('text', '')) for entry in lines):
                self.problems.append(f'{name}: Home classification evidence absent from SG_DRIVER logs')
        if name.startswith('library-recents'):
            # The position regression cannot be understood from UIView frames
            # alone: collect UICollectionView scroll geometry and insets.
            target = {'id': 'YourLibraryContent.collectionView'}
            for prop in ('frame', 'bounds', 'contentOffset', 'contentInset',
                         'adjustedContentInset', 'contentSize', 'safeAreaInsets'):
                write_json(dest / 'scroll-metrics' / (prop + '.json'),
                           self.optional(name, 'get', **target, path=prop))
            for identifier in ('YourLibraryHeader.title', 'Components.UI.FilterChips',
                               'YourLibraryContent.collectionView'):
                write_json(dest / 'named-views' / (identifier.replace('.', '_')+'.json'),
                           self.optional(name, 'find', **{'id': identifier}))
        if 'share' in name:
            write_json(dest / 'sheet-layers.json',
                       self.optional(name, 'layers', **{'id': 'sheet-view', 'depth': 10}))
        if name.startswith('mini-player'):
            write_json(dest / 'connect-button.json', self.optional(name, 'find',
                       **{'id': 'Components.ConnectButtonOutputSwitcher'}))

        if deep:
            # Target known classes without mutating views; store even failed lookups.
            for cls in VIEW_CLASSES:
                found = self.optional(name, 'find', **{'class': cls})
                write_json(dest / 'find' / f'{cls}.json', found)
                if not isinstance(found, dict) or not found.get('ok') or not found.get('count'):
                    continue
                # Large generic classes are numerous; only query optical view layers.
                if cls not in VIEW_CLASSES[:3] and cls != 'UIVisualEffectView':
                    continue
                count = min(3, int(found.get('count', 0)))
                for i in range(count):
                    layers = self.optional(name, 'layers', **{'class': cls, 'index': i, 'depth': 9})
                    write_json(dest / 'layers' / f'{cls}-{i}.json', layers)
                    for prop in ('frame', 'alpha', 'layer.opacity', 'layer.mask', 'layer.animationKeys'):
                        value = self.optional(name, 'get', **{'class': cls, 'index': i, 'path': prop})
                        write_json(dest / 'properties' / cls / f'{i}-{prop.replace(".", "_")}.json', value)
        complete = isinstance(tree, str) and len(tree) > 300 and picture and isinstance(state, dict) and state.get('ok') is not False
        self.results.append({'step': name, 'complete': bool(complete), 'time_s': round(time.monotonic()-self.rootTime, 3),
                             'duration_s': round(time.monotonic()-started, 3), 'treeChars': len(tree) if isinstance(tree, str) else 0})
        if not complete:
            self.problems.append(f'{name}: MISSING required tree, screenshot, or state')
        print(f'  {name}: {"captured" if complete else "INCOMPLETE"}', flush=True)
        return complete

    def start_video(self, tag):
        dest = self.root / tag
        dest.mkdir(parents=True, exist_ok=True)
        video = dest / 'motion.mp4'
        log = (dest / 'recording.log').open('w', encoding='utf-8')
        process = subprocess.Popen(['xcrun', 'simctl', 'io', self.args.udid, 'recordVideo', '--codec=h264', '--force', str(video)],
                                   stdout=log, stderr=subprocess.STDOUT)
        started = time.monotonic()
        for _ in range(40):
            if process.poll() is not None:
                log.close()
                raise RuntimeError(f'recordVideo exited unexpectedly: {dest / "recording.log"}')
            log.flush()
            if 'Recording started' in (dest / 'recording.log').read_text(encoding='utf-8', errors='replace'):
                return process, log, video, time.monotonic()
            time.sleep(.15)
        process.send_signal(signal.SIGINT)
        process.wait(timeout=10)
        log.close()
        raise RuntimeError('recordVideo never reported Recording started')

    def stop_video(self, process, log, path, started):
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=4)
        log.close()
        valid = path.exists() and path.stat().st_size > 4096
        check = {'file': str(path), 'bytes': path.stat().st_size if path.exists() else 0,
                 'capture_duration_s': round(time.monotonic()-started,3), 'exists_and_nonempty': valid}
        if shutil.which('ffprobe') and valid:
            p = run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_name,width,height,r_frame_rate',
                     '-select_streams', 'v:0', '-of', 'json', str(path)], 25)
            try:
                meta = json.loads(p['stdout'])
                check['probe'] = meta
                valid = (p['returncode'] == 0 and bool(meta.get('streams')) and float(meta.get('format',{}).get('duration') or 0) >= .4)
            except Exception:
                valid = False
        check['ok'] = bool(valid)
        self.videos.append(check)
        write_json(path.parent / 'video-check.json', check)
        if not valid:
            self.problems.append(f'Invalid or missing mandatory video: {path}')
        return bool(valid)

    def prompt(self, message):
        print('\n' + message, flush=True)
        if self.args.noninteractive:
            raise RuntimeError('Manual confirmation required; rerun without --noninteractive')
        input('When READY, press Enter here (Ctrl-C cancels): ')

    def manual_screen(self, name, note):
        if name.startswith('home-music') and dt.datetime.now().weekday() != 4:
            self.problems.append('NMF Friday-only regression: captured on a non-Friday date; keep evidence but do not infer absence')
        self.prompt(f'[{name}] {note}')
        self.snapshot(name + '/stable', deep=True)
        time.sleep(.4)
        self.snapshot(name + '/second-pass', deep=False)

    def capture_cold_share(self):
        tag = 'share-cold-first-presentation'
        print('\n[share-cold-first-presentation] This MUST start before the FIRST Share presentation since installation.', flush=True)
        print('Open the song menu but DO NOT open Share until the recorder says GO.', flush=True)
        if not self.args.fresh_install:
            self.problems.append('share-cold: NOT CERTIFIED as first presentation after fresh install (use --fresh-install if true)')
        self.prompt('Leave song menu open with the Share action visible; do not tap Share yet.')
        self.snapshot(tag + '/before', deep=False)
        process, log, video, started = self.start_video(tag)
        event = {'recorder_started_monotonic_s': round(started - self.rootTime, 3),
                 'confirmed_fresh_install': self.args.fresh_install}
        try:
            self.prompt('GO: tap Share NOW and allow its FIRST animation to finish. Then press Enter.')
            event['user_confirmed_sheet_open_s'] = round(time.monotonic()-self.rootTime,3)
            # Never block the animation with tree/layers requests; only record the video.
            time.sleep(1.8)
        finally:
            self.stop_video(process, log, video, started)
        write_json(self.root / tag / 'timing.json', event)
        self.snapshot(tag + '/after', deep=True)
        self.results.append({'step': 'share-cold', 'complete': bool(self.args.fresh_install),
                             'reason': 'video recorded but true cold state requires --fresh-install' if not self.args.fresh_install else 'cold state user-confirmed'})

    def capture_share_warm(self):
        tag = 'share-warm-repeat-presentation'
        self.prompt('Dismiss the Share sheet, return to the same song menu, and STOP BEFORE tapping Share.')
        self.snapshot(tag + '/before', deep=False)
        process, log, video, started = self.start_video(tag)
        try:
            self.prompt('GO: open Share again (warm path). After animation finishes, press Enter.')
            time.sleep(1.8)
        finally:
            self.stop_video(process, log, video, started)
        self.snapshot(tag + '/after', deep=True)
        self.results.append({'step': 'share-warm', 'complete': True, 'reason': 'warm Share presentation video captured'})

    def report(self):
        required = [step for step in self.args.scenarios if step not in ('home-music-previews-on',)]
        got = {result['step'].split('/')[0] for result in self.results if result.get('complete')}
        missing = [x for x in required if x not in got and x != 'share-cold']
        for name in missing:
            self.problems.append(f'{name}: expected evidence not collected')
        if 'share-cold' in required and not self.args.fresh_install:
            self.problems.append('share-cold cannot be verified without a fresh-install first run; video remains useful')
        result = {'status': 'INCOMPLETE' if self.problems else 'CAPTURED_NOT_VISUALLY_VERIFIED',
                  'note': 'A captured tree/video does not by itself prove a glass oval is missing or the NMF identity.',
                  'steps': self.results, 'videos': self.videos, 'missing_evidence': self.problems,
                  'optional_probe_warnings': self.warnings, 'scenarios_requested': self.args.scenarios}
        write_json(self.root / 'report.json', result)
        print('\nStatus:', result['status'], '\nEvidence:', self.root, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=8087)
    parser.add_argument('--udid', default=DEFAULT_UDID)
    parser.add_argument('--output', default='')
    parser.add_argument('--scenarios', nargs='+', default=['tabbar-settings', 'genres', 'song-menu-share', 'lyrics', 'mini-player', 'library-recents', 'home-music', 'home-music-previews-on'],
                        choices=[x[0] for x in SCENARIOS] + ['share-cold', 'share-warm'])
    parser.add_argument('--fresh-install', action='store_true', help='User confirms Share has NEVER been opened since installation (not guessed)')
    parser.add_argument('--noninteractive', action='store_true', help='Fail clearly rather than pretending manual windows were opened')
    args = parser.parse_args()
    if not args.output:
        args.output = f'out/stage38-manual-legacy-evidence-{dt.datetime.now().strftime("%Y%m%d-%H%M%S")}'
    evidence = Evidence(args)
    try:
        evidence.require_driver()
        evidence.metadata()
        for scenario in args.scenarios:
            if scenario == 'share-cold':
                evidence.capture_cold_share()
            elif scenario == 'share-warm':
                evidence.capture_share_warm()
            else:
                info = dict(SCENARIOS)[scenario]
                evidence.manual_screen(scenario, info)
    except (KeyboardInterrupt, EOFError):
        evidence.problems.append('Cancelled before completing every scenario')
    except Exception as exc:
        evidence.problems.append(f'Fatal error: {exc!r}')
        print(f'INCOMPLETE: {exc!r}', file=sys.stderr)
    finally:
        evidence.report()
        archive = evidence.root.with_suffix('.zip')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=4, allowZip64=True) as z:
            for file in evidence.root.rglob('*'):
                if file.is_file():
                    z.write(file, file.relative_to(evidence.root.parent))
        print('Archive:', archive, flush=True)
    return 1 if evidence.problems else 0


if __name__ == '__main__':
    sys.exit(main())
