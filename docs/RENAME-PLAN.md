# Rename plan: UTF to Awase

Ratified 2026-06-12 (operator): the substrate is renamed Awase
(from awaseru, to bring together, to align). PGSD is unchanged.
The rename is prospective only: forward-only git, history files
untouched. Survey basis: full-tree grep at e1f9e3c plus this
session's edits.

## Classification

### R1: living prose, doc-level (patchable now; no build impact)

- README.md: DONE this session (title, descriptor with formerly-UTF
  note, 29 prose occurrences; the one remaining UTF is the
  docs/AWASE_ARCHITECTURAL_DISCIPLINE.md path reference, which waits
  for R2).
- BACKLOG.md (55 occurrences): framing and section headers only.
  The Long-term section header is DONE (it is cross-referenced from
  the README). Remaining occurrences sit inside recorded entry
  text; rename navigational prose case by case on next touch of
  each entry, never the recorded decision language.
- INSTALL.md (39): full prose pass owed; clone URLs change with the
  repo slug (R4) and old URLs redirect after a GitHub rename, so
  URL updates can ride the same edit.
- docs/ living references: POLICY.md, FAILURE_MODES.md,
  FREEBSD_IMPROVEMENTS.md, FREEBSD_ISSUES.md, FREEBSD_SUBSYSTEMS.md,
  PROTOCOL_NAMESPACE_CONVENTION.md, docs/README.md,
  does-awase-have-a-framebuffer.md (content pass; the filename itself
  is R2).
- Subsystem living docs: semadraw/README.md, ARCHITECTURE.md,
  WM_CLIENT_CONTRACT.md; semainput/README.md and design docs;
  s6/README.md; pgsd-sessiond/README.md; shared/ spec prose
  (CLOCK.md, AUDIO_EVENTS.md, INPUT_IOCTL.md, INPUT_SMOOTHING.md);
  inputfs/test/fuzz/README.md; chronofs/BACKLOG.md framing.

### R2: file renames and code comments (one batch, build-verified)

- Five docs/UTF_*.md files rename to docs/AWASE_*.md, plus
  does-awase-have-a-framebuffer.md. Every cross-reference updates in
  the same commit: ADR texts that cite the paths keep their wording
  but a path is a pointer, not prose, so pointers update even in
  historical files (flagged for operator ratification: alternative
  is leaving stubs at the old paths).
- Zig comment references: shared/src/posix_safe.zig (UTF prose and
  the AWASE_ZIG_STDLIB_BOUNDARY.md path), shared/src/clock.zig
  ("canonical UTF" comments and constants commentary, and the
  AWASE_ARCHITECTURAL_DISCIPLINE.md path). Comment-only, but source
  changes ride a clean rebuild: zig build test across subsystems,
  then the standard bare-metal flow.

### R3: operational paths (ADR-grade; bare-metal bench required)

- s6/utf/ scandir and its installed location /var/service/utf/:
  baked into install.sh, the running supervisor on pgsd-bare-metal,
  and AD-20's record. Renaming to s6/awase + /var/service/awase
  needs migration handling in install.sh (reap or move the old
  scandir, the semaaud-reaping pattern), a decision on whether
  running systems migrate or only fresh installs, and bench on
  pgsd-bare-metal. This is a small ADR or at minimum a ratified
  plan entry before code. Alternative: keep the utf path as legacy
  plumbing indefinitely; rejected by default since the name will
  outlive the memory of the rename, but cheap if chosen.
- install.sh, clean.sh, configure.sh, bench_setup.sh: audit for
  utf-named paths and variables in the same pass.

### R4: external coordination (operator-executed)

- GitHub slug: pgsdf/UTF renames to pgsdf/awase. GitHub redirects
  the old URL and remotes; local remotes update at leisure.
- pgsdf.org references to UTF.
- NLnet proposal names UTF. Decision owed: if the application is
  still under review, either hold the public rename until the
  decision or send NLnet a one-line renaming notice; do not let
  the repo and the proposal silently disagree.
- The NDE repository's references to UTF, updated when the
  semantic-design text lands there (the design document itself is
  already renamed).

### Leave alone, permanently

- BACKLOG-history.md (144 occurrences), docs/sessions/*,
  pgsd-sessiond/docs/sessions/*, all ratified ADR texts,
  verification records (*_VERIFICATION*.md, fuzz findings).
  These are the record; the README's formerly-UTF note is the
  bridge for future readers. Sole exception: R2 path pointers as
  flagged above.

## Sequencing

R1 remainder and R2 fit one documentation session (R2's build
verification is mechanical). R3 is its own small item with bench.
R4 rides the next push: rename the slug in the same sitting as
applying this patch, so the README and the repo agree from the
first public moment.
