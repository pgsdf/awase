# 0022 clickpad discrete button event reliability (AD-52)

## Status

Proposed, 2026-06-08. AD-52, carved from AD-27.

## Context

AD-27 (trackpad as cursor) closed on the motion resolution. The same
bench (HAILUCK USB touchpad on pgsd-bare-metal, which has separate
physical buttons rather than a click-anywhere surface) showed the
discrete pointer button events to be unreliable, and that was carved
out as AD-52.

Symptom, across four root-run benches via
`scripts/ad27-cursor-verify.sh`:

  - `pointer.button_down` was emitted exactly once, on the first-ever
    press.
  - `pointer.button_up` was never emitted.
  - the button STATE is read correctly: during a drag the held button
    shows as `buttons=0x1` on every motion record.

So motion and the held-button state are correct; only the discrete
button_down / button_up transitions are broken.

## Root cause (code-grounded)

The touch-button block (`inputfs.c`, the block guarded at line 3521 by
`loc_touch_button.size > 0 && btn != sc_touch_prev_button`) emits
`button_down` or `button_up` on each transition and then assigns
`sc_touch_prev_button = btn` (3558). That assignment is the only write
to the field outside `M_ZERO` at attach (declared 723); nothing else
resets it.

The block sits at the end of `inputfs_digitizer_dispatch`, which is
called once per report from a single site (3879). `btn` is extracted
per report by `inputfs_extract_digitizer` (`inputfs_parser.c` 686),
which returns 0 only for null arguments, invalid digitizer locations,
or a report-ID mismatch. It does not return 0 for an absent tip or
absent contact, and the button block has an explicit no-active-contact
path (3541). So a Report 7 carrying `btn=0` with no contact is not
dropped by extraction and would reach the block.

Therefore the dependency is precise: `button_up` fires if and only if
a Report 7 carrying the `btn=0` transition is actually dispatched and
reaches the block. The latch follows: the first press sets
`sc_touch_prev_button = 1`; if the matching `btn=0` report never flows
(or the device stops reporting with the button still considered held),
`prev` stays 1, every later press reads `btn == prev == 1` (no
`button_down`), and `button_up` is never emitted.

This corrects an earlier hypothesis that the `rc == 0` early return was
dropping the release report; it is not. The fault is the unconditional
dependence on a `btn=0` Report 7 reaching the block, plus a `prev` that
is never reset by any other path.

## The deciding observation

The correct fix depends on one fact the benches did not isolate:
whether the device emits a `btn=0` Report 7 at all after the press.
This observation is promoted from "wanted" to a decision input.

With `inputdump events --watch` on the pointer role, keep a finger
moving on the pad through a deliberate button press and release, so a
`btn=0` Report 7 is guaranteed to flow, and observe `button_up`.

  - Outcome 1: `button_up` fires under guaranteed flow. The defect is
    then confined to the contact-end case (the release coincides with
    loss of contact and no `btn=0` Report 7 is generated for it).
  - Outcome 2: `button_up` does not fire even under guaranteed flow.
    The latch is broader: the button field is not being observed in
    dispatched Touchpad-Mode reports at all.

## Observation result (2026-06-08): Outcome 2 confirmed

Two root-run captures on pgsd-bare-metal (`inputdump events --watch
--role pointer --device 5`), the second with a finger sliding
continuously while the left physical button was pressed and then
released mid-slide:

  - 1198 `pointer.motion` records, of which 687 over 10.6 seconds
    followed the press with the finger still sliding (nonzero dx/dy),
    so Report 7 was demonstrably flowing through and well past the
    release.
  - exactly one `pointer.button_down`, zero `pointer.button_up`.
  - the state `buttons` bit goes 0x0 to 0x1 at the press and stays
    0x1 for every subsequent motion record, never returning to 0x0.

This is Outcome 2. The release transition (`btn` 1 to 0) is never
observed, not as an event and not as the state bit clearing, despite
continuous Report 7 flow. Two consequences follow.

First, D2 is eliminated as a fix. D2 can only act on a `btn=0` present
on a dispatched report, and the finding is that no `btn=0` is present
anywhere in the flowing stream.

Second, the `--role pointer` watch receives button events from both
the digitizer path and the Report 1 (boot mouse) path, since both
publish pointer button events. No `button_up` arrived on either while
the pad streamed touch. So the release is not merely missing from
Report 7; it is not being delivered to inputfs in Touchpad Mode at
all. The likely explanation, consistent with a two-physical-button
trackpad, is that the button edges live on the Report 1 path, which
does not flow while the device streams Report 7.

Direction: D3 is selected. Its exact form depends on one fact still to
be pinned, which report actually carries the button (and the release).
That is the purpose of the AD-52 attach-log diagnostic now added at
inputfs.c (touch versus Report 1 button locations) and the
button-alone-no-finger contrast bench. D3 cannot be finalized or
implemented until that diagnostic resolves where the release is
reported; this ADR remains Proposed until then.

## Decision

### D1: invariant

Every emitted `button_down` must be balanced by a `button_up`, and
`sc_touch_prev_button` must never remain latched at 1 once the device
is idle. A permanently latched `prev` is a defect regardless of the
underlying mechanism. The fix is chosen by the observation but must
satisfy this invariant either way.

