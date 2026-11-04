# AutoMix harness

One song into the next the way an own engine would do it, to listen to before any of it goes into the player.
Finds the tempo, beats and bar lines (the beat with the most kick) of the end of A and the start of B, stretches B
to A's tempo with `SGTimePitch.m` (the tweak's own time stretch, pulling B at rate A/B), starts the blend on a bar
of A with B's first bar on it, crossfades the highs equal power and swaps the lows in the middle: A's bass goes
and B's comes in on a bar line. The blend is a whole, even number of bars, so `--blend` is rounded to it.

    ./build.sh && build/automix songA.mp3 songB.mp3 [out.wav] [--blend 8] [--no-swap]

`--no-swap` crossfades everything equal power, to hear what the swap adds. It prints how sure it is of each bar
line (accent); under 1.15, a song with little kick, expect the bars to be off by beats. A model for beats is next.

It prints both tempos, the stretch, where the blend starts and the unit's delay and underruns, and writes
`build/mix.wav` (A to the blend, the blend, B at its own tempo). Open it at the time it prints.

`beat.h` is the tempo and beat code on its own (vDSP only); it finds a click track's tempo to 0.02 BPM and which beat of its bar carries the kick.

The DJ metadata field automix.auto_transition_recipe is a base64 protobuf. Run build.sh,
then pass a complete value to build/recipe-dump. The output shows field numbers, wire
types, scalar values, and recursively decoded embedded messages.

`build/policy-test` checks `AutoMixPolicy.m` (the adaptive blend: the length each pair of songs gets) on its own.

## Checking the adaptive blend and the transition experiment on the phone

AutoMix > Adapt to each song rewrites Spotify's crossfade length for each pair, and the probe's line for the change
shows what the player did with it. In the log (`scripts/dump-log.sh`):

- `automix adaptive: A -> B: N ms (reason), Spotify was ..., now ...` is the write, made when the pair is first known.
- the next `automix probe: change, X s of the last track left` is the result: X near N/1000 means the player took the
  length at that change; X near the old length means it read it earlier and the write needs to come sooner (try the
  song before); X near 0 with `mixer silent` near 0 is a gapless change.
- a DJ transition is left alone: `automix adaptive: ... is a DJ transition, left to Spotify`.

AutoMix > Testing > Transition experiments (restart after changing) forces the five AutoMix flags on and, 25 s into the
launch, logs the account type and every class named like a transition loader with its ivars and Objective-C methods
(`automix experiment: class ...`). Then play an ordinary playlist and look for `automix.*` keys on the next song in the
`automix probe` lines: if the server sends a transition for a plain playlist they are there, and `automix flag:` lines
say which flags Spotify asked for. Compare an account on Premium with one on Free (and one offline) to see where the gate is.
