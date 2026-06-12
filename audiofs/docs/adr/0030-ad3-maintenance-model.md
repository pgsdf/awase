# 0030 AD-3 maintenance model

## Status

Closed, 2026-06-05: the operator marked AD-3 and this ADR; all
seven criteria are discharged. Closure ends the criteria, not
the law: the seven decisions remain in force as AD-3's standing
terms, and the change classes and takeover protocol govern all
subsequent audio-subsystem work.

Accepted, 2026-06-05: ratified by the operator, with the
commitment decisions (1, stewardship; 2, scope) confirmed
explicitly per closure criterion 1 and ADR 0008's reservation
of those decisions to the project. Criteria 2 through 4
discharged 2026-06-05: the first maintenance batch landed and
the uninstall ordering was verified by bench transcript (the
"stopped utf-supervisor" line, then a reinstall with zero stop
warnings); the takeover protocol is documented in
SUPERVISION.md; the handoffs are recorded (chronofs/BACKLOG.md
CH-1/CH-2, BACKLOG AD-45). The Decision 5 work item also
landed the same day: all four suites passed in production mode
(f5prod.sh) against the supervised installed broker, one pid
throughout, no rotation, every scripted case and both ear
checks. Criterion 5 ruled
2026-06-05: the operator adopted this model's recommendation
and scripts/rc.d is retired wholesale (the legacy chronofs and
semadrawd scripts; install.sh generates all installed shims).
Criterion 6 executed: BACKLOG AD-3 moved to its maintained
end-state. Remaining: the operator mark (7).

Proposed, 2026-06-05.

The last owed item of AD-3. ADR 0006 committed PGSDF to a
from-scratch audio hardware driver "maintained indefinitely,
per supported chipset" and stated that burden bluntly without
stating who carries it or how; ADR 0008 recorded the
maintenance model as an explicitly owed gating input that no
ADR may invent with plausible defaults; ADRs 0010 and 0011
reaffirmed it owed and unchanged; the 2026-05-21 snd(4)
removal added the pgsd-kernel configuration delta to its
contents. With F.0 through F.6 closed (ADRs 0001-0029), the
subsystem this model maintains now exists in full: the
audiofs kernel module (driver, data path, clock writer,
format negotiation, events), the semasound broker (mixing,
adaptation, targets, policy, state publication), and their
supervision and install integration. This ADR supplies the
owed model. Its commitment decisions are the operator's to
ratify, not this document's to assert: ADR 0008's
anti-fabrication rule applies to the proposal itself, so
every decision below that states a commitment is framed as
the realistic model for the operator to confirm or amend.

## Context

What "maintenance" must cover, assembled from the record:

  - THE BURDEN (ADR 0006). Per-chipset driver code for
    hardware UTF does not control, indefinitely. Today that
    is one confirmed target, pgsd-bare-metal: Cirrus Logic
    CS4206 analog (the working path) and an ATI R6xx HDMI
    codec (in scope at full guarantee, bring-up deferred with
    F.3.f behind a UTF display capability). The chipset scope
    RULE (ADR 0008 3a): HDA-class and USB-audio-class, 2016+,
    confirmed-target machines only; F.scope.a codec
    enumeration re-opens per new confirmed target.
  - THE KERNEL DELTA (BACKLOG, 2026-05-21). PGSD's kernel
    config removes `device snd_hda` and suppresses the hda
    module; audiofs owns the PCI HDA controllers without
    contesting hdac.c. This delta must survive every FreeBSD
    rebase, and its maintenance is part of this model by the
    BACKLOG's explicit note.
  - THE OPEN FENCES (ADR 0008 3a). Two questions recorded as
    deliberately undecided: the ownership strategy's
    applicability beyond classic HDA (SST/cAVS/SoundWire/SOF
    firmware-pipeline hardware), and whether PGSD designs for
    a specific platform. This model does not decide them; it
    inherits them as fences on its own scope.
  - THE LIVE SYSTEM (F.5/F.6 closure experience). The
    machine's resting state is now production supervision:
    boot loads audiofs, s6 runs semasound. Closure week
    demonstrated the failure mode this creates: the bench
    workflow and the production workflow fight over one
    machine (a pkilled broker respawned by s6, its run script
    reloading the installed module against bench_setup's
    in-tree load). Maintenance happens on a machine that is
    also in service.
  - THE VERIFICATION ESTATE. Four suites (f5b, f5c, f5d,
    f5e) plus the soak, written against the bench broker and
    /tmp/semasound.log; the F.5.b drift envelope; the ADR
    0023 refill-miss counters as permanent observability;
    bench-on-pgsd-bare-metal as the closure standard for the
    F-chain.
  - THE LEDGER (ADR 0029 closure). Six items: uninstall
    removes the scan tree without stopping utf-supervisor;
    chrono_dump blocks in the supervised world; the
    bench-tone strings marker is stale; utf.conf.sample
    carries a retired [semainput] section and a stale
    clock_path; scripts/rc.d wholesale retirement is an open
    operator question; svscan.log grows unrotated.

