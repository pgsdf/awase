# 0009 F.0 closure: reconciling the question-resolution bookkeeping

## Status

Accepted, 2026-05-19. Confirmed by the decision owner;
supersedes the prior Proposed status. The dispositions in
the Decision section are confirmed; the forward pointers
described in Consequences are to be put in place as a
consequence of this acceptance.

This ADR is bookkeeping, not architecture. It does not
reverse, reopen, or amend any decision in ADRs 0002-0008. It
reconciles a contradiction between ADR 0001's stated F.0
closure criterion and ADR 0008's assertion that F.0 is
complete, by recording explicitly how the proposal's six open
questions (Q1-Q6) were actually disposed of. It is the
audiofs analogue of a scope-correction note: it changes what
the record says about itself, not what the system does.

## Context

`audiofs/docs/audiofs-proposal.md` lists six open
architectural questions: Q1 (audio data path), Q2 (mixer
location), Q3 (OSS coexistence), Q4 (format model), Q5
(latency targets), Q6 (serialization format for semasound's
userland surfaces).

ADR 0001 ("Stage F.0 ADR plan") committed to one ADR per
question and set the closure criterion in two places:

> The F.0 sub-stage closes when all six ADRs are accepted.
> (ADR 0001, Decision)

> The F.0 sub-stage closes when six question-resolving ADRs
> are accepted. This document does not count toward that
> total; it is meta-structural.
> (ADR 0001, Consequences)

ADR 0008 ("Stage F scope and sequencing"), in its Context
section, asserts:

> F.0 (the architectural ADR set, 0001-0007) is complete.

These two statements are not consistent as written. ADR
0001's criterion is "six question-resolving ADRs accepted."
The accepted set resolves the questions as follows:

- **Q2 (mixer location):** resolved by ADR 0004.
- **Q3 (OSS coexistence):** resolved by ADR 0002.
- **Q6 (serialization format):** resolved by deferral. The
  proposal itself records the recommended posture ("defer
  until a real consumer drives the requirement") and states
  the decision is "explicit-by-deferral rather than
  implicit." ADR 0001's recommended drafting order
  anticipated Q6 could "land alongside Q3 or alongside Q4."
  No standalone Q6 ADR was written; the proposal's deferral
  is the decision.
- **Clock writer:** resolved by ADR 0003. This was not one
  of the proposal's six questions; it was pulled out of the
  proposal's implicit framing by `audio-design-space.md` as a
  separable commitment and given its own ADR.
- **Userland architecture (semasound):** resolved by ADR
  0005. Also not one of the six; it is the successor to ADR
  0004 that the design-space document identified.
- **snd(4) ownership:** resolved by ADR 0006, which
  supersedes ADR 0003 section 8's posture. Not one of the
  six; it reverses a premise the proposal stated in prose.
- **Physics/semantics boundary:** resolved by ADR 0007,
  which partially supersedes ADR 0004's scope
  characterisation. Not one of the six.
- **Scheduling (AD-3):** resolved by ADR 0008. Not one of
  the six; it is the scope ADR ADR 0006 required.

The gap is precise: **Q1 (data path), Q4 (format model),
and Q5 (latency targets) have no dedicated resolving ADR.**
ADR 0004 repeatedly defers to "whatever Q1 resolves to."
ADR 0008 lists F.3 as the data-path sub-stage but explicitly
defers F.3's internal decomposition to a future sub-stage
ADR. ADR 0007's native-format-only rule constrains Q4 by
consequence ("format conversion is semantic by definition
... therefore the core rule forbids it in audiofs"), but ADR
0007 does not record itself as the Q4 resolution and ADR
0001's bookkeeping is never updated to say so. Q5 (latency
targets) is named nowhere in the accepted ADRs as resolved;
ADR 0001's own dependency note says Q5 "depends on Q1 (the
data-path choice sets the latency lower bound)," which means
Q5 cannot be closed until Q1 is.

The contradiction is therefore not architectural but
procedural: the proposal questions were dispositioned
without preserving ADR 0001's original "one standalone ADR
per question" structure.

So ADR 0001's literal closure criterion is unmet, while ADR
0008 proceeds on the basis that F.0 is complete. The
schedule in ADR 0008 is not wrong to proceed: the
gating-precondition structure it builds (audit strictly
first, chipset list and maintenance model owed) does not
depend on Q1/Q4/Q5 being resolved as standalone ADRs,
because F.3 is where the data path is actually decided and
F.3 is gate-blocked anyway. What is wrong is the record:
ADR 0001 says F.0 closes one way, ADR 0008 says F.0 is
closed, and the difference is undocumented. A future reader
auditing the ADR set against ADR 0001's own stated criterion
finds it unsatisfied with no explanation.

