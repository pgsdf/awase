# 0019 inputfs → kbdmux Bridge for vt(4) Console Login

## Status

Implemented (2026-05-09). Tracks AD-10.5 (the keystroke-handover
sub-stage of AD-10) and supersedes the design notes preserved in
the AD-28 (original) BACKLOG entry.

The 8-step implementation outline below was followed; one additional
step (2.5) added extended-key 0xE0 prefix encoding for arrow keys,
Right Ctrl/Alt/GUI, Home/End/PgUp/PgDn, Insert/Delete, keypad-Enter,
and keypad-/. Bridge is bench-verified working on
pgsd-bare-metal-test-machine (HAILUCK touchpad keyboard, Broadcom
Bluetooth keyboard, Apple Aluminum keyboard); console login at ttyv0
works through inputfs->kbdmux->vt(4) with hw.inputfs.kbdmux_bridge=1
(default since step 8).

History note: initial Proposed 2026-05-08, implementation begun the
same day, completed 2026-05-09 over multiple sessions. Two
debugging cycles inside the implementation (step 4a's SI_ORDER and
success-check bugs; step 4b's WITNESS-caught sleep-mutex-from-spin
bug) are preserved in commit history rather than retold in this
ADR; see BACKLOG.md AD-10.5 for the per-step closure log.

### Post-AD-39 disposition (added 2026-05-27 evening)

This ADR was written 2026-05-09 against a world where `vt(4)` is
compiled into the PGSD kernel and consumes the bridge's scancode
stream via kbdmux. AD-39 (closed 2026-05-13/14, BACKLOG.md
line 9929) changed that world: `vt`, `vt_efifb`, `vt_vbefb`,
`vt_vga`, `sc`, `vga`, `splash` are now compiled out of the PGSD
kernel config. `kbdmux` itself is retained because the ADR's
bridge code refers to it at the kbd-layer protocol level, but the
*consumer* the bridge was designed to feed - vt(4) at
ttyv0..ttyvN - no longer exists on PGSD.

The bridge therefore publishes AT scancodes into a kbdmux that has
no reader on PGSD systems. Concretely:

  - `inputfs_kbd_intr_cb` runs on every keystroke (HID->AT
    translation, push to lockless ring, taskqueue enqueue).
  - `inputfs_kbd_notify_task` runs in interrupt-thread context,
    acquires Giant, calls kbdmux's KBDIO_KEYINPUT callback.
  - kbdmux's callback runs, but with no opened reader of
    `/dev/kbdmux0` the keystrokes get held in the bridge's ring
    until the bridge's 1024-entry buffer fills, after which they
    are silently dropped by `inputfs_kbd_put_key` (see line 441
    of this file).

Cost on PGSD: small but non-zero. A Giant acquire + a couple of
layers of kbd-subsystem book-keeping per keystroke. At normal
typing rates this is invisible. The more interesting concern is
*surface area*: the bridge is code that runs on every keystroke
under spin-mutex context, with no consumer, in a kernel where
panic is not visible on the display (per AD-39). A bug in the
bridge code path would be hard to diagnose.

The choice taken 2026-05-27 evening (after the audit prompted by
the "is drawfs replacing vt(4) and efifb?" question): **leave the
bridge enabled by default, document the situation, file a
follow-up entry to revisit later.** The full reasoning is in
BACKLOG.md AD-44; the short version is that there is no observed
harm yet, the cost is small, and changing the default risks
silently breaking non-PGSD users who run the same `inputfs.ko`
with vt(4) still in their kernel. If a kernel panic is traced to
the bridge path, or if benching shows the per-keystroke cost
matters, AD-44's revisit criteria would trigger Option B (default
to off) or Option C (compile-out gate).

This addendum does not change anything in the body of the ADR
below (Context, Decision, Consequences, Implementation outline).
Those still describe accurately what the bridge does and how it
was built. The addendum records the post-AD-39 environment that
the bridge now runs in, which differs from the world the
original ADR was written against.

## Context

Two prior bench states bracket the problem this ADR addresses.

