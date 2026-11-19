#!/usr/bin/env python3
"""Autonomous PR #227 UI regression capture: real button taps + redacted DJ telemetry.

Use AFTER starting Spotify AI DJ on the desired output device (iPhone or Connect):
  python3 scripts/dj-autotest.py --port 8086 --allow-playback

The test clicks Queue, Edit, Next DJ Set, Previous, Next, Pause and Play where
visible; otherwise it explicitly labels core-command fallbacks. It records
per-operation latency, the stage of any blocked/slow segment skip, DJ artwork,
and changes in pause/track state. It does not remove, reorder, or enqueue songs.
A Next DJ Set tap changes real playback, including on a Connect target. No
second Next DJ Set tap is sent if the first hangs. Results are redacted locally.
"""
import argparse
import base64
import collections
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import secrets
import threading
import time
import zipfile

SPEC = importlib.util.spec_from_file_location("dj_diagnose", Path(__file__).with_name("dj-diagnose.py"))
diag = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diag)


def current_id(state):
    return (state or {}).get("current", {}).get("probeId", "-")


class Recorder:
    def __init__(self, driver, interval=0.5):
        self.driver = driver
        self.interval = interval
        self.salt = secrets.token_bytes(16)
        self.samples, self.events, self.errors = [], [], []
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.worker = None
        self.art = {}
        self.controls = {}
        self.last_ui_at = 0
        self.since = 0
        self.started = time.time()
        self.initial_art = {}

    def start(self):
        data = self.driver.call("dj.trace", since=0, limit=1)
        self.since = int(data.get("last", 0))
        self.initial_art = {k: int(data.get(k, 0)) for k in ("artCandidates", "artConfirmed", "artPlaylistLabels")}
        self.worker = threading.Thread(target=self._loop, name="dj-autotest-recorder", daemon=True)
        self.worker.start()

    def _loop(self):
        while not self.stop.is_set():
            tick = time.monotonic()
            sample = {"t": time.time()}
            for command, label, clean in (("dj.state", "dj", lambda r: diag.scrub_dj(r, self.salt)),
                                           ("state", "ui", diag.scrub_ui)):
                try:
                    sample[label] = clean(self.driver.call(command))
                except Exception as e:
                    self.errors.append({"t": sample["t"], "command": command, "error": type(e).__name__})
                    sample[label] = {"error": type(e).__name__}
            if time.monotonic() - self.last_ui_at > 2.0:
                self.last_ui_at = time.monotonic()
                try:
                    self.controls = diag.scrub_controls(self.driver.call("dj.ui"))
                except Exception as e:
                    self.errors.append({"t": sample["t"], "command": "dj.ui", "error": type(e).__name__})
            sample["controls"] = self.controls
            try:
                reply = self.driver.call("dj.trace", since=self.since, limit=256)
                batch = diag.scrub_trace(reply)
                self.art = {k: max(0, int(reply.get(k, 0)) - self.initial_art.get(k, 0)) for k in self.initial_art}
                if reply.get("events"):
                    self.since = max(self.since, max(int(e["seq"]) for e in reply["events"]))
                with self.lock:
                    self.events.extend(batch)
            except Exception as e:
                self.errors.append({"t": sample["t"], "command": "dj.trace", "error": type(e).__name__})
            with self.lock:
                self.samples.append(sample)
            self.stop.wait(max(0.05, self.interval - (time.monotonic() - tick)))

    def event_count(self, name):
        with self.lock:
            return sum(e["event"] == name for e in self.events)

    def latest_event(self, name):
        with self.lock:
            return next((event for event in reversed(self.events) if event["event"] == name), None)

    def finish(self):
        self.stop.set()
        if self.worker:
            self.worker.join(timeout=8)


