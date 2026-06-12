# 0012 F.1: state file specification

## Status

Accepted, 2026-05-28. Decision-owner ratification. Per ADR 0011, F.1's closure requires
state-file machinery at `/var/run/sema/audio/state` with
documented schema, magic, version, MOD_LOAD publication,
clean unload, and a controller inventory. This ADR records
the design decision for that state file. The byte-level
schema lives in `shared/AUDIO_STATE.md` (companion to this
ADR, analogous to how inputfs's `shared/INPUT_STATE.md`
relates to `inputfs/docs/adr/0002-shared-memory-regions.md`).

ADR-before-code discipline holds: this ADR plus the
companion spec are the specification; the kernel-side
publish/unpublish implementation is a separate commit that
follows.

This ADR does not reverse, reopen, or amend ADR 0006, ADR
0007, ADR 0008, ADR 0010, or ADR 0011. It specifies one
sub-stage (F.1) under the F-stage map as reconciled by ADR
0011.

## Context

ADR 0011 reframed F.1's closure criteria:

  1. State-file machinery exists at
     `/var/run/sema/audio/state` with magic, version, and a
     documented schema per ADR 0007's physics-only
     constraint.
  2. The schema includes the device inventory in a form
     that lets a reader (semasound or its precursor)
     enumerate what audiofs has attached.
  3. MOD_LOAD writes the state file; MOD_UNLOAD removes it
     or marks it invalid; reattachment is clean.
  4. At least one controller is enumerated (already
     satisfied by current attachment to both
     pgsd-bare-metal controllers; the gap is the file).

UTF has a reference pattern for shared-memory publication.
`shared/CLOCK.md` (20-byte clock region; magic SMCK; little-
endian; sequential-consistency atomic on the load-bearing
counter; Writer/Reader types exposed through a shared
library) is the prototype. `shared/INPUT_STATE.md` (11,328-
byte state region with fixed-size slot arrays for device
inventory, keyboard state, and touch state; magic INST;
version 1) is the closer-fit precedent for audiofs because
audio also has multiple endpoints and per-endpoint state.

The audiofs state file follows this pattern. The decisions
this ADR makes are about what audio-specific content the
region carries, not about whether to use the established
pattern (it does).

## What audiofs needs to publish at F.1

By the reframed F.1 closure criteria and by ADR 0007's
physics-only constraint, the state file at F.1 carries:

  - **Identity of the audiofs writer instance.** Magic,
    version. (Standard idiom.)
  - **Validity flag.** Whether the writer has finished
    initial population (so readers know when to start
    interpreting the rest). (Standard idiom.)
  - **A small writer-state header.** Total endpoint count,
    inventory sequence number (incremented on hot-plug add
    or remove), reserved padding.
  - **Controller inventory.** One slot per attached HDA
    controller (or per future USB audio class device).
    PCI/USB identification, controller capability summary
    (number of ISS/OSS/BSS, 64-bit-DMA support).
  - **Endpoint inventory.** One slot per discovered output
    or input endpoint. An endpoint is the abstraction over
    "a path from a pin complex to a DAC (output) or from
    an ADC to a pin complex (input) that has been topology-
    walked and is electrically ready." Each endpoint
    carries: stable id within this audiofs lifetime, kind
    (analog speaker, analog headphone, HDMI, future:
    USB-audio playback/capture, etc.), direction (output /
    input), the controller and codec it belongs to, and
    its physics-level format capabilities (rate mask, bit-
    depth mask, channel mask).
  - **Per-endpoint runtime state.** Stream-active flag,
    current format if active, current sample rate if
    active. These transition with stream lifecycle; F.2's
    events ring will signal the transitions, but the state
    file is the always-current snapshot for late-joining
    readers.

