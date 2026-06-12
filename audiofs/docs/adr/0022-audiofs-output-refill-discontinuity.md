# 0022 audiofs output refill discontinuity (per-fragment stale replay)

## Status

Accepted, 2026-06-01, with the root cause AMENDED 2026-06-01
after measurement. The original hypothesis in this ADR (an
LPIB-derived refill cursor causing stale-fragment replay) was
REFUTED by its own instrumentation: refill_miss_count is zero
during playback (one miss at stream start only), and a
subsequent capture fork proved the played bytes are byte-exact
(see Amended findings). The defect is real and unchanged in
its signature, but it lies below the software path. The
fix-direction in Decision 1 (DPIB position source) is retained
only as a latent-correctness improvement, NOT as the fix for
this hum; the actual cause is still open and now localized
below the DMA buffer. See the Amended findings section and the
revision history.

The investigation continued in ADR 0023, which RESOLVED the
hum: it was per-fragment interrupt servicing on a slack-free
2-entry DMA ring, fixed by deepening the ring to 4 entries.
This ADR's contribution was the localization (software
exonerated by the refill counters and the byte-exact capture);
the cause and fix are recorded in ADR 0023.

A defect ADR, not a milestone ADR. It records a fault found
during F.5.a bench work, fixes it in the F.3 output DMA path,
and amends the F.3.a-e bench-verified record. It does not
belong to F.5; semasound is not at fault (see Context).

## Amended findings (2026-06-01, after instrumentation)

Two measurements overturned the root cause this ADR proposed
and relocated the defect.

1. Refill-miss instrumentation (Decision 3). With the BCIS
   handler counting fragments refilled per interrupt,
   `refill_miss_count` recorded exactly one miss at stream
   start (the cursor settling on the first interrupt) and zero
   thereafter, across both a hummed tone (440) and a clean one
   (750); `refill_multi_count` stayed zero. The refill delivers
   exactly one fragment per interrupt, on time. The stale-
   fragment-replay hypothesis is refuted.

2. Capture fork. The user-ring refill was made to tee each
   committed fragment, in refill order, into a one-shot 32 KB
   buffer exposed as the `capture_buf` opaque sysctl: the exact
   bytes handed to the DMA region. playtone gained `--refout`
   to dump the identical PCM it generated, and capture_cmp
   compared the two. Result for 440 Hz: 8192 frames, byte-for-
   byte identical. Every sample intended for playback was
   committed to the DMA buffer unaltered.

Conclusion. The whole software path, write(2), the user ring,
the refill copy, and the fragment boundaries, is exonerated by
measurement. The artifact (digital, locked to the 46.875 Hz
fragment rate, inaudible only to fragment-periodic tones,
zero underruns) originates at or below the DMA hardware
programming. Remaining suspects, all below the buffer: the
SDnFMT format word, the BDL completion / IOC-per-fragment
interrupt behavior at the boundary (IOC=1 on both entries
fires at exactly the 46.875 Hz hum rate), DMA position
handling, or the codec path beyond the controller. The next
action is to isolate the BDL interrupt rate and buffer
geometry from the data, under a successor investigation, since
this ADR's stated mechanism no longer holds.

## Context

F.5.a bench play surfaced a frequency-dependent hum: a single
client at 750 Hz is clean, but 440 Hz and 660 Hz carry a low
hum. The diagnosis ran as follows.

semasound is exonerated. The mixer's per-second underflow
counters (short, absent) are zero in every case including two
clients; the mix and ring-pop paths copy contiguously; and
the hum reproduces with playtone writing straight to
`/dev/audiofs0`, with no semasound, socket, or mixer in the
path. So the fault is below semasound.

The hum is locked to the output DMA fragment. The fragment is
1024 frames (`AUDIOFS_BUF_FRAG_BYTES` / 4), so the fragment
rate is 48000 / 1024 = 46.875 Hz. Tones that are exact integer
multiples of that rate are clean (750 = 16x, 468.75 = 10x,
656.25 = 14x, all verified clean on the bench); tones that are
not are hummed (440 = 9.39x, 660 = 14.08x). The artifact is
digital, deterministic, frequency-selective, independent of
the userland write chunk size, and `dev.audiofs.0.underflow_count`
stays 0 throughout (no zero-fill, no FIFOE).

