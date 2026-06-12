# 0002 Reference renderer and golden tests

Status: Accepted

## Context

GPU stacks can be nondeterministic due to driver behavior, precision differences, and scheduling.

## Decision

1. Maintain a software reference renderer.
2. Enforce golden image tests in CI as the semantic oracle.

## Consequences

1. Semantics are defined by executable behavior.
2. GPU backends must match reference behavior within defined tolerances.
3. Regressions are caught early.

## Notes

Golden tests should avoid depending on font rasterization and platform specific font selection.
