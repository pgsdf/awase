# AD-59 Part 4: Bootstrap Design

Status: DRAFT DESIGN.

Purpose: design the smallest bootstrap capable of satisfying the recovery
contract (Part 1), using the loader capabilities established by Part 3,
while preserving the architectural separations defined in Part 2.

Success criterion: on finishing this document, the reader should understand
what the bootstrap is responsible for, and just as importantly, what it is
NOT responsible for.

This is intended to be the last purely architectural document before
permanent loader code is written. It therefore avoids committing to any
implementation mechanism. It derives the information the bootstrap requires
from the bootstrap's responsibilities, rather than beginning from a
preconceived list of information; the information emerges from the
responsibilities, and the responsibilities are not justified by the
information. There is deliberately no "Design" section: the design emerges
from the responsibilities and the information they require.

## Established constraints

Four classes of fact are settled and constrain this document.

  Contract (Part 1): recovery has explicit obligations (RG-1 through RG-6).
    These are immutable.

  Architecture (Part 2): recovery is expressed through roles, policy,
    bindings, and selection. These separations remain intact and are not
    re-litigated here.

  Evidence (Part 3): the loader provides an execution point before menu
    presentation and before kernel loading, capable of redirecting the
    selected boot environment.

  Validation: no architectural assumptions required revision. This is a
    forward constraint: the implementation shall PRESERVE the architecture
    rather than rediscover it.

## Bootstrap responsibilities

The bootstrap has four responsibilities and no others. Each is stated with
its boundary: what it does, and what it must not do.

### 1. Discover

Determine the minimal information needed to make a selection. Nothing more.
No policy evaluation. No repair. No side effects. Discovery only gathers;
it does not decide.

### 2. Decide

Evaluate policy and produce exactly one result: a role. Not a boot
environment, a role (for example VERIFIED or RECOVERY, or whatever the
architectural roles become). Part 2 deliberately separates roles from
implementations, and Decide preserves that separation: its output is a
role, never a dataset.

### 3. Bind

Resolve the chosen role to a boot environment, using whatever binding
representation the design later adopts. Exactly one responsibility:
role in, implementation out.

### 4. Transfer

Invoke the loader primitive demonstrated in Part 3 Experiment 4, once. No
retries. No loops. No fallback logic. No recursive decision making.
Transfer control a single time and continue normal loader execution.

### What the bootstrap is NOT

The bootstrap is a small coordinator, not a subsystem:

    discover -> decide -> bind -> transfer -> done

It is NOT a recovery engine, a state machine, a boot manager, or a retry
framework. Those belong elsewhere if they belong anywhere; in this
architecture, recovery itself is a userspace application in the Recovery
Environment, not part of the loader-stage bootstrap. The bootstrap simply
selects the first kernel to execute. This smallness is not incidental: every
responsibility added to the loader path increases the consequences of
failure, so the bootstrap is kept as small as the four responsibilities
allow.

## Information required by each responsibility

The information the bootstrap needs is DERIVED here from the
responsibilities, one at a time. Each responsibility poses a question; the
information is whatever answers that question, named only as far as the
responsibility forces. Nothing is named before a responsibility requires it.

### Discover

  Question: what information is required before any decision can be made?
  Answer: enough information to evaluate policy. Nothing more.

  Note what is deliberately unsaid: WHAT that information is. Discover does
  not force it; Decide does. So it is not named here.

### Decide

  Question: what information does policy require?

  This is where the document earns its keep, because Decide forces the
  answer. To choose a role, policy must be able to tell the boot cases
  apart. So the information Decide requires is:

    - Whatever observable state distinguishes a normal boot from a recovery
      boot.

  This is stated neutrally on purpose. It does NOT say "whether recovery was
  requested", because that would quietly commit to one model (recovery as an
  operator request). The neutral form leaves the policy question open:
  recovery might be requested, or inferred, or mandatory, or impossible. All
  of those are POLICY questions. The bootstrap does not decide among them; it
  consumes whatever information the chosen policy requires to tell the cases
  apart. Part 4 does not choose the policy; it only records that Decide
  requires enough observable state to distinguish the cases.

### Bind

  Question: once a role is chosen, what information is required to resolve it
  into an implementation?

  Answer: a mapping from the role to a boot environment. The concept of a
  binding appears here, not because we set out to discuss bindings, but
  because Bind requires one. The binding is the information that answers
  Bind's question, and no more is claimed about it here (not its
  representation, storage, or owner).

### Transfer

  Question: what information is required to invoke the loader primitive?
  Answer: the selected boot environment. That is all.

The progression is the point: the information emerged from the
responsibilities. At no step was a piece of information introduced before a
responsibility forced it, and no responsibility was justified by
pre-listed information.

## Deferred design decisions

With the information derived, the remaining questions are mechanical and
implementation-facing. They are deferred, and they are easier now precisely
because the information model was derived rather than invented:

  - Where the information is stored.
  - How it is encoded.
  - What observable state actually distinguishes the boot cases, and how it
    is supplied (the trigger mechanism, if the chosen policy uses one).
  - What the binding representation is.
  - Who writes the binding, who owns it, and how it is updated (the AD-58
    promotion write path).

None of these change the responsibilities or the derived information. They
are the subject of implementation design, which may proceed on this
foundation. Part 2's ownership section already answers "who owns the
binding" (the AD-58 promotion authority); the remaining questions are how,
where, and in what form, which are implementation choices.

## Relationship to BOOT-PATH-OWNERSHIP and AD-11

Part 4 defines the bootstrap ARCHITECTURE and responsibilities. The current
implementation target is the FreeBSD local.lua hook validated in Part 3.
BOOT-PATH-OWNERSHIP defines a future transition to an Awase-owned EFI
loader. That transition changes the implementation MECHANISM, not the
architectural responsibilities defined here.

This is the architecture/mechanism distinction Part 4 is built around.
Nothing in the four responsibilities (Discover, Decide, Bind, Transfer)
requires Lua. Today they are realized in local.lua inside the stock loader,
because Part 3 demonstrated that this insertion point exists and can
redirect boot. Under BOOT-PATH-OWNERSHIP they could later be realized in an
Awase-owned loader. The mechanism changes; the architecture does not: the
role/policy separation, the binding model, and the Discover to Decide to
Bind to Transfer decomposition all remain. Only the code that performs the
responsibilities moves. There is one recovery architecture with two
possible implementation mechanisms: the current Lua realization validated
by Part 3, and the future Awase-owned loader envisioned by
BOOT-PATH-OWNERSHIP.

The Part 3 experiments remain valuable regardless of which loader is the
long-term host: they established that the architecture is realizable using
the current loader, and they informed the design of the responsibilities.
If implementation later moves into an Awase loader, those responsibilities
migrate with it.

AD-11 (the Alt-held recovery trigger) is not in tension with the Decide
step. Part 4 asks what information policy requires, using the neutral
formulation "what observable state distinguishes a normal boot from a
recovery boot." AD-11 is one PRODUCER of that information: AD-59 consumes
"recovery requested?" as an input, and AD-11 defines one mechanism by which
that input becomes true. Other producers (inference, a mandatory recovery
condition) remain possible; AD-11 is one, not the only one, and the
bootstrap consumes the information without depending on how it was produced.