This ADR supplies the explanation and amends the criterion
to match what was actually done, rather than retrofitting
three thin ADRs to satisfy a count.

## Decision

### 1. ADR 0001's closure criterion is amended, not deemed met

ADR 0001's "six question-resolving ADRs" criterion is
replaced by the disposition recorded in section 2. ADR 0001
is not edited (the record is append-only and forward-only);
this ADR is the amendment, and ADR 0001 should be read with
a forward pointer to it, in the same manner ADR 0003 section
8 is read with a forward pointer to ADR 0006.

The reason for amending rather than satisfying: the
"one ADR per question" structure was a reasonable starting
plan, but the actual F.0 work showed that (a) two of the six
questions are correctly resolved by something other than a
standalone ADR (Q6 by documented deferral), (b) three of the
six (Q1/Q4/Q5) are correctly pushed into the F.3 sub-stage
because they are data-path-implementation decisions that ADR
0008 already gate-blocks, and (c) the load-bearing F.0
decisions turned out to be ones the proposal's six-question
list did not contain (clock writer, snd(4) ownership,
physics/semantics boundary). Forcing three placeholder ADRs
for Q1/Q4/Q5 now, before the gate and before F.3's
decomposition, would be inventing decisions to satisfy a
bookkeeping count. That is the failure mode the
governance-independence work this cycle was careful to
avoid, and ADR 0008 section 3 names it explicitly for the
chipset list. The same restraint applies here.

### 2. Disposition of the six proposal questions

For purposes of F.0 closure bookkeeping, a proposal question
is considered dispositioned if it is (a) resolved directly
by an accepted ADR, (b) resolved as a necessary consequence
of an accepted ADR, or (c) explicitly deferred into a named
future stage with recorded gating conditions or reopening
criteria.

This is the authoritative mapping. F.0 is closed when, and
is closed because, each of the six questions has reached one
of the dispositions below, all of which now hold.

- **Q1 (audio data path): deferred into F.3, gate-blocked.**
  The choice among tmpfs ring / kernel-mapped DMA / hybrid
  is a data-path-implementation decision. ADR 0008 places
  the data path at F.3, names F.3 the irreversible
  commitment, and requires F.3 to be decomposed in its own
  sub-stage ADR before it starts. Q1 itself is not decided
  in F.0; F.0 closes Q1 procedurally by assigning it to the
  gated F.3 sub-stage ADR. F.0's obligation for Q1 is
  discharged by ADR 0004 bounding the design space
  (single-writer) and ADR 0008 placing and gating the
  decision, not by selecting within the space now.

- **Q2 (mixer location): resolved by ADR 0004.** Closed.

- **Q3 (OSS coexistence): resolved by ADR 0002.** Closed.

- **Q4 (format model): resolved by consequence of ADR
  0007.** ADR 0007's core rule (audiofs may contain only
  hardware-derivable behaviour) forbids in-kernel format
  conversion as semantic policy; native-format-only is
  recorded there as a direct consequence, not a separate
  preference. This ADR records that ADR 0007 is the Q4
  resolution. The residual question (which hardware-
  supported format is elected, when the codec exposes
  several equally valid ones) is explicitly assigned to
  semasound by ADR 0007 stress case 2, through the single
  fenced downward control path. Q4 is therefore closed: the
  kernel-side answer is "native only, no conversion" (ADR
  0007); the userland-side answer is "semasound elects among
  hardware states" (ADR 0007 + ADR 0005). No standalone Q4
  ADR is needed.

- **Q5 (latency targets): deferred into F.3, gate-blocked,
  dependent on Q1.** ADR 0001's own dependency analysis
  states Q5 depends on Q1 (the data-path choice sets the
  latency lower bound). Since Q1 itself is decided in the
  F.3 sub-stage ADR, Q5's lower bound is not knowable until
  then; the upper bound (what semasound's mixing window can
  usefully do) is a semasound-implementation concern under
  ADR 0005 / ADR 0007. Q5 itself is not decided in F.0;
  F.0 closes Q5 procedurally by assigning its numeric budget
  to the F.3 sub-stage ADR and semasound implementation
  work. The proposal's "~20 ms per OSS-based semaaud
  refill, match at minimum, ideally improve" language
  remains guidance rather than an accepted budget.

