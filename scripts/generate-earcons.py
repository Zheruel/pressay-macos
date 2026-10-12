#!/usr/bin/env python3
"""Synthesizes Pressay's earcons into Config/Sounds (48 kHz stereo, 16-bit).

Each note is a struck tuned bar: modal partials at marimba-like ratios with
faster decay on the upper modes, a soft felt-mallet attack, and a 2 ms
filtered noise tick so the cue feels tactile rather than electronic. A few
low-passed early reflections give a small-room tail without a smear.

Begin rises a perfect fourth (E5 -> A5) and release mirrors it, so the pair
reads as "open" and "closed" even when heard half-attentively. Levels sit
near the previous -28 dBFS peak so frequent use stays comfortable.

    python3 scripts/generate-earcons.py
"""
import math
import os
import random
import struct
import wave

RATE = 48_000
OUT = os.path.join(os.path.dirname(__file__), "..", "Config", "Sounds")

# (ratio, relative amplitude, decay seconds) — a tuned bar's first modes.
BAR = [(1.0, 1.0, 0.085), (3.99, 0.16, 0.030), (9.85, 0.035, 0.012)]
SOFT_BAR = [(1.0, 1.0, 0.07), (3.99, 0.07, 0.022)]


def note(freq, start, gain, partials=BAR, length=0.24, tick=0.05):
    """Returns (start_frame, left, right) for one struck note."""
    n = int(length * RATE)
    rng = random.Random(int(freq * 1000))
    left, right = [0.0] * n, [0.0] * n
    lp = 0.0
    for i in range(n):
        t = i / RATE
        # Felt mallet: ~3 ms raised-cosine attack instead of a hard edge.
        attack = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / 0.003))
        body_l = body_r = 0.0
        for ratio, amp, decay in partials:
            env = amp * math.exp(-t / decay)
            f = freq * ratio
            # A 0.25% detune between channels gives width without phasiness.
            body_l += env * math.sin(2 * math.pi * f * t)
            body_r += env * math.sin(2 * math.pi * f * 1.0025 * t + 0.3)
        # Mallet contact: low-passed noise burst, gone within ~4 ms.
        lp += 0.35 * (rng.uniform(-1, 1) - lp)
        contact = lp * tick * math.exp(-t / 0.0012)
        left[i] = (body_l * attack + contact) * gain
        right[i] = (body_r * attack + contact) * gain
    return int(start * RATE), left, right


def render(notes, duration, peak_dbfs):
    n = int(duration * RATE)
    left, right = [0.0] * n, [0.0] * n
    for start, nl, nr in notes:
        for i in range(len(nl)):
            j = start + i
            if j >= n:
                break
            left[j] += nl[i]
            right[j] += nr[i]
    # Small-room early reflections, low-passed and cross-fed.
    for delay_ms, gain in [(9.5, 0.16), (15.0, 0.11), (23.5, 0.07)]:
        d = int(delay_ms / 1000 * RATE)
        state_l = state_r = 0.0
        src_l, src_r = left[:], right[:]
        for i in range(d, n):
            state_l += 0.3 * (src_r[i - d] - state_l)
            state_r += 0.3 * (src_l[i - d] - state_r)
            left[i] += state_l * gain
            right[i] += state_r * gain
    # Click-safe 12 ms fade to digital silence at the end.
    fade = int(0.012 * RATE)
    for k in range(fade):
        g = 0.5 + 0.5 * math.cos(math.pi * k / fade)
        left[n - fade + k] *= g
        right[n - fade + k] *= g
    peak = max(max(abs(x) for x in left), max(abs(x) for x in right))
    scale = 10 ** (peak_dbfs / 20) / peak
    return [x * scale for x in left], [x * scale for x in right]


def write(name, channels):
    left, right = channels
    path = os.path.join(OUT, f"{name}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for l, r in zip(left, right):
            frames += struct.pack("<hh", int(round(l * 32767)), int(round(r * 32767)))
        w.writeframes(bytes(frames))
    print(f"wrote {path} ({len(left) / RATE * 1000:.0f} ms)")


E5, A5, C6S, E6 = 659.26, 880.0, 1108.73, 1318.51
D5, B4, G4 = 587.33, 493.88, 392.0

# Durations must match DictationSoundPlayer.Cue.duration.
write("dictation-begin", render(
    [note(E5, 0.0, 0.8), note(A5, 0.042, 1.0)], 0.17, -25.0))
write("dictation-release", render(
    [note(A5, 0.0, 0.85), note(E5, 0.040, 0.9, partials=SOFT_BAR)], 0.16, -26.5))
write("dictation-cancel", render(
    [note(D5, 0.0, 1.0, partials=SOFT_BAR, tick=0.03)], 0.09, -29.0))
write("dictation-error", render(
    [note(D5, 0.0, 1.0, partials=SOFT_BAR), note(B4, 0.07, 1.0, partials=SOFT_BAR)], 0.2, -26.5))
write("dictation-learned", render(
    [note(E5, 0.0, 0.7), note(A5, 0.055, 0.8), note(E6, 0.11, 0.75)], 0.3, -28.0))
