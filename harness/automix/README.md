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
