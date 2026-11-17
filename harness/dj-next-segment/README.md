# New DJ set: skip-mode regression checks

Run `python3 harness/dj-next-segment/check.py`. The portable checks verify that
skip mode is the default, the request mode is a single exclusive choice, the
neutral prompt retry defaults to off, and the skip action contains no native
jump or text request. On macOS, the same command compiles the production
`isNewSegmentItem` predicate with Foundation fakes and verifies that old tracks,
queued tracks and delimiters cannot be mistaken for a new DJ page; a new page
can reuse an intro UID if its `page_instance_id` changed, and a genuinely
new UID can belong to a new segment even when Spotify retains the same page ID.
If the next page is not published after reaching the final track, a bounded
physical Next advances past the old song/outro, but never through a hand queue.

This is **not** a live playback test. Verify on Spotify 9.1.90 that the queue
button appears with Edit, leaves the current page without hearing its remaining
songs, plays the next page's intro, preserves the paused state if originally
paused, and times out gracefully if the DJ cannot produce a new page. Also
verify that the legacy request choice and native Let DJ pick still work. The
skip action uses only player pause/skip and awaits the core's next segment;
it does not call the native `CompositeJumpable` or send a suggested prompt.
