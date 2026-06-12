/*-
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2026 Pacific Geoscience Systems Development Foundation.
 * All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

/*
 * inputfs_kbdmux.c -- inputfs to kbdmux bridge for vt(4) console
 * login. Implements ADR 0019 (AD-10.5).
 *
 * The bridge is a kbd-layer keyboard driver inside the inputfs
 * module. It registers itself with FreeBSD's kbd subsystem under
 * the driver name "inputfs_kbd"; per-keyboard instances become
 * slaves of kbdmux, which feeds vt(4)'s console keystroke
 * pipeline. inputfs's existing event-ring and state-region
 * publication paths continue unchanged; the bridge is purely
 * additive at the userland-publication layer (ADR 0018 §3a's
 * exclusive-HID-consumer invariant remains intact at the hidbus
 * attachment layer).
 *
 * Status: implemented and active by default. The bridge is gated
 * by hw.inputfs.kbdmux_bridge (default 1 since AD-10.5 step 8).
 * Setting the gate to 0 disables the producer path while leaving
 * bridge instances registered with the kbd layer; useful as a
 * recovery option if a future change destabilises the producer.
 *
 * History (visible in commit log; preserved here for orientation):
 *
 *   step 1  Skeleton: kbdsw vtable and module load hooks.
 *   step 2  Per-keyboard softc, lockless SPSC ring, HID-to-AT
 *           translation table.
 *   step 3  Producer hook (inputfs_kbd_intr_cb) and deferred
 *           kbdmux notification via taskqueue_fast.
 *   step 4a Bridge attach/detach lifecycle, kbd_register
 *           integration, kbdmux enslavement.
 *   step 4b Producer wiring at the four publish sites in
 *           inputfs_keyboard_diff_emit, gated on the sysctl.
 *   step 5  Sysctl gate hw.inputfs.kbdmux_bridge.
 *   step 6  Bench verification with sysctl off (no behavior
 *           change).
 *   step 7  Bench verification with sysctl on (ttyv0 login
 *           works through the bridge).
 *   step 8  Default flipped from 0 to 1.
 *   step 2.5 Extended-key 0xE0 prefix encoding for arrow keys,
 *           Right Ctrl/Alt/GUI, Home/End/PgUp/PgDn,
 *           Insert/Delete, keypad-Enter, keypad-/.
 *
 * Reference: hkbd at sys/dev/usb/input/ukbd.c (in current
 * FreeBSD; the iichid project's hkbd.c is the post-2021 HID-
 * subsystem conversion). The structural shape mirrors hkbd's
 * keyboard_switch but with HID-event production deferred to
 * inputfs_keyboard_diff_emit (in inputfs.c) rather than this
 * driver's own interrupt path.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/malloc.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/taskqueue.h>
#include <sys/sysctl.h>

#include <machine/atomic.h>

#include <sys/kbio.h>
#include <dev/kbd/kbdreg.h>

#include "inputfs_kbdmux.h"

/*
 * inputfs uses M_INPUTFS for its allocations; MALLOC_DEFINE is in
 * inputfs.c. The bridge shares the same malloc type to keep the
 * vmstat -m "inputfs" line representative of the entire module's
 * footprint rather than splitting bridge allocations under a
 * separate name.
 */
MALLOC_DECLARE(M_INPUTFS);

/*
 * Driver name. Visible to userland as the "kind" reported by
 * `kbdcontrol -i < /dev/kbdN` once instances exist (steps 4+).
 * Distinct from "hkbd" so the bridge can coexist with hkbd if
 * a future bench configuration loads both (not the current PGSD
 * configuration; AD-30.1's discipline keeps hkbd unloaded).
 */
#define INPUTFS_KBD_DRIVER_NAME "inputfs_kbd"

/*
 * Producer gate: hw.inputfs.kbdmux_bridge.
 *
 * Controls whether the producer hook (inputfs_kbd_intr_cb,
 * called from inputfs_keyboard_diff_emit) actually pushes
 * scancodes into the bridge ring and notifies kbdmux. With the
 * gate at 0 the producer is a no-op and the bridge is
 * operationally inert: instances are still registered with the
 * kbd layer (kbdmux can see them as slaves) but no input flows.
 *
 * Default 1 since AD-10.5 step 8. Setting the gate to 0 at
 * runtime disables the producer path on the next HID transition;
 * useful as a recovery option if a future change destabilises
 * the producer without requiring a kernel module unload.
 *
 * Why a sysctl rather than a build-time #define: a runtime
 * toggle is the right fit. CTLFLAG_RWTUN means the setting can
 * also be pre-set in /boot/loader.conf so an operator can boot
 * with the bridge disabled if needed:
 *
 *   hw.inputfs.kbdmux_bridge=0
 *
 * Read pattern: the producer hot path reads this with a plain
 * load. On amd64 (the bench architecture), aligned int loads
 * are atomic, so a torn read is impossible. Read-acquire /
 * write-release semantics are not required because the gate
 * is monotone within a session (operator flips 1->0 once if
 * needed); eventual visibility of a flip across CPUs within
 * microseconds is sufficient.
 *
 * Visibility from inputfs.c: the variable is declared with
 * external linkage (no `static`) and exposed via
 * inputfs_kbdmux.h so inputfs_keyboard_diff_emit's call sites
 * can read it directly without a function call.
 */
int inputfs_kbd_bridge_enabled = 1;
SYSCTL_DECL(_hw_inputfs);
SYSCTL_INT(_hw_inputfs, OID_AUTO, kbdmux_bridge, CTLFLAG_RWTUN,
    &inputfs_kbd_bridge_enabled, 1,
    "Enable inputfs->kbdmux bridge producer (default on)");

/* ---------------------------------------------------------------- */
/*  AD-10.5 step 2: per-keyboard softc, ring, HID-to-AT translation */
/* ---------------------------------------------------------------- */

/*
 * Step-2 scope note: the data structures (trtab, softc) and helper
 * functions (put_key, get_key, input_pending, emit_at) below have
 * no callers yet. Step 3's inputfs_kbd_intr_cb is the producer that
 * exercises put_key and emit_at; step 5's read_char/check_char real
 * implementations consume via get_key and input_pending.
 *
 * Because the FreeBSD kernel build uses -Werror with
 * -Wunused-function, unreferenced static functions break the build.
 * Each helper carries the __unused attribute for the duration of
 * step 2; step 3 removes the attribute when it adds the call sites.
 * The trtab table is similarly tagged because it is only read by
 * emit_at, which is itself unused in step 2.
 *
 * This is a deliberately conservative review boundary: step 2
 * lands the data and primitives in isolation so they can be read
 * for correctness without entanglement with the inputfs.c
 * integration that step 3 introduces.
 */

/*
 * Number of distinct HID Keyboard/Keypad usage codes the bridge
 * tracks per instance. The HID usage page 0x07 is defined for
 * codes 0x00..0xFF; this matches hkbd's HKBD_NKEYCODE and ukbd's
 * earlier UKBD_NKEYCODE. The translation table (inputfs_kbd_trtab)
 * is therefore a 256-entry array indexed by HID usage.
 *
 * The CTASSERT pins the relationship between the trtab size and
 * the uint8_t indexing range used by inputfs_kbd_emit_at. If
 * either side ever changes the build catches the mismatch.
 */
#define INPUTFS_KBD_NKEYCODE    256
CTASSERT(INPUTFS_KBD_NKEYCODE == 256);

