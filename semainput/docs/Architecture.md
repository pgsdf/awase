# Architecture

**Archived 2026-05-08.** This document described the architecture
of `semainputd`, the userland input-classification daemon that
ran from before AD-1 (inputfs introduction) through Phase 2 of
AD-2a (libsemainput extraction). The daemon was retired in
AD-2a Phase 3 step 2 (commit landed 2026-05-08); see the root
`BACKLOG.md` AD-2a entry for the multi-phase plan that led
here.

The architecture below is preserved as a record of how input
flowed *before* Phase 1 inverted the relationship between
inputfs and semainputd. None of the named components exist in
the current tree.

## Pre-retirement pipeline (historical)

```text
reader threads
→ raw semantic queue
→ activity tracker
→ startup staging buffer
→ classification + aggregation + identity
→ pointer smoothing
→ structured semantic output
→ gesture recognizer
→ structured gesture output
```

Each arrow corresponds to a deleted source file under
`semainput/src/`: `event_queue.zig`, `device_activity.zig`,
`device_classify.zig` / `device_aggregate.zig` /
`device_identity.zig`, `smoother.zig`, `output.zig`,
`gesture.zig`. The files are gone from the working tree;
`git log -- semainput/src/` retrieves the history.

## Current architecture

For the input pipeline as of 2026-05-08, see:

- `inputfs/docs/inputfs-proposal.md` — the kernel-side
  HID owner that publishes the event ring at
  `/var/run/sema/input/events` and the device state region
  at `/var/run/sema/input/state`.
- `semadraw/src/backend/inputfs_input.zig` — semadrawd's
  consumer of the inputfs ring. Drains once per
  composition cycle.
- `semainput/libsemainput/` — the userland gesture
  recogniser. semadrawd holds one `GestureRecognizer` per
  session and feeds it events translated from the ring.
