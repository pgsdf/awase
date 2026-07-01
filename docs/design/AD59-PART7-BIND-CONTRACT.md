# AD-59 Part 7: Bind Contract

Status: DRAFT CONTRACT.

This document defines the contract for the Bind responsibility (Part 4). It
is written before any code and is the acceptance criteria for the first
implementation of bind().

Bind resolves without deciding. It takes a role and produces the boot
environment that implements that role. It is a pure resolver: it does not
choose which role, and it does not perform the transfer. Its single
transformation is role in, implementation out.

The contract follows the pattern established by the Discover and Decide
contracts: positive obligations, negative obligations, acceptance criteria,
with care taken to define what Bind must remain ignorant of.

## Purpose of Bind (recap from Part 4)

Bind resolves the chosen role to a boot environment, using whatever binding
representation the design adopts. Exactly one responsibility: role in,
implementation out. Part 2 establishes that policy binds roles to
implementations and that the AD-58 promotion authority owns the binding;
Bind READS that binding to resolve a role, and owns neither the binding nor
the choice of role.

## Question 1: what information may Bind use?

  P1: Use the role from Decide, and the role-to-implementation binding. Bind
      takes exactly one role (Decide's output) and consults the binding that
      maps roles to boot environments.

  N1: Consult nothing about why the role was chosen. Bind does not see, and
      does not use, Discover's observations or any part of Decide's
      reasoning. It receives a role and resolves it; the justification for
      the role is not its concern and is not available to it. Bind resolves
      the role it is given, whatever that role is.

## Question 2: what may Bind conclude?

  P2: Produce exactly one boot environment. Bind resolves the role through
      the binding and returns the single boot environment that implements
      it.

  N2: Never choose among roles. Bind does not select, prefer, or override
      the role. If the role is the Recovery Role, Bind resolves the Recovery
      Role; it does not reconsider whether recovery was the right choice.
      Choosing the role is Decide's responsibility, already complete before
      Bind runs.

  N3: Never invent an implementation. Bind returns the boot environment the
      binding specifies for the role. It does not synthesize, guess, or
      substitute an environment the binding does not name. If the binding
      does not resolve the role, that is an error condition to surface, not
      an occasion for Bind to choose on its own.

## Question 3: what must Bind remain ignorant of?

  N4: Policy. Bind does not know the rules by which the role was selected,
      nor any observable state Decide evaluated. It knows a role and a
      binding, nothing of the decision that produced the role.

  N5: Transfer mechanics. Bind does not know how control is transferred to
      the boot environment it returns, what the loader primitive is, or what
      happens after resolution. Its work ends when the boot environment is
      produced; Transfer acts on that result.

  N6: The binding's ownership and update. Bind reads the binding; it does not
      write it, own it, or know how it is maintained. Per Part 2, the AD-58
      promotion authority owns the binding. Bind is a reader (Part 2's
      owner-versus-reader separation), and how the binding comes to hold what
      it holds is opaque to Bind.

Bind's ignorance keeps the decision (Decide) and the action (Transfer) on
either side of it opaque, so Bind is exactly a resolver: it neither revisits
the decision nor performs the action. It is also what keeps Bind portable
into the future Awase loader: a resolver that reads a role and a binding and
returns an implementation migrates unchanged, whatever the binding's future
representation.

## Acceptance criteria for bind()

An implementation of bind() is accepted if and only if:

  - it takes exactly one role (Decide's output) and consults the
    role-to-implementation binding, and nothing about why the role was
    chosen (P1, N1);
  - it produces exactly one boot environment (P2), never reconsidering the
    role (N2) and never inventing an implementation the binding does not
    name (N3);
  - it remains ignorant of policy, transfer mechanics, and the binding's
    ownership and update (N4, N5, N6);
  - it surfaces a resolution failure as an error rather than choosing on its
    own (N3);
  - it is written to be portable into the future Awase loader: expressed as
    role-in and implementation-out, using loader-specific idioms only where
    essential, with a narrow interface.

## Dependency: the binding representation

Bind's contract is complete in shape. Its one specific, the binding's
concrete representation and storage, is a deferred implementation decision
(Part 4's deferred questions: where the binding is stored, in what form).
Part 2 already fixes the binding's OWNER (the AD-58 promotion authority);
Bind's contract fixes that Bind is a READER of it. The representation is
chosen at implementation, constrained by Part 4 (loader-readable, before
kernel load) and unconstrained here beyond "Bind reads it to resolve a
role."

Status: DRAFT CONTRACT; acceptance criteria for the first bind().

Bench: none (design contract).
