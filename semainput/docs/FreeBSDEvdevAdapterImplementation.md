# FreeBSD evdev adapter implementation

**Archived 2026-05-08.** The evdev adapter described here lived
in `semainput/src/adapters/evdev.zig`, which was deleted in
AD-2a Phase 3 step 2. The adapter read `/dev/input/event*`
nodes via FreeBSD's evdev compatibility shim and forwarded
events to `semainputd`'s classifier.

That entire path no longer exists. Under inputfs (Stages A-D
of AD-1, completed 2026-04), the kernel module owns HID
exclusively at the hidbus layer (per ADR 0007 / ADR 0018 §3a)
and publishes pre-classified events directly into a
shared-memory ring; the evdev userland reader path is gone,
and no userland code reads `/dev/input/event*` in UTF Mode.

## Historical v28 notes (preserved for context)

The `semainputd` daemon exposed structured JSON-line output:

- emits newline-delimited JSON output
- semantic events were structured rather than free-form debug text
- gesture events were structured rather than free-form debug text
- multitouch scroll hysteresis
- drag suppression during active multitouch scroll
- smoothed two-finger scroll output
- touch marker key filtering

The classification logic and gesture recogniser survive in
`semainput/libsemainput/`; semadrawd consumes them directly,
without a JSON serialisation step.
