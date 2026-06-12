# Stage D verification

Acceptance test for Stage D of the inputfs roadmap (focus
routing, coordinate transform, publication enable tunable).
The Stage D closeout bullet in `BACKLOG.md` is flipped only
after this protocol passes end-to-end on bare-metal FreeBSD.

The protocol has two parts, mirroring the Stage C structure:

1. The automated checks in `inputfs/test/d/d-verify.sh`. These
   exercise everything that does not require a live compositor
   or synthetic focus writer: D.1 reader infrastructure, D.2
   geometry sysctls, D.3 transform_active byte and pointer
   seed, D.5 enable-tunable transitions.

2. The manual checklist below. These exercise D.0a/D.0b under
   live input (real keyboards and pointing devices), D.4
   routing under a live compositor (or a synthetic focus
   writer), and HID hotplug behaviour.

Both parts must pass for Stage D to be considered verified on
a given machine.

Stage C verification (`c-verify.sh` plus
`docs/C_VERIFICATION.md`) must already pass on this machine
before Stage D verification is meaningful: Stage D inherits
Stage C's publication regions and module lifecycle unchanged.

## Recipe

The short version, for someone who already knows the project:

```
cd ~/Development/UTF/inputfs
zig build                                 # produces zig-out/bin/inputdump
cd sys/modules/inputfs && sudo make       # produces inputfs.ko
cd ../../../

sudo sh test/c/c-verify.sh                # Stage C must pass first
sudo sh test/d/d-verify.sh                # Stage D automated checks

# Then, for the manual checklist:
sudo zig-out/bin/inputdump events --watch
# Move the mouse, click, type. Observe events with the right
# event types, dx/dy values, button masks, key usages.
# Ctrl-C to stop.
```

If both verification scripts report `0 failed` and the manual
checklist below matches what you observe, Stage D is verified
on this machine.

## Preconditions

Same as Stage C:

- Root access (kldload, /var/run access).
- The kernel module builds cleanly:
  `cd inputfs/sys/modules/inputfs && sudo make`.
- The inputdump CLI builds cleanly:
  `cd inputfs && zig build`.
- `/var/run` is writable (typically tmpfs).
- HID input devices attached (at least one keyboard and one
  pointing device).

Plus, for the active-path tests of D.2 and D.3:

- drawfs is loaded (or its `.ko` is reachable for the script
  to load it). If absent, the geometry-unknown variants of
  D.2 and D.3 are run instead, and these still verify the
  fallback behaviour but do not exercise the active geometry
  path.

## Manual checklist

### D.0a: pointer events under live input

With `inputfs` loaded and `inputdump events --watch` running:

- [ ] Move the mouse left, right, up, down. `pointer.motion`
      events arrive with non-zero `dx` / `dy` matching the
      direction of motion.
- [ ] Click the left button. `pointer.button_down` event with
      bit 0 set in the changed-mask, then `pointer.button_up`
      on release.
- [ ] Click the right button. Same as left but bit 1.
- [ ] If the mouse has a wheel: scroll up and down.
      `pointer.scroll` events with non-zero `dy`. (Wheel
      direction may be inverted depending on the device; what
      matters is that scroll events arrive at all.)
- [ ] If the device exposes additional buttons (middle, side
      buttons): click and confirm corresponding bits flip.

### D.0b: keyboard events under live input

- [ ] Press and release a letter key. `keyboard.key_down`
      followed by `keyboard.key_up` with matching `hid_usage`.
