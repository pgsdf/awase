# 0001 Zig and SDCS as the foundation

Status: Accepted

## Context

The project requires deterministic replay, strict validation, and stable semantics across hardware and kernel graphics changes.

## Decision

1. Implement the project in Zig.
2. Use SDCS as the canonical binary representation of graphics intent.

## Consequences

1. Tooling and libraries share a single language and type system.
2. Recording and replay become first class features.
3. Backends can be replaced without semantic drift.

## Notes

This ADR is aligned with TECHNICAL_DECISIONS.md and serves as the first entry in an ADR series.
