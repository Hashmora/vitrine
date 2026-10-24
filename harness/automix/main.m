// AutoMix harness: one song into the next the way an own engine would do it, on the Mac, to listen to.
//
// Reads the end of A and the start of B (WAV, MP3, M4A, FLAC: anything Core Audio opens), finds both tempos, where
// their beats fall and which beat starts a bar (the one with the most kick), starts the blend on a bar of A with B's
// first bar on it, plays B at A's tempo (SGTimePitch pulling B at rate A/B, the tweak's own time stretch) and mixes
// the two. The highs crossfade equal power over the blend; the lows swap in the middle, on a bar line: A's bass
// goes and B's comes in at once, so two basses never play together. Writes the whole thing as a WAV: A up to the
// blend, the blend, then B at its own tempo.
//
// The blend is a whole, even number of bars of A, so the swap falls on a bar: the length asked for is rounded to it.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Shared/Player/SGTimePitch.h"
#import "beat.h"

static const double kRate = 44100;

typedef struct { float *l, *r; size_t frames; } Song;
typedef struct { UInt32 n; AudioBuffer b[2]; } Stereo;   // an AudioBufferList of two planar channels

// The file as float, planar stereo at kRate.
static BOOL load(const char *path, Song *song) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    ExtAudioFileRef file;
    OSStatus status = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (status) { fprintf(stderr, "cannot open %s (%d)\n", path, (int)status); return NO; }
    AudioStreamBasicDescription format = {kRate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof format, &format);
    size_t capacity = 1 << 22, frames = 0;
    float *l = malloc(capacity * 4), *r = malloc(capacity * 4);
    for (;;) {
        if (frames + 65536 > capacity) { capacity *= 2; l = realloc(l, capacity * 4); r = realloc(r, capacity * 4); }
        Stereo list = {2, {{1, 65536 * 4, l + frames}, {1, 65536 * 4, r + frames}}};
        UInt32 count = 65536;
        if (ExtAudioFileRead(file, &count, (AudioBufferList *)&list) || !count) break;
        frames += count;
    }
    ExtAudioFileDispose(file);
    *song = (Song){l, r, frames};
    return frames > 0;
}