## Decisions

### 1. Ownership: PGSDF stewardship, named, with the bus factor stated

The audio subsystem (audiofs kernel module, semasound and its
tools, their install and supervision integration, the
pgsd-kernel snd(4)-removal delta) is maintained by PGSDF as
steward, concretely the project operator, with the ADR corpus
(0001-0029) plus this document as the transfer artifact. The
bus factor is one and this model says so rather than
gesturing at a community that does not exist; the mitigation
is not imaginary headcount but the discipline already in
force: every decision in ADRs, every closure with pasted
evidence, every divergence recorded, so that a future
maintainer (human or organizational) inherits a corpus, not
an oral tradition.

### 2. Scope holds at confirmed targets; extension is gated, never incidental

The supported-hardware set is exactly the confirmed-target
machines under ADR 0008 3a's rule. Adding a chipset is an
ADR-gated act that re-opens F.scope.a for the new machine
(codec enumeration from the real hardware), states the
bring-up plan against the F-chain's existing contracts, and
confronts the classic-HDA fence: hardware beyond the
classic-HDA regime cannot be adopted by analogy, only by a
new ownership-strategy decision of ADR 0006's own kind. HDMI
on the existing target stays governed by the F.3.f deferral.
USB-audio-class remains in the scope rule with no instance on
the confirmed target; its first instance is a scope ADR, not
a patch.

### 3. Change classes and what each owes the bench

Maintenance changes are classified, and the class fixes the
verification owed before merge. The closure standard (all
evidence from pgsd-bare-metal, pasted, operator-marked)
remains for anything class K or contract-touching.

  - K (kernel: audiofs.c, the module build, the rc loader):
    full rebuild and reload on pgsd-bare-metal, the four
    suites, and a boot test when the rc path or load order is
    touched. Refill/underflow counters checked before and
    after.
  - B (broker behavior: mixing, adaptation, election,
    targets, policy, publication): the four suites; plus the
    soak when the change can plausibly touch timing, pacing,
    or the predictor (the F.5.b envelope is the regression
    bar); plus the relevant EAR CHECK when audibility is the
    point.
  - P (protocol or surface contract: Hello versions, surface
    schemas, events grammar): suites plus an explicit
    compatibility statement in the change's ADR; contract
    changes are ADR-gated without exception.
  - T (tooling, harnesses, docs): syntax gates and a run of
    whatever the tool itself verifies; no bench claim is made
    or required.
  - R (rebase: FreeBSD or Zig version moves): the kernel
    delta is re-verified (the snd_hda suppression present,
    audiofs attaching first), then K-class obligations; a Zig
    move runs every daemon's `zig build test` before anything
    else, in the AD-2a migration tradition.

### 4. One machine, two regimes: the takeover protocol is the law

Production supervision owns the machine at rest; the bench
borrows it. The protocol bench_setup now implements is the
required shape for ALL maintenance tooling: down the
supervised service through s6 (never bare pkill), verify the
module state explicitly before claiming it, restore
production (`s6-svc -u`) when done. The reverse direction
holds too: install.sh and the uninstall path must stop
supervision before mutating the scan tree (the ledger's
uninstall-ordering item is accepted as REQUIRED WORK under
this decision, not optional polish). Bench scaffolding that
predates this protocol is brought to it before its next use,
not grandfathered.

### 5. The suites learn the production world, deliberately

The verification estate's bench-only assumptions (the
/tmp/semasound.log preflight, owned lifecycle) are a recorded
limitation: today the suites cannot interrogate the broker
the system actually runs. The committed direction: a
production mode for the suite preflight (s6-log aware,
lifecycle via s6-svc, installed-module tolerant) so that
K/B-class verification can run against the supervised stack,
with the bench mode retained for development iteration. This
is the first substantive work item under this model. Until it
lands, B-class changes verify on the bench broker per
Decision 3, which is the same binary by build provenance; the
gap is acknowledged, not hidden.

