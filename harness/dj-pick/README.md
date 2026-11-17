# DJ Pick recovery

Run `python3 harness/dj-pick/check.py`. It compiles the production attempt class
from `Shared/Player/DJPick.x` with Foundation fakes and the real protobuf encoder.

Checks cover genuine native landings without a fallback, local acknowledgement
without movement, one fallback only, the native prompt wire payload, success only
when a landing is observed, failure/timeouts without discarding the custom order,
context changes, pause, an explicit user prompt/skip, and ordinary advancement
inside the same DJ page (which must not falsely confirm a new set).

## Spotify 9.1.90 simulator evidence

Dedicated Vitrine DJ simulator, driver port 8087; no other simulator or phone.

Before the fix, native and queue Pick both sent `signal_id: "jump"` with no
parameters. ESPContextPlayerClientImpl answered with an empty successful
ESPResponseWithReasons and SignalJumpable completed with no NSError. The later
network response on `/playlist/v2/playlist/37i9dQZF1EYkqdzj48dyYq/signals` was HTTP
502. Thus the completion established local acceptance, not a successful server
operation. The native SeekingJumpable fallback was not invoked on that apparent
success; invoking it separately produced error 4, "Could not find narration track".

A native suggested request used `signal_id: "prompt"`; its parameters were a
base64 protobuf containing field 1 (English text) and field 2 = 3 (suggested
request). That same endpoint answered 200. A neutral request using this exact
native wire format returned 200 and moved to `spotify:media:0000000000000000000000`
(`list_intro_item`) within about half a second, then to a new music selection.

The recovery preserves the normal native request first. After a six-second grace
period with no landing it sends one neutral suggested request: “Surprise me with
a new mix based on my taste.” No genre or artist is imposed. It waits for an actual
landing before completing the native action and releasing the queue's custom
order. The prompt has a 20-second timeout; the local command acknowledgement is
not accepted as proof of success. All temporary network/body probes were removed.

Final live checks:

- The native request sheet calls CompositeJumpable on a worker queue, while the
  queue action calls it on main. The adapter marshals the native entry to main
  asynchronously before creating its timer or changing queue UI. In the native
  sheet, Dangerous -> list_intro_item -> Trndsttr confirmed a new selection.
- With the queue reordered, Walk remained playing during the native grace period.
  The owned No Hands copy was removed before the request (including its delayed
  arrival in the core queue). The result was list_intro_item -> Be Honest, with
  the queue populated again and ordered=false. An owned/manual queue copy cannot
  falsely confirm a new DJ set. Failure/cancellation can prepare the preserved
  old order again; a successful landing discards that old order.
