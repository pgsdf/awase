# 0029 F.6: semaaud retirement

## Status

Closed, 2026-06-05: all ten closure criteria verified on
pgsd-bare-metal (criterion 1 corroborated on pgsd-dev) and the
operator marked F.6 complete.

Accepted, 2026-06-04 (ratified as written, with enumeration
completions folded into Decisions 3 and 5 so the decision
text explicitly names what the closure criteria already
enforce, and with the operator's independent audit recorded
as converging with the Context findings on every point).

The final AD-3 milestone before the maintenance model. Depends
on F.5 complete (ADRs 0021, 0024-0028, all closed): semasound
is installed, enabled, and boot-supervised; semaaud is present
but dormant (semaaud_enable=NO, the AD-42.1 down marker). This
ADR retires it.

## Context

ADR 0011 scoped the OSS replacement with semaaud retirement as
its end state; ADR 0020 deferred the retirement to F.6 behind
feature parity, and F.5.d/e recorded three parity gaps for
this audit: the control plane (control/control-capabilities
and the command socket), session tokens in events, and the
layout prefix (/tmp/draw/audio versus /var/run/sema/audio plus
/usr/local/etc/semasound).

The audit was performed on the operator-supplied baseline
(the F.5-complete tree). Findings, recorded as evidence:

  - The /tmp/draw surface prefix has ZERO consumers outside
    semaaud's own sources. Nothing reads semaaud's surfaces.
  - The control socket has ZERO consumers outside semaaud's
    own sources (the only other mention is the ADR 0005
    design discussion). Nothing speaks the command plane.
  - semaaud's per-event session tokens have ZERO consumers:
    nothing reads semaaud's stream/events at all. semadraw's
    session machinery is pgsd-sessiond's, unrelated.
  - The clock: /var/run/sema/clock (the shared 20-byte mmap
    region, shared/src/clock.zig) is read by the inputfs
    kthread, the chronofs reader library, and semadrawd
    (setChronofsClockPath). Its WRITER since F.4 is the
    audiofs kernel module (ADR 0018, closed). semaaud's clock
    role is already historical; what remains is rc capability
    bookkeeping (its shim PROVIDEs utf_clock; semadraw's
    REQUIREs it) and two stale comments naming semaaud as
    publisher (inputfs.c, start.sh).
  - Operational remnants: start.sh (manual foreground startup,
    semaaud-first, pre-AD-20) and scripts/utf-up.sh /
    utf-down.sh (iterate chronofs semaaud semainput semadrawd,
    referencing the retired semainput) predate the supervision
    architecture. scripts/rc.d/semaaud is the pre-AD-20
    standalone rc script.
  - Documentation referencing semaaud: shared/CLOCK.md,
    EVENT_SCHEMA.md, SESSION.md, README.md, INSTALL.md,
    s6/README.md, and historical module docs.

## Decisions

### 1. The three parity gaps close by audit, not by porting

