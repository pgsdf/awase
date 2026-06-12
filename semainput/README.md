# semainput

The `semainputd` userspace gesture daemon was retired on
2026-05-08 (AD-2a Phase 3). The daemon binary, the
`semainput/src/` source tree, the rc.d shim, and the s6 service
directory were all deleted at that time. The only thing that
remains under `semainput/` is the gesture-recognition library
`libsemainput/`, consumed by `semadrawd` directly.

**For current status, see `semainput/libsemainput/README.md`.**
That document is the authority for what exists here now. The
design decisions are recorded in
`inputfs/docs/adr/0016-libsemainput-extraction.md`, and the
historical multi-phase retirement plan is the AD-2a entry in the
root `BACKLOG.md`.

The kernel-side input substrate that replaced the daemon's role
is `inputfs/` (see `inputfs/docs/`). UTF's runtime input path no
longer involves a userspace evdev daemon.

## Historical note

Before retirement, semainput was a versioned userspace daemon
(reaching v41) that read evdev devices, classified them, applied
pointer smoothing, and emitted gesture events. The last daemon
revisions added a calibrated `scale_factor` field to pinch
events (v41) and refined three-finger arbitration (v40). That
recognition logic was not discarded: it was migrated into
`libsemainput/` during AD-2a Phase 2.3 and lives on there. This
section is retained only so the version lineage is not lost; it
does not describe anything currently running.