/*
 * Ring buffer for AT scancodes pending consumption by kbdmux.
 *
 * Producer (interrupt context, under inputfs_state_mtx):
 *   inputfs_keyboard_diff_emit observes keyboard transitions
 *   and calls inputfs_kbd_put_key for each. put_key writes into
 *   sc_input[head & MASK] and stores-release sc_input_head.
 *
 * Consumer (process context, under Giant):
 *   kbdmux drains via kbdd_read_char, which calls
 *   inputfs_kbd_sw_read_char, which calls inputfs_kbd_get_key.
 *   get_key load-acquires sc_input_head, reads
 *   sc_input[tail & MASK], stores sc_input_tail.
 *
 * The single-producer single-consumer invariant is enforced by
 * the locking model:
 *   - Producer side: inputfs_keyboard_diff_emit is the only
 *     site that calls put_key (step 3), and it runs under
 *     inputfs_state_mtx, which serialises all HID interrupt
 *     contexts.
 *   - Consumer side: the kbdsw read_char path is invoked with
 *     the keyboard's kb_lock (which is Giant for the bridge)
 *     held by the kbd layer, serialising all reads.
 *
 * With single-producer and single-consumer, the ring needs only
 * atomic load-acquire / store-release on the head and tail
 * counters; no mutex coordination between the two contexts. This
 * is the lockless-queue pattern D27991 (the hkbd FreeBSD review)
 * documents as the modern way to bridge spin-mutex-protected
 * producers to Giant-protected consumers.
 *
 * Buffer size is a power of two so head/tail wrap by bitmask.
 * Sized 1024 entries: at HID's worst case of ~1000 reports/sec
 * per keyboard, even with 3-byte AT prefix sequences this is
 * roughly one second of headroom. Real typing produces ~10
 * transitions/sec; the buffer never approaches full under
 * normal use. Overflow drops the oldest scancode (FIFO) which
 * is correct for keyboard input since vt(4) and consumers
 * will drop typing during system stalls anyway.
 */
#define INPUTFS_KBD_BUF_SIZE    1024
#define INPUTFS_KBD_BUF_MASK    (INPUTFS_KBD_BUF_SIZE - 1)
CTASSERT((INPUTFS_KBD_BUF_SIZE & INPUTFS_KBD_BUF_MASK) == 0);

/*
 * AT scancode encoding constants. The kbd layer's K_RAW mode
 * delivers AT scancodes one byte at a time. Press / release is
 * encoded in the high bit of the byte (0x80 set = release).
 *
 * The bridge represents each AT byte as a uint32_t in the ring
 * (zero-extended); the high bits beyond bit 7 are unused at the
 * ring layer. Extended-key encoding (the 0xE0 prefix for arrow
 * keys, Right Ctrl/Alt/GUI, etc.) is handled at the trtab layer:
 * trtab entries are uint16_t with the prefix in the high byte
 * and the scancode in the low byte; emit_at pushes prefix and
 * scancode as two separate ring entries.
 */
#define INPUTFS_KBD_SCAN_RELEASE        0x80

/*
 * Translation table from HID Keyboard/Keypad usage page (0x07)
 * codes to AT keyboard scancodes.
 *
 * Encoding (uint16_t per entry):
 *   0x0000   no AT translation; emit_at drops the event.
 *   0x00XX   no prefix; emit_at pushes the single byte XX.
 *   0xE0XX   extended; emit_at pushes 0xE0 then XX. The 0x80
 *            release bit goes on the scancode only; the prefix
 *            is unchanged for release (AT set 1 semantics).
 *
 * Originally derived from hkbd_trtab[256] in
 * sys/dev/usb/input/ukbd.c (and its iichid-project successor
 * hkbd.c) as a uint8_t table. hkbd ships its own keymap
 * (ukbdmap.h) that interprets synthetic non-standard scancodes
 * for extended keys (0x59 for Right Arrow, 0x5A for Right Ctrl,
 * etc.); under kbdmux we get the system default kbdtables.h
 * which interprets standard 0xE0-prefixed codes. AD-10.5 step
 * 2.5 widened the table to uint16_t and switched the
 * extended-key entries to standard scancodes plus a 0xE0 high
 * byte. Most other entries are carried verbatim from the hkbd
 * table since they were already standard AT scancodes (letters,
 * digits, function keys, modifiers without prefix).
 *
 * The HID usage page is universal across keyboards, so this
 * table is correct for every HID keyboard the bridge encounters,
 * including the three on the current PGSD bench (HAILUCK
 * touchpad keyboard, Broadcom Bluetooth, Apple Aluminum).
 *
 * The 0 entries (defined here as NN) mark HID usages with no
 * AT-scancode equivalent; emit_at drops them. Examples: usage
 * 0x67 (Keypad =), usage 0x90 (Kana). Two notable keys are
 * intentionally retained as hkbd synthetic values rather than
 * given proper extended encoding because their AT sequences are
 * non-uniform multi-byte forms with quirks: HID 0x46
 * PrintScreen (AT 0xE0 0x2A 0xE0 0x37 with shift-eating) and
 * HID 0x48 Pause (AT 0xE1 0x1D 0x45 0xE1 0x9D 0xC5, no break
 * code). Neither is useful at the console.
 *
 * Multimedia / internet keys (HID 0x68-0x91) retain their hkbd
 * synthetic values; these have no equivalent in standard AT
 * set 1.
 */
#define NN 0      /* no translation; HID usage has no AT equivalent */

static const uint16_t inputfs_kbd_trtab[INPUTFS_KBD_NKEYCODE] = {
	0,      0,      0,      0,      30,     48,     46,     32,     /* 00 - 07 */
	18,     33,     34,     35,     23,     36,     37,     38,     /* 08 - 0F */
	50,     49,     24,     25,     16,     19,     31,     20,     /* 10 - 17 */
	22,     47,     17,     45,     21,     44,     2,      3,      /* 18 - 1F */
	4,      5,      6,      7,      8,      9,      10,     11,     /* 20 - 27 */
	28,     1,      14,     15,     57,     12,     13,     26,     /* 28 - 2F */
	27,     43,     43,     39,     40,     41,     51,     52,     /* 30 - 37 */
	53,     58,     59,     60,     61,     62,     63,     64,     /* 38 - 3F */
	65,     66,     67,     68,     87,     88,     92,     70,     /* 40 - 47 */
	104,    0xE052, 0xE047, 0xE049, 0xE053, 0xE04F, 0xE051, 0xE04D, /* 48-4F: Pause(syn) Ins Home PgUp Del End PgDn Right */
	0xE04B, 0xE050, 0xE048, 69,     0xE035, 55,     74,     78,     /* 50-57: Left Down Up NumLk KP/ KP* KP- KP+ */
	0xE01C, 79,     80,     81,     75,     76,     77,     71,     /* 58-5F: KPEnter KP1..7 */
	72,     73,     82,     83,     86,     107,    122,    NN,     /* 60 - 67 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* 68 - 6F */
	NN,     NN,     NN,     NN,     115,    108,    111,    113,    /* 70 - 77 */
	109,    110,    112,    118,    114,    116,    117,    119,    /* 78 - 7F */
	121,    120,    NN,     NN,     NN,     NN,     NN,     123,    /* 80 - 87 */
	124,    125,    126,    127,    128,    NN,     NN,     NN,     /* 88 - 8F */
	129,    130,    NN,     NN,     NN,     NN,     NN,     NN,     /* 90 - 97 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* 98 - 9F */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* A0 - A7 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* A8 - AF */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* B0 - B7 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* B8 - BF */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* C0 - C7 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* C8 - CF */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* D0 - D7 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* D8 - DF */
	29,     42,     56,     0xE05B, 0xE01D, 54,     0xE038, 0xE05C, /* E0-E7: LCtl LSh LAlt LGUI RCtl RSh RAlt RGUI */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* E8 - EF */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* F0 - F7 */
	NN,     NN,     NN,     NN,     NN,     NN,     NN,     NN,     /* F8 - FF */
};

#undef NN

