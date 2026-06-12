/*
 * inputfs_parser.h: HID parser surface declarations.
 *
 * Stage AD-9.2a (per inputfs/docs/adr/0014-hid-fuzzing-scope.md):
 * extracts the parser-relevant declarations from inputfs.c so the
 * parser code can be compiled in isolation by AD-9.2b's userspace
 * fuzzing harness.
 *
 * In kernel mode this header is included by both inputfs.c and
 * inputfs_parser.c. In userspace (the fuzz harness) it is
 * included by main.c and inputfs_parser.c, with FreeBSD's
 * <dev/hid/hid.h> coming from the vendored copy under
 * inputfs/test/fuzz/vendored/dev/hid/.
 *
 * The parser surface deliberately depends only on
 * <dev/hid/hid.h>'s `hid_size_t` and `struct hid_location` plus
 * C99 fixed-width integer types. No softc dependencies; no
 * sysctls, mutexes, or device-tree handles. inputfs_keyboard_diff_emit
 * is NOT declared here because it mixes parser concerns with
 * event-emission concerns and stays in inputfs.c (out of fuzz
 * scope per ADR 0014).
 */

#ifndef _INPUTFS_PARSER_H_
#define _INPUTFS_PARSER_H_

#include <dev/hid/hid.h>

/*
 * Parser state: cached HID locations and previous-state buffer.
 * Embedded in struct inputfs_softc as the field sc_parser; the
 * four pure-parser functions below take a pointer to this struct
 * directly, so the harness can construct one on the stack and
 * invoke the parser with no softc machinery.
 *
 * Field-name convention drops the sc_ prefix that softc fields
 * use, since these are no longer softc fields directly. Access
 * from kernel code is sc->sc_parser.loc_x rather than
 * sc->sc_loc_x.
 *
 * Pointer location cache (Stage D.0a): each location's size
 * field is zero when the corresponding usage is not present in
 * the descriptor. Consumers check size > 0 before extracting.
 * loc_buttons covers the button usage range as a single
 * location with one bit per button; we cap at 32 buttons in
 * the wire format.
 *
 * Keyboard location cache and previous-state buffer
 * (Stage D.0b): the interrupt path extracts the modifier byte
 * and keys-held array, diffs against prev_modifiers / prev_keys,
 * and updates the previous-state buffer. n-key rollover beyond
 * 6 is reported by HID as 0x01 in all six slots and filtered
 * out. loc_modifiers covers the 8-bit modifier bitfield as a
 * single location whose size is 8. loc_keys covers the keys-held
 * array as a single location whose size is the per-element bit
 * width and count is the array length.
 */
struct inputfs_parser_state {
	uint8_t			 pointer_locations_valid;
	struct hid_location	 loc_x;
	struct hid_location	 loc_y;
	struct hid_location	 loc_wheel;
	struct hid_location	 loc_buttons;
	uint8_t			 loc_x_id;
	uint8_t			 loc_y_id;
	uint8_t			 loc_wheel_id;
	uint8_t			 loc_buttons_id;
	uint8_t			 button_count;
	uint8_t			 has_wheel;

	uint8_t			 keyboard_locations_valid;
	struct hid_location	 loc_modifiers;
	struct hid_location	 loc_keys;
	uint8_t			 loc_modifiers_id;
	uint8_t			 loc_keys_id;
	uint8_t			 prev_modifiers;
	uint8_t			 prev_keys[6];

	/*
	 * Digitizer location cache (Stage AD-1 HUP_DIGITIZERS sub-item,
	 * step 3). Populated by inputfs_digitizer_locate from the
	 * descriptor's Touch Pad collection (HUP_DIGITIZERS,
	 * HUD_TOUCHPAD). All locations share the same report ID
	 * (digitizer_report_id); locator verifies this.
	 *
	 * Per-finger fields (one finger collection per Report ID 7
	 * arrival, per ADR 0018): tip_switch, confidence, contact_id,
	 * x, y. Per-report fields: scan_time, contact_count, button.
	 *
	 * Range fields (logical_min/max) are kept for X/Y because the
	 * parser converts device coordinates to compositor pixel space
	 * via the Stage D.3 transform; the ranges are needed for
	 * scaling.
	 */
	uint8_t			 digitizer_locations_valid;
	uint8_t			 digitizer_report_id;
	struct hid_location	 loc_tip_switch;
	struct hid_location	 loc_confidence;
	struct hid_location	 loc_contact_id;
	struct hid_location	 loc_touch_x;
	struct hid_location	 loc_touch_y;
	struct hid_location	 loc_scan_time;
	struct hid_location	 loc_contact_count;
	struct hid_location	 loc_touch_button;
	int32_t			 touch_x_min;
	int32_t			 touch_x_max;
	int32_t			 touch_y_min;
	int32_t			 touch_y_max;

