# 0010 Per-Device Role Classification (Stage B.5)

## Status

Proposed

## Context

ADR 0004 fixed the role taxonomy: a closed set of five semantic roles
(`pointer`, `keyboard`, `touch`, `pen`, `lighting`), with explicit
event variants per role, routing rules, and a closed-set discipline
that requires an ADR revision to add a new role. ADR 0004 § Notes line
134 explicitly defers enumeration granularity to Stage B:

> Enumeration granularity is a Stage B concern, not a taxonomy
> concern.

The `inputfs-proposal.md` (line 173) commits to classification at
enumeration time as a kernel concern, not a userspace reconstruction:

> `inputfs` classifies each attached device into a role at
> enumeration time: `pointer`, `keyboard`, `touch`, `pen`, `gamepad`,
> `unknown`. Role assignment is a first-class kernel concern, not a
> userspace reconstruction from capability bitmaps.

Stage B.4 (ADR 0009) registered an interrupt handler and verified
that reports flow from real hardware. The driver matches a TLC at
probe and prints a transient `kind` string at attach time. What is
missing is a **stable, queryable representation** of role membership
stored on the softc, suitable for Stage C dispatch (which event
variants this device produces) and any future ioctl/query path that
reports per-device role membership to userspace.

This ADR specifies the classification mechanism, the on-softc encoding,
and the scope boundary between B.5 and later stages.

## Decision

### 1. Encoding

The softc gains one new field:

```c
uint8_t sc_roles;   /* bitmask of INPUTFS_ROLE_* */
```

Five role bits are defined, one per role in ADR 0004's closed set.
All five are defined now even though only two are populated by this
stage's classifier; the encoding is stable from the outset so Stage C
and later ioctl paths do not have to re-version it:

```c
#define INPUTFS_ROLE_POINTER    (1u << 0)
#define INPUTFS_ROLE_KEYBOARD   (1u << 1)
#define INPUTFS_ROLE_TOUCH      (1u << 2)
#define INPUTFS_ROLE_PEN        (1u << 3)
#define INPUTFS_ROLE_LIGHTING   (1u << 4)
```

Bit positions follow the order roles are listed in ADR 0004 § Decision
item 1. The remaining three bits of `sc_roles` are reserved and must
be zero. `sc_roles == 0` is a valid state (see Decision item 4).

### 2. Classification signal

Classification uses the single TLC matched at probe time, retrieved
via `hidbus_get_usage(dev)` and decomposed with `HID_GET_USAGE`.

The existing attach path already consumes this signal: the `kind`
switch in `inputfs_attach` maps the matched TLC to a transient stack
string (`"keyboard"`, `"mouse"`, `"pointer"`, `"unknown"`) printed in
the attach line. That switch is, in effect, the classification
decision in a different shape. What it produces is a **device-class**
label, not a **role** label; B.5 reframes the same signal as a role
bitmask stored persistently on the softc.

In the current TLC match table, device class and role happen to
align: a `HUG_KEYBOARD` TLC always means a keyboard-role device, and
`HUG_MOUSE`/`HUG_POINTER` always mean a pointer-role device. This
coincidence is what makes TLC-only classification cheap. The rule
is a direct table lookup with no further descriptor inspection. The
alignment will not hold once the match table grows: a digitizer TLC
under `HUP_DIGITIZERS` may produce touch-role *or* pen-role events
depending on its sub-collections, and a gamepad TLC will be a device
class with no current role at all. When those cases arrive, the
classifier becomes more than a TLC lookup, but the role bitmask is
already the right destination shape.

The classification rule:

| Matched TLC usage | Role bit set                  |
|-------------------|-------------------------------|
| `HUG_KEYBOARD`    | `INPUTFS_ROLE_KEYBOARD`       |
| `HUG_MOUSE`       | `INPUTFS_ROLE_POINTER`        |
| `HUG_POINTER`     | `INPUTFS_ROLE_POINTER`        |
| anything else     | none (`sc_roles` remains `0`) |

The descriptor walk results from B.3 (`sc_input_items`,
`sc_output_items`, `sc_feature_items`, `sc_collection_depth`) are
**not** consulted. B.5 deliberately does not reopen the descriptor
walker; see Rationale § Alternatives.


### 3. Classification site

Classification runs once, in `inputfs_attach`, after the descriptor
walk and interrupt registration succeed. A new helper:

```c
static void inputfs_classify_roles(struct inputfs_softc *sc);
```

reads `hidbus_get_usage(sc->sc_dev)`, applies the rule above, and
writes the result to `sc->sc_roles`. The helper is called exactly
once per attach. There is no reclassification path; if a device's
role membership were to change during its lifetime, that would
require a detach/reattach cycle, which is consistent with how all
other softc state is managed.

### 4. Empty role set is valid

A device with `sc_roles == 0` is fully attached, has its descriptor
walked, has its interrupt callback registered, and may produce
reports; it produces no events visible to userspace clients,
because no role currently covers its event variants. This matches
ADR 0004 § Decision item 6's rule for gamepad ("attaches and
enumerates at Stage B without producing events"). The empty-role
state is a feature, not an error: it lets future stages widen the
TLC match table to include digitizers, gamepads, or other classes
without forcing the role taxonomy to grow first.