### 6. The ledger is dispositioned

  - Uninstall stop-before-delete: REQUIRED (Decision 4),
    AD-3-scoped, first maintenance batch.
  - chrono_dump blocking read: AD-3-adjacent but
    chronofs-owned; recorded as a chronofs backlog item
    (replace the blocked wait with an invalid-clock report;
    its ingestion-era design is the same family as the
    unwired resolver path, both awaiting chronofs's own
    reckoning). Not fixed under AD-3.
  - Bench-tone strings marker: T-class, first maintenance
    batch.
  - utf.conf.sample stale [semainput] section and clock_path:
    T-class, first maintenance batch (the file already
    carries the F.6 pointer comment pattern to follow).
  - scripts/rc.d wholesale retirement: remains the operator's
    question, recorded here with this model's recommendation:
    retire it (install.sh generates all shims; the directory
    is pre-AD-20 and uninstalled), pending the operator's
    ruling.
  - svscan.log rotation: project-wide supervision hygiene,
    assigned to the deferred whole-of-project supervision
    evaluation (ADR 0028 Decision 1), not to AD-3.

### 7. Scope fences

This model does not: decide the post-classic-HDA ownership
question or the specific-platform question (both stay open
per ADR 0008 3a); perform the whole-of-project supervision
evaluation (ADR 0028 Decision 1, after field experience);
adopt new hardware (Decision 2's gate); or add semasound
features (feature work is new AD-numbered scope, not
maintenance).

## Closure criteria

  1. The operator ratifies Decisions 1 and 2 explicitly (the
     commitment decisions ADR 0008 reserved to the project).
  2. The first maintenance batch lands and verifies per its
     classes: uninstall ordering (Decision 4), the two
     T-class ledger items (bench-tone marker,
     utf.conf.sample), each with the evidence its class owes.
  3. The takeover protocol is documented where operators
     look: a short section in INSTALL.md or SUPERVISION.md
     stating the s6-first rule for maintenance work.
  4. The chronofs and supervision-evaluation handoffs
     (Decision 6) are recorded in BACKLOG under their owning
     items, so nothing dispositioned here silently vanishes.
  5. The scripts/rc.d question receives the operator's ruling
     (either outcome closes it).
  6. BACKLOG AD-3 records the maintenance model supplied and
     AD-3 moves to its maintained end-state (`[x]` with this
     model as its standing terms), the chipset-scope rule and
     open fences carried forward by reference.
  7. Operator marks the maintenance model `[x]`.

## References

  - ADR 0006: the commitment whose carrier this names.
  - ADR 0008: the owed-input rule and chipset scope (3a).
  - ADRs 0010, 0011: the owed status reaffirmed.
  - ADR 0028: the supervision architecture and the deferred
    whole-of-project evaluation this model feeds.
  - ADR 0029: the closure ledger dispositioned in Decision 6.
  - BACKLOG 2026-05-21 entry: the kernel configuration delta.

## Revision history

  - 2026-06-05: proposed. Seven decisions: named PGSDF
    stewardship with the bus factor stated; confirmed-target
    scope with ADR-gated extension; change classes K/B/P/T/R
    with per-class bench obligations; the s6-first takeover
    protocol as law in both directions; a production mode for
    the suites as the first substantive work item; the
    six-item ledger dispositioned; scope fences inherited.
  - 2026-06-05: ratified by the operator as proposed, all seven
    decisions, the commitment decisions explicitly. Criterion 1
    discharged; the model is in force from this date. The change
    classes and the takeover protocol govern all subsequent AD-3
    maintenance work, beginning with the first maintenance batch
    (Decision 6's required and T-class items).
  - 2026-06-05 (later): criteria 2, 3, and 4 discharged by the
    first maintenance batch and its bench evidence; the
    Decision 5 production mode landed and proved itself in the
    same session: f5b/f5c/f5d/f5e all passed against the
    s6-supervised /usr/local/bin/semasound through the s6-log
    current file, the first verification of the production
    broker in the project's history. The suites' bench mode is
    unchanged and remains the development path.
  - 2026-06-05 (closure bookkeeping): criterion 5 ruled, the
    operator adopting the recommendation: scripts/rc.d retired
    wholesale (two legacy pre-AD-20 scripts, uninstalled,
    unreferenced; install.sh generates every installed shim).
    Criterion 6 executed: the AD-3 entry, marked done with this
    model as its standing terms, moved to BACKLOG-history.md
    beside the F-chain record per the split convention; the
    F.3.f deferral gained its own live entry in BACKLOG.md's
    Deferred section; the chipset rule and open fences are
    carried by this ADR. Criterion 7, the operator mark, is the
    only open item.
  - 2026-06-05 (the mark): the operator marked AD-3 and this ADR
    closed. Criterion 7 discharged; nothing remains open. AD-3,
    opened as "replace OSS dependency", ends governed: a
    from-scratch kernel driver, a supervised broker, a kernel
    clock writer, a proven production verification mode, and the
    operational law to maintain them.
