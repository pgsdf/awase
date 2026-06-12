# Backward compatibility policy

This policy governs evolution of the semantic API and SDCS.

## Definitions

1. Semantic compatibility means the same SDCS stream produces the same observable result.
2. Binary compatibility means older SDCS files remain decodable.
3. Source compatibility means Zig API changes are minimal and mechanical to update.

## Rules

1. SDCS versioning is monotonic.
2. Existing opcodes never change meaning.
3. New opcodes may be added.
4. Reserved fields remain reserved until specified.
5. Unknown chunks must be skippable.
6. Unknown opcodes may be rejected or skipped only if the stream declares optionality.

## Deprecation

1. Deprecations must be documented for at least two minor versions.
2. Deprecations must include an automated migration path when feasible.

## Compatibility testing

1. Golden image tests are required for semantic behavior.
2. Replay tests must run headless in CI.
3. A reference corpus of SDCS files is maintained over time.