	/*
	 * Device Mode feature field cache (Stage AD-1 step 5). Populated
	 * by inputfs_digitizer_locate alongside the input-side fields
	 * above, only when the descriptor declares both a digitizer
	 * input collection AND a Device Mode feature field.
	 *
	 * device_mode_valid: 1 if the field was located and the report
	 * size was non-zero. Caller checks before issuing the SET_REPORT.
	 *
	 * device_mode_rid: the report ID of the feature report containing
	 * the Device Mode field. On the HAILUCK this is 11.
	 *
	 * device_mode_rlen: the report's full byte size, including the
	 * report-ID byte. Returned by hid_report_size(). For HAILUCK
	 * this is 2 (1 ID byte + 1 payload byte).
	 *
	 * The location's pos / size are bit offsets within the payload
	 * portion of the report (after the report-ID byte), matching
	 * hid_get_udata / hid_put_udata's offset semantics.
	 */
	uint8_t			 device_mode_valid;
	uint8_t			 device_mode_rid;
	hid_size_t		 device_mode_rlen;
	struct hid_location	 loc_device_mode;
};

/*
 * Populate the pointer location cache by walking the HID
 * descriptor for X, Y, wheel, and button-1 usages, plus a
 * descriptor walk to count buttons. Called once at attach.
 *
 * On entry, p must point to a parser_state (the contents are
 * fully overwritten). rdesc / rdesc_len describe the device's
 * HID report descriptor blob; either may be NULL/0 in which
 * case the function returns with pointer_locations_valid = 0.
 *
 * No return value: success/failure is reflected in
 * p->pointer_locations_valid (1 if any pointer usage was
 * located, 0 otherwise).
 */
void	inputfs_pointer_locate(struct inputfs_parser_state *p,
	    const void *rdesc, hid_size_t rdesc_len);

/*
 * Extract pointer-event fields (X delta, Y delta, wheel delta,
 * button bitmask) from a single HID input report. Uses the
 * cache populated by inputfs_pointer_locate.
 *
 * On entry, p must contain valid pointer locations
 * (pointer_locations_valid == 1). buf / len describe the report
 * bytes as received from the device. out_dx, out_dy, out_dw,
 * out_buttons must be non-NULL; the caller has zero-initialised
 * them.
 *
 * Returns 1 if at least one location was extracted (the report
 * ID matched and the location was non-empty), 0 otherwise.
 * Outputs are only modified for locations that were extracted;
 * outputs for absent locations remain at their caller-supplied
 * zero defaults.
 */
int	inputfs_extract_pointer(struct inputfs_parser_state *p,
	    const uint8_t *buf, hid_size_t len,
	    int32_t *out_dx, int32_t *out_dy, int32_t *out_dw,
	    uint32_t *out_buttons);

/*
 * Populate the keyboard location cache by walking the HID
 * descriptor for the modifier byte (usage 0xE0..0xE7 packed)
 * and the keys-held array (HUP_KEYBOARD usage 0x00 with array
 * declaration). Called once at attach.
 *
 * On entry, p must point to a parser_state (the keyboard
 * portion is fully overwritten; the pointer portion is left
 * unchanged so a single parser_state may host both caches).
 * rdesc / rdesc_len describe the device's HID report
 * descriptor; either may be NULL/0 in which case the function
 * returns with keyboard_locations_valid = 0.
 *
 * The previous-state buffer (prev_modifiers, prev_keys) is
 * cleared as part of locate so the first emitted diff is
 * against an empty baseline.
 */
void	inputfs_keyboard_locate(struct inputfs_parser_state *p,
	    const void *rdesc, hid_size_t rdesc_len);

