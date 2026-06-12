# inputfs foundations

Status: In progress, 2026-04-23 (decisions only; rationale to follow)

This document captures the foundational decisions for the inputfs
substrate — the decisions that cross-cut individual ADRs and that
each later ADR should reference rather than re-derive.

It is written in two passes. Pass 1 (today) records only the
**Decision** line for each foundation. Pass 2 (later session) adds
rationale, consequences, and notes.

No ADRs should be drafted against an unexpanded foundation. A
Decision without a Rationale is a hypothesis, not a commitment.

## 1. Coordinate space

### Decision

Pointer coordinates flow through inputfs in a single space: **compositor
post-transform pixels**. inputfs reads the compositor's transform state
from a shared memory region (symmetric to how the compositor reads input
state from inputfs) and normalises device events into that space before
publication. On resolution or scale change, normalised position is
preserved rather than raw pixel index. Internal representation is
higher precision than the published i32 wire format.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

## 2. Device model

### Decision

inputfs has a single unified event ingestion pipeline. **Sources are
pluggable; only some sources instantiate devices.** Physical HID
hardware is a device-backed source with identity and lifecycle.
Remote input is a session-scoped source. Accessibility and test
synthesis are synthetic sources. All sources produce events in the
same shape; only device-backed sources contribute to the published
device inventory.

A device carries stable identity and one-to-many **role endpoints**
(pointer, keyboard, touch, pen, lighting, etc.). Composite devices
expose multiple roles under one identity. Bluetooth devices that
reconnect with new wire identities retain stable logical identity.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

## 3. Event ordering

### Decision

Every event admitted to inputfs receives a **monotonic sequence
number at ingestion**, assigned under a single serialisation point.
Total ordering across all sources is preserved regardless of the
interrupt context or thread that produced the event.

The sequence number is the authoritative ordering mechanism. Clock
timestamps (see §6) are for diagnostics and A/V sync, not ordering.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

## 4. Event stream and state consistency

### Decision

inputfs publishes two surfaces:

- **Current state region** (shared memory): pointer position,
  per-device keyboard modifier and key-held state, device
  inventory. Updated by inputfs on each event.
- **Event history ring** (shared memory, bounded): recent events
  in sequence-number order.

State is a **materialised view of the event stream**. The invariant
is that state visible to a reader reflects all events up to and
including some sequence number `N`, and the state read includes a
version tag indicating which `N`.

State reads use **seqlock-style versioned access**: consumers may
retry on torn reads. Event ring reads are lock-free consumer-side
(single-producer multiple-consumer).

Real-time consumption is supported by a **pollable fd** (kqueue-able)
that wakes consumers when new events are published. The ring exists
for history and for consumers that tolerate polling; the fd exists
for consumers that cannot afford polling latency.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

## 5. Keyboard semantics

### Decision

Key events in inputfs are **pre-text, not text**. inputfs does not
perform layout translation, compose-key handling, dead-key
handling, or IME integration. Those concerns belong to the
compositor.

Each key event carries **both** the hardware HID usage code and a
stable positional code (where derivable). Layout-dependent
interpretation — "this key produces the character 'A'" — is the
compositor's responsibility.

Auto-repeat is **not** generated in inputfs; it is a compositor
(or per-client) concern.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

## 6. Timestamps and clocks

### Decision

Every event carries two timestamps:

- **Ordering clock**: a kernel monotonic time source, used
  together with the sequence number to reconstruct absolute timing
  without requiring readers to consume the sequence. Survives
  normal uptime; behaviour across suspend/resume is a deferred
  detail (see Open edges).
- **Sync clock**: audio-sample position read from semaaud's
  published clock at event-ingestion time. Used for A/V
  synchronisation. `null` when semaaud is unavailable.

Ordering is determined by sequence number (§3), not by timestamp.
Timestamps are diagnostic and synchronisation metadata.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

### Open edges

- Exact FreeBSD kernel clock source (monotonic vs suspend-aware
  equivalent of Linux `CLOCK_BOOTTIME`) to be finalised during
  Stage B implementation.

## 7. Security and access

### Decision

inputfs v1 uses a two-tier access model with room for extension:

- **Read access** to published state and event ring: granted by
  membership in a dedicated group (name TBD, working name `input`).
- **Write access** (event synthesis): requires elevated privilege
  (root or a distinct capability; working assumption root).

The API surface is designed to admit future extension to
**per-session scoping** and **capability tokens** without breaking
existing consumers. No consumer should assume the v1 group-based
check is the only gate that will ever exist.

Device grabs (exclusive-access locks equivalent to evdev's
`EVIOCGRAB`) are **not** supported in v1. Compositor-level grabs
(e.g. pointer grabs during menu display) are a compositor concern,
implemented via inputfs's routing, not via exclusive device locks.

### Rationale

*(Pass 2)*

### Consequences

*(Pass 2)*

---

## Terminology reference

Defined here to prevent drift between ADRs. Expanded in Pass 2.

- **Device** — a source with stable identity and lifecycle.
- **Source** — any producer of events: device-backed, remote,
  synthetic.
- **Role endpoint** — a semantic facet of a device (pointer,
  keyboard, touch, pen, lighting).
- **Compositor space** — post-transform pixel coordinates as the
  compositor sees them.
- **Ordering clock** — monotonic kernel time, used together with
  the sequence number for diagnostic absolute timing.
- **Sync clock** — audio-sample position, optional, for A/V sync.
- **Sequence number** — authoritative total-ordering index,
  assigned at ingestion.