Code review clears the software copy. The producer
(`audiofs_cdev_write`) is frame-aligned, splits correctly at
the ring wrap, and does the sleeping `uiomove` outside the
lock with the head advanced only after the copy. The
per-fragment refill (`audiofs_refill_user_fragment`) copies a
full contiguous fragment from the user ring, handles the wrap,
and advances the tail exactly. The static BDL is correct: two
entries at the right addresses, `len` = fragment bytes, IOC on
each, CBL = full buffer, LVI = 1.

The remaining mechanism is the refill cursor. In the BCIS
branch (audiofs.c ~4903) the driver computes
`curr_fragment = curr_lpib / AUDIOFS_BUF_FRAG_BYTES` from a
same-instant LPIB read and refills `next_refill_fragment` up
to `curr_fragment`. SDnLPIB is known to be imprecise and laggy
at fragment boundaries on HDA controllers; the HDA
specification recommends the DMA Position Buffer (DPIB) for
accurate position. On the 2-entry / 8 KB ring there is no
slack. If LPIB at the interrupt still reports a position
inside the just-completed fragment, then
`curr_fragment == next_refill_fragment`, the while loop
refills nothing, and when the DAC loops back to that fragment
it replays the stale contents from two fragments ago.

A stale fragment is bit-identical to the correct one for any
tone whose period divides the 1024-frame fragment (750,
468.75, 656.25) and a phase discontinuity for any tone that
does not (440, 660). That is precisely the observed
selectivity, and it is why `underflow_count` stays 0: the
buffer is never starved, the data is merely stale. The entire
F.3.a-e bench history used playtone, which emitted only 750 Hz
until the F.5.a work added a frequency option, so this defect
was masked by testing exclusively at the one immune frequency.

## Decision

1. Stop deriving the refill cursor from LPIB. Use the HDA DMA
   Position Buffer (DPIB) as the accurate position source for
   the refill-target computation. Audit `frames_played` and
   the F.4 clock accumulation (ADR 0018), which also consume
   LPIB deltas, for the same dependence and correct them if
   the lag introduces error.

2. Deepen the output DMA ring beyond two fragments so the
   refill always operates well behind the DAC and a single
   mistimed interrupt cannot produce a stale replay. The 8 KB
   / 2-entry buffer was an early bring-up artifact (the commit
   6c note in audiofs.c calls it proof the DMA path is live,
   not proof of glitch-free audio). A deeper ring also lowers
   the interrupt rate. This is defense in depth; the position-
   source fix removes the cause, ring depth hardens against
   timing slop.

3. Confirm the mechanism before committing the fix. Instrument
   the BCIS handler to count, per interrupt, the number of
   fragments refilled, exposing `refill_miss_count` (interrupts
   that refilled zero) and `refill_multi_count` (two or more)
   as sysctls. The miss is a timing artifact of the LPIB read
   against the cursor and does not depend on the audio samples,
   so it is frequency-independent: the prediction is that
   `refill_miss_count` climbs during playback at any tone,
   including the clean 750, with `refill_multi_count` tracking
   it as the cursor catches up. The decisive observation is
   that 750 accrues misses yet sounds clean, which directly
   demonstrates that a stale fragment is inaudible when the
   tone is fragment-periodic. If instead `refill_miss_count`
   stays at zero (exactly one refill per interrupt), the
   cursor-miss hypothesis is refuted and the discontinuity is
   systematic and elsewhere, redirecting the investigation.

4. Re-verify F.3.a-e at non-750 tones once fixed. This defect
   amends those closures: they verified the DMA mechanism, not
   glitch-free audio at arbitrary frequencies. With playtone's
   `--freq`, replay 440, 660, and a non-multiple sweep direct
   to the device; all must be clean with `underflow_count` at
   0; 750 must remain clean.

