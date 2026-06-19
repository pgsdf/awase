# 0020 Frame pacing clock liveness and idle freeze recovery

## Status

Accepted 2026-06-18 (operator). Ratified as drafted. The one open question
(the 500 ms GATE_STALL_REWIRE_NS stall window versus a tighter window with
hysteresis) is carried to bench tuning, with 500 ms retained for the first
cut. Drafted after the audio-clock-freeze diagnosis below was confirmed on
bare-metal-test-bench with inputdump and the frame_scheduler regression tests
landed in the same investigation. Supersedes nothing; it formalises and
extends the AD-43.3a runtime watchdog, which until now existed only as code
comments in compositor.zig, frame_scheduler.zig, and events.zig.

## Context

The compositor paces its FrameScheduler on a pluggable ClockSource. When
audiofs is clocking at daemon start, semadrawd wires a ChronofsClockSource
(reading /var/run/sema/clock, the kernel sample counter audiofs publishes)
and the compositor adopts it for pacing if it passes the AD-43.3a adoption
gate (ChronofsClockSource.isAdvancing(): the published sample count advances
across one 50 ms read window). The adoption is logged as
"frame pacing: adopted audio hardware clock". The point of adopting it is
av-sync: frame_complete events and audio stream events then share one
timeline.

FrameScheduler.shouldComposite() is `clock.now() >= next_deadline_ns`, and
next_deadline_ns only moves forward in advanceFrame, which runs on a
composite. So the deadline advances only while the compositor is actually
compositing, and the decision to composite is gated on the adopted clock
having reached the deadline.

audiofs advances samples_written only while the output stream is running
(BDL draining, interrupts firing). When the stream stops, RUN is cleared and
DMA stops, so samples_written freezes. clock_valid stays 1; only the counter
stops. This is a designed state, not an error: the clock is truthfully
reporting that no samples are being played.

The consequence is a permanent compositor stall. After the output stream
goes idle (observed at roughly one to two minutes of desktop inactivity),
the adopted audio clock freezes below next_deadline_ns. shouldComposite()
then returns false on every pass forever, the compositor never composites
again, the cursor and any client surface stop updating, and the desktop
appears to stop accepting input. The input path itself is healthy
throughout: inputdump on the inputfs event ring showed pointer.motion events
streaming with unbroken sequence numbers across an idle gap of about eight
minutes (seq 235 at ts 132.9 s straight to seq 236 at ts 626.5 s), proving
the kernel, hidbus, the device, and the ring are all live. The fault is
entirely the frozen pacing clock starving the composite loop.

AD-43.3a already anticipated a frozen pacing clock (its motivating case was
`kldunload audiofs` with the desktop up) and added a runtime watchdog in
Compositor.needsComposite: when `has_damage and not should_composite and not
clock_rewired_to_wall` persists for GATE_STALL_REWIRE_NS (500 ms of wall
time), rewire the scheduler to the wall clock once and warn. That watchdog
does not rescue the idle freeze, because its arming condition requires
pending damage:

  1. During idle there is no damage, so the watchdog never starts its timer
     and the freeze sets in silently.
  2. Recovery is then made to depend on the user generating input that marks
     damage, but the compositor that would render that input is itself
     frozen, and the field report is a permanent stall, so the damage-gated
     path is at best fragile and does not reliably fire in the idle case.

The startup adoption gate cannot prevent this either: the clock is advancing
at adoption time and only freezes later, mid-life. Liveness of an adopted
pacing clock is therefore a runtime property that must be checked
continuously, not once at adoption.

## Decision

Make stall detection damage-independent and reversible.

1. Detect a frozen adopted clock directly. On each needsComposite
   evaluation, sample the adopted clock and compare against a stored
   (value, wall-time) snapshot. If the adopted clock value advanced, refresh
   the snapshot. If it has not advanced and wall time has progressed past a
   stall window, the adopted clock is frozen. Remove `has_damage` from the
   stall condition entirely: a pacing clock that has stopped is a fault
   whether or not anything currently wants to draw, and the existing
   has_damage gate is exactly what blinds the watchdog to the idle case.