**State A (before 2026-05-08 morning).** `pgsd-bare-metal-test-machine`
was running PGSD-DEBUG with `hkbd.ko` loaded as a kld (drift from
AD-8's WITHOUT_MODULES discipline, see AD-30). Three keyboards
attached via hkbd: HAILUCK touchpad keyboard, Broadcom Bluetooth,
Apple Aluminum Mini Keyboard. Each registered a `/dev/kbd<N>` device
which kbdmux aggregated into `/dev/kbdmux0`, feeding vt(4)'s console
keystroke pipeline. Console login at ttyv0 worked. inputfs was
loaded but losing every hidbus probe race — attached to zero HID
devices. UTF input pipeline was dead.

**State B (after 2026-05-08 AD-30.1 recovery).** Legacy HID modules
removed from `/boot/kernel/`. inputfs wins every probe, attaches to
six HID TLCs, publishes a valid state region. UTF input pipeline
fully alive: trackpad and mouse both drive the cursor. Console login
at ttyv0 stopped working: vt(4) has no keystroke producer. SSH from
another machine became the only login path.

The two states are the two stable configurations of the FreeBSD
keyboard pipeline: one delivers keystrokes to vt(4) via hkbd→kbdmux,
the other delivers them to the UTF compositor via inputfs's event
ring. Neither delivers to both.

State C — keystrokes reach both vt(4) and inputfs's compositor —
is the operational target. AD-10.5 (this ADR) describes how to get
there at the kernel layer: a bridge driver that registers itself
with kbdmux as a keyboard producer, observes keyboard transitions
already computed by inputfs's existing keyboard diff path, and
pushes the corresponding AT scancodes into a ring buffer that
kbdmux drains. inputfs continues to publish its own
`keyboard.key_down` / `keyboard.key_up` events to the event ring
unchanged; the bridge is purely additive.

The relationship to AD-10's larger scope: AD-10 covers two
independent vt(4) cooperation surfaces — framebuffer ownership
(AD-10.1-.4) and keystroke handover (AD-10.5). The framebuffer side
is about preventing kernel log spam from drawing over UTF surfaces;
the keystroke side is about ensuring vt(4) gets keystrokes when
it's the active output (i.e., when drawfs has not taken over the
framebuffer). They land independently. This ADR addresses only
the keystroke side.

The relationship to the AD-28 closure (2026-05-08, commit `0a0da8f`):
AD-28 was closed because the bench state at that time had hkbd
loaded, kbdmux's pipeline alive, and console login working. The
closure note observed that the pipeline existed and concluded "no
bridge to build." That observation was correct for State A. State B
inverts the conclusion: with hkbd absent, the bridge is necessary.
The AD-28 (original) entry's pre-implementation source-reading
work — `kbd_register` / `kbdsw` notes, ukbd structural reference,
HID-to-AT translation table — remains valid and informs this ADR.

## Decision

### 1. Bridge as a kbd-layer keyboard driver

The bridge presents to FreeBSD's `sys/dev/kbd/` keyboard layer as
a keyboard driver named `inputfs_kbd`. It implements the
`keyboard_switch` (`kbdsw`) vtable defined in `sys/dev/kbd/kbdreg.h`,
identical in shape to `ukbd(4)`'s `ukbdsw` (defined in
`sys/dev/usb/input/ukbd.c:2199-2217`) but with inputfs's HID
interrupt path as the producer instead of usbhid.

Why ukbd as the structural reference: ukbd is the most direct
existing analogue. Both ukbd and the bridge sit downstream of a HID
parser and feed kbdmux. ukbd's per-keyboard softc layout, ring
buffer mechanics, modifier-state tracking, and HID-to-AT translation
table are battle-tested in production FreeBSD; the bridge inherits
the same shape so the surface area for novel bugs is minimised.

Why not extending hkbd: hkbd is the driver inputfs displaces. The
bridge is fundamentally a userland-facing shim, not a HID-layer
driver, and lives in inputfs's tree because its data source is
inputfs's HID interrupt path.

### 2. kbd_register-driven auto-discovery

When a successful `kbd_register` call lands a new keyboard with the
kbd layer, kbd.c at line 226-232 issues `KBADDKBD` to any existing
kbdmux instance, automatically attaching the new keyboard as a
kbdmux slave. No userland configuration, no rc.d hook, no
`kbdcontrol` invocation required.

The bridge calls `kbd_register` once per inputfs keyboard device.
Specifically: at the end of inputfs's keyboard-classified attach
path (currently the site that emits the `attached HID keyboard ...`
log line at `inputfs.c:3702`), if the bridge sysctl is enabled and
the device's role bitmask includes `INPUTFS_ROLE_KEYBOARD`, the
bridge allocates a per-keyboard softc, fills in the kbdsw vtable,
and calls `kbd_register`. On detach, the bridge calls
`kbd_unregister` to release the kbdmux slave slot.