## Rejected alternatives

  - The speaker. Rejected: 468.75 and 656.25, exact multiples
    of the fragment rate, are clean while 440 and 660 hum. A
    mechanical resonance cannot align to the DMA fragment rate.

  - An underrun or a too-slow refill. Rejected:
    `underflow_count` is 0; the buffer is never starved. The
    data is stale, not missing.

  - A bug in the ring copy (producer or consumer). Rejected on
    review: both are frame-aligned and contiguous.

  - Enlarging the buffer as the only fix. Insufficient alone
    if the cursor still trusts a laggy LPIB; a deep ring masks
    the symptom but does not remove the cause. Do the position-
    source fix; treat ring depth as hardening.

## Consequences

  - F.3.a-e closures are amended: re-verification at non-750
    is now required, and the bench notes on those entries must
    record that the original verification used only the immune
    750 Hz tone.

  - Real-world audio (music, voice, anything not fragment-
    aligned) was glitching at the fragment rate the whole
    time. This fix is a precondition for audiofs being usable
    beyond the test tone, and therefore a precondition for
    semasound delivering correct audio in practice even though
    semasound itself is correct.

  - F.5.a is unaffected and correct (ADR 0021); it may close
    on its own merits with this defect filed here. The F.5.a
    multi-client hum will disappear once this is fixed.

  - The F.4 clock (ADR 0018) shares the LPIB dependence;
    delta accumulation is more tolerant of lag than absolute
    position, but the audit in Decision 1 must confirm no
    regression.

## Closure criteria

  1. Mechanism confirmed by instrumentation: `refill_miss_count`
     is nonzero during playback (frequency-independent), and
     750 accrues misses while sounding clean, demonstrating
     stale-fragment replay. If it stays zero, the cursor-miss
     hypothesis is refuted and the investigation redirects.
  2. After the fix, playtone direct at 440, 660, and a non-
     multiple sweep play clean; 750 stays clean;
     `underflow_count` stays 0.
  3. semasound two-client play at 440 + 660 is clean (the
     F.5.a hum is gone).
  4. F.3.a-e re-verified at non-750 tones on pgsd-bare-metal;
     bench notes appended to those entries and to the F.4
     clock audit result.
  5. Operator marks the F.3 entries re-verified.

## References

  - ADR 0014 (F.3.a continuous streaming), ADR 0016 (F.3.c
    interrupt-driven position; the LPIB/IOC design this
    revisits), ADR 0017 (F.3.d xrun), ADR 0018 (F.4 clock;
    shares the LPIB dependence), ADR 0021 (F.5.a; the bench
    work that surfaced this).
  - audiofs.c: BCIS refill cursor ~4903, refill copy
    `audiofs_refill_user_fragment` ~4624, producer
    `audiofs_cdev_write` ~5595, BDL/CBL/LVI setup ~4436.
  - HDA specification: DMA Position Buffer as the accurate
    stream position source, versus SDnLPIB.

## Revision history

  - 2026-06-01: first draft. Diagnosis (semasound exonerated;
    fragment-locked digital artifact at 46.875 Hz; producer,
    refill copy, and BDL clean; underflow_count 0), root cause
    (LPIB-derived refill cursor on a slack-free 2-fragment ring
    causing stale-fragment replay), fix decision (DPIB position
    source, deeper ring, instrument-then-fix, re-verify F.3 at
    non-750).
  - 2026-06-01: corrected Decision 3 and closure criterion 1.
    The refill miss is a timing artifact independent of the
    audio samples, so it is frequency-independent; the original
    "misses during 440/660, none during 750" prediction was
    wrong. The sharper proof is that 750 accrues misses yet
    sounds clean.
  - 2026-06-01: root cause AMENDED after measurement. Refill-
    miss instrumentation showed zero misses during playback,
    and the capture fork proved the played bytes byte-exact
    (8192 frames identical for 440 Hz). The stale-fragment
    hypothesis is refuted; the software path is exonerated; the
    defect is relocated to at or below the DMA hardware
    programming. Status amended accordingly; a successor
    investigation will isolate the BDL/IOC interrupt rate and
    buffer geometry from the data. See Amended findings.