What audiofs does NOT publish at F.1:

  - **Policy.** No "default output", no "preferred sink",
    no "ducking active" flag. ADR 0007's physics/semantics
    boundary places policy in semasound (userland); the
    state file is physics-only.
  - **Mix state.** No current mix gains, no per-stream
    volume. Mixer location per ADR 0004 is single-writer
    in semasound; the kernel does not mix.
  - **The user-control surface.** F.3.b decides whether
    that surface is ioctl, /dev node, or something else.
    The state file does not pre-empt that decision.
  - **The clock region.** That is a separate file at
    `/var/run/sema/clock` per ADR 0003. The audiofs state
    file does not duplicate it.
  - **Event semantics.** F.2 (events ring) carries delta
    information. The state file is the always-fresh
    snapshot; events are the ordered stream.

## Decision

### 1. Path and lifecycle

`/var/run/sema/audio/state`. Created with mode 0644 owned
by root:wheel by audiofs on MOD_LOAD. Parent directory
`/var/run/sema/audio/` created if absent (idiom from
inputfs).

On MOD_UNLOAD, the file is removed. If MOD_UNLOAD cannot
remove the file (e.g. directory permission lost), the file
is at minimum marked invalid by zeroing the `state_valid`
byte before module unload completes.

On reattach (hot-plug new controller, or driver reload),
the file is re-populated atomically. The writer is
single-writer-single-region: there is one audiofs.ko
loaded at a time, and it owns the file.

### 2. Schema (header)

A fixed 64-byte header at offset 0, mirroring the
inputfs INPUT_STATE.md header shape. Magic 4 bytes (ASCII
"AUST" = 0x54535541 little-endian, "Audio State"); version
1 byte (starts at `1`); state_valid 1 byte; reserved bytes
for future use; total endpoint count; inventory sequence
number; padding.

Full header field layout in `shared/AUDIO_STATE.md`.

### 3. Schema (controller inventory)

Fixed-size slot array following the header. Each slot:
controller id, PCI vendor/device, controller subtype (HDA
PCI vs USB audio class), num_iss/num_oss/num_bss,
support_64bit, a name string (free-form, for display
purposes only; not load-bearing semantically).

Slot count is fixed at 8 in v1. Most systems have 1-2
controllers; 8 is a safe ceiling and keeps the per-slot
array small enough that the total file size stays in the
1-2 KB range. Bumping the count later requires a version
bump and the established compatibility-rules apply.

### 4. Schema (endpoint inventory)

Fixed-size slot array. Each slot: stable endpoint id
(within audiofs's current lifetime), controller index (into
the controller-inventory array above), codec address, kind
(see categorical enum in `shared/AUDIO_STATE.md`),
direction (output / input / loopback), pin nid, dac/adc
nid, electrical-readiness flag (was the path's pin
controlled and amplifier unmuted at attach), runtime-
active flag, current format word if active, supported
format-capability summary.

Slot count is fixed at 32 in v1. Real-world endpoint
counts on UTF target hardware: pgsd-bare-metal iMac
exposes roughly 6-10 endpoints (internal speaker,
headphone, line-in, line-out, microphone, plus HDMI
sinks). 32 is a comfortable ceiling for the v1 family of
target machines. Bumping later requires a version bump.

### 5. Format-capability summary

ADR 0007's native-format-only constraint in the kernel
means audiofs publishes what the DAC/ADC actually supports
at the hardware level. The summary is bitmasks:

  - rate_mask: bit i = the i'th HDA-spec-defined sample
    rate is supported by this endpoint's converter (or USB
    audio class set, when applicable). HDA rate-bit
    encoding per HDA 1.0a Table 87 is used as-is.
  - bit_depth_mask: bit i = the i'th HDA-spec-defined bit
    depth is supported. Encoding per HDA 1.0a Table 87.
  - channel_mask: bit i set = (i+1) channels supported.
    Most analog endpoints support stereo (bit 1); HDMI
    supports up to 8 (bit 7).

The point is to let semasound (or a precursor reader)
answer "can I open this endpoint at 48 kHz / 16-bit /
stereo?" by checking bitmasks, without round-tripping
into the kernel.

### 6. Hot-plug semantics

