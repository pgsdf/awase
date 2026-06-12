# Protocol Mismatch Investigation Report

**Date**: 2026-01-04
**Scope**: drawfs kernel module and semadraw drawing system

## Overview

This report documents protocol incompatibilities identified between the two codebases in this repository:

- **drawfs**: A kernel module providing graphics surface management via file descriptors and ioctl
- **semadraw**: A userspace drawing system with its own IPC protocol and SDCS (Semantic Draw Command Stream) format

---

## Critical Incompatibilities

### 1. SURFACE_PRESENT Reply Structure Conflict

**Location**: `drawfs/sys/dev/drawfs/drawfs_proto.h` (lines 176-181 vs 199-203)

Two conflicting struct definitions exist for the same reply message:

```c
// First definition (missing cookie field)
struct drawfs_surface_present_rep {
    int32_t status;
    uint32_t surface_id;
    uint32_t reserved0;
    uint32_t reserved1;
};

// Second definition (has cookie field per spec)
struct drawfs_rpl_surface_present {
    int32_t  status;
    uint32_t surface_id;
    uint64_t cookie;
} __packed;
```

**Impact**: The PROTOCOL.md specification (lines 135-139) requires `cookie: u64`. If the kernel implementation uses the first struct, clients expecting the cookie field will read garbage data.

**Recommendation**: Remove the duplicate `drawfs_surface_present_rep` struct and keep only `drawfs_rpl_surface_present` which correctly includes the cookie field.

---

### 2. API Documentation vs Implementation Mismatch

**Location**: `semadraw/docs/API_OVERVIEW.md` (lines 37-51) vs `semadraw/src/ipc/protocol.zig`

The documentation specifies incorrect message type values:

| Message | Documented Value | Actual Implementation |
|---------|------------------|----------------------|
| HELLO_REPLY | `0x0002` | `0x8001` |
| ERROR | `0x00FF` | `0x80F0` |

**Impact**: Developers relying on documentation will implement incorrect message handling. The actual code correctly uses the `0x8000` high-bit convention for reply messages.

**Recommendation**: Update API_OVERVIEW.md to reflect the correct message type values from protocol.zig.

---

### 3. Incomplete SDCS Command Support in drawfs Backend

**Location**: `semadraw/src/backend/drawfs.zig` (lines 573-588)

The drawfs backend in semadraw only implements two SDCS commands:

| Opcode | Command | Status |
|--------|---------|--------|
| `0x0010` | FILL_RECT | ✓ Implemented |
| `0x00F0` | END | ✓ Implemented |
| `0x0001` | RESET | ✗ Missing |
| `0x0004` | SET_BLEND | ✗ Missing |
| `0x0007` | SET_ANTIALIAS | ✗ Missing |
| `0x0011` | STROKE_RECT | ✗ Missing |
| `0x0012` | STROKE_LINE | ✗ Missing |

**Impact**: Any SDCS command stream using unsupported opcodes will be silently ignored, leading to incomplete or incorrect rendering.

**Recommendation**: Implement the missing SDCS commands in the drawfs backend, or document the supported subset explicitly.

---

### 4. ioctl Encoding Platform Dependency

**Location**: `semadraw/src/backend/drawfs.zig` (line 46) vs `drawfs/sys/dev/drawfs/drawfs_ioctl.h` (line 61)

The semadraw backend hardcodes the ioctl number:

```zig
// semadraw hardcodes:
const DRAWFSGIOC_MAP_SURFACE: u32 = 0xC0104402;
```

While drawfs uses a platform-specific macro:

```c
// drawfs uses macro:
#define DRAWFSGIOC_MAP_SURFACE _IOWR('D', 0x02, struct drawfs_map_surface)
```

**Impact**: The ioctl encoding depends on:
- Platform (`_IOWR` macro differs between FreeBSD/Linux)
- Struct size (currently 16 bytes for `struct drawfs_map_surface`)