Load-order dependency: kbdmux must already be present when inputfs
attaches its first keyboard. kbdmux is in the base kernel
(`sys/dev/kbd/kbdmux.c`) and inputfs is a kld module loaded later;
this ordering is automatic on every PGSD bench configuration. No
additional sequencing logic needed.

### 3. K_RAW slave model

kbdmux sets each registered slave to K_RAW mode via
`kbdd_ioctl(kbd, KDSKBMODE, &K_RAW)` after allocation
(`kbdmux.c:1020-1022`). Slaves return raw AT scancodes; kbdmux owns
the keymap and performs the K_RAW → K_CODE → K_XLATE translation
in its own `read_char`.

The bridge therefore returns AT scancodes from `read_char`, not
character codes. HID usage codes from inputfs's keyboard parser
(usage page 0x07: HID Keyboard/Keypad) are translated to AT
scancodes via a static 256-entry table mirroring `ukbd_trtab[256]`
(`ukbd.c:255-288`). The translation is verbatim from ukbd; the HID
Keyboard/Keypad usage page is universal across HID keyboards, so
the table works unchanged.

`UKBD_EMULATE_ATSCANCODE` (`ukbd.c:1654-1664`) is the relevant code
path in ukbd: a single HID transition produces a sequence of
1-3 AT scancode bytes (modifiers may produce extended codes
prefixed with 0xE0). The bridge ports this logic verbatim.

### 4. Hooking inputfs's keyboard diff path

The natural integration point is `inputfs_keyboard_diff_emit`
(`inputfs.c:2604`). This function already computes the bitmap diff
between previous and current modifier byte and key array, and
emits one `keyboard.key_up` or `keyboard.key_down` event per
transition to inputfs's event ring. The bridge observes the same
transitions and pushes the AT scancode equivalent into its own
per-keyboard ring buffer.

Implementation shape: `inputfs_keyboard_diff_emit` calls the bridge
once per transition with `(softc, hid_usage, is_down, modifiers)`.
The bridge translates `hid_usage` to AT scancode(s) via the trtab,
calls `put_key` to enqueue them, then signals kbdmux via the
registered `kb_callback` that data is available. kbdmux's task
queue drains the ring on its own schedule.

This is cleaner than ukbd's approach in one respect: ukbd does its
own bitmap diff inside its interrupt handler. Here the diff is
already computed by inputfs's keyboard parser; the bridge sees
each transition exactly once. No risk of double-emission from a
diff misalignment.

### 5. Locking model

`sys/dev/kbd/kbd.c` requires Giant for nearly every kbd-layer call
(`GIANT_REQUIRED` annotations at `kbd.c:101, 246, 330, 353, 375,
533, 563, 587, 658, 801`, et al.). ukbd handles this by using Giant
as its primary lock (`UKBD_LOCK = mtx_lock(&Giant)`,
`ukbd.c:234-236`). The bridge inherits the same constraint by
necessity — `kbd_register` itself cannot be called without Giant.

inputfs's HID interrupt path runs under `inputfs_state_mtx`
(MTX_SPIN, designed for interrupt context). Acquiring Giant
(MTX_DEF) from a spin-mutex context is a lock-order violation
that WITNESS will flag. The bridge therefore cannot push to
kbdmux directly from inputfs's interrupt path.

Solution: defer the bridge work to a taskqueue. The interrupt path
populates the bridge's per-keyboard ring buffer (which is local to
the bridge softc, not shared with kbd-layer state) under
`inputfs_state_mtx`, then schedules a taskqueue task. The task
runs at process context, takes Giant, calls the kb_callback to
notify kbdmux. kbdmux drains the ring on its own task at its
own schedule.

