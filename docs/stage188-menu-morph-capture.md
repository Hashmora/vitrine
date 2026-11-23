# Stage 188 — iOS 26 → iOS 18 Menu Morph Evidence

**Purpose:** collect reproducible evidence before writing the iOS 18 morph renderer. This is an **instrumentation-only** stage; it does not alter UIKit, the dropdown appearance, gestures, Spotify settings, or the tab bar.

## Targets

- iOS 26 (`PHONE_PORT=8088`, `SIM_PORT=8088`), Spotify 9.1.90 with `SG_DRIVER=1`
- Optional Legacy iOS 18 (`PHONE_PORT=8087`, `SIM_PORT=8087`)
- The script discovers the sole booted iOS 26 simulator by runtime (or accepts `--udid26`), never guesses its UUID.

## Recording

```bash
python3 scripts/diagnostics/stage188-ios26-menu-morph-capture.py \
  --port26 8088 --trials 3 --layers-pass --zip
```

Add `--compare --port18 8087` to capture the same transition on iOS 18. Each case is independently prepared using SG_DRIVER, so the resulting takes do not depend on manual taps or a particular menu being left open. The cases are:

1. `root-open` — player `⋯` → root popup
2. `root-close` — root popup → dismissal by outside tap
3. `more-open` — root popup → `More` submenu
4. `more-close` — `More` → outside dismissal
5. `home-open` — Home Filter button → popup
6. `home-close` — Home Filter popup → dismissal

To run just two:

```bash
python3 scripts/diagnostics/stage188-ios26-menu-morph-capture.py \
  --port26 8088 --trials 3 --cases root-open root-close --zip
```

Run from the repository root. Start with Spotify signed in, a track loaded for player cases, and Redesigned UI enabled on both. Do **not** delete or reset existing data. The script only navigates, opens/closes menus, and records their visuals. On a failure, it writes `INCOMPLETE`, never a false PASS.

## Evidence per take

- `capture.mp4`: continuous simulator screen video, including pre/post-roll.
- `frames/frame_000000.png` ...: **every decoded video frame**, with no deliberate FPS reduction. Simulator screen recording can still miss high-refresh frames; verify `avg_frame_rate` and timestamp sequence.
- `frames/timestamps.json`: actual presentation timestamps from `ffprobe` (relative to recording, not aligned perfectly with SG_DRIVER).
- `before`/`after`: SG_DRIVER `state`, view tree, menu findings, UIKit layer hierarchy when accessible, and screenshot.
- `event`: host-side monotonic times when action was sent and returned.
- `analysis/frame-metrics.csv` (if `numpy` + `opencv-python` installed): per-frame **proxies** for changing region, center/bounds, contour compactness, relative luminance, bright rim, and moving background pixels.
- `secondary-take/layer-samples.json` (with `--layers-pass`): repeated UIKit view hierarchy snapshots through a **separate run**, never used for timing optical capture.

For optional numeric metrics, install `numpy` and `opencv-python` in the Python interpreter you run with. **Neither package is needed to record and extract frames.** `ffmpeg`/`ffprobe` are required to extract and timestamp all frames.

## What to measure in the resulting captures

| Property | Method | Caveat |
|---|---|---|
| Start/end location | UI hierarchy + first/last visual contour | A source button's frame is not necessarily the start silhouette |
| Position, scale, acceleration, spring overshoot | Track menu contour over frames and compare open/close | Motion should be timed using video PTS, not driver HTTP reply time |
| Corner shape, fusion/splitting | Shape segmentation plus layer masks/paths when present | Simple `bbox` is **not** a corner-radius measurement |
| Rim luminance and highlights | Contrast profile along rim; bright streak motion | Needs controlled static background and multiple runs |
| Refraction / dispersion | Background texture feature displacement and per-channel offsets | Optical flow in current script is only a rough proxy |
| Transparency / tint / blur | Compare background with/without the glass at identical layout | Content movement can corrupt difference estimates |
| Content choreography | Compare action rows, icons, checkmarks and separator reveal across frames | Do not scale text with surface |
| Reverse/dismiss | Capture closing independently | Spotify's dismissal isn't assumed to match Apple's canonical transition |

The current script is the **measurement stage**. It **does not** claim to extract Metal shader source or auto-apply the correct glass renderer to iOS 18. A genuine iOS 18 implementation must be a separate, parameterized `SGRDropdownMorphTransition` + optical surface, fitted to collected frames and checked again against the native capture. Writing a guessed renderer now would reproduce the problems of Stage 180/184.

## Native Photos as an additional canonical reference

A future separate driver can record Apple Photos menu transitions (including dismissal) by controlling the actual Photos app through `XCUITest`/UI automation and recording its simulator display. The existing Spotify-injected SG_DRIVER cannot touch views in another app's process. Confirm that Photos exists in the selected simulator runtime; otherwise use a test iPhone and a suitable device automation host. No Photos automation is included in Stage 188.

## Avoid misleading 1:1 claims

The public iOS 26 SDK and runtime headers expose API/class structure, **not a portable renderer for iOS 18**. Independent Metal backports are useful references, but need visual and performance checks; don't import a guessed implementation wholesale. A capture showing every *recorded* video frame is not guaranteed to show every compositor frame on a ProMotion device.
