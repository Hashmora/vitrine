# PR #227 — `getState` cap behavior and measurement

## Why the context-free subscription is not gated on the current track

The queue needs enough future tracks to populate an AI DJ segment (up to 16
requested, though the core can return fewer). `ESPContextPlayerClientImpl
getState:onResponse:` also receives a **context-free, long-lived subscription**
created before Spotify selects any playback context. The subscription remains
active when the user later starts the DJ. Limiting that request according to
*the context currently playing* would bake the ordinary cap into the subscription
and risk leaving a later DJ session with too few tracks. Requests bearing an
explicit non-DJ `contextURI` already retain Spotify's original cap.

No safe subscription replacement or dynamic resubscription mechanism has been
verified for Spotify 9.1.90. Until one is established on a device, the context-
free subscription still requests 16 next and 16 previous tracks. This is a
**deliberate compatibility limitation**, not a claim that non-DJ behavior is
fully unchanged. The extra data must be measured and disclosed to the reviewer.

## Evidence already collected (simulator, DJ Queue enabled)

The user-supplied `dj-diagnostics-20261120-010846.zip` recorded **78 non-DJ
snapshots across 59.43 seconds**. They contained **one distinct state
signature** repeated across the recording, not 78 distinct ESP responses.
The state exposed **16 future references** in each sample, compared with the
original request cap of 2: **14 additional future-track references** visible
in the reported state. Previous-track counts were not present in this capture.

These are counts of references in sampled state, **not** measured network bytes,
number of server requests, allocations, CPU time, power consumption, or a
memory-retention estimate. A single repeated state cannot establish a request
rate or energy cost. No baseline with the DJ switch disabled has been collected.

## Reproducible A/B procedure

1. Build Spotify 9.1.90 with `SG_DRIVER=1`, then enable **Player → DJ → DJ Queue**,
   restart Spotify, and play an **ordinary, non-DJ playlist**. Record at least
   60 seconds of stable playback:

   ```bash
   python3 scripts/dj-cap-capture.py --port 8086 --seconds 60 --out out/with-dj-queue.zip
   ```

2. Turn the **DJ Queue** switch **off**, restart Spotify, select the same
   playlist and (if possible) the same track and position, and record 60
   seconds without changing playback:

   ```bash
   python3 scripts/dj-cap-capture.py --port 8086 --seconds 60 --out out/without-dj-queue.zip
   ```

   This recorder uses existing `dj.state` data, including `reverseCount` when
   the driver returns it. It is independent of `scripts/dj-diagnose.py` and
   never sends playback actions.

3. Compare the anonymized captures:

   ```bash
   python3 scripts/dj-cap-occupancy.py \
       out/with-dj-queue.zip \
       --baseline out/without-dj-queue.zip \
       --output out/dj-cap-comparison.json
   ```

4. Compare average, peak and 95th-percentile future-track counts and the number
   of **distinct sampled states**. Repeat on a few ordinary playlists. Report
   the results with the explicit limitation that these are sampled state sizes,
   not traffic or CPU samples. For an actual performance claim, separately
   profile the simulator/device with Instruments (Allocations, Time Profiler,
   and network capture), using matching scenarios.

**Do not infer** “78 requests × 14 extra tracks” from 78 sampled rows.

## Next DJ Set UI clarification for the PR response

In the tested Spotify UI, **both the native Edit and the Vitrine Next DJ Set
button are flat capsules**. The Native and Redesigned implementations have
already been separated. Changing only Next DJ Set to a glass button would
create a visual mismatch rather than fix one; no UI-material change is needed.