The taskqueue introduces ~one tick of latency (typically 1-10ms
on FreeBSD's `taskqueue_swi` queue). For console keystrokes this
is imperceptible; vt(4)'s own line-discipline batching is
coarser-grained.

The defer-via-taskqueue pattern is the standard FreeBSD idiom for
moving work from interrupt context to a context that can take
sleeping locks, used widely in the network stack and elsewhere.

### 6. Sysctl gating

The bridge is gated by `hw.inputfs.kbdmux_bridge`, default 0
(disabled) for the first commit. Same convention as inputfs's
existing sysctls (`hw.inputfs.debug_descriptor`,
`hw.inputfs.debug_reports`, `hw.inputfs.enable`).

When the sysctl is 0 at attach time, `kbd_register` is not called;
the bridge's per-keyboard softc is not allocated; the diff-path
hook is a no-op. inputfs's existing event-ring keyboard publication
continues unchanged. No bridge presence in `/dev/kbd*` listings;
no kbdmux slaves added.

When the sysctl is flipped from 0 to 1 at runtime, the change takes
effect on the *next* attach. Already-attached keyboards are not
retroactively bridged. Operator workflow: set the sysctl, then
reload inputfs (`kldunload inputfs; kldload inputfs`) or reboot.
This avoids a class of edge cases where the sysctl flip happens
mid-keystroke and the bridge state machine is in an unknown
condition; restart-on-flip is simpler and safer.

When the sysctl is flipped from 1 to 0, the inverse: the bridge
keeps existing slaves registered until detach. New keyboards
attached after the flip do not register with kbd-layer.

The default-off-then-default-on flip is a deliberate two-commit
process. The first commit (skeleton + integration + sysctl) lands
with default 0 so the bridge can be exercised on the bench without
disturbing other consumers. After bench verification confirms
console login works, modifiers behave correctly, multi-keyboard
behavior is sound, and inputfs's other consumers (semadrawd,
inputdump) see no regressions, a follow-up commit flips the default
to 1.

### 7. Coexistence with inputfs's existing keyboard event publication

The bridge is purely additive. inputfs continues to publish
`keyboard.key_down` / `keyboard.key_up` events to its own event
ring exactly as before. The bridge observes the same transitions
in `inputfs_keyboard_diff_emit` and pushes parallel AT scancode
data to kbdmux's slave ring. Both consumers — inputfs event ring
(consumed by semadrawd, inputdump, libsemainput) and kbdmux ring
(consumed by vt(4)) — see every keystroke, independently.

This is double-delivery, the operational concern AD-28's closure
note (2026-05-08) flagged. For physical-console-only use it is
harmless — vt(4) is the only consumer, semadrawd buffers events
that no UTF surface is rendering. For combined console-plus-UTF
use it would mean a single keystroke ending up in two consumers
(vt(4) tty AND focused UTF surface).

The double-delivery question is *not* solved by this ADR. It is
the structural concern AD-10's framebuffer-ownership work
(AD-10.1-.4) plus AD-11's UTF-native console replacement address.
When drawfs holds VT_PROCESS-mode ownership, vt(4) is suspended
and won't process the kbdmux keystrokes; when drawfs releases,
vt(4) resumes and the keystrokes flow to the foreground tty. That
is, the framebuffer ownership state implicitly gates whether
double-delivery is observable to the user, not the bridge itself.

Until AD-10.1-.4 lands, double-delivery is observable but
operationally minor: the user types into a vt(4) console while
semadraw-term (if running) sees the same keystrokes in its
buffered ring. semadraw-term doesn't display anything because
its surface isn't rendering (vt(4) is on the framebuffer); the
buffered keystrokes get drained on next focus.

### 8. Failure modes

These are the bench-verifiable failure modes the implementation
must not exhibit. Each is observed during bench verification
(see Consequences below).

**Double-typing.** Each key produces two characters at the console.
Indicates the bridge fires on every HID report rather than per
transition. Diagnostic: bitmap-diff logic error, or the bridge is
hooked at the wrong site (interrupt-handler raw report instead of
post-diff transition).

**Stuck modifiers.** Releasing Shift leaves console thinking Shift
is held; subsequent letters appear capitalised. Diagnostic: the
modifier byte's 0xE0..0xE7 transition handling is missing the
release case; the bridge passed an old modifier mask after a key
was released.

**Repeating-key drops.** Holding a key produces fewer characters
than the OS expects. vt(4) handles key repeat itself given a single
down event; a real cause of dropped repeats would be the bridge's
ring buffer overflowing under fast typing or the taskqueue being
starved. Both are bench-observable; mitigation is bumping the
ring size or the taskqueue priority.

**Different keyboards interfering.** Pressing Shift on the Apple
keyboard while typing letters on the Broadcom Bluetooth keyboard
produces unexpected output. Indicates the bridge is sharing a
single softc across all inputfs keyboard devices instead of
allocating one per device. The design above explicitly allocates
per-device softcs to prevent this.

