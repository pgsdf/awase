# audiofs ADRs

This directory holds the architectural decision records for
audiofs, plus the auxiliary artifacts that individual ADRs bind to
their correctness envelope.

## File-naming convention (namespace governance)

Files in this directory share one numbered namespace, but they are
not all the same kind of file. The number groups related files; the
slug suffix classifies them.

  - `NNNN-<slug>.md` is a **decision record**. It is an ADR proper:
    a ratifiable, status-bearing decision (Proposed, Accepted,
    Superseded). It participates in ADR numbering semantics.

  - `NNNN-<slug>-<artifact>.md` is an **ADR-bound auxiliary
    artifact**. It shares the decision's number for adjacency and
    discoverability, but it is not a decision record and does not
    occupy an ADR number of its own. Examples: a verification or
    regression-test map, an instrumentation plan, a measurement
    record that an ADR's merge gates depend on.

So `docs/adr/` is a bound set keyed by number, not a flat class of
decision records. The number is a grouping axis; the suffix is the
classifier.

### Why this convention exists

It is the explicit form of a rule the repository was already
operating under implicitly: an artifact that is required by an
ADR's merge gates, and is not reusable infrastructure, belongs
adjacent to that ADR. Co-location is part of correctness here, the
decision and the means of verifying it are auditable together,
under one number, without a second lookup axis.

Making it explicit prevents three drifts:

  - accidental ADR number collisions (an auxiliary artifact being
    mistaken for, or numbered as, a decision record);
  - misclassification of a verification artifact as an independent
    testing system living under some parallel taxonomy;
  - the slow split of ADR-bound material into a separate
    documentation tree that weakens the coupling the ADR depends
    on.

### Worked example

ADR 0031 is the first place this pattern is load-bearing rather
than incidental:

  - `0031-state-event-decoupling-and-topology-split.md` is the
    decision record (Accepted 2026-06-19).
  - `0031-regression-test-map.md` is its ADR-bound auxiliary
    artifact: it turns the ADR's ten merge gates into concrete
    assertions and is referenced by those gates. It carries no
    status of its own and does not consume an ADR number.

### Scope

This convention governs the `audiofs/docs/adr/` namespace. It is
not specific to any one ADR and is not revocable by a single
decision record; it is directory-level governance. A change to the
convention is itself a governance change to this README, not an
ADR decision.
