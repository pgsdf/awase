# Protocol Constants Namespace Convention

**Date**: 2026-05-04
**Scope**: `shared/protocol_constants.json`, `semadraw/src/ipc/protocol.zig`,
`drawfs/sys/dev/drawfs/drawfs_proto.h`
**Trigger**: ADR 0017 design pause; re-discovered during 0017-rev2 drafting.

## Summary

`shared/protocol_constants.json` defines two distinct protocols
(`drawfs_protocol` and `semadraw_ipc`) under separate top-level keys. Each
namespace is internally well-formed. Each declares the same numbering
convention (`Requests use 0x0xxx, Replies use 0x8xxx, Events use 0x9xxx`).
Because the convention is shared, identical hex values appear in both
namespaces with different meanings.

This is not a bug. Both protocols have the same shape (request/reply/event)
and the convention captures that shape. The protocols are correctly separated
in the JSON, in the generators, and in the consuming code. There is no
runtime collision.

What there *is* is a visual collision: a hex value like `0x9003` cannot be
read in isolation. It means `EVT_SURFACE_PRESENTED_REGION` in
`drawfs_protocol` and is currently unused in `semadraw_ipc`. A reader
encountering `0x9003` in conversation, in a commit message, in a code
comment, or in a chat log has no way to know which namespace is meant
without consulting the surrounding context.

This note records that the design is intentional, identifies the cost
(human-readable ambiguity, not machine ambiguity), and proposes whether
to leave it alone, change it, or formalize the as-is convention.

## Evidence

`shared/protocol_constants.json` top-level structure:

```
{
  "drawfs_protocol": {
    "message_types": {
      "_convention": "Requests use 0x0xxx, Replies use 0x8xxx, Events use 0x9xxx",
      "requests":  { "REQ_HELLO": 0x0001, "REQ_DISPLAY_LIST": 0x0010, ... },
      "replies":   { "RPL_OK": 0x8000, "RPL_HELLO": 0x8001, ... },
      "events":    { "EVT_SURFACE_PRESENTED": 0x9002,
                     "EVT_SURFACE_PRESENTED_REGION": 0x9003,
                     "EVT_KEY": 0x9010, "EVT_POINTER": 0x9011,
                     "EVT_SCROLL": 0x9012, "EVT_TOUCH": 0x9013 }
    }
  },
  "semadraw_ipc": {
    "message_types": {
      "_convention": "Requests use 0x0xxx, Replies use 0x8xxx, Events use 0x9xxx",
      "requests":  { "HELLO": 0x0001, "CREATE_SURFACE": 0x0010, ... },
      "replies":   { "HELLO_REPLY": 0x8001, "SURFACE_CREATED": 0x8010, ... },
      "events":    { "KEY_PRESS": 0x9001, "MOUSE_EVENT": 0x9002,
                     "CLIPBOARD_DATA": 0x9050 }
    }
  },
  "sdcs": { ... }
}
```

Generated outputs (`shared/_generated_files`):

  - `drawfs/sys/dev/drawfs/drawfs_proto.h` consumes `drawfs_protocol`.
  - `semadraw/src/ipc/protocol.zig` consumes `semadraw_ipc`.
  - `semadraw/src/sdcs.zig` consumes `sdcs`.

The two protocols never share a generated artifact. A constant value in
the Zig file refers exclusively to a `semadraw_ipc` member; a constant in
the C header refers exclusively to a `drawfs_protocol` member. Generation
boundaries enforce the separation correctly.

Visible collisions in the events block (the only category where both
protocols are populated overlappingly):

| Value     | drawfs_protocol               | semadraw_ipc      |
|-----------|-------------------------------|-------------------|
| `0x9001`  | (unused)                      | KEY_PRESS         |
| `0x9002`  | EVT_SURFACE_PRESENTED         | MOUSE_EVENT       |
| `0x9003`  | EVT_SURFACE_PRESENTED_REGION  | (unused)          |
| `0x9010`  | EVT_KEY                       | (unused)          |
| `0x9011`  | EVT_POINTER                   | (unused)          |
| `0x9012`  | EVT_SCROLL                    | (unused)          |
| `0x9013`  | EVT_TOUCH                     | (unused)          |
| `0x9050`  | (unused)                      | CLIPBOARD_DATA    |