The inventory sequence number in the header increments on
any inventory change: controller attach, controller
detach, endpoint appear (e.g. HDMI sink connects),
endpoint disappear (e.g. headphone unplugged with jack
detection). Readers comparing the inventory sequence
number across reads can know "the inventory has changed,
re-read."

The actual fields update on the same writes. Concurrency
follows the inputfs INPUT_STATE.md pattern: writes are
seqlock-protected for atomic multi-field reads;
sequential-consistency atomics on the writer side; readers
loop on the seqlock until they see a consistent read.

The exact seqlock layout is in `shared/AUDIO_STATE.md`.

Hot-plug events are also signalled on the F.2 events ring
when F.2 lands. The state file is the always-fresh
snapshot; events are the ordered stream. A reader using
both can correlate: an event with sequence number N
corresponds to the state observed after the inventory
sequence number reached value M, where the relationship
between N and M is defined by the F.2 event schema (to be
specified in the F.2 ADR).

### 7. Endpoint id stability

Endpoint ids are stable within audiofs's current lifetime.
On MOD_UNLOAD / MOD_LOAD they are reassigned freely.
Stability across reboot is not promised; semasound and
later consumers that need cross-reboot identity must look
up endpoints by (controller PCI id, codec address,
pin/dac nid) and not by endpoint id.

This matches the inputfs precedent: device_ids are stable
within the inputfs instance but identity hashes are used
for cross-reboot matching.

### 8. Endpoint-kind enum

Categorical, physics-derived, semantically narrow:

  - 0: unused (the slot is empty)
  - 1: analog speaker (internal speaker pin, OUTPUT_CAP)
  - 2: analog headphone (HEADPHONE_CAP pin)
  - 3: analog line-out (OUTPUT_CAP, not HP-classed,
    not speaker-classed by pin config default)
  - 4: analog mic (INPUT_CAP, mic-class pin config default)
  - 5: analog line-in (INPUT_CAP, line-class)
  - 6: HDMI playback (digital pin, type HDMI per pin
    config default)
  - 7: DisplayPort playback (digital pin, type
    DisplayPort per pin config default; treated
    similarly to HDMI)
  - 8-15: reserved (future analog variants, S/PDIF,
    loopback, USB-audio devices once F.3 brings them up)

Pin classification follows the pin-configuration-default
register interpretation; pin config defaults are HDA-spec
defined (HDA 1.0a section 7.3.3.31, "pin widget control"
and the "configuration default" section). Codec-vendor
quirks that misreport pin config defaults are out of scope
for v1; if encountered, they go in the platform-policy
table (per commit 6g pattern) rather than in audiofs
endpoint classification.

## Why this design

**Why a single state file, not per-endpoint files.** The
inputfs precedent is one state file with slot arrays. A
reader can mmap once and read the whole inventory.
Per-endpoint files would require enumeration of the
directory and one mmap per file, with no clear benefit.

**Why fixed-size slot arrays, not a variable-length list.**
The inputfs and clock precedents use fixed-size arrays.
Variable-length lists complicate the reader (it must know
where each variable-length record ends) and the writer
(it must avoid concurrent re-layout during reads). Fixed-
size arrays match UTF's existing pattern and keep readers
simple.

**Why slot counts of 8 controllers and 32 endpoints.**
Sized for the v1 hardware family (PC-class systems with
1-2 HDA controllers and a handful of endpoints). Sized
small enough that the total file remains in the 1-2 KB
range. Sized loosely enough to leave headroom for HDMI
endpoint proliferation (a multi-monitor system can present
many HDMI sinks) and future USB audio class devices.

**Why physics-only.** ADR 0007 is explicit. The kernel
substrate publishes what hardware *can* do; semasound (or
a precursor) decides what hardware *should* do. Putting
policy in the state file would import semantic decisions
into the kernel that ADR 0007 deliberately excludes.

**Why publish endpoint format-capability summary, not full
format descriptors.** The full HDA format word is 16 bits
of encoded combination; consumers do not need the encoded
form (which they would have to decode anyway). Bitmasks
let consumers check "is rate R supported" with a single
test. Once a stream is active, the current format word is
also published verbatim (so a diagnostic tool can show the
actual format being delivered).

