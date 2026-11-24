#!/usr/bin/env python3
"""Synthesises tikjot's sound set (Motion storyboards · H, SPEC §11.11) into App/Resources/Sounds/*.caf.

    scripts/make-sounds.py          # writes tick, tock, whoosh, chime, tap

Pure Python (stdlib only) + macOS `afconvert` for the CAF container, so it runs on any Mac without extra packages.
The output is deterministic (seeded noise), so re-running it gives byte-identical files.

Sounds (48 kHz, mono, 16-bit, each < 600 ms):
  tick    start  – short dry wooden click, ~70 ms (three damped wood modes + a 2 ms noise transient)
  tock    stop   – the same click a fourth lower
  whoosh  sent   – soft paper whoosh synced to the paper plane (band-passed noise sweeping upwards)
  chime   sent   – two-note chime on the hero (G5 → C6, soft bell partials)
  tap     failed – one low muted tap (pitch-dropping thump, heavily low-passed)

Level: each sound is normalised to about −20 LUFS. LUFS (ITU-R BS.1770) is defined over ≥ 400 ms blocks, which is
longer than a click, so we measure K-weighted loudness over the sound's *active* part (where the envelope is within
30 dB of its peak) and scale to −20 LUFS; the sample peak is then capped at −1 dBFS (no clipping). The script prints
the measured loudness, RMS and peak of every file.
"""
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave

SR = 48_000
TARGET_LUFS = -20.0
PEAK_CEILING_DB = -1.0
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Resources", "Sounds")


# ---------------------------------------------------------------- building blocks

def silence(seconds):
    return [0.0] * int(SR * seconds)


def mix(a, b, offset=0):
    n = max(len(a), offset + len(b))
    out = a + [0.0] * (n - len(a))
    for i, v in enumerate(b):
        out[offset + i] += v
    return out


def fade(x, fade_in=0.001, fade_out=0.008):
    n_in, n_out = int(SR * fade_in), int(SR * fade_out)
    y = list(x)
    for i in range(min(n_in, len(y))):
        y[i] *= 0.5 - 0.5 * math.cos(math.pi * i / n_in)
    for i in range(min(n_out, len(y))):
        y[-1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / n_out)
    return y


