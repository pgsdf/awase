#!/usr/bin/env python3
"""Generate the PGSD boot initialization tone sequence (ADR 0032).

Committed source of truth for boot.pcm, which is a build product and
is never committed to history. install.sh runs this at install time
and ships the result to $PREFIX/share/pgsd/sounds/boot.pcm.

Standard library only: no numpy, no third-party dependencies. The
inputfs fuzz harness set the precedent that python3 is an acceptable
tool dependency; nothing beyond the stdlib is.

Output: 2.000 s of interleaved signed 16-bit LE PCM, stereo, at the
requested rate (default 48000, semasound's CANON_RATE, the bit-exact
passthrough path). First and last frames are sample-exact zero so the
stream can be cut hard with no click.

Structure of the sequence:
  0.00 - 0.60 s : low root swell, A2 gliding up one octave to A3
  0.35 - 1.60 s : three bell tones, A4 -> E5 -> A5, staggered,
                  panned lightly left -> right -> center
  1.20 - 2.00 s : shimmer tail (detuned A5 pair, split L/R)
  final 5 ms    : linear fade forcing exact-zero endpoints
"""

import argparse
import math
import struct
import wave

TAU = 2.0 * math.pi


def bell_sample(local, freq, amp):
    """Bell voice at time `local` since note start: fast attack,
    exponential decay, decaying 2nd and 3rd harmonics."""
    attack = min(local / 0.012, 1.0)
    env = attack * math.exp(-local * 4.5)
    tone = (
        1.00 * math.sin(TAU * freq * local)
        + 0.35 * math.sin(TAU * freq * 2.0 * local) * math.exp(-local * 7.0)
        + 0.12 * math.sin(TAU * freq * 3.0 * local) * math.exp(-local * 10.0)
    )
    return amp * env * tone


def main():
    ap = argparse.ArgumentParser(description="PGSD boot tone generator")
    ap.add_argument("--rate", type=int, default=48000, help="sample rate (Hz)")
    ap.add_argument("--mono", action="store_true", help="emit mono instead of stereo")
    ap.add_argument("--wav", action="store_true", help="also write a WAV preview copy")
    ap.add_argument("--out", default="boot", help="output basename (may include a path)")
    args = ap.parse_args()

    sr = args.rate
    total = 2.0
    n = int(sr * total)

    # Bell notes: start time, frequency, duration, amplitude, pan (0=L, 1=R).
    notes = [
        (0.35, 440.00, 1.10, 0.34, 0.35),
        (0.70, 659.25, 1.05, 0.30, 0.65),
        (1.05, 880.00, 0.95, 0.26, 0.50),
    ]
    pans = [(math.cos(p * math.pi / 2), math.sin(p * math.pi / 2))
            for (_, _, _, _, p) in notes]

    swell_dur = 0.60
    tail_t0, tail_dur = 1.20, 0.80
    fade_n = int(sr * 0.005)

    left = [0.0] * n
    right = [0.0] * n
    phase = 0.0

    for i in range(n):
        t = i / sr
        l = 0.0
        r = 0.0

        # 1. Root swell: A2 (110 Hz) glides one octave up; the phase
        # accumulator keeps the glide continuous.
        if t < swell_dur:
            frac = t / swell_dur
            freq = 110.0 * (2.0 ** frac)
            phase += TAU * freq / sr
            env = math.sin(math.pi * frac) ** 1.5
            s = 0.30 * env * math.sin(phase)
            l += s
            r += s

        # 2. Bell arpeggio.
        for (t0, f, d, a, _), (pl, pr) in zip(notes, pans):
            local = t - t0
            if 0.0 <= local < d:
                s = bell_sample(local, f, a)
                l += s * pl
                r += s * pr

        # 3. Shimmer tail: detuned pair split across channels.
        if tail_t0 <= t < tail_t0 + tail_dur:
            local = t - tail_t0
            env = math.sin(math.pi * local / tail_dur) ** 2
            l += 0.10 * env * math.sin(TAU * 878.0 * local)
            r += 0.10 * env * math.sin(TAU * 882.0 * local)

        # 4. Terminal fade to sample-exact zero.
        if i >= n - fade_n:
            ramp = (n - 1 - i) / fade_n
            l *= ramp
            r *= ramp

        left[i] = l
        right[i] = r

    # Normalize with headroom (-1.4 dBFS) and quantize.
    peak = max(max(abs(v) for v in left), max(abs(v) for v in right))
    scale = (0.85 / peak) * 32767.0 if peak > 0 else 0.0

    if args.mono:
        frames = [int((left[i] + right[i]) * 0.5 * scale) for i in range(n)]
    else:
        frames = []
        for i in range(n):
            frames.append(int(left[i] * scale))
            frames.append(int(right[i] * scale))

    pcm = struct.pack("<%dh" % len(frames), *frames)
    channels = 1 if args.mono else 2

    raw_path = args.out + ".pcm"
    with open(raw_path, "wb") as f:
        f.write(pcm)
    print("wrote %s (%d bytes, %d Hz, %d ch, s16le)"
          % (raw_path, len(pcm), sr, channels))

    if args.wav:
        wav_path = args.out + ".wav"
        with wave.open(wav_path, "wb") as w:
            w.setnchannels(channels)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes(pcm)
        print("wrote %s (preview)" % wav_path)


if __name__ == "__main__":
    main()
