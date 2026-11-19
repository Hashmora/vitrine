#!/usr/bin/env python3
"""Record an automated, read-only DJ Queue diagnostic session from the phone driver.

Prerequisite: SIM_PORT=8086 SG_DRIVER=1 scripts/sim-build.sh Spotify.ipa
Usage: python3 scripts/dj-diagnose.py --port 8086 --seconds 180

Open DJ and exercise the broken features while this runs; no controls are pressed
by the recorder. Ctrl-C ends recording and still writes a report + ZIP.
Only state flags, counts, and pseudonymous per-run track identifiers are saved.
No song names, Spotify URIs, account data, or driver log text leave the app.
"""
import argparse
import collections
import datetime as dt
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

DJ_CONTEXT = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"
FIELDS = (
    "active", "sessionDetected", "ordered", "handover", "muted", "mutedBuffers", "paused",
    "duplicateBeforeOutro", "localAudioReady", "speedAllowed", "queueRows", "injectedRows", "aheadRows", "hiddenCount",
    "playedCount", "orderCount", "copyCount", "waiting", "picking", "pageVisible",
    "editMode", "sessionGeneration", "position", "duration", "displayPosition",
    "nonDJCapSamples", "nonDJExtraNextTotal", "nonDJExtraPrevTotal",
    "nonDJExtraNextPeak", "nonDJExtraPrevPeak",
)


def pseudonym(value, salt):
    return hashlib.sha256(salt + str(value).encode("utf-8")).hexdigest()[:10] if value else "-"


def safe_tag(value, fallback, salt):
    # Even a malformed/unexpected driver must never put an unredacted UID in a report.
    return value if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{8}", value) else pseudonym(fallback, salt)


def track_info(obj, salt):
    if not isinstance(obj, dict):
        return None
    uri = obj.get("uri", "")
    return {
        "id": safe_tag(obj.get("probeId"), obj.get("uid"), salt),
        "logicalId": safe_tag(obj.get("logicalProbeId"), obj.get("logicalUID"), salt),
        "kind": "voice" if uri.startswith("spotify:media:") else (
            "song" if uri.startswith("spotify:track:") else "other"),
        "queued": bool(obj.get("queued")), "played": bool(obj.get("played")),
        "hidden": bool(obj.get("hidden")),
    }


def scrub_dj(reply, salt):
    if reply.get("note"):
        return {"note": "no player state"}
    out = {key: reply[key] for key in FIELDS if key in reply}
    out["contextKind"] = "dj" if reply.get("context") == DJ_CONTEXT else (
        "other" if reply.get("context") else "none")
    out["current"] = track_info(reply.get("current"), salt)
    out["shown"] = track_info(reply.get("shown"), salt)
    out["future"] = [track_info(x, salt) for x in reply.get("future", []) if isinstance(x, dict)]
    return out


def scrub_controls(reply):
    allowed = ("edit", "nextSet", "nativeArt", "redesignedArt")
    out = {}
    for name in allowed:
        fields = reply.get("controls", {}).get(name, {})
        out[name] = {k: max(0, int(fields.get(k, 0))) for k in ("total", "shown", "enabled")}
    return out


def scrub_ui(reply):
    current = reply.get("nowPlaying")
    result = {"playerOpen": bool(reply.get("player")), "menuOpen": bool(reply.get("menu"))}
    # Controller class names are implementation details, not user content.
    if current and isinstance(current, dict):
        result["playing"] = bool(current.get("playing"))
        result["paused"] = bool(current.get("paused"))
    return result


