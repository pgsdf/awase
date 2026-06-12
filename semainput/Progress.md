# Progress

**This file tracked the `semainputd` daemon, which was retired
on 2026-05-08 (AD-2a Phase 3). It is no longer maintained.**

For the current state of what remains under `semainput/` (the
`libsemainput` gesture-recognition library), see
`semainput/libsemainput/README.md`, which carries its own
phase history. The retirement plan and its closure are recorded
under AD-2a in the root `BACKLOG.md`.

## Historical daemon version lineage

Retained so the lineage is not lost. None of the below describes
anything currently running; the recognition logic these
revisions developed was migrated into `libsemainput/` during
AD-2a Phase 2.3.

v41 added:

- calibrated `scale_factor` field on `pinch_begin` and `pinch`
  events (ratio of current to previous finger separation)
- `delta` recalibrated to a pixel-distance difference
- `scale_hint` and `delta` retained for backward compatibility

v40 added:

- correct anchor placement for three-finger arbitration
- lower three-finger activation threshold
- more reliable swipe promotion on smooth hardware
- retained high-quality post-lock output
