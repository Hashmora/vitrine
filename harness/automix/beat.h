// Tempo and beat phase of a stretch of mono audio, by spectral flux and its autocorrelation, with vDSP only.
// Plain C, so the same code runs in the harness and in a test.
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

enum { kBeatFFT = 2048, kBeatHop = 512 };
static const double kBeatMinBPM = 60, kBeatMaxBPM = 200;

typedef struct {
    double bpm;     // 0 when the stretch is too short or has no pulse
    double phase;   // frames from the start of the stretch to its first beat, in [0, one beat)
    double period;  // frames per beat
    int bar;        // which beat from the first (0...3) is the downbeat of a four beat bar
    double accent;  // how much stronger the downbeat's low end is than the other beats' (1 is no clue)
} Beat;

// Half-wave rectified spectral flux, one value per hop, and the same of the low end (under 250 Hz: the kick) alone.
// The caller frees both.
static size_t beatFlux(const float *mono, size_t frames, double rate, float **flux, float **low) {
    *flux = *low = NULL;
    if (frames < (size_t)kBeatFFT * 4) return 0;
    size_t hops = (frames - kBeatFFT) / kBeatHop;
    vDSP_Length log2n = 11;
    FFTSetup fft = vDSP_create_fftsetup(log2n, FFT_RADIX2);
    size_t lowBins = (size_t)fmax(2, 250.0 * kBeatFFT / rate);
    float *outLow = calloc(hops, sizeof(float));
    float *out = calloc(hops, sizeof(float)), *window = malloc(kBeatFFT * sizeof(float));
    float *prev = calloc(kBeatFFT / 2 + 1, sizeof(float)), *windowed = malloc(kBeatFFT * sizeof(float));
    DSPSplitComplex spec = {malloc(kBeatFFT / 2 * sizeof(float)), malloc(kBeatFFT / 2 * sizeof(float))};
    vDSP_hann_window(window, kBeatFFT, vDSP_HANN_NORM);
    for (size_t h = 0; h < hops; h++) {
        vDSP_vmul(mono + h * kBeatHop, 1, window, 1, windowed, 1, kBeatFFT);
        vDSP_ctoz((const DSPComplex *)windowed, 2, &spec, 1, kBeatFFT / 2);
        vDSP_fft_zrip(fft, &spec, 1, log2n, FFT_FORWARD);
        float sum = 0, sumLow = 0;
        for (size_t k = 0; k <= kBeatFFT / 2; k++) {
            // zrip packs DC in realp[0] and Nyquist in imagp[0].
            float re = k < kBeatFFT / 2 ? spec.realp[k] : spec.imagp[0];
            float im = k > 0 && k < kBeatFFT / 2 ? spec.imagp[k] : 0;
            float mag = sqrtf(re * re + im * im) / kBeatFFT;
            if (mag > prev[k]) {
                sum += mag - prev[k];
                if (k < lowBins) sumLow += mag - prev[k];
            }
            prev[k] = mag;
        }
        out[h] = sum;
        outLow[h] = sumLow;
    }
    free(window); free(windowed); free(prev); free(spec.realp); free(spec.imagp);
    vDSP_destroy_fftsetup(fft);
    *flux = out;
    *low = outLow;
    return hops;
}

// The beat of a stretch of `frames` mono samples at `rate`.
static Beat beatOf(const float *mono, size_t frames, double rate) {
    Beat beat = {0, 0, 0};
    float *flux, *low;
    size_t hops = beatFlux(mono, frames, rate, &flux, &low);
    if (!hops) return beat;
    double perHop = kBeatHop / rate;
    size_t minLag = (size_t)floor(60.0 / (kBeatMaxBPM * perHop)), maxLag = (size_t)ceil(60.0 / (kBeatMinBPM * perHop));
    if (maxLag + 2 >= hops || minLag < 1) { free(flux); free(low); return beat; }

    float *score = calloc(maxLag + 2, sizeof(float));
    size_t best = minLag;
    for (size_t lag = minLag; lag <= maxLag; lag++) {
        float s = 0;
        for (size_t i = 0; i + lag < hops; i++) s += flux[i] * flux[i + lag];
        score[lag] = s / (float)(hops - lag);
        if (score[lag] > score[best]) best = lag;
    }
    // One hop is about 2.5 BPM at 128: place the peak between lags.
    double lag = (double)best;
    if (best > minLag && best < maxLag) {
        double l = score[best - 1], c = score[best], r = score[best + 1], den = l - 2 * c + r;
        if (den < 0) lag += 0.5 * (l - r) / den;
    }
    // A click track at 128 can autocorrelate best at two beats (64): take the half lag when it is nearly as strong.
    size_t half = (size_t)llround(lag / 2);
    if (half >= minLag && score[half] >= 0.6f * score[best]) lag /= 2;
    free(score);
    if (!(lag > 0)) { free(flux); free(low); return beat; }

    // Tempo and phase together: the period and offset whose grid of beats lands on the most flux. The period is
    // refined here because a lag a hair off drifts the grid by tens of milliseconds over a stretch.
    double bestLag = lag, bestOffset = 0, bestMean = -1;
    for (double candidate = lag - 0.6; candidate <= lag + 0.6; candidate += 0.02) {
        if (candidate < 1) continue;
        for (double offset = 0; offset < candidate; offset += 0.5) {
            double sum = 0;
            size_t n = 0;
            for (double at = offset; at < (double)hops; at += candidate, n++) {
                size_t i = (size_t)llround(at);
                sum += flux[i < hops ? i : hops - 1];
            }
            if (n && sum / n > bestMean) { bestMean = sum / n; bestLag = candidate; bestOffset = offset; }
        }
    }
    free(flux);
    lag = bestLag;

    // The downbeat: of the four places a bar can start on the beats, the one whose beats have the most kick.
    // The strength of a beat is the largest low end flux within a hop of it.
    double sum[4] = {0}, all = 0;
    size_t count[4] = {0}, beats = 0;
    for (double at = bestOffset; at < (double)hops; at += lag, beats++) {
        size_t i = (size_t)llround(at);
        float strength = 0;
        for (size_t j = i > 0 ? i - 1 : 0; j <= i + 1 && j < hops; j++) strength = fmaxf(strength, low[j]);
        sum[beats % 4] += strength;
        count[beats % 4]++;
        all += strength;
    }
    free(low);
    beat.bar = 0;
    beat.accent = 1;
    if (beats >= 8 && all > 0) {
        double top = 0, mean = all / beats;
        for (int m = 0; m < 4; m++) {
            double v = sum[m] / count[m];
            if (v > top) { top = v; beat.bar = m; }
        }
        beat.accent = top / mean;
    }
    beat.bpm = 60.0 / (lag * perHop);
    beat.period = lag * kBeatHop;
    beat.phase = bestOffset * kBeatHop;
    return beat;
}
