/*
 * inputfs_kbdmux.h: bridge API surface visible to inputfs.c.
 *
 * The bridge softc is defined privately in inputfs_kbdmux.c.
 * inputfs.c only ever holds an opaque pointer to it (struct
 * inputfs_kbd_softc *). The functions declared here are the
 * contract between inputfs's keyboard attach/detach paths and
 * the bridge:
 *
 *   - inputfs_kbd_bridge_attach: called from inputfs_attach when
 *     a device with a HID keyboard top-level collection comes up.
 *     Allocates and registers a bridge instance with the kbd layer
 *     and returns the opaque softc pointer (or NULL on failure).
 *
 *   - inputfs_kbd_bridge_detach: called from inputfs_detach when
 *     the device goes away. Drains the per-instance taskqueue task,
 *     unregisters from the kbd layer, frees the softc.
 *
 *   - inputfs_kbd_bridge_intr_cb: called from
 *     inputfs_keyboard_diff_emit per HID transition to populate
 *     the bridge's ring and notify kbdmux. Gated by
 *     hw.inputfs.kbdmux_bridge.
 *
 * The bridge softc itself is forward-declared as an opaque struct
 * here; only inputfs_kbdmux.c sees the layout. inputfs.c stores
 * the pointer in its softc as void * (struct inputfs_kbd_softc *
 * would force a circular include) and the bridge functions take
 * void * to match.
 *
 * Implements ADR 0019 (AD-10.5). See
 * inputfs/docs/adr/0019-kbdmux-bridge.md for the design and
 * inputfs_kbdmux.c's file header for the implementation history.
 */

#ifndef _INPUTFS_KBDMUX_H_
#define _INPUTFS_KBDMUX_H_

#ifdef _KERNEL

/*
 * Allocate a bridge softc, register it with the kbd layer as a
 * slave under the given unit number, and return the opaque
 * pointer the caller stores for later detach.
 *
 * unit: per-instance unit number to identify this bridge slave to
 *       the kbd layer. inputfs uses device_get_unit(dev) so the
 *       bridge unit matches the inputfs device unit (e.g.,
 *       inputfs1 → inputfs_kbd1). This keeps the kbd-layer name
 *       inputfs_kbd<N> aligned with the producing inputfs<N>.
 *
 * Returns: opaque bridge softc pointer on success, NULL on
 *          failure (allocation error, kbd_register failure).
 *
 * Caller context: inputfs_attach. Process context, no spin
 *                 mutexes held. Allocation uses M_WAITOK.
 *
 * On failure the bridge logs a kernel printf and returns NULL.
 * inputfs's attach path treats the bridge as advisory: a failure
 * here does not abort the inputfs device's overall attach. The
 * device is still useful for the userland event-ring consumer
 * (UTF compositor input path); only the vt(4)-bridge path is
 * unavailable for that one device.
 */
void *inputfs_kbd_bridge_attach(int unit);

/*
 * Tear down a bridge softc previously returned by attach. Drains
 * the deferred-notification taskqueue task, unregisters from the
 * kbd layer, frees the softc.
 *
 * bridge: opaque pointer from inputfs_kbd_bridge_attach. NULL is
 *         tolerated (no-op) so callers can call unconditionally
 *         from inputfs_detach without checking attach success.
 *
 * Caller context: inputfs_detach. Process context. taskqueue_drain
 *                 may sleep, so no spin mutexes may be held.
 */
void inputfs_kbd_bridge_detach(void *bridge);

/*
 * Producer hook called from inputfs_keyboard_diff_emit at each
 * of its four publish sites (modifier ups, array key ups,
 * modifier downs, array key downs). The function:
 *
 *   1. Translates hid_usage through the HID-to-AT scancode
 *      table (inputfs_kbd_trtab in inputfs_kbdmux.c).
 *   2. Pushes the resulting AT scancode (with the high bit set
 *      for releases; with a 0xE0 prefix prepended for extended
 *      keys) to the bridge's lockless SPSC ring.
 *   3. Schedules a deferred kbdmux notification via
 *      taskqueue_enqueue(taskqueue_fast).
 *
 * Caller contract:
 *
 *   - The gate (hw.inputfs.kbdmux_bridge sysctl) MUST be 1
 *     before this is called. The wrapper does not check it;
 *     checking happens at the call site so there's no
 *     redundant load on every transition when the gate is on.
 *
 *   - bridge can be NULL; the wrapper tolerates it as a
 *     defensive no-op. But callers should normally check
 *     sc->sc_kbd_bridge != NULL before calling, since a
 *     non-keyboard inputfs device legitimately has no bridge.
 *
 *   - hid_usage is the HID Usage ID byte (0xE0..0xE7 for
 *     modifiers L/R/Ctrl/Shift/Alt/Gui, 0x04..0xDD for
 *     normal keys). Out-of-range usages translate to 0
 *     in the trtab, which inputfs_kbd_emit_at then drops.
 *
 *   - is_down is 1 for key-down events (press), 0 for
 *     key-up (release). emit_at adds the SCAN_RELEASE
 *     high-bit (0x80) for the up case.
 *
 *   - Caller context: spin-mutex-protected (inputfs_state_mtx
 *     via the HID intr path). The wrapper inherits this.
 *     Internal body is lockless ring write plus
 *     taskqueue_enqueue, both spin-safe.
 */
void inputfs_kbd_bridge_intr_cb(void *bridge, uint8_t hid_usage, int is_down);

/*
 * Producer gate visible to inputfs.c.
 *
 * inputfs_keyboard_diff_emit reads this at each publish site to
 * decide whether to call into the bridge's producer hook
 * (inputfs_kbd_bridge_intr_cb). When 0, bridge_attach still
 * registers the instance with the kbd layer (so kbdmux sees the
 * slave) but no scancodes are produced. When 1, the full
 * inputfs->kbdmux->vt(4) path is active.
 *
 * Default 1 (since AD-10.5 step 8). Operators can set to 0 with
 * `sysctl hw.inputfs.kbdmux_bridge=0` at runtime, or
 * `hw.inputfs.kbdmux_bridge=0` in /boot/loader.conf, to disable
 * the producer path as a recovery option.
 *
 * Plain `int` access from any caller is safe on the bench
 * (amd64 aligned int loads are atomic). The producer hot path
 * reads this once per keyboard transition; a torn read or
 * stale read is impossible on this architecture, and brief
 * cross-CPU visibility lag (microseconds) at the moment of a
 * sysctl flip is acceptable.
 */
extern int inputfs_kbd_bridge_enabled;

#endif /* _KERNEL */

#endif /* _INPUTFS_KBDMUX_H_ */