The current TLC match table (Generic Desktop keyboard, mouse,
pointer) means no device that successfully attaches today falls into
the empty-role state. The state exists in the encoding so that when
the match table widens, no schema change is needed.

### 5. Logging

A single `device_printf` line is added at the end of attach,
immediately after the existing B.4 attach trailer, summarizing the
role set in a grep-friendly format:

```
inputfs0: roles=pointer
inputfs0: roles=keyboard
inputfs0: roles=<none>
```

For composite role sets (not produced by this stage but reachable
once the encoding admits multi-bit values):

```
inputfs0: roles=pointer,keyboard
```

Format: comma-separated lowercase role names in ascending bit-position
order (`pointer,keyboard,touch,pen,lighting`), or the literal `<none>`
when `sc_roles == 0`. The bit-order rule is a stable invariant of the
formatter, not a consequence of the implementation: the formatter
walks the bits in fixed order regardless of how `sc_roles` was
constructed, so the output for a given bitmask is deterministic and
greppable. The format mirrors the lowercase identifiers fixed in ADR
0004 § Notes.

### 6. Scope deferrals

This ADR explicitly defers, to later ADRs:

- **Touch and pen classification.** Devices on the HID Digitizer
  usage page (`HUP_DIGITIZERS`) do not match the current TLC table
  and therefore do not attach today. Growing the match table to
  include digitizers, and the corresponding extension of the
  classification rule, is a separate stage.
- **Gamepad classification.** ADR 0004 § Decision item 6 keeps
  gamepad in scope as hardware but defers its role definition.
  The current encoding has no gamepad bit; gamepad devices, when
  they attach in a later stage, will land in the empty-role state
  per Decision item 4 until a gamepad role is added by a future
  revision of ADR 0004.
- **Lighting classification.** ADR 0004 § Consequences item 4
  defers the lighting *mechanism* to a companion spec. Lighting is
  a consumer direction, driven by `hid_output` items, not a
  producer-side classification from a TLC. The lighting bit is
  reserved in the encoding but is never set by B.5's classifier.
  The companion lighting spec, when it lands, will own the rule for
  setting the bit.
- **Full-descriptor TLC enumeration.** A device with multiple
  TLCs in one HID interface (a hypothetical mouse + keyboard +
  lighting composite reported as a single hidbus child) is not
  handled. See Rationale § Alternatives.

## Rationale

### Why classify at attach, not lazily

The proposal commits to classification as a first-class kernel
concern at enumeration time. Classifying at attach ties role
membership to the same lifetime as the softc, removes any race
between report arrival and role determination, and makes the role
set visible to any future ioctl that enumerates devices without
that ioctl having to trigger work.

### Why a bitmask, not an enum

A device may legitimately carry more than one role (composite cases
admitted by ADR 0004 § Notes line 127). An enum would not encode
that. The bitmask costs one byte and admits the union directly.

### Alternatives considered

**A. TLC-only classification (chosen).** Read the matched TLC from
`hidbus_get_usage`, switch on it, set the corresponding bit. Cost:
roughly twenty lines of code, no new HID API surface, no new state.
Composite-in-one-softc devices are not detected; each composite
softc carries the role of its single matched TLC.

**B. Full-descriptor-walk classification (rejected for B.5).** Walk
the report descriptor and record the usage of every collection
encountered, not just the one matched at probe. Set role bits for
the union of all top-level collections seen. This is strictly more
expressive: a USB device that exposes a mouse TLC and a keyboard
TLC under one hidbus child would classify as `pointer,keyboard`
rather than as whichever TLC happened to match first.

The rejection reasons:

1. hidbus already splits multi-interface devices (the common
   composite case: unifying receivers, gaming mice with separate
   keyboard interfaces) across separate softcs at the USB
   interface level. Each child arrives at inputfs with its own
   TLC. The TLC-only path classifies these correctly without
   walking.
2. The genuinely-single-softc composite (multiple TLCs in one
   interface descriptor) has not appeared in any device tested
   against B.1–B.4. There is no current hardware to validate
   alternative B against.
3. Alternative B would require extending the B.3 descriptor walker
   to record per-collection usages, a non-trivial change to a
   subsystem that just stabilized. The walker today counts items
   per kind; recording usages adds state and a new exit shape.
4. If single-softc multi-TLC devices appear later, the TLC-only
   classifier reads as "set role bits for the matched TLC," and
   the extension reads as "set role bits for every TLC walked."
   That extension is mechanical and ADR-shaped; it is exactly the
   kind of change a future stage should land deliberately rather
   than absorb opportunistically here.

**C. Lazy classification on first report (rejected).** Defer
classification until the interrupt handler fires, infer role from
report shape. Loses the proposal's commitment to attach-time
classification, introduces a transient pre-classified state that
Stage C dispatch would have to handle, and gains nothing in return:
the matched TLC is already known at attach with no extra cost.

## Consequences

1. The softc grows by one byte (`sc_roles`). No alignment impact:
   the field packs after the existing `uint8_t sc_report_id`.