`0x9001` and `0x9002` are concretely populated in both. Other values are
populated in one and free in the other.

The same overlap pattern holds for requests (`0x0001` is `REQ_HELLO` in
drawfs_protocol and `HELLO` in semadraw_ipc) and replies (`0x8001` is
`RPL_HELLO` in drawfs_protocol and `HELLO_REPLY` in semadraw_ipc). Every
populated value in one namespace either collides with or sits adjacent
to a populated value in the other.

## What this is not

Not a runtime collision. The protocols never share a wire, never share a
parser, never share a generated header. There is no reachable code path
where a `0x9002` byte sequence is ambiguously interpretable.

Not a generator bug. `shared/tools/gen_constants.py` correctly emits
namespace-specific outputs and never mixes constants across protocols.

Not a result of drift or accident. Both `_convention` strings are
identical and intentional. The shared numbering reflects the shared
shape (request/reply/event) of the two protocols.

## What this is

A documentation and human-communication hazard. Specifically:

  - In commit messages, pull request descriptions, and chat threads, a
    bare hex value carries no namespace marker. "Add `0x9020`" is
    unparseable without context.
  - In ADRs that touch both protocols, naming a value risks the
    reader picking the wrong namespace. ADR 0017's original choice of
    `0x9003` for `gesture_event` was made against the `semadraw_ipc`
    namespace (where it is free), but a reader checking the JSON
    encounters `0x9003` in `drawfs_protocol` first
    (`EVT_SURFACE_PRESENTED_REGION`) and concludes the value is taken.
    This is exactly what happened during the ADR 0017 design pause.
  - Search for a hex value in the repo returns hits in both namespaces;
    the reader must classify each result manually.
  - Future contributors who only know one of the two protocols may
    add constants that collide visibly even though they don't collide
    in code.

The cost is friction in human review and design conversation, not in
machine behaviour.

## Options

### Option 1: Accept as-is, document explicitly

Keep the shared numbering convention. The two namespaces have the same
shape; expressing that shape through a shared convention is honest. Add
a leading comment to `shared/protocol_constants.json` explaining that
identical hex values across the two top-level protocols are expected
and unambiguous within their generated outputs.

Add a similar comment to `_generated_files` in each generated artifact:

```c
// Constants in this file belong to the drawfs_protocol namespace.
// semadraw_ipc constants of the same numeric value have different
// meanings; see shared/protocol_constants.json.
```

ADRs and commit messages adopt the convention of always namespace-
qualifying hex values: "drawfs_protocol `0x9003`" or "semadraw_ipc
`0x9030`", never bare `0x9003`.

**Cost**: Discipline in review and writing. No code changes.
**Benefit**: Preserves the symmetry that motivated the original design.

### Option 2: Differentiate the high nibble per protocol

Reserve the existing range pattern (0x0xxx / 0x8xxx / 0x9xxx) for one
protocol and shift the other to a non-overlapping range. Concretely:

  - Keep `drawfs_protocol` on `0x0xxx / 0x8xxx / 0x9xxx`.
  - Shift `semadraw_ipc` to `0x1xxx / 0x9xxx-with-high-bit / 0xAxxx` or
    similar, so no two values can collide.

This requires:

  - Editing every constant in one of the two namespaces in the JSON.
  - Regenerating both artifacts (no source-code edits required if the
    pipeline works).
  - Updating any code, ADR, or doc that names a specific constant by
    value rather than by name. (Code that uses `MsgType.mouse_event`
    survives; code that hard-codes `0x9002` would break.)

**Cost**: Mass renumbering, large patch, breaks any external consumer
that hard-codes a value (none exist today, but the patch is still
intrusive). Loses the symmetry between the two protocols.
**Benefit**: A bare hex value is unambiguously namespaced. Search,
review, and conversation all become unambiguous.

### Option 3: Prefix the constant names per protocol