**Lock-order violation under WITNESS.** Acquiring Giant from a
spin-mutex context. Diagnostic: the taskqueue defer wasn't applied
correctly. WITNESS catches this immediately under PGSD-DEBUG.

**inputdump events regression.** semadrawd's view of keyboard
events changes (events appear delayed, missing, or doubled).
Indicates the bridge is consuming events from inputfs's event
ring instead of observing them. The bridge must be a passive
observer at the diff-emit site; it must not consume from the
ring.

## Consequences

### Operationally

**Restores physical-console login on PGSD.** With the bridge
enabled (`hw.inputfs.kbdmux_bridge=1`), vt(4) at ttyv0..N
receives keystrokes from inputfs's HID parser via kbdmux,
exactly as if hkbd were loaded. SSH access remains unchanged.

**No regression in UTF input pipeline.** inputfs continues to
publish its own keyboard events to the event ring; semadrawd and
libsemainput see identical event streams to the pre-bridge case.
The trackpad-as-cursor synthesis from AD-27 is unaffected.

**Adds Giant lock dependency.** The bridge's `kbd_register` and
ring-feed paths take Giant. Existing inputfs code does not. This
is a structural step backward in lock-discipline modernity — but
the entire FreeBSD kbd layer is Giant-locked, so any keyboard
producer faces the same constraint. The choice is "use Giant for
the bridge and follow ukbd's pattern" or "rewrite the kbd layer."
Option 1 is what this ADR specifies.

### For the operational discipline of AD-30.1

