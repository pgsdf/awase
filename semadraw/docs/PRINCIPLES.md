# Principles

## Semantics first

All operations express meaning, not mechanism.

## Resolution independence

Logical units are used everywhere.
Pixels are a backend concern only.

## Determinism

The same input produces the same output.
This is required for testing, debugging, and trust.

## Explicit state

All state transitions are explicit in the command stream.

## Inspectability

Every frame can be recorded, dumped, and replayed.

## Stability

Semantics evolve slowly.
Backends evolve freely.

## Testability

Graphics must be testable in automated and headless environments.