2. Rewire to the wall clock on a detected freeze. As today, swap
   scheduler.clock to the wall source and call scheduler.start() to re-seed
   next_deadline_ns in the wall epoch, so the first composite lands within
   one frame interval. Warn once per transition.

3. Re-adopt the audio clock when it resumes advancing. Replace the one-shot
   clock_rewired_to_wall latch with a two-state pacing mode (audio or wall).
   While on the wall fallback, probe ChronofsClockSource.isAdvancing() on a
   bounded cadence (not every iteration; the probe costs a 50 ms sleep), and
   when it advances again, re-adopt the audio clock and re-seed. This keeps
   av-sync when audio plays and restores it when audio resumes, instead of
   permanently degrading to wall pacing after the first idle period.

The wall clock (CLOCK_MONOTONIC) is the liveness reference throughout: a
suspect clock cannot judge itself, which is why the stall window is measured
in wall time, exactly as AD-43.3a already does.

## Alternatives considered

A. audiofs coasts samples_written on elapsed wall time while the DAC is
   stopped, so the published clock never freezes. Rejected. samples_written
   has a defined meaning: cumulative real DAC samples played, consumed by
   inputfs ts_sync stamping and by av-sync. A coasting counter would report
   samples that were never played and would lie to every other consumer of
   the clock, and it pushes a compositor-pacing concern down into the kernel
   audio driver. The clock should report truth; the compositor should
   tolerate a truthful clock that legitimately stops.

B. Pace the compositor on the wall clock unconditionally and use the audio
   clock only to stamp presentation timestamps, never to gate the composite
   deadline. This cleanly separates when-to-draw (wall, always live) from
   what-timestamp-to-stamp (audio, for av-sync) and also fixes the freeze.
   Deferred rather than rejected: it removes the audio-paced cadence
   AD-43.3a deliberately adopted and is a larger behavioural change. If the
   watchdog approach in this ADR proves fragile in practice, B is the
   recommended follow-up simplification and should get its own ADR.

C. Only widen the startup adoption gate (a longer isAdvancing window).
   Rejected: the freeze is mid-life, after adoption, so no startup-time gate
   can prevent it.

## Implementation (after ratification)

Confined to semadraw/src/compositor/compositor.zig:

- Add pacing-mode state (audio or wall) and a `(last_audio_clock_value,
  last_audio_clock_wall)` snapshot, replacing the single
  clock_rewired_to_wall bool.
- In needsComposite, before the shouldComposite gate, run the liveness
  check described above; drop the has_damage term from the stall condition.
- Add a bounded re-adoption probe on the wall fallback path.
- Keep GATE_STALL_REWIRE_NS as the stall window for the first cut, but see
  Risks: a tighter window with hysteresis is likely warranted for snappier
  recovery, and the value is the main open tuning question for the bench.

Tests: the FrameScheduler contract is already pinned by the two regression
tests added alongside this ADR (a MockClockSource freeze test and an
end-to-end ChronofsClockSource freeze test in frame_scheduler.zig). A new
compositor-level test should cover the rewire and re-adopt transitions; it
needs a controllable wall clock or a bounded real sleep because the stall
window is measured in wall time.

## Consequences

- The idle freeze is eliminated: the compositor recovers from an adopted
  clock that stops, with no dependence on input or pending damage.
- av-sync is preserved while audio is active and restored when it resumes,
  rather than being abandoned permanently after the first idle.
- needsComposite does slightly more work per iteration: one extra clock read
  and a wall-time compare. It already reads the clock for shouldComposite, so
  the marginal cost is a compare and an occasional snapshot store.
- The AD-43.3a comment and the clock_rewired_to_wall latch are subsumed by
  this ADR and should be updated to point here.

## Risks

- Spurious rewires if the stall window is too tight relative to legitimate
  brief audio gaps. Mitigate with a window of several frame intervals and by
  treating any clock advance as an immediate reset.
- Adopt/rewire flapping if audio toggles rapidly. Mitigate with a minimum
  dwell time on each pacing mode (hysteresis) and a bounded re-adoption probe
  cadence so the 50 ms isAdvancing sleep cannot run hot.
- Re-adoption re-seeds next_deadline_ns in a new epoch; a transient one-frame
  pacing hitch at each transition is expected and acceptable.