def scrub_trace(reply):
    # The native event stream contains only known, fixed-size flags and counters;
    # never allow new arbitrary text fields to enter the report by accident.
    allowed_events = {
        "artwork.classifier", "queue.enter", "queue.leave", "queue.rows", "queue.set", "queue.swipe",
        "button.tap", "button.render", "pick.begin", "pick.finish", "player.state",
        "previous.refused", "previous.target", "previous.fallback",
        "skip.internal", "segment.skip.begin", "segment.skip.end", "segment.hold.begin",
        "segment.land.begin", "segment.outro.begin", "segment.skip.blocked",
        "segment.skip.pauseAck", "segment.skip.newPage", "segment.skip.jump", "segment.skip.physical",
    }
    allowed_strings = {"track", "target", "current", "direction"}
    events = []
    for e in reply.get("events", []):
        if e.get("event") not in allowed_events:
            continue
        data = {}
        for k, value in e.get("data", {}).items():
            if isinstance(value, bool) or isinstance(value, (int, float)):
                data[k] = value
            elif isinstance(value, str) and k == "direction" and value in ("add", "remove"):
                data[k] = value
            elif isinstance(value, str) and k in allowed_strings and re.fullmatch(r"[0-9a-f]{8}", value):
                data[k] = value
        events.append({"seq": int(e["seq"]), "t": float(e["t"]),
                       "event": e["event"], "data": data})
    return events


class Driver:
    def __init__(self, host, port, timeout):
        self.url = f"http://{host}:{port}"
        self.timeout = timeout

    def call(self, command, **params):
        query = urllib.parse.urlencode(params)
        url = f"{self.url}/{urllib.parse.quote(command)}" + (f"?{query}" if query else "")
        request = urllib.request.Request(url, headers={"X-Phone-Driver": "1"})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            obj = json.load(response)
        if not obj.get("ok"):
            raise RuntimeError(f"{command}: {str(obj.get('error', 'unknown failure'))[:120]}")
        return obj


def interpret(samples, events, errors, artwork=None):
    findings = []
    artwork = artwork or {}

    def flag(key, severity, message):
        if not any(x["code"] == key for x in findings):
            findings.append({"code": key, "level": severity, "description": message})

    if errors:
        flag("driver_errors", "warning", f"Driver requests failed {len(errors)} times; see errors.jsonl")
    active = [s for s in samples if s.get("dj", {}).get("active")]
    if not active:
        flag("no_dj", "info", "No active DJ session observed; play AI DJ and repeat the capture")
    if any(s.get("dj", {}).get("sessionDetected") and
           s.get("dj", {}).get("pageVisible") and not s.get("dj", {}).get("active") for s in samples):
        flag("dj_not_active", "warning", "Queue screen visible with DJ session detected, but DJ queue inactive")
    if any(s.get("dj", {}).get("active") and s.get("dj", {}).get("pageVisible") and
           s.get("dj", {}).get("future") and not s.get("dj", {}).get("queueRows") and
           not s.get("dj", {}).get("handover") for s in samples):
        flag("empty_queue", "warning", "DJ has future tracks, but a visible queue showed zero rows")
    if any(s.get("dj", {}).get("active") and s.get("dj", {}).get("pageVisible") and
           s.get("dj", {}).get("editMode") and
           s.get("dj", {}).get("picking") for s in samples):
        flag("edit_pick", "info", "Edit and DJ-set selection overlapped; inspect button visibility")
    for field, maximum, key in (("muted", 9, "mute_long"), ("handover", 15, "handover_long")):
        since = None
        for s in samples:
            if s.get("dj", {}).get(field):
                if since is None:
                    since = s["t"]
                if s["t"] - since > maximum:
                    flag(key, "warning", f"{field} remained true for more than {maximum} s")
            else:
                since = None
    missing_button = [s for s in samples if s.get("dj", {}).get("active") and
                      s.get("dj", {}).get("pageVisible") and not s.get("dj", {}).get("editMode") and
                      s.get("controls", {}).get("edit", {}).get("shown", 0) > 0 and
                      s.get("controls", {}).get("nextSet", {}).get("shown", 0) == 0]
    if len(missing_button) >= 3 and any(e["event"] == "button.render" and
                                      e["data"].get("visible") for e in events):
        flag("next_set_missing", "warning", "Queue Edit is visible but Next DJ Set is missing despite a visible render decision")
    if any(s.get("controls", {}).get("nativeArt", {}).get("shown", 0) and
           s.get("controls", {}).get("redesignedArt", {}).get("shown", 0) for s in samples):
        flag("both_artworks", "warning", "Native and Redesigned DJ artwork overlays visible at the same time")
    if any(e["event"] == "segment.skip.blocked" for e in events):
        flag("next_set_local_guard", "warning", "Next DJ Set was blocked by the local-audio guard (typical on Spotify Connect)")
    if any(e["event"] == "previous.fallback" for e in events):
        flag("previous_fallback", "info", "Previous navigation required fallback; inspect nearby samples")
    if any(e["event"] == "queue.set" and e["data"].get("sent", 0) > 0 and
           e["data"].get("djRows", 0) == 0 and e["data"].get("injected", 0) > 0 for e in events):
        flag("remove_unmatched", "warning", "Native setQueue contained no recognized DJ rows; Edit/Remove may be ignored")
    if any(e["event"] == "button.render" and e["data"].get("visible") and
           any(next_ev["event"] == "queue.leave" for next_ev in events[i+1:])
           for i, e in enumerate(events)) and not any(
            e["event"] == "button.render" and not e["data"].get("visible") for e in events):
        flag("button_not_hidden", "warning", "Next DJ Set was shown but no hide redraw was recorded after leaving DJ")
    # A fast run through many distinct zero-position tracks was present in
    # the first PR #227 recording but previously returned zero warnings.
    # This is suspicious, not proof of a playback bug: an explicit jump or
    # internally requested skips may account for it. Preserve those events.
    arrivals = [e for e in events if e.get("event") == "player.state" and
                e.get("data", {}).get("arrived") and
                e.get("data", {}).get("position", 999) <= 1.5]
    for index, first in enumerate(arrivals):
        window = [e for e in arrivals[index:] if 0 <= e["t"] - first["t"] <= 3]
        if len({e.get("data", {}).get("track") for e in window}) >= 8:
            flag("rapid_track_changes", "warning",
                 "At least eight distinct tracks arrived near 0 s within three seconds; "
                 "compare skip.internal and user actions to determine whether the skips were intended")
            break
    if artwork.get("artCandidates", 0) >= 10 and artwork.get("artConfirmed", 0) == 0:
        flag("artwork_unconfirmed", "warning",
             "DJ artwork classifier saw at least ten candidates but confirmed none; "
             "check the card identity fields and native/redesigned Home and Recents")
    if len(samples) < 2:
        flag("insufficient_samples", "info", "Too few samples to check transitions")
    return findings


