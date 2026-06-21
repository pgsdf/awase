# Session record: 2026-06-21

## Finding: display/input freeze did not recur post-AD-50; storm-coupled hypothesis supported

The display/input-freeze-after-idle symptom that opened the audio
investigation series did not reproduce on the post-AD-50 system across
roughly three hours of idle soak. The evidence supports the hypothesis
that the freeze was a downstream effect of the audiofs underrun storm,
not an independent display defect.

### Background

The original symptom (logged across the predecessor sessions) was
mouse and keyboard input freezing after a few minutes of idle, with the
panel dead and VT switch unresponsive. That symptom was always observed
while the audiofs path_dead_end storm was active (about 47 topology
walks per second plus the associated interrupt load), so the two were
never separated experimentally. The investigation hypothesized, but
could not test, that the freeze was storm-coupled: the storm's sustained
CPU and interrupt pressure starving the input or compositor path, rather
than a distinct bug in drawfs, vt(4), or the efifb scanout.

AD-50 (single-owner DeviceFd; bench-ratified 2026-06-20) removed the
trigger of the unfed-stream wedge, and D1 (s6-log path fix) restored
per-service logging. For the first time the system could sit idle with
no storm and a quiet log, which made the storm-coupled hypothesis
testable.

### What was done

A soak watcher (tools/display-freeze-soak.sh) sampled cheap,
non-perturbing liveness signals at 15 s intervals over one-hour windows:
the audiofs pacing clock samples_written (offset 12, the clock semadrawd
paces on), underflow_count flatness, the three supervised daemons
(semadrawd, pgsd-sessiond, semasound) and the inputfs kernel module. The
watcher deliberately did not use UTF_COMPOSITOR_INSTRUMENT: it is read at
compositor construction (cannot be armed at freeze time without a
restart that clears the freeze) and at about 240 lines per second would
add the steady load the test exists to rule out.

The watcher had two detector defects, both corrected and the corrected
logic verified before the result was trusted:

  - It first checked for a semainputd daemon, which does not exist on
    this system (input is the inputfs kernel module plus semainput linked
    into the compositor). The missing process made the liveness set never
    match its expected value, firing a false capture on every sample.
  - The replacement used a steady-state test (flag whenever the set is
    not all-up), so any check that silently never matched produced a
    permanent false drop. Two one-hour runs each fired 239 false
    captures on a healthy system.

The detector was made edge-triggered: a daemon is flagged as dropped
only on an up-to-down transition, so a check that is wrong from the start
sits at a steady value and cannot fire. The inputfs check was widened to
match either name form via kldstat. The edge logic was unit-tested
against a broken-matcher-on-healthy-system sequence (now zero drops) and
against real death, respawn, and double-drop sequences (fire correctly).

### Result

The corrected run (2026-06-21, one hour, 240 samples) was clean:
the pacing clock advanced on every sample, underflow stayed flat at 0,
no daemon drops, no captures. Combined with the two earlier hour-long
windows (whose underlying liveness was also clean, the 239 captures
each being the detector bug on a healthy system), this is roughly three
hours of idle with no freeze on the post-AD-50 system.

### Disposition

The freeze did not recur once the storm was removed. This supports
treating the display/input-freeze-after-idle symptom as storm-coupled:
a downstream effect of the audiofs underrun storm load, resolved by
AD-50 removing the storm trigger, rather than an independent display
bug in drawfs, vt(4), or the efifb scanout. The AD-10
framebuffer-ownership gap (vt_efifb and drawfs_efifb both mapping the
EFI framebuffer with no protocol) remains a real latent concern in its
own right, but its documented symptom is corruption or strobe, not a
hard freeze, and it was not implicated by this soak.

### Caveats (why this is supported, not closed)

  - The soak observes internal liveness (clock, daemons, audio), not
    panel input directly. Headless sampling cannot confirm "mouse and
    keyboard responsive at the panel"; the watcher's manual trigger
    (kill -USR1, or touch /tmp/freeze-now) covers that only if an
    operator is watching the screen when a freeze is seen. A
    screen-watched idle window with internal liveness green is the
    direct confirmation of the input dimension.
  - The original freeze was intermittent. One clean hour is strong but
    not conclusive against a rare or slow trigger. An overnight soak
    (display-freeze-soak.sh 28800 30) is the hardening step before
    closing the symptom outright.

### Next

  - Optional: a screen-watched idle window to confirm panel input
    directly, and an overnight soak to harden the negative.
  - On those passing, record the original freeze symptom as
    resolved-by-AD-50 (storm-coupled) wherever it is tracked, rather
    than carrying it as an open independent display defect.