- [ ] Hold a key briefly: a single `key_down`; the key_up
      arrives only on release. (No keyboard auto-repeat at the
      inputfs level; that is the consumer's responsibility.)
- [ ] Press shift + a letter: two `key_down` events (modifier
      first, then letter). On release, two `key_up` events.
      The modifier change is reflected in the `modifiers`
      payload field.
- [ ] Press ctrl + alt + a letter: three keys reported with
      matching modifier states.

### D.3: coordinate transform under live input

With drawfs loaded so transform is active:

- [ ] At rest, `inputdump state` shows `pointer.x` and
      `pointer.y` near the centre of the display
      (`geom_width/2`, `geom_height/2`).
- [ ] Move the mouse hard against the left wall. `pointer.x`
      should clamp to 0 and stop changing. Payload `dx`
      values should report `0` once the wall is reached
      (post-clamp deltas; commit landing 2026-05-06 fixed
      the prior behaviour where `dx` reported the unclamped
      raw HID delta and produced phantom drift in delta-
      integrating consumers). Same against the right wall:
      `pointer.x` clamps to `geom_width - 1` and `dx`
      reports `0`.
- [ ] Same for top and bottom walls in the y-axis. Payload
      `dy` reports `0` at the wall.
- [ ] During a normal mid-screen move, payload `dx`/`dy`
      should equal the raw HID delta — the post-clamp delta
      and the raw delta agree when the move doesn't clip an
      edge.
- [ ] Without drawfs loaded, repeat above. The pointer
      accumulator runs unclamped, x/y can grow without bound,
      and payload `dx`/`dy` always equal the raw HID delta
      (no clamping means no correction).
      `transform_active` byte at state offset 48 reads 0.

### D.4: routing with a live focus writer

D.4 routing stamps `session_id` into events based on the
focus snapshot at event time. Without a focus file, all
session_ids are 0 and no leave/enter is synthesised. To
exercise routing, either:

- Run a real compositor that writes
  `/var/run/sema/input/focus` per `shared/INPUT_FOCUS.md`.
- Or write a synthetic focus file with one or more surfaces.

A synthetic-focus harness is not yet bundled with inputfs;
when it is built (a small Zig tool that uses
`shared/src/input.zig`'s `FocusWriter` to publish a known
configuration), the manual procedure becomes:

1. Place a known surface at known coordinates with a known
   session_id (e.g. session_id=42, occupying the full
   screen).
2. Move the mouse over the surface. Observe `pointer.motion`
   events with `session_id = 42`.
3. Add a second surface (session_id=43, smaller, in a known
   rectangle within the first). Move the cursor across the
   boundary.
4. Observe `pointer.leave` for session 42, then
   `pointer.enter` for session 43, then `pointer.motion`
   events with `session_id = 43` while inside the inner
   surface.
5. Move back across the boundary; observe the symmetric
   leave/enter.
6. Set the writer's `keyboard_focus = 43`. Type. Observe
   keyboard events with `session_id = 43`.

Until the harness is built, D.4 is verified at the structural
level by C.5 (events publish correctly, sequence is
monotonic, types decode correctly) plus inspection of the
event payload format (16-byte enter/leave per spec, 24-byte
motion with session_id at offset 20).

### D.5: enable tunable

The automated script covers this already; the manual aspect:

- [ ] With inputfs loaded and events streaming in
      `inputdump events --watch`: set
      `sysctl hw.inputfs.enable=0`. Observe that no new
      events arrive. Move the mouse / type during the
      gated-off period.
- [ ] Set `sysctl hw.inputfs.enable=1`. Events resume
      immediately. The first state sync after re-enable
      shows the *current* pointer position (not the position
      at the moment of disable).

### HID hotplug

- [ ] With inputfs loaded, plug in a new USB input device.
      `dmesg` shows the hidbus attach plus
      `inputfs: device <slot> attached: ...`.
      `inputdump devices` lists the new device.
      `inputdump events` shows a `lifecycle.device_attach`
      event.
- [ ] Generate input from the new device; events arrive with
      its slot index in the `device_slot` field.
- [ ] Unplug the device. `dmesg` shows the detach. The slot
      is zeroed in the state region; `device_count`
      decrements.
- [ ] Plug a different device into the same USB port. New
      slot allocated; old slot data does not leak.

### Stress test

- [ ] Run `inputdump events --watch` while moving the mouse
      vigorously and typing for one minute. Sequence numbers
      remain strictly monotonic; no event drops; ring does
      not corrupt.
- [ ] Verify the kthread keeps up: state-region pointer
      position matches the cursor's actual position within
      ~16ms of motion stopping.
