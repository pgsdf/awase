# Security model

SemaDraw treats SDCS as untrusted input by default.

## Threat model

1. Malicious or malformed SDCS files
2. Remote streams from untrusted clients
3. Resource exhaustion attempts
4. Backend driver faults triggered by crafted streams

## Goals

1. Safe decoding with strict bounds checks
2. Deterministic validation before execution
3. Resource limits with predictable failure modes
4. Backend isolation via process boundaries

## Non goals

1. Protecting against a compromised kernel
2. Guaranteeing GPU driver correctness

## Input validation

1. All lengths and offsets are validated before reading.
2. All numeric scalars are validated as finite.
3. All payload sizes must match opcode specification.
4. All chunk boundaries must be consistent.

## Resource limits

1. Maximum stream size limit
2. Maximum command count per stream
3. Maximum resource count per stream
4. Maximum surface size in pixels for any backend

Limits are enforced by semadrawd.

## Backend isolation

1. semadrawd isolates client parsing from backend execution.
2. High risk backends may run in separate helper processes.
3. Shared memory and DMA buffers are opt in and validated.

## Fuzzing

1. SDCS decoder must be fuzzed continuously.
2. Corpus driven fuzzing should include known valid files and mutated variants.


Implementation note:
Validation is performed by sdcs.validateFile and should be invoked by all consumers prior to execution.
