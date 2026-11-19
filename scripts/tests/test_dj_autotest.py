#!/usr/bin/env python3
"""Tests for non-destructive autonomous DJ UI regression probing without iOS."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'dj-autotest.py'
spec = importlib.util.spec_from_file_location('dj_autotest', PATH)
auto = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto)


class StubRecorder:
    def __init__(self, events=None):
        import threading
        self.lock = threading.Lock()
        self.events = events or []
        self.samples = []
        self.errors = []
        self.art = {}
        self.started = 100.0

    def event_count(self, name):
        return sum(x['event'] == name for x in self.events)


class StubDriver:
    def __init__(self, unique=True):
        self.calls = []
        self.unique = unique

    def call(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if command == 'find':
            return {'views': [{'shown': True}, {'shown': True}] if not self.unique else [{'shown': True}]}
        if command == 'dj.state':
            return {'sessionDetected': True, 'localAudioReady': False, 'speedAllowed': True,
                    'paused': True, 'current': {'probeId': '12345678'}}
        if command == 'dj.ui':
            return {'controls': {'nextSet': {'total': 1, 'shown': 1, 'enabled': 1},
                                 'edit': {'total': 1, 'shown': 1, 'enabled': 1}}}
        if command == 'dj.trace':
            return {'events': [], 'last': 0}
        return {'ok': True}


class AutoTestTests(unittest.TestCase):
    def test_unique_label_tapped(self):
        driver = StubDriver()
        runner = auto.AutoTest(driver, StubRecorder(), settle=0)
        self.assertTrue(runner.tap_any('queue', [('label', 'Queue')]))
        self.assertIn(('tap', {'label': 'Queue'}), driver.calls)

    def test_ambiguous_label_never_tapped(self):
        driver = StubDriver(unique=False)
        runner = auto.AutoTest(driver, StubRecorder(), settle=0)
        self.assertFalse(runner.tap_any('queue', [('label', 'Queue')]))
        self.assertFalse(any(command == 'tap' for command, _ in driver.calls))

    def test_remote_guard_report_and_stop(self):
        driver = StubDriver()
        events = [{'event': 'segment.skip.blocked', 't': 102.0,
                   'data': {'localAudioReady': False}}]
        recorder = StubRecorder(events)
        runner = auto.AutoTest(driver, recorder, settle=0)
        runner.record('nextSet.outcome', 'FAIL', detail='blocked by local-audio gate')
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'report'
            folder.mkdir()
            zipped, findings = auto.report(folder, runner, recorder, 2, 8086)
            self.assertTrue(zipped.exists())
            self.assertIn('next_set_local_guard', [f['code'] for f in findings])
            self.assertNotIn('spotify:', (folder / 'REPORT.md').read_text())

    def test_rapid_changes_trigger_safety_stop(self):
        arrivals = [{'event': 'player.state', 't': 120 + i * 0.1,
                     'data': {'arrived': True, 'track': f'{i:08x}', 'position': 0}}
                    for i in range(9)]
        runner = auto.AutoTest(StubDriver(), StubRecorder(arrivals), settle=0)
        self.assertTrue(runner.unstable_playback())

    def test_no_delete_or_reorder_actions(self):
        # Autonomous runner must never mutate the DJ queue directly.
        src = PATH.read_text()
        self.assertNotIn('self.call("queue.remove"', src)
        self.assertNotIn('self.call("queue.swipe"', src)
        self.assertNotIn('driver.call("swipe"', src)


if __name__ == '__main__':
    unittest.main()