**Why update endpoint runtime state in the state file.**
Late-joining readers (a semasound that starts after
streams are already active) need to see the current state
without replaying events. The state file is the canonical
"current state" surface. Events (F.2) carry deltas; state
(F.1) carries snapshot.

## What this commits

### Closure criteria for F.1

F.1 closes when:

  1. The state file exists at `/var/run/sema/audio/state`
     with magic 0x54535541 ("AUST" in little-endian ASCII)
     and version 1.
  2. The schema in `shared/AUDIO_STATE.md` is implemented
     in the kernel publish path. `audiofs/sys/dev/audiofs/`
     gains the publish/unpublish code.
  3. On MOD_LOAD with the existing pgsd-bare-metal
     attachment, the file contains: header with magic and
     version; one or two controller slots (Intel Sunrise
     Point HDA at slot 0; ATI Oland HDMI at slot 1 if
     also attached); endpoint slots for the discovered
     output paths (at least the iMac internal speaker
     endpoint, given commit 6g enables it automatically).
  4. On MOD_UNLOAD, the file is removed (or marked
     invalid by zeroing `state_valid` if removal fails).
     Subsequent MOD_LOAD cleanly re-publishes.
  5. A reader (initially a small diagnostic tool, to be
     written; in the longer term, semasound) can parse
     the file against `shared/AUDIO_STATE.md` and
     enumerate the inventory.

### What F.1 implementation lands

Approximately:

  - `shared/AUDIO_STATE.md`: the byte-level schema
    (this commit; the spec).
  - Kernel publish code in `audiofs/sys/dev/audiofs/`:
    state-region build, populate, mmap-backed file write,
    seqlock-protected update path, unpublish on unload.
    Probably 200-400 lines of C.
  - Header updates per `shared/AUDIO_STATE.md` schema:
    struct definitions, field-offset asserts.
  - A small diagnostic reader (Zig, in
    `audiofs/tools/audiodump` or similar) that parses the
    file and prints the inventory. Optional but useful;
    not strictly required for F.1 closure.

The implementation lands as a separate commit (or small
series). This commit is specification only.

### What F.1 implementation does NOT land

  - **F.2 events ring.** Out of scope; that is the F.2
    ADR's work.
  - **F.3 data-path completion.** Out of scope; commits
    1-6g already cover the test-tone vertical slice;
    F.3.a (continuous streaming) is the next data-path
    sub-milestone, not part of F.1.
  - **F.4 clock writer.** Out of scope.
  - **A user-control surface.** Out of scope; the state
    file is read-only metadata. F.3.b decides the
    control surface.

## Trade-offs noted but not adopted

**Variable endpoint slot count via re-mmap.** Considered:
let the slot count grow if needed by re-creating the file
at a larger size. Rejected: complicates the reader (which
must detect the re-creation and re-mmap), and the v1 32-
slot ceiling is comfortable for target hardware. If
exceeded in the future, a version bump can either grow
the array or move to a different surface; deferring is
the right call now.

**Publishing more codec-internal detail (widget topology,
amplifier gains).** Considered: include enough that a
semasound could fully reconstruct the codec graph from
state. Rejected: semasound is not the diagnostic surface;
the existing per-controller `dev.audiofs.N.eventlog`
sysctl already exposes the topology walk for human
inspection. Including the codec graph in the state file
would be policy-adjacent (informing semasound how to
configure paths is a semantic decision semasound itself
must make) and contradicts ADR 0007.

**Publishing format quality metrics (jitter, latency).**
Considered: include measured latency or jitter per
endpoint as a hint to semasound. Rejected: these are
secondary-rationale measurements (per ADR 0006); they
require ongoing measurement infrastructure that F.1 does
not have. If desired later, they can be added under a
version bump.