def biquad(x, b0, b1, b2, a1, a2):
    y = [0.0] * len(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


def lowpass(x, fc, q=0.707):
    w = 2 * math.pi * fc / SR
    alpha = math.sin(w) / (2 * q)
    c = math.cos(w)
    a0 = 1 + alpha
    return biquad(x, (1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)


def svf_bandpass(x, cutoff_at, q=1.2):
    """State-variable band-pass with a time-varying cutoff (Hz as a function of the sample index)."""
    low = band = 0.0
    out = [0.0] * len(x)
    damp = 1.0 / q
    for i, v in enumerate(x):
        f = 2 * math.sin(math.pi * min(cutoff_at(i), SR / 6) / SR)
        high = v - low - damp * band
        band += f * high
        low += f * band
        out[i] = band
    return out


def noise(seconds, seed):
    r = random.Random(seed)
    return [r.uniform(-1, 1) for _ in range(int(SR * seconds))]


def damped_modes(modes, seconds):
    """modes: (frequency Hz, amplitude, decay time constant s)."""
    n = int(SR * seconds)
    return [sum(a * math.exp(-t / tau) * math.sin(2 * math.pi * f * t) for f, a, tau in modes)
            for t in (i / SR for i in range(n))]


# ---------------------------------------------------------------- the sounds

def wood_click(pitch=1.0, seed=1):
    # Wood-block modes (inharmonic, short decays) + a tiny filtered noise transient for the "dry" attack.
    modes = [(1_850 * pitch, 1.0, 0.012), (2_960 * pitch, 0.45, 0.008), (4_420 * pitch, 0.22, 0.005),
             (920 * pitch, 0.30, 0.018)]
    body = damped_modes(modes, 0.07)
    tr = noise(0.003, seed)
    tr = [v * math.exp(-i / (SR * 0.0006)) for i, v in enumerate(tr)]
    tr = lowpass(tr, 6_000 * pitch)
    return fade(mix(body, [v * 0.6 for v in tr]), fade_in=0.0002, fade_out=0.012)


def whoosh():
    dur = 0.52
    n = int(SR * dur)
    src = noise(dur, 7)
    # Cutoff sweeps 500 → 2 400 Hz (the plane rising), amplitude: slow rise, slower fall.
    swept = svf_bandpass(src, lambda i: 500 + 1_900 * (i / n) ** 1.4, q=1.6)
    env = []
    for i in range(n):
        t = i / n
        env.append(math.sin(math.pi * min(1.0, t / 0.42) / 2) ** 2 if t < 0.42 else math.cos(math.pi / 2 * (t - 0.42) / 0.58) ** 2)
    soft = lowpass([v * e for v, e in zip(swept, env)], 5_000)
    return fade(soft, fade_in=0.01, fade_out=0.04)


def bell(freq, seconds, amp=1.0):
    # Soft bell: fundamental + a quiet octave + a faint inharmonic partial, gentle attack, exponential decay.
    n = int(SR * seconds)
    out = []
    for i in range(n):
        t = i / SR
        attack = min(1.0, t / 0.004)
        v = (math.sin(2 * math.pi * freq * t) * math.exp(-t / 0.22)
             + 0.22 * math.sin(2 * math.pi * freq * 2.0 * t) * math.exp(-t / 0.10)
             + 0.06 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-t / 0.05))
        out.append(amp * attack * v)
    return out


def chime():
    g5, c6 = 783.99, 1_046.50
    a = bell(g5, 0.56, 0.85)
    b = bell(c6, 0.43, 1.0)
    return fade(mix(a, b, int(SR * 0.13)), fade_in=0.0005, fade_out=0.06)


def tap():
    # Low muted tap: a thump whose pitch drops 190 → 120 Hz, plus a soft low-passed knock. ~120 ms.
    n = int(SR * 0.12)
    phase = 0.0
    out = []
    for i in range(n):
        t = i / SR
        f = 120 + 70 * math.exp(-t / 0.015)
        phase += 2 * math.pi * f / SR
        out.append(math.sin(phase) * math.exp(-t / 0.028))
    knock = lowpass([v * math.exp(-i / (SR * 0.004)) for i, v in enumerate(noise(0.02, 3))], 900)
    return fade(lowpass(mix(out, [v * 0.5 for v in knock]), 1_400), fade_in=0.0005, fade_out=0.02)


# ---------------------------------------------------------------- loudness

def k_weight(x):
    # ITU-R BS.1770-4 K-weighting at 48 kHz: high-shelf pre-filter + RLB high-pass.
    y = biquad(x, 1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
    return biquad(y, 1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)


def active_region(x, below_peak_db=30.0, window=0.005):
    w = int(SR * window)
    env = [max(abs(v) for v in x[i:i + w]) for i in range(0, len(x), w)]
    peak = max(env)
    thr = peak * 10 ** (-below_peak_db / 20)
    idx = [i for i, e in enumerate(env) if e >= thr]
    return idx[0] * w, min(len(x), (idx[-1] + 1) * w)


def loudness(x):
    a, b = active_region(x)
    k = k_weight(x)[a:b]
    ms = sum(v * v for v in k) / max(1, len(k))
    return -0.691 + 10 * math.log10(ms + 1e-20)


def rms_db(x):
    a, b = active_region(x)
    seg = x[a:b]
    return 20 * math.log10(math.sqrt(sum(v * v for v in seg) / max(1, len(seg))) + 1e-20)


def normalise(x):
    gain = 10 ** ((TARGET_LUFS - loudness(x)) / 20)
    y = [v * gain for v in x]
    peak = max(abs(v) for v in y)
    ceiling = 10 ** (PEAK_CEILING_DB / 20)
    if peak > ceiling:
        y = [v * ceiling / peak for v in y]
    return y


# ---------------------------------------------------------------- output

def write_caf(name, x):
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in x))
        dst = os.path.join(OUT, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, dst], check=True)
    peak = max(abs(v) for v in x)
    print(f"{name:7s} {len(x) / SR * 1000:5.0f} ms   loudness {loudness(x):6.1f} LUFS*   RMS {rms_db(x):6.1f} dBFS   "
          f"peak {20 * math.log10(peak):5.1f} dBFS")


def main():
    if sys.platform != "darwin":
        sys.exit("needs macOS (afconvert)")
    sounds = {
        "tick": wood_click(1.0, seed=1),
        "tock": wood_click(2 ** (-5 / 12), seed=2),  # a perfect fourth lower
        "whoosh": whoosh(),
        "chime": chime(),
        "tap": tap(),
    }
    for name, x in sounds.items():
        write_caf(name, normalise(x))
    print("* K-weighted loudness over the active part of each sound (see the module docstring).")


if __name__ == "__main__":
    main()
