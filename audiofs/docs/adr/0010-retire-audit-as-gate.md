# 0010 Retire audit-as-gate framing for AD-3

## Status

Accepted, 2026-05-27 evening. Decision-owner ratification.

This ADR records a change in how the gap-and-governance audit
specified at `audiofs/docs/snd4-gap-governance-audit.md` relates
to AD-3's progression. ADR 0008 made the audit a strict gate
that runs before any F.3+ implementation; this ADR retires
that gate framing. The audit's content (the spec, its
enumeration of UTF capabilities and snd(4) surfaces) is
retained as background reference; the procedural role of the
audit as a precondition for AD-3 to advance is what is being
retired.

This ADR does not reverse, reopen, or amend ADR 0006's
decision to replace snd(4) in full. ADR 0006's primary
rationale (governance independence) is explicitly principled
and not measurement-contingent. The audit was specified to
characterise empirical evidence for that rationale; this
ADR's effect is that the empirical evidence is gathered by
implementing the substrate and observing what works, rather
than by performing a pre-implementation audit.

ADR-before-code discipline continues to apply. Each F-stage
sub-stage still requires its own ADR before its
implementation begins. What changes is one specific
procedural step (the audit gate); the broader discipline
that produced ADRs 0001-0009 continues unchanged.

## Context

ADR 0008 section "Pre-registered decision criteria"
(`audiofs/docs/adr/0008-stage-f-scope.md` lines 74-86, the
gate section) made the gap-and-governance audit a strict
gate: "Stage F does not proceed to F.3+ until the audit
clears." The intent was that F.3 (the irreversible
implementation commitment) should not be entered until the
empirical reinforcement for ADR 0006's primary rationale was
documented.

The 2026-05-20 AD-3 status update (BACKLOG.md line 1438 in
the active file after the 2026-05-27 split) recorded that
implementation work began on `pgsd-bare-metal` despite the
gate. The update was honest about this: "the work crosses
what ADR 0008 framed as a gate against 'any audiofs code
before the audit clears' and the BACKLOG previously framed
as 'not started'; both framings are corrected here rather
than papered over." The implementation was framed as
experimental, with the audit's authoritative specification
remaining frozen and available.

The commit-6.x series landed 2026-05-21 with audible output
verified on the iMac internal speaker. Approximately 3,580
lines of audiofs kernel code now exist. The audit specified
at `audiofs/docs/snd4-gap-governance-audit.md` has not been
performed.

A 2026-05-27 evening review surfaced two observations:

First, the audit's purpose (per the spec itself, lines 50-54)
is evidentiary, not dispositive. ADR 0006's decision does
not rest on it; the audit "characterises the strength of the
evidence" for the decision. A gate framing makes a
characterisation tool into an authorisation barrier, which
is misaligned with the audit's stated purpose.

Second, the project's operating mode is build-and-replace,
not pre-validate-then-build. UTF is creating a new operating
system from FreeBSD's substrate; it can experiment with
ideas, replace what does not work, and create new
subsystems (audiofs, semasound) and a new userland as
needed. The audit-as-gate framing imports a procedural
posture more appropriate to consensus-engineering contexts
(where decisions need defending against an external body)
than to UTF's actual operating mode.

These observations together support retiring the gate
framing while keeping the audit's content as background
reference.

## Decision

The gap-and-governance audit at
`audiofs/docs/snd4-gap-governance-audit.md` is no longer a
gate for AD-3's progression. Specifically:

1. **The audit need not be performed before F.3+ begins.**
   F.3 and onward may proceed under standard ADR-before-code
   discipline (each sub-stage gets its own ADR) without
   audit clearance.

2. **The audit spec becomes background reference material.**
   Its enumeration of UTF audio capabilities (G1-G10 in the
   scaffolding produced 2026-05-27 evening), its candidate
   capability-gap entries (C1-C7), and its framing of
   governance questions remain useful as documentation. A
   future reader who wants to understand what UTF audio
   needs and how it relates to snd(4) can read the spec for
   that purpose. The spec gets a status note recording the
   role change; the spec text itself is not edited (it is
   the historical record of what the audit was specified to
   be).

3. **AD-3's outstanding-work list shifts.** Before this
   ADR, the AD-3 BACKLOG status string listed four owed
   items: userspace semasound, OSS retirement, maintenance
   model, and audit-gate verification. After this ADR, the
   audit-gate verification line is removed. Three
   substantive items remain: F.5 (semasound), F.6 (semaaud
   retirement), and the maintenance model.

4. **ADR discipline holds.** Future audiofs sub-stages
   (F.3 onward) each require their own ADR before
   implementation. The audit retirement is a one-specific-
   procedural-step change, not a softening of the broader
   discipline that produced ADRs 0001-0009.

5. **Architectural-discipline doc unchanged.** The
   governance-independence principle in
   `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md` is not affected.
   ADR 0006's primary rationale stands as principled and
   non-measurement-contingent. What this ADR retires is the
   procedural step that was designed to characterise the
   empirical weight behind that rationale; the rationale
   itself does not require that procedural step.

## Trade made by this decision

The audit was designed with explicit epistemic discipline
(spec lines 116-146): pre-registered decision criteria
(Strong / Weak / Mixed-unknown), the property that "its
outcome is allowed to be inconvenient" (line 171), and the
hms(4) precedent's strict observed-vs-inferred form. By
retiring it as a gate, UTF forgoes one specific mechanism
that would have produced project-internal evidence that the
architectural decision had empirical reinforcement.

