# 0011 Attachment-layer review (hidbus vs lower)

## Status

Proposed: awaiting Stage C measurements.

**Update (2026-04-27):** Stage C completed without the chronofs
ts_sync integration that this ADR's measurements depend on. Every
event published in Stage C carries `ts_sync = 0`; only `ts_ordering`
(via `nanouptime`) is populated. The chronofs integration is
tracked as a Stage C deferred item under AD-1 in BACKLOG.md and
will likely be addressed in Stage D or a dedicated chronofs-
integration sub-stage. The measurement work this ADR is waiting
for will follow that integration: with `ts_sync` populated,
end-to-end latency and jitter from interrupt-callback entry
through publication can be quantified, which is the input
criterion 1 (Chronofs jitter measurement) calls for.

This ADR opens the question of whether inputfs's current attachment to
`hidbus` (per ADR 0007) remains the right long-term layer, or whether
inputfs should attach lower in the FreeBSD USB/HID stack (at `usbhid`
or `usbus`). It does not decide the outcome; it scopes the question,
lists alternatives, and defines the criteria a future revision will use.

## Context

ADR 0001 (module charter) commits inputfs to owning every input-device
class FreeBSD exposes through its USB, HID, and legacy input
infrastructure. This includes device enumeration, HID report parsing,
coordinate normalisation into compositor space, event sequencing,
timestamping, state publication, and focus-routed event delivery at
the system level. ADR 0001 does not prescribe the specific attachment
layer in the device tree.

ADR 0007 made the tactical choice to attach inputfs at `hidbus`,
matching HID Top-Level Collections via `HID_PNP_INFO` and displacing
`hms`/`hkbd`/`hgame`/`hcons`/`hsctrl`/`utouch`. This allowed Stage B
to proceed without implementing USB transfer setup or a full HID
descriptor parser from scratch; inputfs borrows those facilities from
the hidbus layer below it.

Stage B.1–B.5 have now landed against the ADR 0007 attachment.
With competing drivers unloaded and `devctl rescan` performed on
every hidbus instance, inputfs binds to devices, parses descriptors,
registers interrupt callbacks, and performs role classification.
B.5 verification (including the recent smoke-test adjustments) is
complete or imminent on FreeBSD VM and bare-metal targets.
The current implementation functions.

Two observations from Stage B are relevant:

1. The hidbus attachment imposes a steady operational ergonomics cost:
   verification and operation require unloading competing drivers and
   rescanning every hidbus instance. This is documented and tractable
   but remains a friction point.

2. ADR 0001 and `docs/Thoughts.md` require audio-clock-stamped event
   publication anchored via chronofs. Stage B.4 registers interrupt
   callbacks through hidbus's dispatcher, which sits between USB
   transfer completion and inputfs. The latency/jitter contribution
   of this intermediate layer has not yet been measured. Whether it
   affects chronofs determinism is a Stage C question.

This ADR exists because both observations suggest value in owning more
of the stack, yet neither is decisive on its own. Verification
ergonomics alone do not justify migration. Material chronofs jitter
would. The appropriate time to decide is after Stage C produces
empirical data.

## Alternatives Considered

### A. Continue at hidbus (current state)

inputfs remains attached at `hidbus` per ADR 0007. The test toolchain
handles the unload-and-rescan workflow. All future work proceeds on
the existing foundation.

Cost: zero new implementation cost, but continued operational tax.
Risk: if Stage C jitter measurements show material non-determinism
from hidbus dispatch, migration becomes necessary later.

### B. Attach at usbhid

inputfs attaches one level below hidbus, at `usbhid`. It receives raw
HID transfer completions directly, taking ownership of report-ID
dispatch, descriptor caching, and HID descriptor parsing (currently
borrowed via hidbus).

Cost: significant, primarily from implementing or porting a HID
descriptor parser. USB transfer setup remains reusable from `usbhid`.
Compatibility impact: inputfs displaces hidbus for matched devices.

### C. Attach at usbus

inputfs attaches directly to the USB bus, bypassing both hidbus and
usbhid. It owns USB transfer setup, HID class recognition, and all
of the above from alternative B.

Cost: substantial (USB transfer code + parser).
Benefit: maximum control and the cleanest path to low-level
interrupt timestamping.

### D. Hybrid (fast path at usbhid, fallback to hidbus)

inputfs supports both attachment points simultaneously, using the
deeper path only for devices where chronofs determinism requires it.

Cost: highest complexity (dual probe/attach paths, dual interrupt
handling, doubled test matrix). This alternative is recorded for
completeness but is not considered viable; it combines the drawbacks
of A and B with few of the benefits.

## Deciding Criteria

A future revision will select among A–C using these criteria (in
approximate priority order):

1. **Chronofs jitter measurement (Stage C)** is the strongest input.
   End-to-end timestamping will quantify the latency and jitter
   added by hidbus's interrupt dispatcher. If below the noise floor,
   A is justified on merit. If material, B or C becomes justified.

2. **Code complexity and long-term maintenance cost**
   Alternative B requires a HID descriptor parser; C requires that
   plus USB transfer code. The cost is paid once but maintained
   indefinitely.

3. **Operational ergonomics**
   Elimination of the unload-and-rescan workflow is a real benefit
   of B or C, but secondary to determinism measurements.

4. **Cost of porting Stage B work forward**
   Role classification, descriptor handling, and the `sc_roles`
   field would transfer to B with mostly mechanical changes
   (different attach hook, different probe table). Porting to C is
   more structural but still moderate.

5. **Consistency with ADR 0001**
   All three alternatives (A, B, C) satisfy ADR 0001's system-level
   ownership commitment. ADR 0001 does not dictate attachment layer;
   this criterion is recorded only to confirm it was considered.

## Open Questions

Answers to the following are prerequisites for any future decision:

- How exactly will inputfs read the audio clock in Stage C
  (at interrupt-callback entry or later)? This determines which
  dispatch latencies matter.

- Is hidbus interrupt dispatch latency a fixed offset (correctable)
  or variable jitter (problematic for determinism)?

- Are there planned upstream changes to hidbus in FreeBSD 15 that
  would affect this analysis?

- For alternative B: port the existing `dev/hid/hid.c` parser,
  fork it, or write a new minimal one?

## Notes

This ADR deliberately contains no recommendation. Decision and
implementation plan will be added in a future revision once Stage C
measurements exist.

The current master implementation (post B.5 smoke-test adjustments)
is alternative A in practice. Continuing with A is the default;
a positive decision is required only to move to B or C.

This ADR does not supersede ADR 0007. A future revision choosing B
or C would do so.

Reference points:
- ADR 0001 (module charter)
- ADR 0007 (current hidbus attachment)
- `inputfs/docs/foundations.md` (timestamping requirements)
- `docs/Thoughts.md` (chronofs audio-clock anchoring)
- `inputfs/docs/B5_VERIFICATION.md` (operational ergonomics)
- `shared/INPUT_IOCTL.md` (current control-plane layering)