/*
 * Per-keyboard bridge softc. One instance per inputfs keyboard
 * device that the bridge has registered with the kbd layer
 * (registration happens in step 4 from inputfs's keyboard
 * attach path; step 2 only declares the structure shape).
 *
 * Lifetime: allocated during step 4's kbd_register integration
 * with M_INPUTFS / M_WAITOK | M_ZERO; freed when inputfs's
 * keyboard device detaches and kbd_unregister returns.
 *
 * The softc is referenced by:
 *   - inputfs's keyboard softc (struct inputfs_softc) carries
 *     a pointer to this when the bridge is enabled for that
 *     device. inputfs_keyboard_diff_emit dereferences the
 *     pointer to call inputfs_kbd_put_key.
 *   - The kbd layer's keyboard_t.kb_data field, set by
 *     kbd_init_struct in step 4, points back to this softc so
 *     the kbdsw callbacks can reach instance state.
 *
 * Locking layout:
 *   - sc_kbd, sc_keymap, sc_accmap, sc_fkeymap: kbd-layer
 *     state. Accessed only from kbdsw callbacks (which run
 *     under Giant per kbd-layer convention). No additional
 *     locking needed.
 *   - sc_input, sc_input_head, sc_input_tail: the lockless
 *     SPSC ring described above. Producer is the inputfs
 *     keyboard interrupt path under inputfs_state_mtx;
 *     consumer is the kbdsw read_char path under Giant.
 *     atomic_load_acq_32 / atomic_store_rel_32 on the head
 *     and tail counters; no mutex needed.
 *   - sc_buffered_char: scratch space for emitting the
 *     0xE0/0xE1 prefix byte ahead of an extended scancode.
 *     Accessed only from inputfs_kbd_put_key, which runs
 *     under the producer lock; serialised by it.
 *   - sc_mode, sc_state, sc_accents, sc_polling, sc_flags:
 *     kbd-layer instance state. Accessed only from kbdsw
 *     callbacks under Giant. No additional locking needed.
 */
struct inputfs_kbd_softc {
	keyboard_t       sc_kbd;          /* the kbd-layer instance */
	keymap_t         sc_keymap;       /* unused for K_RAW operation */
	accentmap_t      sc_accmap;       /* unused for K_RAW operation */
	fkeytab_t        sc_fkeymap[NUM_FKEYS]; /* fkey strings, kbd-layer reqd */
	int              sc_fkeymap_size;

	/* Lockless SPSC ring of pending AT scancode bytes. */
	uint32_t         sc_input[INPUTFS_KBD_BUF_SIZE];
	volatile uint32_t sc_input_head;  /* writer advances */
	volatile uint32_t sc_input_tail;  /* reader advances */

	/* kbd-layer instance state. K_RAW under kbdmux; mostly
	 * passive, but kbd-layer requires the fields to exist. */
	int              sc_mode;
	int              sc_state;
	int              sc_accents;
	int              sc_polling;
	uint32_t         sc_flags;

	/* Back-pointer to the inputfs keyboard softc that produces
	 * for this bridge instance. NULL until step 4 sets it on
	 * registration. */
	void            *sc_inputfs_softc;

	/*
	 * Per-instance taskqueue task for the deferred kbdmux
	 * notification path (step 3 / ADR 0019 §5).
	 *
	 * The producer side (inputfs_kbd_intr_cb, called from
	 * inputfs_keyboard_diff_emit under inputfs_state_mtx,
	 * which is MTX_SPIN) cannot acquire Giant directly. The
	 * kbd-layer's kb_callback path requires Giant. The bridge
	 * defers the callback to a taskqueue task that runs at
	 * process context where Giant can be acquired safely.
	 *
	 * Lifecycle: TASK_INIT in step 4's instance allocator;
	 * taskqueue_drain in step 4's detach path. Step 3 only
	 * declares the field shape; no enqueue or drain happens
	 * yet because step 3 has no callers.
	 */
	struct task      sc_task;
};

/*
 * inputfs_kbd_put_key -- enqueue one AT scancode byte to the
 * lockless ring.
 *
 * Caller context:
 *   - Producer (step 3): runs from inputfs's keyboard
 *     interrupt path under inputfs_state_mtx. The call site
 *     observes one HID transition and calls put_key 1-3
 *     times (depending on whether the scancode needs an
 *     0xE0/0xE1 prefix).
 *
 * The ring is single-producer; concurrent put_key calls are
 * not permitted. The producer-side lock (inputfs_state_mtx)
 * enforces this.
 *
 * On overflow (head outpacing tail by INPUTFS_KBD_BUF_SIZE),
 * the new key is silently dropped. With a 1024-entry buffer
 * this only happens under sustained ring-not-drained
 * conditions (kbdmux task starvation, or the consumer side
 * not being woken). Real input rates are well below the
 * threshold.
 */
static void
inputfs_kbd_put_key(struct inputfs_kbd_softc *sc, uint32_t key)
{
	uint32_t head = sc->sc_input_head;
	uint32_t tail = atomic_load_acq_32(
	    __DEVOLATILE(uint32_t *, &sc->sc_input_tail));

	/*
	 * head and tail are unsigned counters that grow without
	 * bound (modulo 32-bit wrap, which is harmless because we
	 * mask to INPUTFS_KBD_BUF_MASK on access). The ring is
	 * full when head - tail == INPUTFS_KBD_BUF_SIZE.
	 */
	if ((uint32_t)(head - tail) >= INPUTFS_KBD_BUF_SIZE) {
		/* full; drop. */
		return;
	}

	sc->sc_input[head & INPUTFS_KBD_BUF_MASK] = key;
	atomic_store_rel_32(__DEVOLATILE(uint32_t *, &sc->sc_input_head),
	    head + 1);
}

/*
 * inputfs_kbd_get_key -- dequeue one AT scancode byte from the
 * lockless ring.
 *
 * Returns the byte cast to int32_t, or -1 if the ring is
 * empty.
 *
 * Caller context:
 *   - Consumer (step 3 / step 5): kbdsw read_char and
 *     check_char paths. Run under Giant per kbd-layer
 *     convention. The ring is single-consumer; concurrent
 *     get_key calls are not permitted.
 */
static int32_t
inputfs_kbd_get_key(struct inputfs_kbd_softc *sc)
{
	uint32_t tail = sc->sc_input_tail;
	uint32_t head = atomic_load_acq_32(
	    __DEVOLATILE(uint32_t *, &sc->sc_input_head));
	uint32_t key;

	if (tail == head)
		return (-1);

	key = sc->sc_input[tail & INPUTFS_KBD_BUF_MASK];
	atomic_store_rel_32(__DEVOLATILE(uint32_t *, &sc->sc_input_tail),
	    tail + 1);
	return ((int32_t)key);
}

/*
 * inputfs_kbd_input_pending -- true if get_key would return
 * a byte (non-blocking peek). Used by check_char.
 *
 * No mutation; safe to call from any context that respects
 * the consumer-side serialisation rule.
 */
static int
inputfs_kbd_input_pending(struct inputfs_kbd_softc *sc)
{
	uint32_t tail = sc->sc_input_tail;
	uint32_t head = atomic_load_acq_32(
	    __DEVOLATILE(uint32_t *, &sc->sc_input_head));
	return (tail != head);
}

/*
 * inputfs_kbd_emit_at -- translate one HID keyboard transition
 * to AT scancode byte(s) and push them to the ring.
 *
 * Inputs:
 *   sc:        bridge instance.
 *   hid_usage: 0x00..0xFF, the HID Keyboard/Keypad usage page
 *              code from inputfs's keyboard parser.
 *   is_down:   1 for press, 0 for release.
 *
 * Output:
 *   1 ring entry pushed (or 0 if hid_usage has no AT mapping).
 *   The ring entry is the AT scancode byte: trtab[hid_usage]
 *   for press, or trtab[hid_usage] | 0x80 for release.
 *
 * Scope of this v1
 *
 * Step 2 emits single-byte AT scancodes. The trtab values are
 * AT keycode-set-1 numbers in the FreeBSD-internal convention;
 * for the keys involved in console login (letters, digits,
 * Enter, Backspace, Tab, Space, Shift, Control, the standard
 * function keys, and the alphanumeric punctuation row) this is
 * the correct wire encoding for kbdmux's K_RAW input.
 *
 * Extended-key handling (the 0xE0 prefix byte for keys like
 * arrows, right-side modifiers, Insert/Delete/Home/End/PgUp/
 * PgDn) is deferred. The native ukbd / hkbd implementations
 * use a separate table inside their `key2scan` function to
 * decide which keycodes need the prefix; that table is not
 * trivial to port without reading the FreeBSD source closely,
 * and the keys it covers are not required for the minimal
 * console-login path that step 7's verification protocol
 * exercises first.
 *
 * If step 7 verification reveals that arrows or other
 * extended keys are needed for the operator workflow before
 * step 8's default-on flip, a small follow-up (call it step
 * 2.5) adds the prefix-E0 table and emits two ring entries
 * (0xE0 then the scancode) for affected keys. Until then,
 * extended keys produce their non-extended equivalent (e.g.,
 * Up arrow may produce keypad-8 behavior under NumLock-on
 * vt(4) state) which is benign for login but suboptimal for
 * normal use.
 */
