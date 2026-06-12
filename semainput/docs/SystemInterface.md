# System interface

**Archived 2026-05-08.** This document specified the JSON-line
output schema emitted by `semainputd` on stdout. The daemon
was retired in AD-2a Phase 3 step 2; the JSON-line output
channel no longer exists in the live system.

## Where the schema lives now

The wire-level event schema is now `shared/EVENT_SCHEMA.md` and
the in-memory event types are defined in `shared/src/input.zig`.
inputfs publishes events directly into a shared-memory ring at
`/var/run/sema/input/events`; semadrawd consumes them via
`semadraw/src/backend/inputfs_input.zig`. There is no
JSON-line intermediate.

For diagnostic JSON output equivalent to what semainputd once
produced, run `inputdump` (built from `inputfs/src/`), which
reads the ring and emits one JSON object per event on stdout.
The JSON shape matches `shared/EVENT_SCHEMA.md`.

## Pre-retirement examples (historical)

The samples below illustrate what `semainputd | jq …` produced
before retirement. They are kept so external scripts that
parsed this output can recognise the format.

### Semantic events

```json
{"type":"mouse_move","device":"pointer:rel-2-b2-w0-a0-t0-0","source":"/dev/input/event12","dx":1,"dy":0}
{"type":"touch_down","device":"touch:rel-0-b0-w0-a2-t3-0","source":"/dev/input/event17","contact":165,"x":514,"y":681}
{"type":"mouse_button","device":"button-source:rel-0-b1-w0-a0-t0-0","source":"/dev/input/event14","button":"right","state":"up"}
```

### Gesture events

```json
{"type":"two_finger_scroll","device":"touch:rel-0-b0-w0-a2-t3-0","dx":1,"dy":-6}
{"type":"drag_start","device":"touch:rel-0-b0-w0-a2-t3-0","contact":166,"x":813,"y":281}
{"type":"drag_move","device":"touch:rel-0-b0-w0-a2-t3-0","contact":166,"x":852,"y":443}
{"type":"drag_end","device":"touch:rel-0-b0-w0-a2-t3-0","contact":166,"x":901,"y":561}
{"type":"tap","device":"touch:rel-0-b0-w0-a2-t3-0","contact":170,"x":733,"y":412}
```

### Keyboard events

```json
{"type":"key_down","subsystem":"semainput","session":"...","seq":N,"ts_wall_ns":N,"ts_audio_samples":null,"device":"keyboard:key-0-b0-w0-a0-t0-0","source":"/dev/input/event0","code":30}
{"type":"key_up","subsystem":"semainput","session":"...","seq":N,"ts_wall_ns":N,"ts_audio_samples":null,"device":"keyboard:key-0-b0-w0-a0-t0-0","source":"/dev/input/event0","code":30}
```

`code` carried the evdev key code (KEY_A = 30, KEY_ENTER = 28,
KEY_ESC = 1, KEY_SPACE = 57, KEY_LEFT = 105, KEY_RIGHT = 106,
KEY_UP = 103, KEY_DOWN = 108).

evdev's `value=2` autorepeat events were silently suppressed;
only `value=1` (press) emitted `key_down` and `value=0`
(release) emitted `key_up`. inputfs preserves this behaviour.

### Audio sample timestamping

`ts_audio_samples` was the audio sample position at the moment
of event emission, read from the shared clock region at
`/var/run/sema/clock` (S-4):

- **Non-null**: semaaud was running and at least one PCM stream
  had started.
- **null**: semaaud was not running, the clock file was absent,
  or no audio stream had started yet (`clock_valid == 0`).

The clock-opening logic moved into inputfs; the semantics are
unchanged. Events in the inputfs ring carry `ts_sync` in the
same role.