AD-30.1's closure note documented "console keyboard expectation":
removing legacy HID modules (per AD-8's discipline) costs vt(4)
console keystroke input. The bridge restores the input without
re-loading hkbd, preserving inputfs's exclusive HID consumer
status (ADR 0018 §3a). The "console keyboard works only via SSH"
cost dissolves once the bridge ships and is enabled.

The AD-30.1 escape hatch (`kldload hkbd` on demand) becomes
redundant with the bridge. With the bridge default-on and
verified, the escape hatch is documented as removed.

### For ADR 0018 §3a's exclusive HID consumer invariant

The bridge does not break ADR 0018 §3a. inputfs remains the only
hidbus child driver attached to HID devices. The bridge sits
*downstream* of inputfs at the kbd-layer, not at hidbus. From
hidbus's perspective inputfs is still the exclusive consumer; the
bridge is one of inputfs's userland-facing publication paths,
analogous to the event ring or the state region.

ADR 0018 §3a's "exclusive HID consumer" invariant should gain a
short clarification subsection noting that inputfs's downstream
consumer set is open (event ring, state region, kbdmux bridge,
future surfaces) — exclusivity is at the hidbus attachment layer,
not at the userland-publication layer. This is a small future
amendment to ADR 0018 that lands with the bridge's first commit.

### For AD-10's larger scope

AD-10 covers two independent surfaces: framebuffer ownership and
keystroke handover. This ADR addresses keystrokes only. AD-10's
framebuffer-ownership ADR (a future ADR 0020) addresses VT_SETMODE
acquisition, VT-switch signal handling, and the failure modes
specific to drawfs taking the framebuffer.

The keystroke and framebuffer surfaces interact at one point: when
drawfs takes the framebuffer in VT_PROCESS mode, vt(4) is
suspended and will not process keystrokes from kbdmux until drawfs
releases. The bridge keeps publishing scancodes to kbdmux during
the suspension; kbdmux buffers them; on release, vt(4) drains the
backlog. This is correct behavior — it means a user who presses
keys while drawfs is active will not see those keys arrive at the
shell when drawfs releases. The expected behavior is "keys aimed at
the UTF compositor go to the UTF compositor; keys aimed at vt(4)
go to vt(4)." Whose keys those are is an open product question
that AD-11 (UTF-native console) will resolve. Until then, the
bridge's behavior is "keystrokes go everywhere; downstream consumers
sort it out by who is currently rendering."

## Implementation outline

Each step is a self-contained commit that can be bench-verified
before moving to the next.

  1. **Skeleton (`inputfs/sys/dev/inputfs/inputfs_kbdmux.c`).**
     New file. `keyboard_switch` (kbdsw) with all 17 callbacks
     stubbed to reasonable defaults; `KEYBOARD_DRIVER` macro;
     module load hooks (`kbd_add_driver`, `kbd_delete_driver`).
     Compiles, doesn't link to anything else yet. Static-analysis
     verifiable.

  2. **Per-keyboard softc with ring buffer and HID→AT translation.**
     Ports of `ukbd_put_key`, `ukbd_get_key`, `ukbd_atkeycode`,
     `ukbd_key2scan`, and `ukbd_trtab[256]` from
     `sys/dev/usb/input/ukbd.c`. Self-contained; no integration
     with inputfs yet.

  3. **`inputfs_kbd_intr_cb`.** Bridge's hook function called from
     inputfs's keyboard parser when a transition occurs. Takes
     `(struct inputfs_softc *, hid_usage, is_down, modifiers)`,
     translates to AT scancodes via the trtab, calls `put_key`
     to enqueue, signals kbdmux via `kb_callback`. Exercises the
     softc and ring from step 2.

  4. **`kbd_register` integration.** On inputfs's keyboard attach
     (currently the `attached HID keyboard ...` log site),
     allocate a bridge softc, fill the kbdsw vtable, call
     `kbd_register` if `hw.inputfs.kbdmux_bridge` is set. On
     detach, call `kbd_unregister`. The attach path runs
     under taskqueue defer per §5.

  5. **Sysctl gate.** `hw.inputfs.kbdmux_bridge`, default 0,
     CTLFLAG_RWTUN so loader.conf can override. Read at attach;
     change at runtime takes effect on next attach (per §6).

  6. **Bench verify with sysctl off.** Confirm zero behavior
     change: `inputdump events` shows the same keyboard events
     as before, `inputdump devices` shows the same six TLCs,
     no `/dev/kbd<N>` devices appear from inputfs, console at
     ttyv0 still does not work (expected — bridge disabled).

  7. **Bench verify with sysctl on.** Set
     `hw.inputfs.kbdmux_bridge=1`, reload inputfs, attach
     keyboards. Confirm `/dev/kbd<N>` devices appear,
     `kbdcontrol -i < /dev/kbd<N>` reports a real keyboard,
     `kbdmux0` includes the new keyboards as slaves. Test
     console login at ttyv0: type username, password, press
     Enter; expect successful login.

     Run all the failure-mode tests from §8: type a few
     paragraphs (no double-typing), Shift releases cleanly
     (no stuck modifiers), key repeat works
     (`xxxxxxxxxxxx` from holding x), Apple and Broadcom
     keyboards work independently, `Ctrl+C` interrupts a
     command, `vi` arrow-keys navigate, `Alt+F2` switches
     to ttyv1.

  8. **Default-on flip.** After §7's verification passes,
     a follow-up commit flips the sysctl default from 0 to 1.
     Operator's loader.conf override still works; the
     bridge is now on by default.

  9. **ADR 0018 §3a clarification.** Small amendment noting
     that inputfs's downstream consumer set is open
     (multiple userland-facing publication paths are
     allowed); exclusivity is at the hidbus attachment layer.
     Lands with step 8 or as a separate doc commit.

## References

  - **ADR 0007** Hidbus attachment.
  - **ADR 0009** Interrupt handler registration. The bridge's
    taskqueue defer pattern complies with §Decision-3's
    "no sleeping locks from interrupt context."
  - **ADR 0018** HUP_DIGITIZERS handling. §3a's exclusive HID
    consumer invariant; the bridge sits downstream of that
    invariant, not at the same layer.
  - **AD-10** drawfs negotiates framebuffer ownership with vt(4).
    This ADR addresses AD-10.5 specifically; AD-10.1-.4 are
    the framebuffer side, tracked separately.
  - **AD-28 (original)** Console keyboard input does not reach
    kbdmux. The pre-implementation source-reading work in this
    BACKLOG entry's "Original entry" body informs §1-§5 of this
    ADR; the 8-step implementation outline derives from there.
  - **AD-30.1** pgsd-kernel periodic drift detection. Closure of
    AD-30.1 created the operational pain that the bridge
    addresses.
  - **`sys/dev/kbd/kbdreg.h`**, **`sys/dev/kbd/kbd.c`**,
    **`sys/dev/kbd/kbdmux.c`**, **`sys/dev/kbd/kbdtables.h`**,
    **`sys/dev/usb/input/ukbd.c`**. The kbd-layer source. ukbd is
    the structural reference for the bridge.