No control plane is built (zero consumers; ADR 0027 Decision
4's deferred question answers itself, and the decoupling
constraint recorded there governs any future one). Session
tokens stay omitted from semasound events (zero consumers;
the frames field already provides audio-position correlation
if semadraw's clock wiring ever wants it). The
/var/run/sema/audio + /usr/local/etc/semasound layout becomes
THE layout rather than a divergence (zero readers of the old
prefix). Each closure is grounded in the audit's
zero-consumer finding, not in judgment about hypothetical
consumers.

Tradeoff. If an unknown out-of-tree consumer exists, it
breaks loudly (absent paths), which is the correct failure
mode for an explicitly retired interface.

### 2. utf_clock transfers to the audiofs rc service

The audiofs rc.d script gains the capability: PROVIDE becomes
`audiofs audiofs_loaded utf_clock`. This is bookkeeping
catching up with fact: loading the module IS what starts the
clock writer (ADR 0018), so the service that loads it is the
capability's provider. semadraw's `REQUIRE: utf_supervisor
utf_clock inputfs_loaded` is unchanged and now orders against
audiofs, which rcorder already places at FILESYSTEMS. The
semasound shim continues NOT claiming utf_clock (it neither
writes nor gates the clock). The stale publisher comments in
inputfs.c and shared/CLOCK.md are corrected in the
reconciliation pass (Decision 5).

Rationale. Capability names should name the provider of the
fact, and the fact's provider changed in F.4. The AD-12.2
convention (consumers REQUIRE abstract capabilities so
provider changes need no consumer edits) works exactly as
designed: semadraw's line does not change.

### 3. Removal, with the semainputd reap pattern for upgraded systems

Removed from install.sh: semaaud in BINARIES, build_sub,
install_bin_required, stop_service_if_running, the rc shim
generation, the AD-42.1 down-marker block and the
semaaud_enable special-casing in the sysrc section, both
service-enumeration loops, and the uninstall lists (which
instead gain cleanup of previously installed semaaud
artifacts). install.sh gains a reap block for
/var/service/utf/semaaud and /var/log/utf/semaaud on upgraded
systems, exactly the semainputd pattern: s6-svc -dx with a
short timeout if supervised, then remove, plus removal of a
stale /usr/local/bin/semaaud. Removed from the tree:
semaaud/ (sources), s6/utf/semaaud/, scripts/rc.d/semaaud.
Enumeration completions (ratification): the `[semaaud]`
section of scripts/etc/utf.conf.sample is REMOVED, not
translated, replaced by a pointer comment to semasound's
per-target policy files under /usr/local/etc/semasound/
(semasound does not consume utf.conf); and the root
build.zig and build.sh lose their semaaud aggregation
entries (build-semaaud, test-semaaud, and the build.sh loop
membership). Git history is the archive; forward-only, no
tombstone directories.

### 4. The pre-AD-20 operational scripts retire with their subject

start.sh, scripts/utf-up.sh, and scripts/utf-down.sh are
REMOVED rather than updated: their job (manual ordered
startup of the daemon set) is the AD-20 architecture's job
now (install.sh, utf-supervisor, the rc shims, s6-svc), they
reference two retired daemons (semaaud, semainput), and
updating them would preserve a second, unsupervised way to
run the system that the project no longer wants to exist.
INSTALL.md's quick-start section becomes the single
documented startup story.

Tradeoff. Anyone's muscle memory for `sh start.sh` breaks;
the replacement is `sh install.sh` once and the service verbs
thereafter, documented where start.sh used to be referenced.

### 5. Documentation reconciliation

shared/CLOCK.md states the writer is the audiofs kernel module
(ADR 0018) and drops semaaud as publisher; the inputfs.c
comment block is corrected the same way (comment-only change,
no functional kernel edit); EVENT_SCHEMA.md and SESSION.md
gain a retirement note pointing event consumers at
semasound's events surface and schema (ADR 0027); README.md,
INSTALL.md, and s6/README.md drop semaaud from current
operation and name semasound; historical docs (module
proposals, closed ADRs, BACKLOG-history) are NOT edited,
history stays true.

### 6. Scope fences

NOT in scope: the maintenance model (the next and final AD-3
item); the deferred whole-of-project supervision evaluation
(post-field-experience, ADR 0028 Decision 1); any semasound
feature work (this ADR removes, it does not add); chronofs
changes (its reader library is a consumer and is untouched).

## Closure criteria

  1. The tree builds green with semaaud/ removed (zig build
     test && zig build across affected subprojects; install.sh
     build phase completes).
  2. install.sh on the upgraded bench: the reap block retires
     /var/service/utf/semaaud and /var/log/utf/semaaud
     (evidenced in the transcript), no semaaud binary or shim
     is installed, sysrc shows no semaaud_enable handling.
  3. rcorder confirms the capability transfer: audiofs orders
     before semadraw, and the semadraw shim's REQUIRE line is
     byte-identical to before.
  4. Cold boot: the full system comes up unattended (audiofs
     loads, clock region live, utf-supervisor, semasound and
     semadrawd up), with NO semaaud service present.
  5. The clock is verifiably live without semaaud:
     chrono_dump (or the clock region's mtime/content)
     advances while only audiofs writes it.
  6. The full semasound suite set passes on the post-removal
     system (f5b_election, f5c_targets, f5d_policy,
     f5e_state).
  7. No semaaud references remain outside git history,
     historical documents, and closed ADRs (a tree grep is
     the evidence; the allowlist is named in the commit).
  8. install.sh --uninstall on the post-removal system leaves
     no semaaud or semasound artifacts (binaries, shims,
     service dirs, log dirs, rc.conf keys).
  9. Documentation reconciled per Decision 5, verified by
     reading CLOCK.md, INSTALL.md, and README.md.
 10. Operator marks F.6 `[x]`.
     VERIFIED 2026-06-05: the operator marked F.6 complete
     with criteria 1-9 evidenced by transcript: the build
     gate and all daemon test suites on the post-removal
     tree; the reap firing on a reconstructed upgraded-system
     artifact (service directory with supervise state, down
     marker, log directory, rc.conf key) with per-item
     idempotent silence on already-absent artifacts; rcorder
     placing audiofs before semadraw with the semadraw
     REQUIRE untouched; an unattended cold boot with the full
     supervise tree up and no semaaud in service -e, the scan
     directory, or the process table; the clock advancing at
     exactly 48000.0 Hz (103424 frames over 2.154667 s) under
     the audiofs kernel writer with clock_valid=1,
     clock_source=audio, and the SMCK v1 wire format intact;
     all four suites passing unchanged with flat fd and RSS
     counts; the tree grep returning only allowlisted
     strings; a clean uninstall round trip (which also reaped
     a stale retired binary via the Decision 3 cleanup
     targets); and the Decision 5 documentation in the tree.

## References

  - ADR 0011: the OSS replacement scope this completes.
  - ADR 0018: the clock writer transfer Decision 2's
    bookkeeping catches up with.
  - ADR 0020: the F.5/F.6 decomposition and parity bar.
  - ADRs 0026/0027: the recorded parity gaps audited here.
  - ADR 0028: the staged cutover state this ADR completes;
    the semainputd reap precedent.

## Revision history

  - 2026-06-04: proposed, on the operator-supplied
    F.5-complete baseline, with the parity audit's findings
    recorded in Context as evidence. Six decisions: gaps
    close by audit (zero consumers found for the old surface
    prefix, the control socket, and session tokens);
    utf_clock transfers to the audiofs rc service (the
    factual provider since F.4); removal with the semainputd
    reap pattern; the pre-AD-20 operational scripts retire
    with their subject; documentation reconciliation that
    leaves history true; scope fences.
  - 2026-06-04: ratified by the operator as written, with
    the enumeration completions above folded into Decisions
    3 and 5 (utf.conf.sample section removal with a pointer;
    root build.zig/build.sh aggregation entries; s6-tree
    pattern-comment rewording) and no substantive change to
    any ruling. The operator's independent audit converged
    with the Context findings on every point: zero /tmp/draw
    consumers, zero control-socket consumers, zero
    session-token consumers, audiofs the clock writer since
    F.4, all remaining semaaud presence residual. Recorded as
    additional code-path-level confirmation: chronofs's
    ingestSemaaudLine / spawnIngestionThreads path has NO
    production caller anywhere in the tree, reinforcing the
    zero-consumer conclusion below the interface level;
    chronofs remains fenced and untouched. Decision 4
    (removing rather than updating the pre-AD-20 operational
    scripts) affirmed explicitly: preserving them would
    retain a second, unsupervised control surface
    incompatible with the AD-20 model. Implementation order:
    install.sh removal and reap (with the utf_clock PROVIDE
    transfer, same file), tree removals, reconciliation,
    closure verification.
  - 2026-06-05: criterion 10 confirmed by the operator; F.6
    CLOSED. semaaud is retired: no sources, no service, no
    binary, no rc artifacts, with upgraded systems reaped by
    install.sh. The criterion 7 allowlist, named here as the
    closure record: the ADR set, BACKLOG.md and
    BACKLOG-history.md, historical and verification documents
    (docs/, audiofs/docs, inputfs/docs, semadraw/docs,
    semainput/docs, pgsd-kernel and pgsd-sessiond READMEs,
    session notes), chronofs sources and clock_dump.c (the
    Decision 6 fence), semasound's parity citations
    (policy.zig, policy_state.zig, protocol.zig), install.sh's
    reap and uninstall cleanup targets, and the deliberate
    retirement notes in README.md, INSTALL.md, s6/README.md,
    shared/EVENT_SCHEMA.md, shared/SESSION.md, and
    scripts/etc/utf.conf.sample. Closure-week findings
    recorded to the housekeeping ledger (BACKLOG AD-3):
    uninstall removes the scan tree without stopping
    utf-supervisor first (orphaned processes, SIGKILL
    warnings on the next install); chrono_dump blocks rather
    than reporting in the supervised world (the pre-AD-20
    ingestion design, same family as the unwired resolver
    path); the bench-tone --badrate/--gap strings marker is
    stale; utf.conf.sample retains a [semainput] section and
    a stale clock_path; scripts/rc.d wholesale retirement
    remains the operator's open question; svscan.log grows
    unrotated. AD-3 retains only the MAINTENANCE MODEL.