static void
inputfs_kbd_emit_at(struct inputfs_kbd_softc *sc, uint8_t hid_usage,
    int is_down)
{
	uint16_t entry;
	uint8_t prefix, scancode;

	/*
	 * hid_usage is uint8_t (range 0..255). The trtab has
	 * exactly INPUTFS_KBD_NKEYCODE (256) entries, so any
	 * hid_usage value indexes safely. The file-scope
	 * CTASSERT near INPUTFS_KBD_NKEYCODE pins the
	 * relationship; if either side ever changes the build
	 * catches the mismatch.
	 *
	 * Trtab encoding (added in step 2.5):
	 *   0x0000   no AT translation, drop.
	 *   0x00XX   single byte XX, no prefix.
	 *   0xE0XX   two bytes: 0xE0 prefix then XX.
	 *
	 * AT scancode set 1 release semantics: the 0x80 bit on
	 * the scancode means release. The prefix byte is
	 * unchanged for press vs release; only the scancode
	 * carries the bit. emit_at applies the bit after the
	 * prefix has been pushed.
	 */
	entry = inputfs_kbd_trtab[hid_usage];
	if (entry == 0x0000)
		return; /* no AT translation; HID usage not console-relevant */

	prefix   = (uint8_t)(entry >> 8);
	scancode = (uint8_t)(entry & 0xFF);

	if (prefix != 0)
		inputfs_kbd_put_key(sc, (uint32_t)prefix);

	if (!is_down)
		scancode |= INPUTFS_KBD_SCAN_RELEASE;

	inputfs_kbd_put_key(sc, (uint32_t)scancode);
}

/* ---------------------------------------------------------------- */
/*  AD-10.5 step 3: producer hook + deferred kbdmux notification    */
/* ---------------------------------------------------------------- */

/*
 * Step-3 scope note: the function inputfs_kbd_intr_cb below has
 * no callers yet. Step 4 wires it into inputfs_keyboard_diff_emit
 * (in inputfs.c) and instantiates the per-keyboard bridge softc
 * via kbd_register; until that lands, intr_cb cannot fire because
 * no inputfs keyboard device has a bridge softc to invoke it on.
 *
 * Step 3 also adds the taskqueue notification function
 * (inputfs_kbd_notify_task) which kbd_event_keyinput-style
 * deferred wakeup uses. Same situation: no enqueue site yet, so
 * the function is dead until step 4. Both are __unused-tagged
 * for the same reason as step 2's helpers.
 *
 * The split between intr_cb and notify_task implements the
 * spin-mutex-to-Giant handoff documented in ADR 0019 §5:
 *
 *   producer (inputfs HID intr context, MTX_SPIN held)
 *     -> inputfs_kbd_intr_cb
 *        -> inputfs_kbd_emit_at (lockless ring write)
 *        -> taskqueue_enqueue(taskqueue_fast, sc_task)
 *
 *   later, at SWI thread context, Giant available
 *     -> inputfs_kbd_notify_task
 *        -> mtx_lock(&Giant)
 *        -> kb_callback.kc_func(KBDIO_KEYINPUT)
 *        -> mtx_unlock(&Giant)
 *
 * The kb_callback path is what kbdmux registers when it allocates
 * a slave; the callback is set by kbdmux's allocator
 * (kbdmux_kbd_event), and KBDIO_KEYINPUT tells it "data is ready
 * on this slave's ring; come drain via kbdd_check_char and
 * kbdd_read_char." kbdmux's callback runs at its own taskqueue's
 * context and serialises with the kbdsw layer correctly.
 *
 * Failure-mode considerations:
 *
 *   - Repeated taskqueue_enqueue calls between the task running.
 *     FreeBSD's taskqueue tracks task pending state internally
 *     and a second enqueue while the first is pending is a no-op
 *     (the task runs once per pending-clear). The bridge's
 *     repeated enqueue calls are therefore cheap and correct.
 *
 *   - Task running while a fresh interrupt populates more ring
 *     entries. Producer side is lockless on the ring; consumer
 *     side (kbdmux's kbdd_read_char calls) iterates until empty.
 *     Both safe; the lockless SPSC ring's atomic load-acquire
 *     sees later head writes.
 *
 *   - kbd_callback.kc_func == NULL (nobody listening). kbdmux
 *     sets this when it allocates a slave, so under normal
 *     conditions it is non-NULL by the time intr_cb fires (step 4
 *     calls kbd_register only after kbdmux is loaded; ADR 0019
 *     §2). The task function defensively skips the kb_callback
 *     when func is NULL, so a misconfigured state silently drops
 *     notifications rather than crashing.
 */

/*
 * inputfs_kbd_notify_task -- taskqueue task: notify kbdmux that
 * scancodes are pending in this slave's ring.
 *
 * Caller context:
 *   - Run by taskqueue_fast's SWI thread (or whichever
 *     taskqueue inputfs_kbd_intr_cb enqueued onto).
 *     SWI thread context; sleeping locks legal; Giant
 *     safe to acquire. Per John Baldwin (freebsd-arch
 *     May 2013): "swi's run in an interrupt thread, and
 *     interrupt threads can use regular mutexes." The
 *     "fast" qualifier on the queue affects only the
 *     enqueue path (uses spin locks so producers can call
 *     from spin context); dispatch is still in a normal
 *     SWI thread.
 *
 * What it does:
 *   - Acquires Giant (the kbd-layer's required lock for
 *     callback invocation).
 *   - Calls kb_callback.kc_func(kbd, KBDIO_KEYINPUT, kc_arg)
 *     if the callback function pointer is non-NULL.
 *   - Releases Giant.
 *
 * The function does NOT drain the ring itself. kbdmux's callback
 * is responsible for calling back through kbdd_read_char to
 * dequeue scancodes; this task just prods kbdmux to do so. The
 * separation matches FreeBSD's standard kbd-layer protocol and
 * avoids the bridge holding Giant longer than necessary.
 */
static void
inputfs_kbd_notify_task(void *context, int pending __unused)
{
	struct inputfs_kbd_softc *sc = context;
	keyboard_t *kbd = &sc->sc_kbd;

	mtx_lock(&Giant);
	if (kbd->kb_callback.kc_func != NULL) {
		(*kbd->kb_callback.kc_func)(kbd, KBDIO_KEYINPUT,
		    kbd->kb_callback.kc_arg);
	}
	mtx_unlock(&Giant);
}

/*
 * inputfs_kbd_intr_cb -- producer hook: translate one HID
 * keyboard transition to AT scancodes and notify kbdmux.
 *
 * This function is the bridge's integration point with inputfs's
 * keyboard parser. Step 4 wires it into
 * inputfs_keyboard_diff_emit at the four existing
 * inputfs_events_publish call sites (modifier ups, array key
 * ups, modifier downs, array key downs).
 *
 * Inputs:
 *   sc:        bridge softc for the producing inputfs keyboard.
 *              Looked up by inputfs.c via the back-pointer it
 *              maintains on the inputfs keyboard's own softc.
 *   hid_usage: the HID Keyboard/Keypad usage page code from
 *              inputfs's keyboard parser. For modifier
 *              transitions, inputfs.c synthesises 0xE0 + bit
 *              (Left Ctrl through Right Meta); for array-key
 *              transitions, the usage byte from the report.
 *   is_down:   1 for press, 0 for release.
 *
 * What it does:
 *   1. Calls inputfs_kbd_emit_at to translate hid_usage to AT
 *      scancode via the trtab and push into the lockless ring.
 *      If trtab returns NN (no AT mapping; e.g., Power, Kana),
 *      the function silently no-ops and no notification is
 *      scheduled.
 *   2. Schedules the per-instance taskqueue task to notify
 *      kbdmux that data is ready. taskqueue_enqueue is
 *      idempotent against an already-pending task — repeated
 *      calls collapse to a single deferred run, which is
 *      correct semantically (kbdmux drains the entire ring on
 *      each notification).
 *
 * Caller context:
 *   - inputfs's HID interrupt handler path, under
 *     inputfs_state_mtx (MTX_SPIN). The lockless ring write is
 *     safe under spin context; taskqueue_enqueue is also safe
 *     (it uses its own internal locking and does not block).
 *
 * Failure modes:
 *   - sc == NULL: caller bug; defensive null-check returns
 *     without doing anything. Step 4 ensures the back-pointer
 *     is non-NULL only when a bridge softc has been allocated
 *     and registered.
 *   - emit_at no-op (trtab[hid_usage] == 0): function returns
 *     without scheduling, because there's nothing for kbdmux
 *     to drain. This is correct: a redundant notification on
 *     an empty ring would still produce no console output but
 *     wastes a taskqueue cycle.
 *
 * Skipping the enqueue when emit_at didn't push anything is a
 * minor optimisation. Implementing requires emit_at to return
 * a "did push" indication. To keep emit_at's signature simple
 * and the failure-mode analysis monotonic (every call results
 * in at most one notification), we always enqueue. The cost is
 * negligible and the code stays simpler.
 */