**Per-endpoint volume / mute state.** Considered: include
"the amp's current gain setting" per endpoint. Rejected:
this is mixer state, and ADR 0004 places the canonical
mix in semasound. The kernel-side amplifier unmute at
attach (commit 6a) sets a known initial state; if
semasound wants to read the current amplifier gain for
diagnostic purposes, a separate sysctl can expose it,
distinct from the canonical state file.

## Relationship to ADR 0007 (physics/semantics)

ADR 0007 places physics in the kernel and semantics in
userland. This ADR's design holds the line:

  - The state file publishes what the hardware can do
    (format-capability bitmasks; endpoint enumeration;
    electrical-readiness flag).
  - The state file does NOT publish policy (no "preferred
    sink"; no "default route"; no semantic naming beyond
    pin-config-default classification).
  - Hot-plug events are physics events (pin presence
    changed); semasound interprets what to do about them.
  - Mix state, volume, channel routing: not here. ADR
    0004 places them in semasound.

## Relationship to ADR 0008 / ADR 0011

ADR 0008 sequenced F.1 as "attaches to one PCM endpoint
on a listed chipset, publishes /var/run/sema/audio/state".
ADR 0011 reframed F.1's closure criteria. This ADR
specifies the state file per the reframed criteria. The
"one PCM endpoint" framing from ADR 0008 is superseded by
ADR 0011's "PCI HDA evidence (already present minus the
file); USB audio class folded into F.3"; this ADR's
endpoint inventory accordingly covers all discovered
endpoints on attached controllers, not just one.

## Relationship to ADR 0003 / ADR 0005

ADR 0003 specifies the clock writer surface at
`/var/run/sema/clock`. This ADR does not duplicate or
shadow that file; the audiofs state file is a separate
surface at `/var/run/sema/audio/state`. ADR 0003 still
specifies the clock; F.4 will move clock-writing duty
from semaaud to audiofs without changing the clock
file's schema or location.

ADR 0005 specifies semasound's userland architecture.
This ADR's state file is designed to be read by
semasound but does not pre-empt semasound's design. The
schema is chosen to give semasound enough to enumerate
endpoints and check format compatibility; semasound's own
ADR decisions (per-target listening sockets, per-
connection sessions, etc.) are unaffected.

## Consequences

### What this enables

  - **F.2 has a place to point at.** Events on the F.2
    ring can reference endpoint ids defined by the F.1
    state file. F.2 ADR work can proceed once this
    specification lands.
  - **A diagnostic reader is buildable.** Once F.1
    implementation lands, a small `audiodump state`-style
    tool can be written and is useful immediately.
  - **The semasound bring-up has a concrete reader
    target.** F.5 (semasound) starts with a known state-
    file format to read against.

### What this commits

  - **The state file is committed as a public surface.**
    Schema changes after F.1 implementation lands require
    a version bump and the established compatibility
    rules.
  - **The endpoint-kind enum is committed as the v1 set.**
    Adding kinds requires either using a reserved slot
    (no version bump if backward-compatible) or a version
    bump (if changing existing kind values).
  - **The slot counts (8 controllers, 32 endpoints) are
    committed.** Going larger requires a version bump.

### What this does not address

  - **The kernel-side seqlock implementation details.**
    The companion spec specifies the protocol; the
    implementation commit picks the C primitives.
  - **Whether the diagnostic reader is in scope for F.1
    closure.** The closure criteria require the state
    file plus the schema; the reader is useful but
    optional.
  - **F.2 onward.** Each subsequent sub-stage gets its
    own ADR.

## What this document is not

  - Not the implementation. The implementation is a
    separate commit. This document plus
    `shared/AUDIO_STATE.md` are the specification.
  - Not a replacement for ADR 0005 (semasound
    architecture). Semasound's design is recorded there;
    this ADR records the state file semasound will read
    from, without specifying semasound itself.
  - Not the F.2 ADR. The events ring is a separate
    publication surface with its own design decisions.
    This ADR specifies the state file only.
  - Not a softening of ADR 0007's physics/semantics
    boundary. The state file is physics-only by design;
    this ADR makes that boundary explicit field by
    field.