class AutoTest:
    def __init__(self, driver, recorder, settle=0.5, screenshots_folder=None):
        self.driver, self.recorder, self.settle = driver, recorder, settle
        self.screenshots_folder = screenshots_folder
        self.actions = []
        self.started = time.monotonic()

    def record(self, stage, result, elapsed=0, detail="", **extra):
        row = {"stage": stage, "result": result, "elapsedMs": round(elapsed * 1000),
               "timeS": round(time.monotonic() - self.started, 2), "detail": detail, **extra}
        self.actions.append(row)
        print(f"  {stage}: {result} ({row['elapsedMs']} ms){' — ' + detail if detail else ''}", flush=True)
        return result == "PASS"

    def screenshot(self, stage):
        if self.screenshots_folder is None:
            return
        try:
            raw = self.driver.call("screenshot", scale=0.75)
            png = base64.b64decode(raw["png"], validate=True)
            (self.screenshots_folder / (stage + ".png")).write_bytes(png)
            self.record("screenshot." + stage, "PASS")
        except Exception as exc:
            self.record("screenshot." + stage, "CHECK", detail=type(exc).__name__)

    def call(self, stage, command, **params):
        before = time.monotonic()
        try:
            self.driver.call(command, **params)
        except Exception as exc:
            self.record(stage, "FAIL", time.monotonic() - before, type(exc).__name__)
            return False
        return self.record(stage, "PASS", time.monotonic() - before)

    def state(self):
        try:
            return self.driver.call("dj.state")
        except Exception:
            return {}

    def shown(self, key, value):
        try:
            r = self.driver.call("find", **{key: value})
            return [v for v in r.get("views", []) if v.get("shown")]
        except Exception:
            return []

    def tap_any(self, stage, candidates):
        """Never hit arbitrary screen coordinates; only tap a uniquely shown named control."""
        for kind, value in candidates:
            matches = self.shown(kind, value)
            if len(matches) == 1:
                return self.call(stage, "tap", **{kind: value})
        self.record(stage, "SKIP", detail="no unique visible matching UI control")
        return False

    def observe(self, seconds, condition, step=0.35):
        start = time.monotonic()
        while time.monotonic() - start < seconds:
            try:
                if condition():
                    return time.monotonic() - start
            except Exception:
                pass
            time.sleep(step)
        return None

    def controls(self):
        try:
            return diag.scrub_controls(self.driver.call("dj.ui"))
        except Exception:
            return {}

    def unstable_playback(self):
        with self.recorder.lock:
            arrivals = [e for e in self.recorder.events if e.get("event") == "player.state" and
                        e.get("data", {}).get("arrived") and
                        e.get("data", {}).get("position", 999) <= 1.5]
        if not arrivals:
            return False
        last = arrivals[-1]["t"]
        return len({e.get("data", {}).get("track") for e in arrivals if 0 <= last - e["t"] <= 3}) >= 8

    def change_via_ui(self, title, labels, fallback=None):
        if self.tap_any(title + ".tap", [("label", x) for x in labels]):
            return "ui"
        if fallback:
            self.call(title + ".coreFallback", fallback)
            return "core"
        return "missing"

    def run(self, max_wait=26):
        initial = self.state()
        if not initial.get("sessionDetected"):
            self.record("prerequisite.aiDJ", "FAIL", detail="AI DJ not active; start DJ before running autotest")
            return
        self.record("prerequisite.aiDJ", "PASS", detail="current DJ session detected")
        paused_initially = bool(initial.get("paused"))
        self.record("output.gate", "PASS", detail=("local audio output available" if initial.get("localAudioReady") else
                    "no local audio output (Connect or inactive local renderer)"),
                    localAudioReady=bool(initial.get("localAudioReady")), speedAllowed=bool(initial.get("speedAllowed")))
        try:
            self.call("player.open", "player.open")
            time.sleep(self.settle)
            if not self.tap_any("queue.open", [("label", "Queue")]):
                self.record("queue.open", "FAIL", detail="Queue button could not be located")
                return
            time.sleep(self.settle)
            controls = self.controls()
            self.screenshot("queue")
            self.record("queue.nextSet.present", "PASS" if controls.get("nextSet", {}).get("shown") else "FAIL")
            if controls.get("edit", {}).get("shown"):
                if self.call("queue.edit.enter", "tap", id="queue-edit-button"):
                    time.sleep(self.settle)
                    hidden = self.controls().get("nextSet", {}).get("shown", 0) == 0
                    self.screenshot("edit")
                    self.record("queue.nextSet.hiddenWhileEditing", "PASS" if hidden else "FAIL")
                    self.call("queue.edit.exit", "tap", id="queue-close-edit-button")
                    time.sleep(self.settle)
            else:
                self.record("queue.edit", "SKIP", detail="Edit control absent")
            # This clicks the actual custom queue button, not a direct core method.
            if self.controls().get("nextSet", {}).get("shown"):
                begin = time.monotonic()
                before_end = self.recorder.event_count("segment.skip.end")
                before_block = self.recorder.event_count("segment.skip.blocked")
                before_begin = self.recorder.event_count("segment.skip.begin")
                before_pick = self.recorder.event_count("pick.finish")
                tap_ok = self.call("nextSet.tap", "tap", id="vitrine-dj-new-segment")
                if tap_ok:
                    elapsed = self.observe(max_wait, lambda: (
                        self.recorder.event_count("segment.skip.end") > before_end or
                        self.recorder.event_count("segment.skip.blocked") > before_block or
                        self.recorder.event_count("pick.finish") > before_pick or
                        not self.state().get("sessionDetected")), step=0.45)
                    if self.recorder.event_count("segment.skip.blocked") > before_block:
                        self.record("nextSet.outcome", "FAIL", time.monotonic() - begin,
                                    "blocked by local-audio gate; reproduces Connect regression")
                    elif self.recorder.event_count("segment.skip.end") > before_end:
                        event = self.recorder.latest_event("segment.skip.end")
                        changed = bool(event.get("data", {}).get("changed")) if event else False
                        self.record("nextSet.outcome", "PASS" if changed else "FAIL",
                                    time.monotonic() - begin,
                                    "transition completed" if changed else "transition ended without a new DJ segment")
                    elif self.recorder.event_count("pick.finish") > before_pick:
                        event = self.recorder.latest_event("pick.finish")
                        changed = bool(event.get("data", {}).get("changed")) if event else False
                        self.record("nextSet.outcome", "PASS" if changed else "FAIL",
                                    time.monotonic() - begin,
                                    "DJ request completed" if changed else "DJ request finished without a new segment")
                    else:
                        self.record("nextSet.outcome", "FAIL", time.monotonic() - begin,
                                    "no completion event within bounded window")
                    if self.recorder.event_count("segment.skip.begin") > before_begin:
                        self.record("nextSet.skipMode", "PASS", detail="skip-mode transition entered")
            else:
                self.record("nextSet.tap", "SKIP", detail="button not visible after Edit")
            # Do not compound an uncontrolled skip loop with further playback commands.
            if self.unstable_playback() or self.state().get("handover"):
                self.record("playback.safetyStop", "FAIL",
                            detail="rapid track cycling or unfinished handover; skipping remaining playback taps")
                return
            # Try to navigate back from queue using only named controls.
            if self.state().get("pageVisible"):
                self.tap_any("queue.dismiss", [("id", "queue-close-button"), ("label", "Back"),
                                               ("label", "Close queue")])
                time.sleep(self.settle)
            self.call("player.open.again", "player.open")
            time.sleep(self.settle)
            # Previous/Next prefer real player buttons; exact fallback core commands are labelled.
            earlier = current_id(self.state())
            method = self.change_via_ui("previous", ("Previous track", "Previous"), "previous")
            if method != "missing":
                took = self.observe(7, lambda: current_id(self.state()) != earlier, step=0.5)
                self.record("previous.transition", "PASS" if took is not None else "CHECK",
                            took or 7, "track identity changed" if took is not None else "no track change observed")
            if self.unstable_playback() or self.state().get("handover"):
                self.record("playback.safetyStop", "FAIL", detail="Previous triggered repeated skips or an unfinished handover")
                return
            earlier = current_id(self.state())
            method = self.change_via_ui("next", ("Next track", "Next"), "next")
            if method != "missing":
                took = self.observe(7, lambda: current_id(self.state()) != earlier, step=0.5)
                self.record("next.transition", "PASS" if took is not None else "CHECK", took or 7,
                            "track identity changed" if took is not None else "no track change observed")
            if self.unstable_playback() or self.state().get("handover"):
                self.record("playback.safetyStop", "FAIL", detail="Next triggered repeated skips or an unfinished handover")
                return
            if not self.state().get("paused"):
                self.change_via_ui("pause", ("Pause",), "pause")
                took = self.observe(5, lambda: self.state().get("paused"), step=0.35)
                self.record("pause.ack", "PASS" if took is not None else "FAIL", took or 5)
            else:
                self.record("pause.alreadyPaused", "PASS")
            if self.state().get("paused"):
                self.change_via_ui("play", ("Play",), "play")
                took = self.observe(5, lambda: not self.state().get("paused"), step=0.35)
                self.record("play.ack", "PASS" if took is not None else "FAIL", took or 5)
            if paused_initially and not self.state().get("paused"):
                self.call("restore.initialPause", "pause")
            self.call("player.close", "player.close")
            self.tap_any("home.open", [("label", "Home")])  # never select a track on Home
            time.sleep(1.5)
            self.screenshot("home")
            self.record("home.artwork.observations", "PASS", detail="Home visited; compare overlay and classifier counters")
        finally:
            # Do not leave the player paused when it was initially playing.
            if not paused_initially and self.state().get("paused") and not self.state().get("handover"):
                self.call("restore.initialPlaying", "play")