def write_jsonl(path, records):
    with path.open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False, sort_keys=True, default=str) + "\n")


def write_report(folder, samples, events, errors, art, findings, port, started, duration):
    counts = collections.Counter(e["event"] for e in events)
    stages = collections.Counter("active" if s.get("dj", {}).get("active") else "other" for s in samples)
    warnings = [x for x in findings if x["level"] == "warning"]
    lines = ["# Vitrine PR #227 — automated DJ diagnostic", "",
             f"- Start: {started}", f"- Duration: {duration:.1f} s", f"- Port: {port}",
             f"- State samples: {len(samples)} (DJ active: {stages['active']})",
             f"- Trace events: {len(events)}", f"- Driver request failures: {len(errors)}",
             f"- Findings requiring review: {len(warnings)}", "",
             "## Findings", ""]
    lines += [f"- **{x['level'].upper()} / {x['code']}**: {x['description']}" for x in findings] or ["- No heuristic warnings observed. This is not proof that playback is correct."]
    lines += ["", "## Event summary", ""]
    lines += [f"- `{key}`: {count}" for key, count in counts.most_common()] or ["- No DJ events recorded."]
    lines += ["", "## Artwork classifier (number of hook observations)", "",
              f"- Candidate labels: {art.get('artCandidates', 0)}",
              f"- Positively identified DJ cards: {art.get('artConfirmed', 0)}",
              f"- Rejected generic playlist labels: {art.get('artPlaylistLabels', 0)}", "",
              "## Privacy and interpretation", "",
              "Track identifiers are locally pseudonymized; titles, artists, URIs and account data are omitted.",
              "A missing event or an automated warning is evidence to investigate, not confirmation of a bug.",
              "The recorder performs no playback actions; manually reproduce broken features during capture.", ""]
    (folder / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")
    (folder / "summary.json").write_text(json.dumps({"samples": len(samples), "events": len(events),
        "errors": len(errors), "eventCounts": dict(counts), "art": art, "findings": findings}, indent=2), encoding="utf-8")
    archive = folder.with_suffix(".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for path in sorted(folder.iterdir()):
            if path.is_file():
                z.write(path, path.name)
    return archive


def capture(args):
    folder = Path(args.output or f"out/dj-diagnostics-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}").resolve()
    folder.mkdir(parents=True, exist_ok=False)
    driver = Driver("127.0.0.1", args.port, args.timeout)
    salt = secrets.token_bytes(16)
    samples, events, errors = [], [], []
    since, art = 0, {}
    last_ui_at = -1e9
    controls = {}
    started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    began = time.monotonic()
    try:
        driver.call("dj.trace", since=0, limit=1)
    except Exception as exc:
        print(f"No diagnostic driver at 127.0.0.1:{args.port}: {exc}\n"
              "Build with SG_DRIVER=1, launch Spotify, and check the SIM_PORT.", file=sys.stderr)
        folder.rmdir()
        return 2
    print(f"Recording DJ diagnostics on 127.0.0.1:{args.port}. Reproduce the problem now; Ctrl-C finishes.")
    try:
        while args.seconds <= 0 or time.monotonic() - began < args.seconds:
            time_now = time.time()
            record = {"t": time_now}
            for command, key, scrub in (("dj.state", "dj", lambda x: scrub_dj(x, salt)),
                                       ("state", "ui", scrub_ui)):
                try:
                    record[key] = scrub(driver.call(command))
                except (OSError, TimeoutError, ValueError, RuntimeError) as exc:
                    errors.append({"t": time_now, "command": command, "error": type(exc).__name__})
                    record[key] = {"error": type(exc).__name__}
            if time.monotonic() - last_ui_at >= args.ui_every:
                last_ui_at = time.monotonic()
                try:
                    controls = scrub_controls(driver.call("dj.ui"))
                except (OSError, TimeoutError, ValueError, RuntimeError) as exc:
                    controls = {}
                    errors.append({"t": time_now, "command": "dj.ui", "error": type(exc).__name__})
            if controls:
                record["controls"] = controls
            samples.append(record)
            try:
                reply = driver.call("dj.trace", since=since, limit=256)
                batch = scrub_trace(reply)
                events.extend(batch)
                if reply.get("events"):
                    since = max(since, max(int(e["seq"]) for e in reply["events"]))
                art = {k: reply.get(k, 0) for k in ("artCandidates", "artConfirmed", "artPlaylistLabels", "trimmed", "lostBefore")}
            except (OSError, TimeoutError, ValueError, RuntimeError) as exc:
                errors.append({"t": time_now, "command": "dj.trace", "error": type(exc).__name__})
            if len(samples) % max(1, int(10 / args.interval)) == 0:
                print(f"  {time.monotonic()-began:.0f}s: {len(samples)} samples, {len(events)} events, {len(errors)} errors", flush=True)
            time.sleep(max(0, args.interval - (time.time() - time_now)))
    except KeyboardInterrupt:
        print("Stopping capture…")
    finally:
        duration = time.monotonic() - began
        findings = interpret(samples, events, errors, art)
        write_jsonl(folder / "samples.jsonl", samples)
        write_jsonl(folder / "events.jsonl", events)
        write_jsonl(folder / "errors.jsonl", errors)
        archive = write_report(folder, samples, events, errors, art, findings, args.port, started, duration)
        print(f"Report: {folder/'REPORT.md'}")
        print(f"Archive: {archive}")
        print(f"Findings: {sum(x['level'] == 'warning' for x in findings)} warnings")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=int(os.getenv("SIM_PORT", "8086")))
    p.add_argument("--seconds", type=float, default=180, help="0 means until Ctrl-C")
    p.add_argument("--interval", type=float, default=0.75, help="seconds between state samples")
    p.add_argument("--timeout", type=float, default=3)
    p.add_argument("--ui-every", type=float, default=3, help="seconds between read-only UI probes")
    p.add_argument("--output", help="new output folder; defaults to out/dj-diagnostics-TIMESTAMP")
    args = p.parse_args()
    if args.interval < 0.25 or args.timeout <= 0 or args.seconds < 0 or args.ui_every < 1:
        p.error("interval >= 0.25, timeout > 0, seconds >= 0, ui-every >= 1 required")
    return capture(args)


if __name__ == "__main__":
    raise SystemExit(main())
