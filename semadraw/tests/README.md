# Testing Infrastructure

Run all tests with:
```sh
sh tests/run.sh
```

## Test Types

### 1. Unit Tests (`zig build test`)

Embedded in `src/sdcs.zig`, these test core validation functions:
- `opcodeName` - opcode to string conversion
- `isFiniteF32Bits` - IEEE 754 validity checking
- `pad8Len` - 8-byte alignment padding
- `fourcc` - chunk type encoding
- `validateOpcodePayload` - payload size validation
- Struct sizes (Header, ChunkHeader, CmdHdr)
- Constants (Magic, version)

### 2. Malformed Input Tests (`sdcs_test_malformed`)

Tests the validator's rejection of invalid inputs:
- Empty file
- Truncated header
- Wrong magic bytes
- Unsupported version (major/minor)
- Missing END command
- Wrong payload sizes
- Unknown opcodes
- Payload exceeding chunk bounds
- Chunk exceeding file bounds

Each test verifies the correct error type is returned and diagnostics are populated.

### 3. Golden Image Tests

Reference renderer output verification:
- Generates SDCS files for each feature
- Renders to PPM using `sdcs_replay`
- Compares SHA256 hash against golden baseline

If `tests/golden/golden.sha256` is missing entries, the script appends them.
Commit the updated golden file when you intentionally change semantics.

### 4. Determinism Verification

Ensures the reference renderer produces identical output across runs:
- Runs the same SDCS file 3 times
- Compares SHA256 hashes
- Fails if any run differs

This is critical for the semantic guarantee that identical commands produce identical pixels.

## Fuzzing

A fuzzing harness is available at `./zig-out/bin/sdcs_fuzz`:

```sh
# AFL usage
afl-fuzz -i corpus/ -o findings/ ./zig-out/bin/sdcs_fuzz @@

# Manual testing
./zig-out/bin/sdcs_fuzz <input_file>
```

Generate a fuzzing corpus:
```sh
# Create corpus directory with seed files
mkdir -p corpus
./zig-out/bin/sdcs_make_test corpus/valid.sdcs
```

The fuzzer exits:
- 0: Valid input
- 1: Validation error (expected for malformed input)
- 2: Usage error or crash

## Adding New Tests

1. **Unit tests**: Add `test` blocks to `src/sdcs.zig`
2. **Golden tests**: Create `src/tools/sdcs_make_*.zig`, update `tests/run.sh`
3. **Malformed tests**: Add cases to `src/tools/sdcs_test_malformed.zig`

### 5. IPC Protocol Tests (`src/ipc/protocol.zig`)

Tests for the semadraw IPC protocol:
- Serialize/deserialize roundtrips for all message types
- Message type value validation (matches `shared/protocol_constants.json`)
- Reply convention verification (0x8xxx for replies, 0x9xxx for events)
- Error code validation

These tests ensure protocol compatibility across updates and catch
accidental value changes that would break client-server communication.

Run with: `zig build test`