### D2: contact-end safety (applies under Outcome 1)

Scope, stated up front: D2 is not a general repair for "contact ended
while the button was latched." It is specifically a repair for the
case where the release state (`btn == 0`) is present on the final
dispatched contact report but would otherwise fail to generate a
transition. It does nothing when the final dispatched report still
carries `btn == 1` (button held through the lift); that scenario is
out of D2's scope by construction and is addressed only by D3.

If a `btn=0` report does flow when contact is present (Outcome 1) but
not when the release coincides with the last finger lifting, add a
contact-end safety at the contact-count 1 to 0 transition (near 3374):
if `sc_touch_prev_button != 0` and the current report's `btn == 0`,
emit a `pointer.button_up` at the lifting contact's last position and
reset `sc_touch_prev_button = 0`.

The `btn == 0` guard is required, and it is also what bounds D2's
scope. The button block at 3521 runs later in the same dispatch;
synthesizing on a lift report whose `btn` is still 1 would make that
block see `btn (1) != prev (0)` and re-emit a `button_down`. Guarding
on `btn == 0` also makes the safety idempotent with a genuine `btn=0`
report that does reach 3521 (whichever fires first clears `prev`, the
other sees no transition).

Limitation, stated plainly: this does not cover the case where the
button is physically held while all fingers lift and is then released
with no contact and no further report. That release is unobservable on
the Report 7 channel, and no synthesized event on that channel can be
both correct and timely for it. If that case matters, it is served
only by D3.

Limitation, stated plainly: this does not cover the case where the
button is physically held while all fingers lift and is then released
with no contact and no further report. That release is unobservable on
the Report 7 channel, and no synthesized event on that channel can be
both correct and timely for it. If that case matters, it is served
only by D3.

### D3: button tracking independent of Report 7 flow (applies under Outcome 2, and is the durable remedy generally)

Make button reliability not depend on Report 7 flow at all. Two
complementary parts:

  - verify `loc_touch_button` against this device's report descriptor
    (`inputdump` can dump the parsed locations); the field may be
    mislocated, or the separate physical button may be reported only in
    Mouse Mode.
  - evaluate the button on the Mouse-Mode (Report 1) path, which
    already maintains its own previous-buttons XOR transition logic
    against the state region (near 3780). Routing the clickpad button
    through that path means a click is observed regardless of whether a
    Report 7 carries it.

Under D3 the Report 7 block and the Report 1 path must share a single
source of truth for button state so a click is not emitted twice.

### D4: reattach

No change is needed for a stale latch across device reattach: the
softc is `M_ZERO` at attach, so `sc_touch_prev_button` resets to 0 on
every attach.

## Recommendation

Run the deciding observation first. Prefer D3 as the durable fix even
if Outcome 1 holds, because it removes the structural fragility (button
state coupled to Report 7 flow) rather than papering over one gesture;
D2 is the minimal fix if a Report-1 button is not available on this
device. Decide after the observation; this ADR is filed Proposed so
the mechanism and the branch are recorded without prejudging the
observation.

## Implementation (post-ratification, per outcome)

  - D2: add the guarded `button_up` plus `prev` reset at the count
    1 to 0 site; reuse the existing 20-byte payload (x, y, mask = 1,
    buttons = 0, session) and `INPUTFS_POINTER_BUTTON_UP`.
  - D3: descriptor check first; then correct parsing or wire the
    Report 1 path with shared button state.
  - forward-only; `awk` brace-balance and `sh -n` where applicable in
    the container; pgsd-bare-metal is the arbiter.

## Bench (pgsd-bare-metal, root)

  - deciding observation (finger moving through press and release):
    records whether `button_up` fires under guaranteed `btn=0` flow;
    selects D2 versus D3.
  - press and release with a finger present: one `button_down`, one
    `button_up`, balanced.
  - press, lift all fingers, release: `button_up` emitted exactly once,
    no latch.
  - multiple click cycles: each press emits `button_down`, each release
    emits `button_up`, `prev` never stuck.
  - held drag (button down through motion): still shows `buttons=0x1`
    on motion records, confirming no regression to the working state
    path.
  - button independent of contact lifecycle: press and hold the button
    before any touch contact is established, then introduce and remove
    touch contacts while still holding, then release the button. Expect
    one `button_down` at the press, no spurious button transitions as
    contacts come and go, and one `button_up` at the release. This
    exercises a button transition while the contact count varies and so
    proves the chosen implementation is genuinely independent of the
    contact lifecycle; it is the discriminating bench for D3.

## Consequences

  - AD-52 resolved: discrete clicks become reliable and the AD-27
    motion path is untouched.
  - Under D2 alone, a button held through an all-fingers-up lift and
    released idle is reported as released at lift time (the documented
    tradeoff); D3 removes that concession.

## Risks

  - Double `button_up` if a contact-end safety and a genuine `btn=0`
    report both fire: prevented by the `prev != 0` guard (idempotent).
  - Re-emitted `button_down` if a synthesis is not guarded on
    `btn == 0`: prevented by D2's guard.
  - Choosing D2 when the truth is Outcome 2 would leave clicks broken
    in ordinary finger-present use; mitigated by running the deciding
    observation before committing.
