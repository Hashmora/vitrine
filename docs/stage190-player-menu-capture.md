# Stage 190 — restored iOS 26 player popup capture

This is a **diagnostic-only** stage. It does not alter menus or any iOS renderer. Requires Stage 188/188r and the restored UIKit popup from Stage 189.

The existing Stage 188 recorded Home on iOS 26.3, but the footage sometimes began after the popup had already opened or closed. The new runner waits for a positive `simctl recordVideo` acknowledgement, saves a true on-screen baseline (`simctl screenshot`, as opposed to `drawViewHierarchyInRect`), then allows an additional pre-roll before invoking `SG_DRIVER`.

The four scenarios are: `root-open`, `root-close`, `more-open` and `more-close`. Each is prepared without manual taps using `player.open`, `player.more` and `menu.pick More`. An explicit test rejects a Spotify bottom sheet where a native `_UIContextMenuView` should be visible. No menu entry other than the submenu navigation is selected.

Read-only inspection saves videos, decoded PNG frames, actual video PTS, video-level log, compositor baselines, SG_DRIVER view tree and layers before/after, and optional separate intrusive layer sampling. The video may omit unchanged compositor frames and its PTS are not directly synchronized to the driver clock. Shape/lighting/refraction require post-hoc frame analysis; absent OpenCV should not prevent evidence collection.

## Launch on iOS 26.3 (8088)

```bash
cd ~/Downloads/spoti-fork && \
python3 scripts/diagnostics/stage190-player-menu-morph-capture.py \
  --port26 8088 --udid26 B8E2A0A5-3BE4-4B47-BBAE-095D64219EBA \
  --cases root-open root-close more-open more-close \
  --trials 3 --layers-pass --zip
```

The archive is saved to `out/stage190-player-menu-YYYYMMDD-HHMMSS.zip` and may be large. Avoid sharing it publicly because it can contain Spotify account data.

Capture iOS 18 separately if needed with `--compare --port18 8087` (legacy device `ED66415E-FC8E-44EA-B306-33BB985B9CE8`). Do not mistake frame difference or optical-flow proxies for the real Apple Liquid Glass shader values.