The trade made by this ADR: that pre-validation step is
replaced by the more direct evidence of building the
substrate and observing whether it works on real hardware.
The audible-output milestone of 2026-05-21 (commits 6e
through 6g) is itself empirical evidence about UTF's audio
path; F.3 hardware-driver work will produce more; F.5
semasound bring-up will produce evidence about the userland
mix architecture; F.6 cutover will produce the closure
evidence that semaaud is genuinely replaceable.

This trade is defensible under UTF's operating mode but is
not a free move. The replaced mechanism (pre-validation)
would have produced its evidence before commitment; the
substituted mechanism (build-and-observe) produces its
evidence during and after commitment. The trade is recorded
here as a trade so future readers understand which
discipline-instrument was given up and what the substituted
evidence-gathering mode is.

## Relationship to ADR 0006

ADR 0006 ("Replace snd(4) in full") is unchanged by this
ADR. ADR 0006's primary rationale (governance independence)
is principled and not measurement-contingent; ADR 0006 line
50-54 says this explicitly. The audit was specified to
characterise the empirical weight behind ADR 0006's
rationale, not to authorise the rationale itself. Retiring
the audit-as-gate has no effect on ADR 0006's standing.

ADR 0006's secondary rationale (performance drift) was
marked "secondary and contingent" and "unmeasured" (ADR 0006
line 122-131). That status is unchanged.

## Relationship to ADR 0008

ADR 0008's overall structure stands. The F.0-F.7 sub-stage
breakdown, the maintenance-model owed input, the chipset
list, the irreversibility flag on F.3: all retained. What
this ADR supersedes is one specific aspect of ADR 0008:
the framing of the audit as a strict gate that F.3+ cannot
cross until the audit clears.

Concretely, ADR 0008's text at lines 74-86 ("Pre-registered
decision criteria" with "Stage F does not proceed to F.3+
until the audit clears") is retired by this ADR. The
substantive content of that section (the Strong / Weak /
Mixed-unknown taxonomy) remains useful as a way to think
about evidence; what is retired is its role as a gate
criterion.

ADR 0008 itself is not edited (forward-only ADR discipline:
an Accepted ADR records the decision at the time it was
made). This ADR records the supersession; future readers
follow the chain ADR 0008 -> ADR 0010 to understand the
current state.

## Relationship to the audit spec

`audiofs/docs/snd4-gap-governance-audit.md` is preserved as
written, including its careful epistemic framing. A Status
section addendum records that its role has changed from
"specification of a strict gate" to "background reference
material on UTF audio capabilities and snd(4) surfaces." The
spec's enumeration of capabilities and template form remain
useful for future audiofs design work that needs to relate
UTF requirements to snd(4) surfaces.

The 2026-05-27 evening Claude-produced scaffolding
(`/mnt/user-data/outputs/snd4-gap-governance-audit-DRAFT-
scaffolding.md` at the time of this ADR) is reference
material only. It contributed source-grounded extraction
work (G1-G10 UTF capabilities; C1-C7 candidate snd(4)
surfaces) that may be useful background, but it is not the
audit (which is now retired as an artefact to be produced)
and not a deliverable of this ADR.

## Consequences

### What this enables

- **F.3 substantive implementation work proceeds** under
  standard ADR-before-code discipline. The audit-gate
  procedural step no longer sits between commit-6.x and
  F.3 decomposition.
- **AD-3 progression is clear.** Three substantive
  outstanding items (F.5 semasound, F.6 semaaud retirement,
  maintenance model) replace the previous four-item list
  with its audit-gate ambiguity.
- **Documentation is honest about the operating mode.**
  The build-and-replace operating mode is now recorded as
  an ADR (this one), not implicit in BACKLOG status
  updates. Future architectural decisions can reference
  this ADR rather than rediscovering the framing.

### What this commits

- **ADR discipline continues.** F.3, F.4, F.5, F.6, F.7
  each need their own ADR before implementation. The
  retirement of the audit-as-gate is not a retirement of
  the broader ADR-before-code mandate.
- **The trade is real.** UTF accepts that the substituted
  evidence-gathering mode (build-and-observe) produces its
  evidence after commitment, not before. If audiofs's
  implementation reveals that ADR 0006's premise was less
  well-supported than assumed, the response is to address
  it then, not to retroactively perform the audit.
- **Architectural-discipline doc remains authoritative.**
  Governance independence as a principle continues to
  apply. Future "audit-style" questions (does dependency
  on X expose UTF to governance risk?) get answered by
  the principle, not by procedural audit instruments.

### What this does not address

- **The maintenance model** is still an owed input for AD-3
  (per ADR 0008's "explicitly owed" list). This ADR does
  not produce it; the owed status is unchanged.
- **The chipset list final discharge** (the specific action
  of recording `hdacc`/`hdaa` codec identities on
  confirmed-target machines, per AD-3's 2026-05-17 status
  update at BACKLOG.md line 1384) is still owed.
- **F.3 sub-stage decomposition** is still flagged by ADR
  0008 as needing its own ADR before implementation. This
  ADR does not pre-empt that work.

## What this document is not

- Not a softening of UTF's architectural discipline. The
  build-and-replace operating mode is itself a discipline;
  this ADR records it explicitly so future work can rely on
  it being the operating mode rather than assuming a
  consensus-engineering posture by default.
- Not a retroactive justification for the 2026-05-20
  decision to begin experimental implementation. That
  decision was recorded honestly at the time as crossing
  the gate; this ADR retires the gate prospectively, not
  retroactively. The 2026-05-20 status update remains as
  the honest record of what happened.
- Not a claim that the audit's content was wasted work.
  The spec's enumeration of capabilities, the
  hms(4)-precedent template form, and the Strong / Weak /
  Mixed-unknown taxonomy are useful intellectual
  artefacts. Retiring the audit-as-gate retires only the
  procedural role of the artefact, not the artefact's
  documentary value.