static BOOL writeWAV(const char *path, const float *l, const float *r, size_t frames) {
    AudioStreamBasicDescription format = {kRate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    AudioFileID file;
    OSStatus status = AudioFileCreateWithURL(url, kAudioFileWAVEType, &format, kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    if (status) { fprintf(stderr, "cannot write %s (%d)\n", path, (int)status); return NO; }
    int16_t *pcm = malloc(frames * 4);
    for (size_t i = 0; i < frames; i++) {
        pcm[2 * i] = (int16_t)(fmaxf(-1, fminf(1, l[i])) * 32767);
        pcm[2 * i + 1] = (int16_t)(fmaxf(-1, fminf(1, r[i])) * 32767);
    }
    UInt32 bytes = (UInt32)(frames * 4);
    status = AudioFileWriteBytes(file, false, 0, &bytes, pcm);
    free(pcm);
    AudioFileClose(file);
    return status == noErr;
}

static float *mono(const Song *song, size_t from, size_t count) {
    float *m = malloc(count * 4);
    for (size_t i = 0; i < count; i++) m[i] = 0.5f * (song->l[from + i] + song->r[from + i]);
    return m;
}

// SGTimePitch's source: B from `at`, silence past its end.
typedef struct { const Song *song; size_t at; } Feed;

// Four one pole low passes in a row (24 dB per octave); the highs are what the low pass leaves, so they sum to the input.
static inline float lowpass(float x, float *state, float coefficient) {
    for (int stage = 0; stage < 4; stage++) {
        state[stage] += coefficient * (x - state[stage]);
        x = state[stage];
    }
    return x;
}

static OSStatus feedB(void *context, UInt32 frames, AudioBufferList *data) {
    Feed *feed = context;
    size_t left = feed->at < feed->song->frames ? feed->song->frames - feed->at : 0, give = MIN((size_t)frames, left);
    for (UInt32 c = 0; c < 2; c++) {
        const float *from = (c ? feed->song->r : feed->song->l) + feed->at;
        float *to = data->mBuffers[c].mData;
        memcpy(to, from, give * 4);
        memset(to + give, 0, (frames - give) * 4);
    }
    feed->at += frames;
    return noErr;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *paths[3] = {NULL, NULL, "build/mix.wav"};
        double blendSeconds = 8;
        BOOL swap = YES;
        int n = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--blend") && i + 1 < argc) blendSeconds = atof(argv[++i]);
            else if (!strcmp(argv[i], "--no-swap")) swap = NO;
            else if (n < 3) paths[n++] = argv[i];
        }
        if (n < 2 || blendSeconds < 1) {
            fprintf(stderr, "usage: build/automix A.mp3 B.mp3 [out.wav] [--blend seconds] [--no-swap]\n");
            return 1;
        }
        Song a, b;
        if (!load(paths[0], &a) || !load(paths[1], &b)) return 1;
        if (a.frames < (size_t)(blendSeconds * kRate * 4) || b.frames < (size_t)(blendSeconds * kRate * 4)) {
            fprintf(stderr, "each song must be longer than four times the blend\n");
            return 1;
        }

        // Tempo and beats from the part that matters: the last 30 s of A, the first 30 s of B.
        size_t window = MIN((size_t)(30 * kRate), MIN(a.frames, b.frames));
        size_t aFrom = a.frames - window;
        float *ma = mono(&a, aFrom, window), *mb = mono(&b, 0, window);
        Beat beatA = beatOf(ma, window, kRate), beatB = beatOf(mb, window, kRate);
        free(ma); free(mb);
        if (!beatA.bpm || !beatB.bpm) { fprintf(stderr, "no tempo found in %s\n", !beatA.bpm ? paths[0] : paths[1]); return 1; }

        // B plays at A's tempo; a half or double time reading of one of them is folded to the nearest.
        double rate = beatA.bpm / beatB.bpm;
        while (rate > 1.41) rate /= 2;
        while (rate < 0.71) rate *= 2;
        printf("A %.2f BPM, B %.2f BPM: B plays at %.4fx%s\n", beatA.bpm, beatB.bpm, rate,
               fabs(rate - 1) > 0.15 ? " (a big stretch, it will sound it)" : "");

        printf("downbeat: A beat %d of 4 (accent %.2f), B beat %d of 4 (accent %.2f)%s\n", beatA.bar + 1, beatA.accent, beatB.bar + 1,
               beatB.accent, MIN(beatA.accent, beatB.accent) < 1.15 ? ": weak, the bar line may be off by beats" : "");

        // The blend is a whole, even number of A's bars, so its middle is a bar line. It starts on the last
        // downbeat of A that leaves room for it, B on its first downbeat.
        double bar = 4 * beatA.period;
        size_t bars = (size_t)MAX(2, 2 * llround(blendSeconds * kRate / (2 * bar)));
        size_t blend = (size_t)llround(bars * bar);
        double downbeat = aFrom + beatA.phase + beatA.bar * beatA.period;
        double k = floor((a.frames - blend - downbeat) / bar);
        size_t start = k >= 0 ? (size_t)llround(downbeat + k * bar) : a.frames - blend;
        size_t bFrom = (size_t)llround(beatB.phase + beatB.bar * beatB.period);
        if (start + blend > a.frames || bFrom + (size_t)(blend * rate) + 1 >= b.frames) { fprintf(stderr, "not enough audio for the blend\n"); return 1; }
        printf("blend of %zu bars, %.1f s, from %.2f s in A, B from %.2f s in B; bass swap %s\n", bars, blend / kRate, start / kRate,
               bFrom / kRate, swap ? "in the middle" : "off");

        // B stretched: the unit's delay first, which is dropped, then the blend.
        Feed feed = {&b, bFrom};
        SGTimePitch *unit = SGTimePitchCreate(kRate, 2, feedB, &feed);
        if (!unit) { fprintf(stderr, "SGTimePitchCreate failed\n"); return 1; }
        SGTimePitchSetFollows(unit, false);
        SGTimePitchSetRate(unit, (float)rate);
        SGTimePitchSetSemitones(unit, 0);
        SGTimePitchReset(unit);
        size_t delay = (size_t)llround(SGTimePitchLatency(unit) * kRate), total = blend + delay;
        float *sl = calloc(total, 4), *sr = calloc(total, 4);
        for (size_t done = 0; done < total;) {
            UInt32 count = (UInt32)MIN((size_t)kSGTimePitchMaxFrames, total - done);
            Stereo list = {2, {{1, count * 4, sl + done}, {1, count * 4, sr + done}}};
            OSStatus status = SGTimePitchRender(unit, count, (AudioBufferList *)&list);
            if (status) { fprintf(stderr, "render failed (%d)\n", (int)status); return 1; }
            done += count;
        }
        printf("unit delay %.0f ms, %u underruns, %u failures\n", delay * 1000 / kRate, SGTimePitchUnderruns(unit), SGTimePitchFailures(unit));
        SGTimePitchDestroy(unit);

        // B goes on at its own tempo from where the stretched part stood.
        size_t resume = MIN(b.frames, bFrom + (size_t)llround(blend * rate));
        size_t length = start + blend + (b.frames - resume);
        float *l = calloc(length, 4), *r = calloc(length, 4);
        memcpy(l, a.l, start * 4);
        memcpy(r, a.r, start * 4);
        // Highs crossfade equal power. Lows: A's until the middle, B's after, the change smoothed over 30 ms.
        float coefficient = (float)(1 - exp(-2 * M_PI * 200 / kRate));
        float lowA[2][4] = {{0}}, lowB[2][4] = {{0}};
        double width = 0.03 * kRate, middle = blend / 2.0;
        for (size_t i = 0; i < blend; i++) {
            double t = (double)i / blend, x = fmax(0, fmin(1, (i - (middle - width / 2)) / width));
            float ga = (float)cos(t * M_PI_2), gb = (float)sin(t * M_PI_2);
            float la = swap ? (float)(1 - x * x * (3 - 2 * x)) : ga, lb = swap ? (float)(x * x * (3 - 2 * x)) : gb;
            float inA[2] = {a.l[start + i], a.r[start + i]}, inB[2] = {sl[delay + i], sr[delay + i]}, mix[2];
            for (int c = 0; c < 2; c++) {
                float bassA = lowpass(inA[c], lowA[c], coefficient), bassB = lowpass(inB[c], lowB[c], coefficient);
                mix[c] = bassA * la + (inA[c] - bassA) * ga + bassB * lb + (inB[c] - bassB) * gb;
            }
            l[start + i] = mix[0];
            r[start + i] = mix[1];
        }
        memcpy(l + start + blend, b.l + resume, (b.frames - resume) * 4);
        memcpy(r + start + blend, b.r + resume, (b.frames - resume) * 4);

        if (!writeWAV(paths[2], l, r, length)) return 1;
        printf("wrote %s (%.1f s). Listen from %.0f s.\n", paths[2], length / kRate, MAX(0, start / kRate - 10));
        free(l); free(r); free(sl); free(sr);
        free(a.l); free(a.r); free(b.l); free(b.r);
    }
    return 0;
}
