# Unified Event Log Schema

> **Retirement note (F.6, ADR 0029).** `semaaud` and `semainputd` are
> retired; no producer of the `semaaud` or `semainput` subsystems
> remains, and the chronofs ingestion path for this format is unwired
> library code. Audio observability now lives on semasound's
> per-target `events` surface (key=value lines with a `frames` audio
> position; ADR 0027), which is a state surface, not this stdout
> event-log format. This document is the reference for the RECORDED
> format only: an audit during chronofs ADR 0001 (2026-06-05) found
> no current emitter of these lines in any daemon or shared library.
> The chronofs `--replay` tool resolves recorded semadraw lines;
> the semaaud and semainput ingestion arms were removed by the same
> ADR, so those domains of old recordings no longer resolve.

This document defines the JSON-lines event format shared by the PGSDF
daemons: historically `semaaud`, `semainput`, `semadraw`, and `drawfs`. It is
the authoritative reference for the event fields required by the chronofs
temporal coordination layer.

---

## Output channel

All daemons emit events as **newline-delimited JSON** to **stdout**. Each line
is a complete, self-contained JSON object followed by `\n`. No line spans
multiple newlines. The calling process (a supervisor, log aggregator, or the
chronofs ingestion driver) is responsible for routing stdout from each daemon
to the appropriate consumer.

