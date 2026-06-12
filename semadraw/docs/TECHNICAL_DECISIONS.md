# Technical Decisions

This document records major technical decisions made in the SemaDraw project.
Its purpose is to preserve context and rationale over time.

## Language choice: Zig

Decision:
SemaDraw is implemented in Zig.

Rationale:
1. Precise control over memory layout and binary formats
2. Explicit endian handling
3. No hidden floating point behavior
4. Excellent C interoperability when needed
5. Suitable for FreeBSD userland and kernel adjacent work

Alternatives considered:
1. C was rejected due to weak safety and ergonomics
2. C plus plus was rejected due to complexity and ABI instability
3. Rust was rejected due to ownership complexity for low level binary protocols

## Canonical representation: SDCS

Decision:
The SemaDraw Command Stream is the canonical representation of graphics intent.

Rationale:
1. Enables deterministic replay
2. Allows recording and inspection
3. Works equally for IPC, files, and testing
4. Decouples clients from execution details

Structured representations are secondary and derived.

## Binary format over textual format

Decision:
SDCS is a binary format.

Rationale:
1. Compact and efficient
2. Precise floating point representation
3. Easier to validate strictly
4. Suitable for IPC and storage

Text formats are permitted only for debugging and tooling.

## Deterministic reference backend

Decision:
A software renderer is maintained as the reference backend.

Rationale:
1. Defines authoritative behavior
2. Enables golden image testing
3. Provides headless execution
4. Removes GPU nondeterminism from validation

GPU backends are best effort but must match reference semantics.

## Separation of semantics and acceleration

Decision:
No GPU or kernel concept appears in the semantic API.

Rationale:
1. Prevents API churn driven by hardware
2. Keeps semantics stable over decades
3. Allows multiple backends without semantic drift
4. Aligns with Plan 9 style system design

## No implicit global state

Decision:
All state is explicit in the command stream.

Rationale:
1. Improves reasoning and correctness
2. Enables replay and diffing
3. Prevents backend specific behavior leaks

## Process model

Decision:
semadrawd is a userland service.

Rationale:
1. Keeps policy out of the kernel
2. Allows crash isolation
3. Supports remote and headless operation
4. Aligns with FreeBSD architectural principles

## FreeBSD first

Decision:
SemaDraw targets FreeBSD as the primary platform.

Rationale:
1. Clean kernel graphics architecture
2. Long term system stability
3. Alignment with project goals

Ports to other systems are possible but secondary.

## Non goals reaffirmed

Decision:
SemaDraw does not attempt to replace toolkits or desktops.

Rationale:
Semantics should be shared while policy should vary. This avoids ecosystem fragmentation.
