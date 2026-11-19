# PR #227: automated DJ Queue diagnostic

The diagnostic patch is **read-only**: it records state and events but never
changes the queue, track order, preferences, or playback. Its event recorder is
compiled only when `SG_DRIVER=1`; regular release builds have no trace hooks.

## On the Mac with the simulator (iOS 27, port 8086)

```bash
cd ~/Downloads/spoti-fork
SIM_PORT=8086 SG_DRIVER=1 scripts/sim-build.sh \
  '/Users/andrew/Desktop/ipa/Spotify-9.1.90.ipa'
python3 scripts/dj-diagnose.py --port 8086 --seconds 240
```

While the last command is running, open AI DJ in the simulator and reproduce the
broken feature(s). For example: open Home/Recents to check DJ artwork; open
Queue to check the rows and Next DJ Set; try Edit/Remove/Undo or a swipe;
change track, then go Previous; and pause during a DJ-set transition. These
are *manual reproduction steps*; the diagnostic command does not trigger them.
To stop earlier press Ctrl-C. For a longer session, use `--seconds 0` and stop
with Ctrl-C. The script also checks visible UI elements every 3 seconds by
`find`, and detects prolonged mute/handover and mismatched queue state.

The resulting `out/dj-diagnostics-YYYYMMDD-HHMMSS.zip` contains:

- `REPORT.md` — summary and warnings with event counts
- `samples.jsonl` — timeline of playback, queue and controls
- `events.jsonl` — track arrivals, removals, changes of DJ set, and more
- `errors.jsonl` — unreadable driver samples, including after an app crash
- `summary.json` — machine-readable counters and findings

Events live in a bounded memory ring (768 entries). The Mac-side recorder
polls `dj.trace` and `dj.state` while the app is running; it **cannot recover
past traces** after the app is terminated and relaunched. No audio or screenshots
are captured. The reports do **not** contain raw Spotify URIs, song titles,
artists, access tokens, or account data. Per-process short track identifiers
allow correlating an event with a playback snapshot.

The summary is a set of heuristics, not proof that any specific issue is fixed
or broken. For example a transient empty queue during a handover is expected;
a persistent empty queue while AI DJ has future tracks may not be.

Run the offline diagnostic self-test (no simulator/Xcode required):

```bash
python3 harness/dj-diagnostics/check.py
```

The client deliberately does not auto-start `iproxy`: when targeting the
simulator's 8086 port, falling back to an attached phone would collect the
wrong session.