static void
inputfs_kbd_intr_cb(struct inputfs_kbd_softc *sc, uint8_t hid_usage,
    int is_down)
{
	if (sc == NULL)
		return;

	inputfs_kbd_emit_at(sc, hid_usage, is_down);

	/*
	 * Schedule the deferred kbdmux notification. Idempotent
	 * against a task already pending; harmless to call from
	 * the spin-mutex-protected interrupt context.
	 *
	 * taskqueue_fast (NOT taskqueue_swi) is required here:
	 * the producer runs under inputfs_state_mtx (MTX_SPIN)
	 * via the HID intr path, and only taskqueue_fast uses
	 * spin locks internally for its enqueue. taskqueue_swi
	 * uses a sleep mutex internally; calling
	 * taskqueue_enqueue(taskqueue_swi, ...) from spin
	 * context trips WITNESS with "acquiring blockable
	 * sleep lock with spinlock or critical section held"
	 * (subr_taskqueue.c:308). Bench-observed in step 7
	 * verification before the previous fixup.
	 *
	 * Note on the API: FreeBSD review D5131 (Jan 2016)
	 * removed the separate taskqueue_enqueue_fast function;
	 * since then taskqueue_enqueue itself dispatches to the
	 * right internal locking based on the queue's type.
	 * Calling taskqueue_enqueue with taskqueue_fast as the
	 * queue argument uses spin locks internally, which is
	 * what we need from spin context. The previous fixup
	 * tried to call taskqueue_enqueue_fast, which built
	 * fine on older FreeBSDs but fails on 15.0 with
	 * "use of undeclared function 'taskqueue_enqueue_fast'".
	 *
	 * The dispatch side runs in an interrupt thread regardless
	 * of which fast/swi queue we use, so notify_task can still
	 * acquire Giant from there. The "fast" qualifier applies
	 * only to the enqueue path; the task body itself runs in
	 * a normal SWI thread context where regular mutexes are
	 * fine. See John Baldwin, freebsd-arch May 2013: "swi's
	 * run in an interrupt thread, and interrupt threads can
	 * use regular mutexes."
	 */
	taskqueue_enqueue(taskqueue_fast, &sc->sc_task);
}

/* ---------------------------------------------------------------- */
/*  AD-10.5 step 1 (continued): kbdsw vtable stubs                  */
/* ---------------------------------------------------------------- */

/*
 * Forward declarations for the kbdsw vtable. Each callback's
 * full implementation is below in the same order kbdreg.h
 * declares them in keyboard_switch_t.
 */
static kbd_probe_t              inputfs_kbd_sw_probe;
static kbd_init_t               inputfs_kbd_sw_init;
static kbd_term_t               inputfs_kbd_sw_term;
static kbd_intr_t               inputfs_kbd_sw_intr;
static kbd_test_if_t            inputfs_kbd_sw_test_if;
static kbd_enable_t             inputfs_kbd_sw_enable;
static kbd_disable_t            inputfs_kbd_sw_disable;
static kbd_read_t               inputfs_kbd_sw_read;
static kbd_check_t              inputfs_kbd_sw_check;
static kbd_read_char_t          inputfs_kbd_sw_read_char;
static kbd_check_char_t         inputfs_kbd_sw_check_char;
static kbd_ioctl_t              inputfs_kbd_sw_ioctl;
static kbd_lock_t               inputfs_kbd_sw_lock;
static kbd_clear_state_t        inputfs_kbd_sw_clear_state;
static kbd_get_state_t          inputfs_kbd_sw_get_state;
static kbd_set_state_t          inputfs_kbd_sw_set_state;
static kbd_poll_mode_t          inputfs_kbd_sw_poll;

/*
 * Skeleton implementations. Step 1 returns "no activity" or
 * "operation not supported" from each callback. This is safe
 * because step 1 also does not call kbd_register; with no
 * keyboard instances registered, kbdmux will never invoke any
 * of these callbacks. The implementations exist purely to make
 * the kbdsw vtable complete (FreeBSD's kbd layer requires every
 * non-NULL function pointer to be valid; NULL is rejected at
 * driver registration in some code paths, so explicit stubs
 * are safer than NULLs even where NULL would mean "not
 * implemented").
 *
 * Subsequent steps replace these with real implementations:
 *   step 2: clear_state, get_state, set_state, lock (softc
 *     and per-keyboard ring buffer)
 *   step 3: read, read_char, check, check_char (consume
 *     scancodes from the ring under polling and callback-
 *     driven access)
 *   step 4: probe, init, term, enable, disable (instance
 *     lifecycle from inputfs's keyboard attach path)
 *   step 5: ioctl (KDSKBMODE, KDSETLED, KDGKBSTATE etc.,
 *     including the K_RAW mode that kbdmux requires)
 */

static int
inputfs_kbd_sw_probe(int unit, void *arg, int flags)
{
	(void)unit; (void)arg; (void)flags;
	/*
	 * Probe is only meaningful for self-driven instances
	 * (devices that the kbd layer is asked to discover). The
	 * bridge is not self-driven; instances appear as
	 * inputfs's own attach path calls kbd_register. ENXIO
	 * tells callers "no device by that unit number found by
	 * autoprobe."
	 */
	return (ENXIO);
}

static int
inputfs_kbd_sw_init(int unit, keyboard_t **kbdpp, void *arg, int flags)
{
	(void)unit; (void)kbdpp; (void)arg; (void)flags;
	/*
	 * Same rationale as probe: the bridge does not get
	 * autoprobed. Step 4 will populate this with the real
	 * per-instance setup (kbd_init_struct, kbd_set_maps,
	 * KBD_FOUND_DEVICE / KBD_PROBE_DONE / KBD_INIT_DONE).
	 */
	return (ENXIO);
}

static int
inputfs_kbd_sw_term(keyboard_t *kbd)
{
	(void)kbd;
	/* Step 4 fills this in alongside init. */
	return (ENXIO);
}

static int
inputfs_kbd_sw_intr(keyboard_t *kbd, void *arg)
{
	(void)kbd; (void)arg;
	/*
	 * Bridge has no hardware interrupt to service; inputfs's
	 * HID interrupt path handles report ingestion. Returning
	 * 0 signals "nothing to do," which is correct.
	 */
	return (0);
}

static int
inputfs_kbd_sw_test_if(keyboard_t *kbd)
{
	(void)kbd;
	/* Operation not supported; the bridge is virtual. */
	return (ENODEV);
}

static int
inputfs_kbd_sw_enable(keyboard_t *kbd)
{
	/*
	 * Mark the keyboard active. Called by the kbd-layer
	 * (typically from kbdmux during enslavement, or by
	 * kbd_register itself) to transition the instance into
	 * the active state. The active flag gates kbdsw
	 * dispatcher behavior: KBD_IS_ACTIVE is checked by
	 * read_char/check_char before consulting our ring, so
	 * an inactive keyboard always reports NOKEY/FALSE.
	 */
	KBD_ACTIVATE(kbd);
	return (0);
}

static int
inputfs_kbd_sw_disable(keyboard_t *kbd)
{
	KBD_DEACTIVATE(kbd);
	return (0);
}