- **Q6 (serialization format): resolved by documented
  deferral in the proposal.** The proposal records the
  recommended posture and explicitly frames it as
  "explicit-by-deferral rather than implicit," with a stated
  reopening criterion (a concrete consumer polling
  `/tmp/draw/audio/<target>/` at a sustained rate where JSON
  parsing cost matters). ADR 0005 inherits semaaud's JSON
  surfaces verbatim, consistent with that deferral. Q6 is
  closed by deferral; no standalone ADR is needed, and ADR
  0001 anticipated this ("the proposal's recommended posture
  is 'defer ...,' which is itself a decision worth recording
  explicitly").

### 3. F.0 closure is hereby recorded

With section 2's dispositions, F.0's purpose as the proposal
states it ("produces the documentation that makes subsequent
sub-stages possible") is satisfied: every question either
has a resolving ADR, is resolved by a consequence of one, or
is deferred-with-recorded-criterion into a gate-blocked
sub-stage. ADR 0008's "F.0 ... is complete" is therefore
correct as reconciled by this ADR, and ADR 0008 should be
read with a forward pointer here for the basis of that
claim.

This does not advance AD-3. The gating preconditions ADR
0008 names (the owed maintenance model, the unperformed
gap-and-governance audit) are unaffected by this ADR. F.0
being closed and AD-3 being startable are different
statements; only the first is addressed here.

### 4. What this ADR explicitly does not do

- It does not select Q1's data path. That is F.3's
  sub-stage ADR.
- It does not set Q5's latency budget. That is F.3 +
  semasound implementation.
- It does not write standalone Q1/Q4/Q5/Q6 ADRs. It records
  why they are not needed.
- It does not edit ADR 0001 or any prior ADR. It is the
  forward-pointer amendment, consistent with the
  supersession discipline used by ADRs 0003/0006 and
  0004/0007.
- It does not assert F.0 closure on its own authority; it
  records the dispositions that make ADR 0008's existing
  closure assertion true, and makes them auditable.

## Consequences

### What this resolves

- The contradiction between ADR 0001's closure criterion
  and ADR 0008's "F.0 is complete" assertion is removed. A
  future reader auditing the set against ADR 0001 now finds
  a forward pointer to an explicit, per-question
  disposition rather than an unexplained gap.
- The Q1-Q6 traceability the proposal and ADR 0001 promised
  is restored in a single place, including the two
  questions resolved by something other than a standalone
  ADR (Q4 by consequence, Q6 by deferral) and the three
  pushed into F.3 (Q1, Q5) or constrained by consequence
  (Q4).

### What this does not change

- No mechanism, wire format, or architectural decision in
  ADRs 0002-0008 is altered.
- AD-3's gating preconditions and schedule (ADR 0008) are
  untouched. This ADR does not make AD-3 startable.
- The README's characterisation of F.0 status is downstream
  of this ADR and is corrected separately, once this ADR's
  status is settled. After this ADR is accepted, the README
  should describe F.0 as closed and AD-3 as blocked on the
  owed maintenance model and unperformed audit.

### Cost accepted

Amending ADR 0001's criterion rather than satisfying it
literally means the F.0 ADR set does not have the clean
"six questions, six ADRs" shape ADR 0001 first imagined.
This is accepted for the reason section 1 states: the
literal shape would require inventing three decisions
(Q1/Q4/Q5) ahead of the gate and ahead of F.3's
decomposition, which is exactly the fabrication the project
spent this cycle's discipline work learning not to do. A
slightly less tidy bookkeeping record is the correct price.

## What this document is not

- **An architectural decision.** It selects nothing, builds
  nothing, and reverses nothing. It records how prior
  decisions disposed of the proposal's six questions and
  amends one stale closure criterion to match.
- **A schedule or a gate change.** ADR 0008's gating
  structure is authoritative and unchanged.
- **A Q1/Q4/Q5/Q6 specification.** Q1 and Q5 are F.3
  sub-stage work; Q4's kernel side is ADR 0007 and its
  userland side is ADR 0005; Q6 is the proposal's recorded
  deferral.
- **A claim that AD-3 may proceed.** It closes F.0's
  bookkeeping only. The owed maintenance model and the
  unperformed gap-and-governance audit remain the binding
  preconditions per ADR 0008.
