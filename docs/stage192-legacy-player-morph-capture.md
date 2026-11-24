# Stage 192 — compact Legacy player capture (Stage 191)

Diagnostics only. Requires Stage 188r, Stage 190 and the installed Stage 191 app build. No iOS renderer changes, no requests to port 8088. Uses the existing `simctl recordVideo` capture with an acknowledged start and baseline, plus the existing AVFoundation decoder in new `--pts-only` mode. The old PNG extraction mode is unchanged.

Records root-open, root-close, more-open, more-close; three trials each by default. Validates the actual visible `SGRDropdownPanel`, absence of native popup, and presence/absence of `Vitrine.Dropdown.Back` to distinguish More from root. Saves raw MP4, compositor baseline/end screenshots, UIKit state/layers/tree before/after, decoded PTS and optional separate layer sampling. The SG_DRIVER layer samples are intrusive and not synchronized to video PTS. Failed trials are preserved. If the AVFoundation metadata step fails, original MP4 is still preserved and the report includes the error.

No frame PNGs are generated. The archive writer makes independent ZIP parts with a conservative 400 MiB cap. Upload all `-upload*.zip` files from this run. Original evidence stays on disk. A single evidence file above the cap is reported explicitly rather than silently discarded. Evidence may contain account information; don't post it publicly.

```bash
cd ~/Downloads/spoti-fork && \
SIM_PORT=8087 SG_DRIVER=1 scripts/sim-build.sh '/Users/andrew/Desktop/ipa/Spotify-9.1.90.ipa' --device ED66415E-FC8E-44EA-B306-33BB985B9CE8 && \
python3 scripts/diagnostics/stage192-legacy-player-morph-capture.py --port18 8087 --udid18 ED66415E-FC8E-44EA-B306-33BB985B9CE8 --trials 3 --layers-pass
```

Linux verification: Python syntax, compact archive split/exclusion test, git apply check against diagnostic base from provided Stage 188/188r/190 patches. Apple AVFoundation compilation and actual simulator run require macOS; not verified here.