2. Stage C dispatch can branch on `sc->sc_roles` to choose which
   event variants this device produces, without re-deriving the
   information from `hidbus_get_usage` or the descriptor.
3. A future per-device-query ioctl can return `sc_roles` directly
   as the role membership field; the encoding is the wire encoding.
4. The TLC match table (`inputfs_devs[]`) is unchanged. Touch, pen,
   gamepad, and lighting devices remain unattachable until the
   match table grows in a later stage. The empty-role state is
   reachable today only as a defensive default in the classifier;
   no live device produces it.
5. The `kind` string in the existing attach line and the new
   `roles=` line carry related but distinct information: `kind` is
   the device-class label derived from the matched TLC, while
   `roles=` is the semantic role membership. They coincide today
   because the current TLC match table only admits cases where
   class and role align. The two are kept as separate lines to
   preserve B.2's verified attach output and to keep the device-
   class label available once it stops aligning with role (see
   Decision § 2). No future cleanup should collapse them.

## Stage B.5 Scope

In scope:

- Add `sc_roles` field and the five `INPUTFS_ROLE_*` macros.
- Add `inputfs_classify_roles(sc)` helper.
- Call the helper once at the end of `inputfs_attach`, after the
  B.4 interrupt registration succeeds.
- Add the `roles=` `device_printf` line.
- Update `inputfs/docs/adr/README.md` (if present) to list ADR 0010.

Out of scope:

- TLC match table changes.
- Descriptor-walk extensions.
- Stage C event dispatch reading `sc_roles`.
- ioctl exposure of `sc_roles` to userspace.
- Any change to ADR 0004's taxonomy.

## Implementation Plan

1. Add the five role macros and the `sc_roles` field to
   `inputfs/sys/dev/inputfs/inputfs.c` (or its header if one exists
   by then; current code keeps softc and macros in the .c file).
2. Implement `inputfs_classify_roles` immediately above
   `inputfs_attach`. The function reads
   `hidbus_get_usage(sc->sc_dev)`, switches on `HID_GET_USAGE(usage)`,
   and sets bits.
3. Implement a small `inputfs_format_roles(uint8_t roles, char *buf,
   size_t buflen)` helper that writes the comma-separated role names
   or the literal `<none>` into `buf`. Bounded by a fixed-size local
   buffer in `inputfs_attach` (the longest possible string is
   `pointer,keyboard,touch,pen,lighting` = 35 chars + NUL).
4. Call `inputfs_classify_roles(sc)` at the end of `inputfs_attach`,
   followed by a single `device_printf(dev, "inputfs: roles=%s\n",
   buf)`.
5. No detach-side change: `sc_roles` is plain data on the softc and
   is freed with the softc.

## Testing

Verification platform: a FreeBSD VirtualBox VM with a physical
USB mouse passed through to the guest, matching the platform used
for B.4 verification.

Acceptance signals:

1. `kldload inputfs` and physically present a USB mouse: dmesg
   shows `inputfs0: roles=pointer`.
2. Same with a USB keyboard passed through (HID boot keyboard or
   a regular USB keyboard exposing `HUG_KEYBOARD`): dmesg shows
   `inputfs0: roles=keyboard`.
3. `kldunload inputfs` succeeds with no warnings, matching B.4's
   clean-unload signal.
4. The pre-existing B.4 raw-report logging continues to fire after
   B.5 lands; classification does not interfere with the interrupt
   path.

No new automated test infrastructure is added at this stage; the
verification protocol matches B.2 through B.4 (live dmesg
inspection on a real FreeBSD VM with real or passed-through HID
devices).

## Notes

The role encoding values are part of the inputfs ABI from the
moment Stage C reads them. Reordering bits, repurposing reserved
bits, or changing the wire shape requires an ADR revision once
Stage C ships; until then the encoding is malleable. The point of
defining all five bits in B.5 rather than two is precisely to
freeze the encoding before Stage C makes it permanent.

The `roles=<none>` literal uses angle brackets to distinguish the
empty-set case from a hypothetical role literally named `none`.
ADR 0004's closed set has no such role, but the literal pattern
follows the convention used elsewhere in BSD kernel logging for
sentinel values.

## Errata to inputfs-proposal

The proposal (`inputfs/docs/inputfs-proposal.md` line 174) lists six
role candidates: `pointer`, `keyboard`, `touch`, `pen`, `gamepad`,
`unknown`. ADR 0004 refined this to a closed set of five
producer/consumer roles with explicit handling for the cases the
proposal's two extra entries were trying to express:

- `gamepad`: kept in scope as hardware, deferred as a role. Gamepad
  devices enumerate with an empty role set and produce no events
  until a gamepad role is added by a future revision of ADR 0004.
- `unknown`: not a role. A device that does not match any role
  classifier carries `sc_roles == 0`, the empty role set. The
  proposal's "unknown" was effectively a placeholder for this
  empty-set state.

ADR 0010 adopts ADR 0004's model. Where the proposal's wording
conflicts with ADR 0004 or this ADR, ADR 0004 and ADR 0010 govern.
This errata note is the same lightweight housekeeping pattern as
ADR 0008 § Errata.
