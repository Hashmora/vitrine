# DJ queue regression checks

Run `python3 harness/dj-queue/check.py` on macOS. It compiles the production
history and spent-track decision functions from `DJQueue.x` against Foundation
fakes, then checks passed rows, queue-copy identities, removed rows, previous and
next history entries, and skipping spent context tracks before their audio starts.

Spotify 9.1.90, iOS 26.3, redesigned look, isolated **Vitrine DJ** simulator
(driver port 8087), 2026-11-17:

- The original five tracks were Another One Bites The Dust, I Feel It Coming,
  Billie Jean, Left and Right, and Cool. Tapping Billie Jean and then Cool,
  Previous visited Left and Right → Billie Jean → I Feel It Coming →
  Another One Bites The Dust. Next visited the same four tracks forwards.
- Previous was tested after seeking to zero, retaining Spotify's behavior that
  a press beyond the first three seconds restarts the current track.

The simulator checks verify track transitions and UI state. They do not measure
audio samples or certify phone audio behavior.

The production asynchronous handover is also exercised with a fake core that delays
pause/skip acknowledgements and resumes on skip, as Spotify 9.1.90 does. The real
output gate is checked on two PCM buffers, then released without changing samples.
The lossless handoff app completed on the isolated simulator with `RESULT failures=0`.
Its player-observer stub was updated for the current SpeedPitch subscription, and
its recovery assertion now waits for the recovery callback rather than overtaking
it on a busy simulator.

`historyFutureRows` projects the entries after the current logical history position
back into both the queue page and the now-playing lens. The checks include a
queued copy as the current track, rows passed by a tap, removed rows and the end
of the history. Already played tracks are restored only as visible upcoming rows;
the bookkeeping used to avoid repeats is retained.

Follow-up UI check on the same simulator: after tapping Mad Love past BLOCKKIDS
and LOCKED IN FREESTYLE, Previous returned to LOCKED IN FREESTYLE and then
BLOCKKIDS. The queue then displayed LOCKED IN FREESTYLE → Mad Love → Job's Not
Done, restoring the passed row before the tapped track. Ordinary Next/Previous
also restored BLOCKKIDS after returning to Rottweiler.

Shared-UID outro regression: the core may land on a spent song before a
`spotify:media:` item with the same UID. Confirmation now checks the physical URI,
and the muted bridge advances over a context original and its known queue copy
before releasing the voice. The checks assert that the gate stays closed while
those songs are current and that the displayed song/clock remain the held snapshot.
`dj.state` in driver builds exposes raw/shown items and the render gate's muted
buffer count for simulator diagnosis.