/*
 * Extract keyboard-event fields (modifier byte, keys-held
 * array) from a single HID input report. Uses the cache
 * populated by inputfs_keyboard_locate.
 *
 * On entry, p must contain valid keyboard locations
 * (keyboard_locations_valid == 1). buf / len describe the
 * report bytes. out_modifiers and out_keys must be non-NULL;
 * the caller has zero-initialised them.
 *
 * Returns 1 if at least one location was extracted, 0
 * otherwise. The diff against p->prev_modifiers / p->prev_keys
 * is the responsibility of the caller (in kernel,
 * inputfs_keyboard_diff_emit; in the fuzz harness, no diff is
 * needed because we only test that extract returns without
 * crashing on malformed input).
 */
int	inputfs_extract_keyboard(struct inputfs_parser_state *p,
	    const uint8_t *buf, hid_size_t len,
	    uint8_t *out_modifiers, uint8_t out_keys[6]);

/*
 * Populate the digitizer location cache by walking the HID
 * descriptor for the Win8+ Precision Touchpad usages: Tip Switch,
 * Confidence, Contact Identifier, X (Generic Desktop, but inside
 * a HUP_DIGITIZERS Touch Pad collection), Y (likewise), Scan Time,
 * Contact Count, and Button 1. Called once at attach.
 *
 * The locator first finds Tip Switch (which only exists in the
 * digitizer collection), records its report ID as
 * digitizer_report_id, then verifies that all subsequent located
 * fields share the same report ID. X and Y are tricky because
 * Generic Desktop X/Y also appear in the Mouse fallback collection
 * (Report ID 1 on the HAILUCK); the locator iterates index = 0, 1,
 * 2, ... until it finds a match whose report ID equals
 * digitizer_report_id.
 *
 * On entry, p must point to a parser_state (the digitizer portion
 * is fully overwritten; pointer and keyboard portions are left
 * unchanged so a single parser_state may host all three caches).
 * rdesc / rdesc_len describe the device's HID report descriptor;
 * either may be NULL/0 in which case the function returns with
 * digitizer_locations_valid = 0.
 *
 * No return value: success/failure is reflected in
 * p->digitizer_locations_valid (1 if Tip Switch and at least X
 * and Y were located, 0 otherwise).
 */
void	inputfs_digitizer_locate(struct inputfs_parser_state *p,
	    const void *rdesc, hid_size_t rdesc_len);

/*
 * Extract digitizer-event fields (per-contact and per-report) from
 * a single HID input report. Uses the cache populated by
 * inputfs_digitizer_locate.
 *
 * On entry, p must contain valid digitizer locations
 * (digitizer_locations_valid == 1). buf / len describe the report
 * bytes as received from the device (including the leading report
 * ID byte). All out_ pointers must be non-NULL; the caller has
 * zero-initialised them.
 *
 * Returns 1 if the report's ID matched digitizer_report_id and
 * extraction proceeded; 0 otherwise (caller should not interpret
 * the out_ values when the return is 0). The actual touch field
 * absence is reflected in the parser state (the corresponding
 * loc_*.size is 0); extract simply leaves those out_ values at
 * their caller-supplied defaults.
 *
 * Per-contact fields:
 *   out_tip_switch    1 if contact in surface contact, 0 otherwise
 *   out_confidence    1 if device thinks contact is real (default 1
 *                     when descriptor lacks Confidence — caller
 *                     should check parser_state.loc_confidence.size
 *                     to know whether confidence is actually in use)
 *   out_contact_id    contact identifier 0..7 (3-bit field)
 *   out_x, out_y      device-unit coordinates
 *
 * Per-report fields:
 *   out_scan_time     16-bit scan time (units of 100us per HID spec)
 *   out_contact_count 4-bit count of contacts in this frame
 *   out_button        1 if the integrated clickpad button is pressed
 */
int	inputfs_extract_digitizer(struct inputfs_parser_state *p,
	    const uint8_t *buf, hid_size_t len,
	    uint8_t *out_tip_switch, uint8_t *out_confidence,
	    uint8_t *out_contact_id,
	    int32_t *out_x, int32_t *out_y,
	    uint32_t *out_scan_time, uint8_t *out_contact_count,
	    uint8_t *out_button);

#endif /* _INPUTFS_PARSER_H_ */
