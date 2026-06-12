# Shared Protocol Constants

This directory contains the canonical specification for protocol constants used across the graphics stack.

## Files

### protocol_constants.json

Single source of truth for all protocol constants across:
- **drawfs protocol** - Kernel interface for display/surface management
- **semadraw IPC** - Daemon-client communication protocol
- **SDCS** - Semantic Draw Command Stream format

## Usage

### Current State

`protocol_constants.json` is the single source of truth, and code
generation from it is implemented and in use. The generator is
`shared/tools/gen_constants.py`; it reads this JSON and rewrites the
generated constant blocks in the target files (see "Code Generation"
below). The generated blocks in `semadraw/src/ipc/protocol.zig` and
`semadraw/src/sdcs.zig` carry the generator's sentinel markers and are
produced output, not hand-maintained.

When adding or changing protocol constants:
1. Edit `protocol_constants.json`, not the generated blocks in the
   target files
2. Ensure new constants do not conflict with existing ones
3. Run `python3 shared/tools/gen_constants.py` to regenerate, or
   `--validate` to check the committed outputs are in sync

### Code Generation

`gen_constants.py` emits language-specific constant blocks into:
- `drawfs/sys/dev/drawfs/drawfs_proto.h` (C enums)
- `semadraw/src/ipc/protocol.zig` (Zig enums)
- `semadraw/src/sdcs.zig` (SDCS opcodes)

It rewrites only the regions delimited by sentinel comments
(`BEGIN GENERATED CONSTANTS` / `END GENERATED CONSTANTS`) and refuses
to run if the sentinels are absent. `--validate` exits non-zero if
regeneration would change any committed file; wiring that check into
CI is tracked separately (see `SPRINT.md`) and is the one remaining
piece, the generator and its adoption are otherwise complete.

## Protocol Conventions

### Message Type Ranges

| Range | Purpose |
|-------|---------|
| 0x0001-0x0FFF | Requests (client → server) |
| 0x8000-0x8FFF | Replies (server → client) |
| 0x9000-0x9FFF | Events (async server → client) |

### Reply Convention

Reply types set the high bit: `reply = request | 0x8000`

Example: `HELLO (0x0001)` → `HELLO_REPLY (0x8001)`

### Error Codes

Error codes are numeric, starting at 0 (success). Each protocol layer has its own error code namespace to allow layer-specific errors.

## Validation

To validate constants match implementations:

```bash
# Check drawfs constants
grep -E "DRAWFS_(REQ|RPL|ERR|EVT)_" drawfs/sys/dev/drawfs/drawfs_proto.h

# Check semadraw IPC constants
grep -E "(hello|create_surface|error)" semadraw/src/ipc/protocol.zig

# Check SDCS opcodes
grep "pub const.*0x00" semadraw/src/sdcs.zig
```