static int
inputfs_kbd_sw_read(keyboard_t *kbd, int wait __unused)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;
	int32_t key;

	if (!KBD_IS_ACTIVE(kbd) || sc == NULL)
		return (-1);

	/*
	 * The kbd-layer "read" semantics return the next byte or
	 * -1 if nothing pending. Our ring entries are AT scancode
	 * bytes (with the SCAN_RELEASE high bit for releases);
	 * read just returns the next one. Wait is ignored: we do
	 * not block in interrupt or callback paths.
	 */
	key = inputfs_kbd_get_key(sc);
	if (key == -1)
		return (-1);
	kbd->kb_count++;
	return ((int)(key & 0xff));
}

static int
inputfs_kbd_sw_check(keyboard_t *kbd)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;

	if (!KBD_IS_ACTIVE(kbd) || sc == NULL)
		return (FALSE);
	return (inputfs_kbd_input_pending(sc) ? TRUE : FALSE);
}

static u_int
inputfs_kbd_sw_read_char(keyboard_t *kbd, int wait __unused)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;
	int32_t key;

	if (!KBD_IS_ACTIVE(kbd) || sc == NULL)
		return (NOKEY);

	/*
	 * In K_RAW mode (which kbdmux unconditionally sets on
	 * slave keyboards per kbdmux(4)), read_char returns the
	 * next AT scancode byte verbatim. Our ring already holds
	 * AT scancode bytes (with the high bit set for releases);
	 * we just return them.
	 *
	 * K_XLATE mode (used by autonomous keyboards talking to
	 * vt(4) directly without kbdmux) would translate the
	 * scancode through the keymap into a character action
	 * here. The bridge is designed to be enslaved by kbdmux,
	 * not to be a primary console driver, so we treat all
	 * modes as K_RAW for simplicity. If a future kbdcontrol
	 * -k /dev/inputfs_kbdN < /dev/console attempts to use
	 * the bridge as primary, behavior degrades to "raw
	 * scancodes only" rather than crashing.
	 */
	key = inputfs_kbd_get_key(sc);
	if (key == -1)
		return (NOKEY);
	kbd->kb_count++;
	return ((u_int)(key & 0xff));
}

static int
inputfs_kbd_sw_check_char(keyboard_t *kbd)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;

	if (!KBD_IS_ACTIVE(kbd) || sc == NULL)
		return (FALSE);
	return (inputfs_kbd_input_pending(sc) ? TRUE : FALSE);
}

static int
inputfs_kbd_sw_ioctl(keyboard_t *kbd, u_long cmd, caddr_t data)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;
	int i;

	if (sc == NULL)
		return (ENODEV);

	switch (cmd) {
	case KDGKBMODE:
		*(int *)data = sc->sc_mode;
		return (0);

	case KDSKBMODE:
		/*
		 * kbdmux unconditionally sets K_RAW on enslaved
		 * slave keyboards (per kbdmux(4)). The bridge
		 * accepts any of K_XLATE, K_RAW, K_CODE without
		 * actually changing translation behavior; our
		 * ring always holds AT scancode bytes and
		 * read_char returns them verbatim regardless of
		 * mode. Accepting all three modes is what hkbd
		 * and atkbd do as well; only the actively
		 * console-driving state machine cares about the
		 * distinction, and that lives in vt(4).
		 */
		i = *(int *)data;
		if (i != K_XLATE && i != K_RAW && i != K_CODE)
			return (EINVAL);
		sc->sc_mode = i;
		return (0);

	case KDGETLED:
		*(int *)data = (sc->sc_state & LOCK_MASK);
		return (0);

	case KDSETLED:
		/*
		 * Caps/Num/Scroll lock LED state from kbdmux.
		 * The bridge doesn't drive any physical LEDs
		 * (it has no hardware); inputfs's HID layer
		 * could theoretically forward this to the HID
		 * device's output report, but that path is out
		 * of scope here. Just record the state so
		 * subsequent KDGETLED returns it consistently.
		 */
		sc->sc_state = (sc->sc_state & ~LOCK_MASK) |
		    (*(int *)data & LOCK_MASK);
		return (0);

	case KDGKBSTATE:
		*(int *)data = (sc->sc_state & LOCK_MASK);
		return (0);

	case KDSKBSTATE:
		i = *(int *)data;
		if (i & ~LOCK_MASK)
			return (EINVAL);
		sc->sc_state &= ~LOCK_MASK;
		sc->sc_state |= i;
		return (0);

	case KDSETREPEAT:
		/*
		 * Typematic repeat rate; kbdmux passes its own
		 * configured rate down. The bridge has no
		 * autorepeat (HID devices generate repeat events
		 * themselves and the parser passes them through),
		 * so we just accept and discard. atkbd's
		 * implementation actually programs the controller;
		 * for the bridge there is no controller to
		 * program.
		 */
		return (0);

	case KDSETRAD:		/* deprecated alias for KDSETREPEAT */
		return (0);

	case PIO_KEYMAP:
	case PIO_KEYMAPENT:
	case PIO_DEADKEYMAP:
		/*
		 * Keymap modification ioctls. kbdmux owns the
		 * keymap that vt(4) sees; the bridge's keymap is
		 * vestigial. Returning ENOIOCTL here is the
		 * standard "this driver doesn't implement that
		 * ioctl" reply; kbdcontrol may report an error
		 * if pointed at our /dev/kbd<N>, which is fine
		 * because the bridge is not designed to be a
		 * primary console keyboard target.
		 */
		return (ENOIOCTL);

	default:
		return (ENOIOCTL);
	}
}

static int
inputfs_kbd_sw_lock(keyboard_t *kbd, int lock)
{
	(void)kbd; (void)lock;
	/*
	 * Per-instance kbd-layer lock acquire/release. Real
	 * implementation in step 2 wraps the bridge softc's
	 * private mutex. Returning 0 here is safe because no
	 * instances exist to lock.
	 */
	return (0);
}

static void
inputfs_kbd_sw_clear_state(keyboard_t *kbd)
{
	struct inputfs_kbd_softc *sc = (struct inputfs_kbd_softc *)kbd->kb_data;

	if (sc == NULL)
		return;
	/*
	 * Reset the kbd-layer instance state fields. The
	 * lockless ring is intentionally NOT drained here:
	 * pending scancodes from before the clear are still
	 * valid, and clear_state is called by kbdmux during
	 * enslavement before the K_RAW transition. Dropping
	 * pending input would be incorrect.
	 */
	sc->sc_state = 0;
	sc->sc_accents = 0;
}

static int
inputfs_kbd_sw_get_state(keyboard_t *kbd, void *buf, size_t len)
{
	(void)kbd; (void)buf; (void)len;
	/*
	 * Read instance state into a userland buffer (used by
	 * console driver suspend/resume). Step 2 implements with
	 * the softc layout. Returns size or -1; -1 here means
	 * "operation not supported on this driver" which is
	 * equivalent to the no-instance case.
	 */
	return (-1);
}

static int
inputfs_kbd_sw_set_state(keyboard_t *kbd, void *buf, size_t len)
{
	(void)kbd; (void)buf; (void)len;
	/* Symmetric with get_state. */
	return (-1);
}

static int
inputfs_kbd_sw_poll(keyboard_t *kbd, int on)
{
	(void)kbd; (void)on;
	/*
	 * Polling-mode toggle (used by kdb / panic recovery).
	 * Step 5 sets a flag in the softc that read_char
	 * consults to bypass the callback path. Returning 0
	 * (success) is safe in step 1 because there is no
	 * instance to put into polling mode anyway.
	 */
	return (0);
}

/*
 * The kbdsw vtable. Order MUST match the keyboard_switch_t
 * definition in kbdreg.h:
 *
 *   probe, init, term, intr, test_if, enable, disable, read,
 *   check, read_char, check_char, ioctl, lock, clear_state,
 *   get_state, set_state, get_fkeystr, poll, diag.
 *
 * Two slots (get_fkeystr, diag) are left NULL; kbd_add_driver
 * patches in the generic kbd-layer implementations during
 * registration (see review D22835). On older FreeBSD branches
 * the genkbd_* symbols were exported as public functions and
 * drivers wired them up explicitly; modern branches keep them
 * static inside kbd.c and use the auto-fill path. PGSD targets
 * FreeBSD 14+ which has the auto-fill.
 */