Daemons do not write events to files directly. Filesystem state surfaces
(e.g. semasound's `/var/run/sema/audio/{target}/state`, ADR 0027) are
separate from the event log and serve introspection, not chronofs.

---

## Required fields

Every event, regardless of subsystem or type, must include the following fields
in this order:

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Event type identifier. See per-subsystem tables below. |
| `subsystem` | string | One of `"semaaud"`, `"semainput"`, `"semadraw"`, `"drawfs"`. |
| `session` | string | 16-character lowercase hex session token from `shared/src/session.zig`. Same value for all daemons within a fabric lifetime. |
| `seq` | u64 | Per-subsystem monotonic sequence number starting at 1. Never resets within a daemon lifetime. Used to detect dropped events. |
| `ts_wall_ns` | i64 | Wall-clock nanoseconds at event emission (`std.time.nanoTimestamp()`). |
| `ts_audio_samples` | u64 or null | Audio clock position in PCM sample frames at event emission. Read atomically from the shared memory clock region (S-4). Null when no semaaud stream is active or S-4 is not yet implemented. |

### Field ordering convention

Required fields appear first in the JSON object, in the order listed above.
Subsystem-specific fields follow. This makes log lines grep-friendly and keeps
the mandatory envelope consistent across all event types.

### Example envelope

```json
{"type":"stream_begin","subsystem":"semaaud","session":"deadbeefcafebabe","seq":1,"ts_wall_ns":1712345678901234567,"ts_audio_samples":null,...}
```

---

## Nullability rules

- `session` is never null. If the session file cannot be read at startup, the
  daemon generates a local fallback token and logs a warning to stderr.
- `seq` is never null. It increments for every emitted line including lifecycle
  events.
- `ts_wall_ns` is never null.
- `ts_audio_samples` is null when:
  - No semaaud stream is active (counter is valid but `clock_valid` is false).
  - The clock shared memory region (`/var/run/sema/clock`) is absent or
    unreadable (S-4 not yet deployed).
  - The emitting daemon is semaaud itself, where `ts_audio_samples` equals
    `samples_written` at the moment of emission.

---

## Per-subsystem event types

### semaaud

Emitted to stdout in addition to the existing filesystem state surfaces.
The `target` field identifies which audio target (`"default"` or `"alt"`) the
event concerns.

| Type | When emitted | Key additional fields |
|------|-------------|----------------------|
| `stream_begin` | A PCM stream is accepted and begins playing. | `target`, `stream_id`, `client_id`, `client_label`, `client_class`, `client_origin`, `uid`, `gid`, `authenticated`, `policy`, `default_pcm`, `audiodev`, `mixerdev`, `sample_rate`, `channels`, `sample_format` |
| `stream_end` | A stream ends normally (client disconnected). | `target`, `stream_id`, `default_pcm`, `audiodev`, `mixerdev` |
| `stream_stop` | A stream is stopped by the control server. | `target`, `stream_id`, `default_pcm`, `audiodev`, `mixerdev` |
| `stream_flush` | A stream is flushed by the control server. | `target`, `stream_id`, `default_pcm`, `audiodev`, `mixerdev` |
| `stream_preempt` | A higher-priority client preempts the active stream. | `target`, `old_stream_id`, `old_client_id`, `old_client_label`, `new_client_id`, `new_client_label`, `new_client_class`, `new_client_origin`, `policy` |
| `stream_reject` | A client is rejected by policy. | `target`, `client_id`, `client_label`, `client_class`, `client_origin`, `uid`, `gid`, `authenticated`, `policy`, `default_pcm`, `audiodev`, `mixerdev` |
| `stream_reroute` | A denied client is rerouted to a fallback target. | `from_target`, `to_target`, `client_id`, `client_label`, `client_class`, `client_origin`, `uid`, `gid`, `authenticated`, `reason` |
| `stream_group_block` | A client is blocked because another target in the same group is active. | `target`, `group`, `blocking_target`, `client_id`, `client_label`, `client_class`, `client_origin`, `uid`, `gid`, `authenticated`, `reason` |
| `stream_group_preempt` | A client preempts another target in the same group. | `target`, `group`, `preempted_target`, `client_id`, `client_label`, `client_class`, `client_origin`, `uid`, `gid`, `authenticated`, `reason` |

### semainput

Already emits JSON-lines to stdout. Fields added in I-1: `subsystem`,
`session`, `seq`, `ts_wall_ns`, `ts_audio_samples`.

**Lifecycle events**

| Type | When emitted | Key additional fields |
|------|-------------|----------------------|
| `daemon_start` | Daemon begins. | `name`, `version` |
| `classification_snapshot` | Device capability classification updated. | `devices` (array of device capability objects) |
| `identity_snapshot` | Logical device mapping updated. | `mappings` (array of mapping objects) |

**Semantic input events**

| Type | When emitted | Key additional fields |
|------|-------------|----------------------|
| `mouse_move` | Pointer device produces relative motion. | `device`, `source`, `dx`, `dy` |
| `mouse_button` | Pointer button state changes. | `device`, `source`, `button`, `state` (`"down"` or `"up"`) |
| `mouse_scroll` | Scroll wheel produces relative motion. | `device`, `source`, `dx`, `dy` |
| `key_down` | Keyboard key pressed. | `device`, `source`, `code` |
| `key_up` | Keyboard key released. | `device`, `source`, `code` |
| `touch_down` | Touch contact begins. | `device`, `source`, `contact`, `x`, `y` |
| `touch_move` | Touch contact moves. | `device`, `source`, `contact`, `x`, `y` |
| `touch_up` | Touch contact ends. | `device`, `source`, `contact` |

**Gesture events**

| Type | When emitted | Key additional fields |
|------|-------------|----------------------|
| `scroll_begin` | Two-finger scroll gesture activates. | `device` |
| `two_finger_scroll` | Two-finger scroll in progress. | `device`, `dx`, `dy` |
| `scroll_end` | Two-finger scroll gesture ends. | `device` |
| `pinch_begin` | Pinch gesture activates. | `device`, `delta`, `scale_factor` |
| `pinch` | Pinch gesture in progress. | `device`, `delta`, `scale_hint`, `scale_factor` |
| `pinch_end` | Pinch gesture ends. | `device` |
| `three_finger_swipe_begin` | Three-finger swipe activates. | `device`, `dx`, `dy`, `total_dx`, `total_dy`, `axis`, `confidence` |
| `three_finger_swipe` | Three-finger swipe in progress. | `device`, `dx`, `dy`, `total_dx`, `total_dy`, `axis`, `confidence` |
| `three_finger_swipe_end` | Three-finger swipe ends. | `device` |
| `drag_start` | Single-contact drag begins. | `device`, `contact`, `x`, `y` |
| `drag_move` | Drag in progress. | `device`, `contact`, `x`, `y` |
| `drag_end` | Drag ends. | `device`, `contact`, `x`, `y` |
| `tap` | Short single-contact tap. | `device`, `contact`, `x`, `y` |
| `intent_hint` | Gesture intent detected before lock (advisory). | `device`, `gesture`, `axis`, `confidence` |

### semadraw

Event types to be defined in D-1. The following types are specified here as
the target for D-1 implementation:

| Type | When emitted | Key additional fields |
|------|-------------|----------------------|
| `client_connected` | A client completes the HELLO handshake. | `client_id`, `client_version_major`, `client_version_minor` |
| `client_disconnected` | A client session ends. | `client_id`, `reason` (`"disconnect"` or `"error"`) |
| `surface_created` | A surface is created. | `client_id`, `surface_id`, `width`, `height` |
| `surface_destroyed` | A surface is destroyed. | `client_id`, `surface_id` |
| `frame_complete` | A frame is rendered and presented. | `surface_id`, `frame_number`, `backend`, `render_time_ns`, `ts_audio_samples` |

### drawfs

No event emission is planned for the kernel module at this time. drawfs
surfaces are managed by semadraw which emits `surface_created` and
`surface_destroyed` events.

---

## Wire format examples

### semaaud stream_begin

```json
{"type":"stream_begin","subsystem":"semaaud","session":"deadbeefcafebabe","seq":1,"ts_wall_ns":1712345678901234567,"ts_audio_samples":null,"target":"default","stream_id":1,"client_id":"cli-1","client_label":"stream-client-1","client_class":"interactive","client_origin":"local","uid":1001,"gid":1001,"authenticated":true,"policy":"allow","default_pcm":"/dev/dsp0","audiodev":"/dev/dsp0","mixerdev":"/dev/mixer0","sample_rate":48000,"channels":2,"sample_format":"s16le"}
```

### semainput mouse_move

```json
{"type":"mouse_move","subsystem":"semainput","session":"deadbeefcafebabe","seq":42,"ts_wall_ns":1712345678912345678,"ts_audio_samples":96012,"device":"pointer:rel-2-b2-w0-a0-t0-0","source":"/dev/input/event12","dx":3,"dy":-1}
```

### semadraw frame_complete

```json
{"type":"frame_complete","subsystem":"semadraw","session":"deadbeefcafebabe","seq":7,"ts_wall_ns":1712345679000000000,"ts_audio_samples":97600,"surface_id":1,"frame_number":120,"backend":"software","render_time_ns":2341567,"ts_audio_samples":97600}
```

---

## Validation

A conforming event line must:

1. Be valid JSON (parseable by `json.loads` in Python or equivalent).
2. Contain all six required fields with correct types.
3. Have `subsystem` set to one of the four known values.
4. Have `seq` strictly greater than the previous `seq` for the same subsystem
   within a single daemon lifetime.
5. Have `ts_wall_ns` as a signed integer (i64 range).
6. Have `ts_audio_samples` as either a non-negative integer or JSON `null`.

A simple validation command:

```sh
# Validate a stream of events from the inputfs ring. inputdump
# (semainput/zig-out/bin/inputdump pre-AD-2a-Phase-3 / inputfs/zig-out/bin/inputdump
# post-retirement) reads /var/run/sema/input/events and emits one JSON
# object per event on stdout. Pre-2026-05-08 the equivalent producer was
# `semainputd` (retired in AD-2a Phase 3).
inputdump | python3 -c "
import sys, json
for line in sys.stdin:
    e = json.loads(line)
    assert 'type' in e and 'subsystem' in e and 'session' in e
    assert 'seq' in e and 'ts_wall_ns' in e and 'ts_audio_samples' in e
    print('OK', e['type'])
"
```

---

## Implementation checklist

Each daemon adopts this schema in the following backlog items:

| Daemon | Backlog item | Status |
|--------|-------------|--------|
| semaaud | A-3 — Unified event log schema adoption | Open |
| semainput | I-1 — Unified event log schema adoption | Open |
| semadraw | D-1 — Event emission in unified schema | Open |
| drawfs | — | Not planned |

The `ts_audio_samples` field will be null in all daemons until S-4 (clock
publication) is implemented and I-3 (audio clock timestamping in semainput)
is complete.