def report(folder, runner, rec, duration, port):
    findings = diag.interpret(rec.samples, rec.events, rec.errors, rec.art)
    for item in runner.actions:
        if item["result"] == "FAIL":
            findings.append({"code": item["stage"], "level": "warning", "description": item["detail"] or "automated check failed"})
    counts = collections.Counter(x["event"] for x in rec.events)
    lines = ["# PR #227 — autonomous UI and playback diagnostic", "",
             f"- Port: {port}", f"- Duration: {duration:.1f} s", f"- Captured samples: {len(rec.samples)}",
             f"- Trace events: {len(rec.events)}", f"- Driver errors: {len(rec.errors)}", "",
             "## Automated actions and timings", ""]
    for a in runner.actions:
        lines.append(f"- **{a['result']}** `{a['stage']}` — {a['elapsedMs']} ms" + (f" — {a['detail']}" if a['detail'] else ""))
    lines += ["", "## Skip-stage timing", ""]
    stages = [e for e in rec.events if e["event"].startswith("segment.skip.")]
    for e in stages:
        data = e.get("data", {})
        lines.append(f"- `{e['event']}` at {round(e['t'] - rec.started, 2)} s" +
                     (f" · elapsedMs={data['elapsedMs']}" if "elapsedMs" in data else ""))
    if not stages:
        lines.append("- No skip-stage events were observed; inspect button and remote guard findings.")
    lines += ["", "## Findings", ""]
    lines += [f"- {f['level'].upper()}: `{f['code']}` — {f['description']}" for f in findings] or ["- None detected (not proof of correctness)."]
    lines += ["", "## Artwork and event counts", "",
              f"- DJ artwork candidates: {rec.art.get('artCandidates', 0)}",
              f"- Confirmed DJ artwork: {rec.art.get('artConfirmed', 0)}", ""]
    lines += [f"- `{name}`: {count}" for name, count in counts.most_common()]
    lines += ["", "## Notes", "", "This test presses playback controls and can change the current DJ set on a Connect device.",
              "It does not delete or reorder tracks. Raw identifiers and titles are not saved in text reports.",
              "CHECK/SKIP mean unverified, not pass. Screenshots, if requested, may include song names and account details."]
    (folder / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    diag.write_jsonl(folder / "actions.jsonl", runner.actions)
    diag.write_jsonl(folder / "samples.jsonl", rec.samples)
    diag.write_jsonl(folder / "events.jsonl", rec.events)
    diag.write_jsonl(folder / "errors.jsonl", rec.errors)
    (folder / "summary.json").write_text(json.dumps({"findings": findings, "events": dict(counts),
        "art": rec.art, "actions": len(runner.actions)}, indent=2), encoding="utf-8")
    zipped = folder.with_suffix(".zip")
    with zipfile.ZipFile(zipped, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for item in folder.iterdir():
            if item.is_file():
                archive.write(item, item.name)
    return zipped, findings


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=int(os.getenv("SIM_PORT", "8086")))
    p.add_argument("--allow-playback", action="store_true", help="confirm real playback-control taps")
    p.add_argument("--max-next-set-wait", type=float, default=26, help="bounded wait after the one DJ Set tap")
    p.add_argument("--screenshots", action="store_true", help="capture UI images (may include song names/account details)")
    p.add_argument("--output", help="new results folder")
    a = p.parse_args()
    if not a.allow_playback:
        p.error("add --allow-playback: this test will press Next DJ Set, Previous, Next, Pause and Play")
    if not 5 <= a.max_next_set_wait <= 40:
        p.error("--max-next-set-wait must be 5..40 seconds")
    driver = diag.Driver("127.0.0.1", a.port, 4)
    folder = Path(a.output or f"out/dj-autotest-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}").resolve()
    folder.mkdir(parents=True, exist_ok=False)
    recorder = Recorder(driver)
    runner = AutoTest(driver, recorder, screenshots_folder=folder if a.screenshots else None)
    try:
        recorder.start()
    except Exception as exc:
        folder.rmdir()
        p.error(f"DJ driver is unavailable at 127.0.0.1:{a.port}: {type(exc).__name__}")
    print("Starting automated DJ test. Keep Spotify foregrounded; do not tap manually.", flush=True)
    try:
        runner.run(a.max_next_set_wait)
    except KeyboardInterrupt:
        runner.record("interrupted", "CHECK", detail="test interrupted by user")
    except Exception as exc:
        runner.record("unexpectedException", "FAIL", detail=type(exc).__name__)
    finally:
        recorder.finish()
        zipped, findings = report(folder, runner, recorder, time.monotonic() - runner.started, a.port)
        print(f"Report: {folder / 'REPORT.md'}\nZIP: {zipped}\nWarnings: {sum(f['level'] == 'warning' for f in findings)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