static keyboard_switch_t inputfs_kbd_sw = {
	.probe       = inputfs_kbd_sw_probe,
	.init        = inputfs_kbd_sw_init,
	.term        = inputfs_kbd_sw_term,
	.intr        = inputfs_kbd_sw_intr,
	.test_if     = inputfs_kbd_sw_test_if,
	.enable      = inputfs_kbd_sw_enable,
	.disable     = inputfs_kbd_sw_disable,
	.read        = inputfs_kbd_sw_read,
	.check       = inputfs_kbd_sw_check,
	.read_char   = inputfs_kbd_sw_read_char,
	.check_char  = inputfs_kbd_sw_check_char,
	.ioctl       = inputfs_kbd_sw_ioctl,
	.lock        = inputfs_kbd_sw_lock,
	.clear_state = inputfs_kbd_sw_clear_state,
	.get_state   = inputfs_kbd_sw_get_state,
	.set_state   = inputfs_kbd_sw_set_state,
	/*
	 * .get_fkeystr and .diag are intentionally left NULL.
	 * Modern FreeBSD's kbd_add_driver (per review D22835)
	 * patches in the generic implementations
	 * (genkbd_get_fkeystr, genkbd_diag) when these slots are
	 * NULL during driver registration. The genkbd_* symbols
	 * themselves are static within sys/dev/kbd/kbd.c and not
	 * exported to drivers, so we cannot assign them directly;
	 * the auto-fill is the supported path.
	 *
	 * On older FreeBSD branches without the auto-fill (pre-2020,
	 * before D22835 landed), the kbd-layer would crash on
	 * NULL .get_fkeystr because the dispatcher macro
	 * dereferences the pointer unconditionally. PGSD targets
	 * FreeBSD 14.0+ which has the auto-fill, so the NULL is
	 * safe.
	 */
	.poll        = inputfs_kbd_sw_poll,
};

/*
 * keyboard_driver_t aggregate that the SYSINIT at the bottom of
 * the file registers via kbd_add_driver.
 *
 * The definition lives here, above inputfs_kbd_bridge_attach,
 * because the bridge attach debug log reads .name and .kbdsw to
 * compare against what kbd_register's strcmp loop will see in
 * the SLIST. C requires the symbol to be visible at the point of
 * use; placing the driver struct here is the simplest option.
 *
 * Designated initialisers (added in step 4a fixup) keep the init
 * layout-robust. The full rationale lives in that fixup commit.
 */
static keyboard_driver_t inputfs_kbd_driver = {
	.name      = INPUTFS_KBD_DRIVER_NAME,	/* "inputfs_kbd" */
	.kbdsw     = &inputfs_kbd_sw,
	.configure = NULL,			/* no console-driver backdoor */
	/* link, flags: zero-initialised by C semantics. */
};

/* ---------------------------------------------------------------- */
/*  AD-10.5 step 4a: bridge attach/detach API for inputfs.c         */
/* ---------------------------------------------------------------- */

/*
 * inputfs_kbd_bridge_attach -- create one bridge softc for an
 * inputfs keyboard device and register it with the kbd layer.
 *
 * Caller is inputfs_attach in inputfs.c, after a HID descriptor
 * has been parsed and inputfs_keyboard_locate has returned with
 * keyboard_locations_valid == true.
 *
 * What this function does:
 *
 *   1. Allocate a struct inputfs_kbd_softc (M_INPUTFS, M_WAITOK |
 *      M_ZERO). The softc contains the embedded keyboard_t
 *      (sc_kbd), the kbd-layer keymap fields, the SPSC ring, and
 *      the per-instance taskqueue task.
 *
 *   2. TASK_INIT the deferred-notification task. The task runs
 *      inputfs_kbd_notify_task with sc as context; step 3's
 *      intr_cb (when wired in step 4b) enqueues this task to
 *      hand off from the spin-mutex-protected interrupt context
 *      to a Giant-protected process context.
 *
 *   3. kbd_init_struct: tell the kbd layer the keyboard's name
 *      ("inputfs_kbd"), type, unit number, and config flags.
 *
 *   4. kbd_set_maps: attach the (intentionally empty) keymap,
 *      accent map, and fkey table. These are vestigial under
 *      kbdmux's K_RAW operating mode but the kbd layer requires
 *      non-NULL pointers.
 *
 *   5. Set kb_data to the bridge softc so kbdsw callbacks can
 *      reach it via kbd->kb_data.
 *
 *   6. Mark the keyboard KBD_FOUND_DEVICE, KBD_PROBE_DONE,
 *      KBD_INIT_DONE so the kbd-layer registration sees a fully
 *      initialised instance and does not call back into our
 *      probe/init stubs.
 *
 *   7. kbd_register: announce the keyboard to the kbd layer.
 *      This is what makes /dev/kbd<N> appear and (if kbdmux is
 *      loaded) what triggers kbdmux to pick the keyboard up as
 *      a slave via its own KBADDKBD handling.
 *
 * Return: opaque void * to the bridge softc, or NULL on
 *         failure (allocation error or kbd_register rejection).
 *
 * Failure modes
 *
 *   - malloc returns NULL only if M_WAITOK is somehow violated
 *     (panic-equivalent in normal kernel context). Effectively
 *     unreachable; we still check defensively.
 *
 *   - kbd_register can fail if the unit number conflicts with
 *     an existing kbd instance under the same driver name. With
 *     unit == device_get_unit(dev), conflicts only happen if
 *     two inputfs<N> devices share a unit number, which the
 *     NEWBUS allocator does not permit. Defensive handling
 *     logs and frees the softc.
 */
void *
inputfs_kbd_bridge_attach(int unit)
{
	struct inputfs_kbd_softc *sc;
	keyboard_t *kbd;
	int error;

	sc = malloc(sizeof(*sc), M_INPUTFS, M_WAITOK | M_ZERO);
	if (sc == NULL) {
		printf("inputfs_kbd: bridge softc alloc failed (unit=%d)\n",
		    unit);
		return (NULL);
	}

	sc->sc_fkeymap_size = NUM_FKEYS;

	/*
	 * Initialise the deferred-notification task. The task runs
	 * inputfs_kbd_notify_task with the bridge softc as context;
	 * the producer hook (inputfs_kbd_intr_cb) enqueues this
	 * task on taskqueue_fast when scancodes are pushed to the
	 * ring.
	 */
	TASK_INIT(&sc->sc_task, 0, inputfs_kbd_notify_task, sc);

	kbd = &sc->sc_kbd;

	/*
	 * Initialise the kbd-layer instance. KB_101 is the generic
	 * "101-key keyboard" type that hkbd, ukbd, and atkbd all
	 * report; it tells the kbd layer roughly what to expect
	 * without claiming any specific protocol variant.
	 */
	kbd_init_struct(kbd, INPUTFS_KBD_DRIVER_NAME, KB_101, unit, 0, 0, 0);
	kbd_set_maps(kbd, &sc->sc_keymap, &sc->sc_accmap, sc->sc_fkeymap,
	    sc->sc_fkeymap_size);
	kbd->kb_data = sc;

	KBD_FOUND_DEVICE(kbd);
	KBD_PROBE_DONE(kbd);
	KBD_INIT_DONE(kbd);

	/*
	 * kbd_register makes the keyboard visible to the kbd layer
	 * and (transitively) to kbdmux. After this call, /dev/kbdN
	 * symlinks to /dev/inputfs_kbd<unit> and kbdsw callbacks
	 * may begin firing on this instance.
	 */

	/*
	 * kbd_register's contract (per /usr/src/sys/dev/kbd/kbd.c):
	 *   - returns the new keyboard slot index (≥ 0) on success
	 *   - returns -1 on failure (no free slot, or driver name
	 *     not in keyboard_drivers SLIST)
	 *
	 * Step 4a originally treated any non-zero return as failure,
	 * which is wrong: when the kbd layer is given the first
	 * non-kbdmux keyboard, the slot index is 1, then 2, then 3,
	 * etc. Those are success returns. The bridge softc was being
	 * freed after a successful kbd_register, leaving a dangling
	 * keyboard_t pointer in the kbd layer's keyboard[] array
	 * pointing into freed memory. The fix is the < 0 check.
	 */
	error = kbd_register(kbd);
	if (error < 0) {
		printf("inputfs_kbd: kbd_register(unit=%d) failed\n",
		    unit);
		free(sc, M_INPUTFS);
		return (NULL);
	}

	KBD_CONFIG_DONE(kbd);

	printf("inputfs_kbd%d: registered (kbd_index=%d)\n",
	    unit, kbd->kb_index);

	return (sc);
}