If the kernel is compiled on a different platform or with a different struct layout, the ioctl will fail.

**Recommendation**: Either:
- Generate ioctl numbers at build time from the kernel headers, or
- Document the exact platform requirements and struct layout assumptions

---

## Moderate Incompatibilities

### 5. Version Mismatch

| Component | Version | Location |
|-----------|---------|----------|
| drawfs | v1.0 (`0x0100`) | `drawfs_proto.h:7` |
| semadraw IPC | v0.1 (major=0, minor=1) | `protocol.zig:8-9` |
| SDCS | v0.1 (major=0, minor=1) | `sdcs.zig:31-32` |

**Impact**: During the HELLO handshake, version negotiation will reveal that drawfs is at stable v1.0 while semadraw components are pre-release v0.1. This may affect compatibility guarantees.

**Recommendation**: Document the version compatibility matrix and update semadraw to v1.0 when stable.

---

### 6. Alignment Mismatch

| Protocol | Alignment | Location |
|----------|-----------|----------|
| drawfs | 4-byte | `PROTOCOL.md` lines 9-10 |
| SDCS | 8-byte | `sdcs.zig` line 95 |

**Impact**: When SDCS command streams are embedded within drawfs frames, alignment boundaries must be carefully managed to prevent misaligned reads.

**Recommendation**: Document the alignment requirements at protocol boundaries and add padding where necessary.

---

### 7. Field Naming Inconsistency

**Location**: `drawfs/sys/dev/drawfs/drawfs_proto.h` vs `drawfs/docs/PROTOCOL.md`

The HELLO reply structure uses different field names:

| Header File | Specification |
|-------------|---------------|
| `caps_bytes` | `max_reply_bytes` |

**Impact**: While semantically equivalent, this inconsistency causes confusion when cross-referencing code and documentation.

**Recommendation**: Align field names between header and specification.

---

## Structural Comparison

| Aspect | drawfs | semadraw IPC | SDCS |
|--------|--------|--------------|------|
| **Transport** | File descriptor (ioctl/mmap) | Unix domain socket | Memory buffer |
| **Magic** | `0x31575244` ("DRW1") | None | `"SDCS0001"` |
| **Frame Header** | 16 bytes | 8 bytes | 64 bytes |
| **Message Header** | 16 bytes | 8 bytes | 8 bytes (CmdHdr) |
| **Alignment** | 4-byte | 8-byte | 8-byte |
| **Reply Convention** | High bit `0x8000` | High bit `0x8000` | N/A (command stream) |

---

## Summary

### Critical Issues (Will Cause Failures)

1. ✗ **SURFACE_PRESENT reply ambiguity** - Two conflicting struct definitions
2. ✗ **API Documentation vs Implementation** - Wrong message type values in docs
3. ✗ **Incomplete SDCS Support** - Most drawing commands not implemented
4. ✗ **ioctl Platform Dependency** - Hardcoded encoding will fail on different platforms

### Moderate Issues (May Cause Problems)

5. ⚠ **Version Mismatch** - drawfs v1.0 vs semadraw v0.1
6. ⚠ **Alignment Mismatch** - 4-byte vs 8-byte alignment
7. ⚠ **Field Naming Inconsistency** - Confusing documentation

---

## File References

| File | Description |
|------|-------------|
| `drawfs/docs/PROTOCOL.md` | drawfs protocol specification |
| `drawfs/sys/dev/drawfs/drawfs_proto.h` | Header with conflicting struct definitions |
| `drawfs/sys/dev/drawfs/drawfs_ioctl.h` | ioctl definitions |
| `semadraw/src/ipc/protocol.zig` | Actual IPC implementation |
| `semadraw/src/backend/drawfs.zig` | drawfs backend with incomplete SDCS support |
| `semadraw/docs/API_OVERVIEW.md` | Documentation with incorrect values |
| `semadraw/src/sdcs.zig` | SDCS command stream format |
