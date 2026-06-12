# snd(4) gap-and-governance audit: specification

Status: Specification, 2026-05-17. The audit itself is not
yet performed. AD-3 is Open and not scheduled; this document
defines what the audit is, so that when AD-3 is picked up the
premise-validation work starts from a decided method rather
than an open question. This is the specification, not the
result.

**Status addendum, 2026-05-27 evening (ADR 0010):** the
audit-as-gate framing this spec was written under has been
retired. ADR 0010
(`audiofs/docs/adr/0010-retire-audit-as-gate.md`, Accepted
2026-05-27 evening) records the framing change: UTF operates
by build-and-replace, the audit's purpose was evidentiary
not dispositive, and its gate role is misaligned with UTF's
actual operating mode. This spec is preserved as background
reference material on UTF audio capabilities and snd(4)
surfaces. Its enumeration of capabilities, the template
form, and the hms(4) precedent it models on remain useful as
documentation. What is retired is the spec's procedural role
(as the specification of a gate F.3+ must clear), not the
spec's intellectual content. The text below is preserved as
written, without edits, as the historical record of what the
audit was specified to be.

## Why this exists, and what it is not

ADR 0006 decides UTF replaces snd(4) in full. Its primary
rationale (ADR 0006 "Rationale", and
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` "Governance
independence") is that a dependency on snd(4) is a
dependency on its maintainers' governance, goals, and
cadence: when UTF needs a driver-level capability that is
not provided, the options under a dependency all gate UTF's
objectives on a decision process UTF does not control.

That rationale should be validated before the very large
scope ADR 0006 commits to is acted on. The original framing
of this validation (an earlier "Path B") was a cross-version
performance-drift measurement. That framing was wrong for
the primary rationale and is retained only as a secondary
follow-up (see "Relationship to the performance
measurement"). The performance measurement tests whether
snd(4) *performs badly or drifts*. It does not test the
governance argument at all: a perfectly stable, perfectly
performing driver with a capability gap UTF cannot get
closed on its own terms is still exactly the problem the
primary rationale describes.

What actually tests the primary rationale is an enumeration
of concrete, real capability gaps in the snd(4) audio path
on UTF's target hardware, and, for each, an honest
assessment of what closing it under a dependency would
require. That is this audit. It is modelled directly on the
one instance UTF has already lived through and verified:
the `hms(4)` input precedent recorded in the discipline
doc.

This document does not perform the audit, does not
pre-decide its outcome, and does not assume the rationale
will be confirmed. If the audit finds few or no real gaps,
or finds that the gaps it finds are cheaply closable
without subordinating UTF's objectives, that is a material
finding and is recorded as such, because the honest form of
premise-validation is one whose result can come back
against the decision it supports. ADR 0006's decision does
not rest on this audit (its primary rationale is explicitly
not measurement-contingent), but the audit characterises
the strength of the evidence for it, and a weak result
should be visible, not buried.

## The template: the hms(4) precedent

The discipline doc records the worked precedent. Restated
here as the shape every audit entry should take:

- **Capability UTF needs:** gesture recognition in the
  input path (three-finger swipe-and-select, pinch).
- **External component depended on:** `hms(4)`.
- **Observed state:** the features were not implemented;
  macOS-origin users requested them; over `hms(4)`'s
  lifetime they were not added and no action toward adding
  them was observed.
- **Governance assessment:** delivering the capability
  under the dependency would have required upstream action
  that showed no sign of occurring on any timeline UTF
  controlled. Not a refusal; an absence UTF could not
  resolve.
- **Resolution under ownership:** UTF owned the input path
  (inputfs), implemented the recogniser as UTF-owned code,
  and verified it on real hardware (AD-2, Phase 2.5).

An audit entry that cannot be filled in with this level of
concreteness is not evidence and must not be counted as
evidence. Hypothetical or anticipated gaps are recorded
separately from observed ones and are explicitly weaker.

## What the audit must produce

For UTF's target audio hardware (the bare-metal target's
HDA codec, and a representative USB audio class device, at
minimum), enumerate the concrete capability gaps in the
snd(4) path relative to what UTF's audio guarantees
require. For each gap, record, in the template's form:

1. The specific capability UTF needs and why the guarantee
   path requires it (not "would be nice"; tied to a stated
   UTF audio requirement).
2. The specific snd(4) surface or behaviour that does not
   provide it, named concretely (a missing facility, an
   unspecified behaviour, a structural limitation), not
   "snd(4) is generally unsuitable."
3. Observed state, at the epistemic level the observer can
   actually stand behind, in the discipline doc's careful
   form: distinguish "observed absent" from "observed
   refused" from "inferred likely to be a problem." Do not
   impute maintainer intent that was not observed.
4. Governance assessment: what closing this under a
   dependency would concretely require (an upstream
   feature, a behavioural guarantee, an API), and what is
   actually known about whether that is forthcoming on a
   timeline UTF controls. "Unknown" is a permitted and
   honest answer and must be recorded as unknown rather
   than assumed in either direction.
5. Whether ownership (the ADR 0006 path) actually resolves
   it, or merely relocates it. A gap that ownership does
   not resolve is not evidence for the ownership decision
   and must be recorded as such.

## Decision criteria, stated before the audit

Pre-registering how the result is read, so the audit
cannot be retrofitted to justify the decision already made
(the failure mode UTF's discipline exists to prevent):

- **Strong support:** multiple gaps meeting the template's
  concreteness bar, each with a governance assessment
  showing the capability is not forthcoming on a timeline
  UTF controls, each resolved by ownership. The primary
  rationale is then evidenced, not merely asserted.
- **Weak / no support:** few or no gaps meet the
  concreteness bar, or the gaps found are cheaply closable
  without subordinating UTF's objectives, or ownership
  does not actually resolve them. This does not by itself
  reverse ADR 0006 (its primary rationale is principled,
  not measurement-contingent), but it must be recorded
  prominently: it means the decision rests on the
  principle alone without empirical reinforcement, and
  that fact should be visible to anyone relying on the
  decision. It also reopens, for explicit reconsideration,
  whether the narrower pcm-core-only option carries
  acceptable governance exposure after all.
- **Mixed / unknown-dominated:** if most entries resolve to
  "unknown" on the governance assessment, the honest
  finding is that the premise is neither confirmed nor
  refuted and the evidence base is thin. That is itself a
  result and is recorded as one, not smoothed into
  apparent support.

The criteria are fixed here, before the audit, on purpose.
Changing them after seeing results requires an explicit,
dated note saying so and why.

## Relationship to the performance measurement

The cross-version snd(4) performance-drift measurement
(originally framed as Path B) is retained as a separate,
secondary follow-up. It tests ADR 0006's secondary
(performance-drift) rationale, which ADR 0006 explicitly
marks as contingent and unmeasured. It is worth doing to
characterise that secondary risk, but it is not this audit
and does not validate the primary rationale. If performed,
its results attach to ADR 0006's secondary rationale, not
to this document's conclusion.

## Status of the rationale this validates

ADR 0006's primary rationale does not depend on this audit
coming back any particular way; it is a principled position
that ownership of the guarantee path is required where the
alternative is gating UTF's objectives on others'
governance. This audit determines how much *empirical*
weight sits behind that position for audio specifically. A
strong result strengthens it; a weak result does not refute
it but removes its empirical reinforcement and must be
recorded as having done so. Either way, the audit's value
is that its outcome is allowed to be inconvenient.
