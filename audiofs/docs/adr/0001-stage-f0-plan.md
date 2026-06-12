# 0001 Stage F.0 ADR plan

## Status

Accepted, 2026-04-30.

## Context

`audiofs/docs/audiofs-proposal.md` (Stage F) identifies a set
of architectural decisions that must be captured before any
audiofs kernel code is written. The proposal calls this
sub-stage F.0 and describes its purpose:

> Before any kernel code, the architectural decisions are
> captured in ADRs. The data path (tmpfs ring, kernel-mapped
> DMA, or a hybrid), the mixer location (semasound is sole
> writer, vs in-kernel mixing), the OSS coexistence model,
> and the clock-writer transfer are all decided in writing
> first. This sub-stage produces no compiled artefact; it
> produces the documentation that makes subsequent sub-stages
> possible.

The proposal lists six open architectural questions in its
"Open architectural questions" section: Q1 (audio data path),
Q2 (mixer location), Q3 (OSS coexistence), Q4 (format model),
Q5 (latency targets), and Q6 (serialization format for
semasound's userland surfaces).

This ADR establishes the structure of F.0's ADR work. It does
not resolve any of the six questions; it commits to the shape
of the resolution.

## Decision

**One ADR per question.** Each of the six open architectural
questions in the proposal becomes its own short, focused ADR
in `audiofs/docs/adr/`. Each ADR can land independently when
its decision is ready; no question waits on another being
resolved unless a real dependency exists between them. The
per-ADR shape mirrors how `inputfs/docs/adr/` separates
distinct concerns (charter, attachment layer, role taxonomy,
fuzzing scope) into individual documents.

The F.0 sub-stage closes when all six ADRs are accepted. At
that point, audiofs implementation work (Stage F.1 onward)
becomes possible.

**Numbering:** audiofs ADRs use this directory's local
namespace, starting at 0001 (this document). Each subsequent
ADR receives the next available number. The Q1-Q6 labels from
the proposal map to ADRs as their decisions land; the mapping
is not pre-assigned because the drafting order is not the
question order.

**Drafting order, recommended:** ADRs land as their decisions
mature. The order below is a suggestion based on how the
questions interact, not a hard sequencing constraint:

1. Q3 (OSS coexistence). Independent of all other questions
   in framing. The architectural-discipline anchor (external
   code stays out of the guarantee path, fallbacks count as
   in-the-path) constrains the answer space. Likely the
   first substantive ADR after this plan document.
2. Q6 (serialization format). Independent of all data-path
   and mixer questions. The proposal's recommended posture
   is "defer until a real consumer drives the requirement,"
   which is itself a decision worth recording explicitly.
   Could land alongside Q3 or alongside Q4 later.
3. Q1 (data path) and Q2 (mixer location). Coupled: the
   proposal explicitly notes "the answer affects the
   audio-data-path ADR." Best drafted as a paired
   decision, possibly in the same session, possibly
   landing as two ADRs that reference each other.
4. Q4 (format model). Depends on Q2's mixer answer (if
   audiofs has no mixer, format must be agreed upstream of
   audiofs).
5. Q5 (latency targets). Depends on Q1 (the data-path
   choice sets the latency lower bound).

The drafting order is a suggestion; the dependencies above
are the real constraints. Q1+Q2 must be resolved before Q4;
Q1 must be resolved before Q5. The other three questions
(Q3, Q6) can land in any order.

## Consequences

- A new directory `audiofs/docs/adr/` exists with this
  document as its first entry.
- Each subsequent ADR records one architectural decision,
  with the same shape used elsewhere in the project: Status,
  Context, Decision, Consequences, and (optionally) an
  Implementation notes section. References to the
  proposal's question label (Q1-Q6) appear in each ADR's
  Context section so a reader can trace from question to
  decision.
- The F.0 sub-stage closes when six question-resolving ADRs
  are accepted. This document does not count toward that
  total; it is meta-structural.
- BACKLOG.md's audiofs entry currently says "four open
  architectural questions"; that statement was written
  before Q5 (latency) and Q6 (serialization) were added to
  the proposal. The BACKLOG entry is corrected as part of
  this commit.

## What this document is not

This is not an architectural decision in itself. It does not
say where audio bytes will flow, where mixing happens, how
formats are negotiated, what the latency budget is, how
audiofs and OSS coexist during migration, or what
serialization format the userland surfaces use. Those
decisions live in their respective ADRs. This document only
says they will be six separate ADRs and recommends an order.

This is also not the audiofs proposal. The proposal at
`audiofs/docs/audiofs-proposal.md` remains the source of
truth for what audiofs is and why; this directory's ADRs
record the decisions made within the proposal's framing.