/*
 * inputfs_kbd_bridge_detach -- tear down a bridge softc.
 *
 * Symmetric with attach. Drains the per-instance taskqueue task
 * (so any in-flight kb_callback delivery completes before we
 * free the softc), unregisters from the kbd layer, frees the
 * softc.
 *
 * NULL bridge is tolerated as a no-op so callers in
 * inputfs_detach can call unconditionally without checking
 * whether attach succeeded.
 *
 * Caller context: inputfs_detach. Process context.
 * taskqueue_drain may sleep, so callers must not hold spin
 * mutexes.
 */
void
inputfs_kbd_bridge_detach(void *bridge)
{
	struct inputfs_kbd_softc *sc = bridge;
	keyboard_t *kbd;
	int unit;

	if (sc == NULL)
		return;

	kbd = &sc->sc_kbd;
	unit = kbd->kb_unit;

	/*
	 * Order matters: drain the taskqueue first so no in-flight
	 * notify_task can dereference sc after we free it. Then
	 * unregister from the kbd layer (this severs the kb_index
	 * mapping and tears down the /dev/kbdN symlink). Finally
	 * free the softc.
	 *
	 * KBDIO_UNLOADING delivery to kbdmux happens inside
	 * kbd_unregister via the kb_callback path, so we don't
	 * need to fire that ourselves.
	 */
	taskqueue_drain(taskqueue_fast, &sc->sc_task);
	(void)kbd_unregister(kbd);

	printf("inputfs_kbd%d: unregistered\n", unit);

	free(sc, M_INPUTFS);
}

/*
 * inputfs_kbd_bridge_intr_cb -- public wrapper around the
 * internal inputfs_kbd_intr_cb for callers in inputfs.c.
 *
 * AD-10.5 step 4b: this is the producer hook called from
 * inputfs_keyboard_diff_emit at each of its four publish sites
 * (modifier ups, array key ups, modifier downs, array key
 * downs). The internal intr_cb takes a typed
 * struct inputfs_kbd_softc *; the wrapper takes the opaque
 * void * pointer that inputfs.c stores in sc->sc_kbd_bridge.
 *
 * This wrapper is the single point at which the bridge's
 * private softc type meets the public API. Keeping
 * intr_cb internal preserves the type for emit_at and
 * put_key (which both want struct inputfs_kbd_softc * for
 * direct field access) without forcing the header to expose
 * the layout.
 *
 * The gate (hw.inputfs.kbdmux_bridge sysctl) is checked by
 * the caller in inputfs.c before this wrapper is invoked, so
 * we don't re-check it here. Callers must not invoke the
 * wrapper if the gate is 0 — that's the contract; the wrapper
 * does no work to verify it. This avoids a redundant load on
 * every transition when the gate is 1.
 *
 * NULL bridge is tolerated as a no-op: the caller normally
 * checks sc->sc_kbd_bridge != NULL but a defensive guard here
 * keeps the wrapper safe against accidental misuse.
 *
 * Caller context: inputfs_keyboard_diff_emit is called under
 * the inputfs_state_mtx spin mutex. The wrapper inherits that
 * context. inputfs_kbd_intr_cb's body is lockless (atomic
 * SPSC ring write) plus a taskqueue_enqueue (which is
 * spin-mutex-safe), so the spin context is preserved.
 */
void
inputfs_kbd_bridge_intr_cb(void *bridge, uint8_t hid_usage, int is_down)
{
	struct inputfs_kbd_softc *sc = bridge;

	if (sc == NULL)
		return;
	inputfs_kbd_intr_cb(sc, hid_usage, is_down);
}

/*
 * Module load/unload integration with the rest of inputfs.
 *
 * inputfs.c declares MODULE_VERSION and DRIVER_MODULE for the
 * NEWBUS hidbus child driver. We extend the same module with a
 * keyboard_driver_t registered via kbd_add_driver at SYSINIT
 * time and de-registered via kbd_delete_driver at SYSUNINIT. This
 * keeps the bridge inside the inputfs module rather than splitting
 * it into a separate kld; the bridge is operationally inseparable
 * from inputfs (its data source is inputfs's HID parser) so there
 * is no scenario where one is loaded without the other.
 *
 * Why not the KEYBOARD_DRIVER macro: that macro adds a static
 * struct to the kbddriver_set linker set, which kbd.c processes
 * during cninit. For a built-in driver that pattern works fine.
 * For a kld, the explicit kbd_add_driver / kbd_delete_driver pair
 * gives clean load/unload symmetry: kldunload of the inputfs
 * module fully removes the driver name from the kbd layer's
 * driver list. With KEYBOARD_DRIVER the kld load and unload still
 * work (kbd_add_driver is idempotent against the linker set since
 * FreeBSD review D22835, January 2020), but the explicit pair is
 * the cleaner expression of intent.
 *
 * SYSINIT order: SI_SUB_DRIVERS / SI_ORDER_FIRST.
 *
 * Why SI_ORDER_FIRST and not SI_ORDER_MIDDLE: DRIVER_MODULE
 * (declared in inputfs.c) expands to a SYSINIT at the same
 * subsystem (SI_SUB_DRIVERS) at SI_ORDER_MIDDLE. When two
 * SYSINITs share both subsystem and order, their relative
 * order is determined by linker order of the object files,
 * which is fragile and platform-dependent.
 *
 * The bench-observed failure mode without SI_ORDER_FIRST: the
 * NEWBUS DRIVER_MODULE SYSINIT runs first, registers the
 * inputfs driver with hidbus, hidbus immediately probes and
 * attaches all matching child devices, inputfs_attach calls
 * inputfs_kbd_bridge_attach, which calls kbd_register —
 * BEFORE our kbd_add_driver has run. kbd_register's name
 * lookup against keyboard_drivers SLIST falls through (we're
 * not in the list yet) and returns -1.
 *
 * SI_ORDER_FIRST sorts strictly before SI_ORDER_MIDDLE within
 * SI_SUB_DRIVERS, so the SYSINIT that adds inputfs_kbd to the
 * keyboard_drivers SLIST runs before any NEWBUS attach can
 * trigger bridge_attach. By the time the first inputfs<N>
 * device attaches, our entry is in the SLIST and kbd_register
 * succeeds.
 *
 * kbd_add_driver itself has no dependencies beyond the SLIST
 * head being initialised, which happens at file-scope in
 * kbd.c (SLIST_HEAD_INITIALIZER) and is therefore available
 * from boot. SI_ORDER_FIRST is safe to use here.
 */

static int inputfs_kbd_driver_added = 0;

static void
inputfs_kbd_sysinit(void *unused __unused)
{
	int err;

	err = kbd_add_driver(&inputfs_kbd_driver);

	if (err == 0) {
		inputfs_kbd_driver_added = 1;
	} else {
		printf("inputfs_kbd: kbd_add_driver(%s) failed: %d\n",
		    INPUTFS_KBD_DRIVER_NAME, err);
	}
}

static void
inputfs_kbd_sysuninit(void *unused __unused)
{
	if (inputfs_kbd_driver_added) {
		(void)kbd_delete_driver(&inputfs_kbd_driver);
		inputfs_kbd_driver_added = 0;
	}
}

SYSINIT(inputfs_kbd_init, SI_SUB_DRIVERS, SI_ORDER_FIRST,
    inputfs_kbd_sysinit, NULL);
SYSUNINIT(inputfs_kbd_uninit, SI_SUB_DRIVERS, SI_ORDER_FIRST,
    inputfs_kbd_sysuninit, NULL);