Keep the numbering shared. Disambiguate at the symbol level instead:

  - `drawfs_protocol` constants stay as `REQ_*`, `RPL_*`, `EVT_*`
    (already the case in the JSON).
  - `semadraw_ipc` constants become `IPC_REQ_*`, `IPC_RPL_*`,
    `IPC_EVT_*` (currently `HELLO`, `MOUSE_EVENT`, etc., with no
    namespace prefix).

The Zig output would gain the prefix; the C output already has one
(`drawfs_*`).

This requires:

  - Renaming every `semadraw_ipc` constant in the JSON.
  - Regenerating `semadraw/src/ipc/protocol.zig`.
  - Updating every Zig source file that names a `MsgType` member, since
    `MsgType.mouse_event` becomes `MsgType.ipc_mouse_event` or similar.

**Cost**: Renames spread across the semadraw tree. Symbol-level churn
in source code. Search-and-replace is mechanical but touches many
files.
**Benefit**: Symbol names carry their namespace; bare hex values still
collide but are less commonly used than symbol names in actual code.

### Option 4 (rejected): Unify into a single namespace

Merge `drawfs_protocol` and `semadraw_ipc` into one numbering space, so
no two constants share a value. This was considered and rejected:

  - The two protocols have different consumers (kernel module ↔
    userspace, vs. daemon ↔ client) and different evolution pressures.
  - Forcing a shared space couples their evolution: adding a request
    to semadraw_ipc would require checking drawfs_protocol's space.
  - The current separation is architecturally honest. Unifying would
    encode a false coupling.

## Recommendation

**Option 1**, with the discipline of namespace-qualified writing.

The runtime separation is correct. The cost of Options 2 and 3 is
non-trivial — broad renaming, generated-artifact churn, and risk of
breaking external consumers — and the benefit is mostly cosmetic. The
ADR 0017 confusion that triggered this note was a single instance of a
recurring writing-discipline failure (naming a hex value without its
namespace), not a structural problem. The fix is to write more
carefully, not to renumber.

Concretely:

  - Add a leading comment to `shared/protocol_constants.json`:

    ```json
    "_namespace_note": "Top-level keys (drawfs_protocol, semadraw_ipc, sdcs) define independent namespaces. Identical hex values across namespaces have different meanings and never share a wire or generator. When citing a constant value in prose, always qualify with namespace: 'drawfs_protocol 0x9003' or 'semadraw_ipc 0x9030'."
    ```

  - Add a header comment to `semadraw/src/ipc/protocol.zig` (in the
    generator template, so it survives regeneration):

    ```zig
    //! Constants in this file belong to the semadraw_ipc namespace.
    //! drawfs_protocol uses overlapping numeric values for different
    //! purposes; see shared/protocol_constants.json.
    ```

  - Add the equivalent header to `drawfs/sys/dev/drawfs/drawfs_proto.h`.

  - Adopt the namespace-qualified citation discipline in ADRs, commit
    messages, and design discussions going forward. ADR 0017-rev2
    already does this implicitly (`semadraw_ipc 0x9030` for
    `gesture_event`); make it explicit in the writing-style note in
    `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`.

If a future event makes Option 2 or 3 worthwhile (e.g. a third protocol
joins the JSON and the visual collision count grows past tolerable),
revisit. As of 2026-05-04 the cost-benefit doesn't justify the churn.

## References

  - `shared/protocol_constants.json` — the canonical source of both
    namespaces.
  - `shared/tools/gen_constants.py` — the generator that consumes the
    JSON and emits per-namespace artifacts.
  - `inputfs/docs/adr/0017-gesture-event-wire-format-and-routing.md`
    (original) — picked `0x9003` against `semadraw_ipc`, surfaced the
    visual-collision problem during design review.
  - `inputfs/docs/adr/0017-rev2-gesture-event-wire-format-and-routing.md`
    — revised to `0x9030` and references this note.
  - `docs/PROTOCOL_MISMATCH_FINDINGS.md` — earlier protocol audit,
    different scope (drawfs C/spec mismatches), useful prior art for
    investigation tone.
