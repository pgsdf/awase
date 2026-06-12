/*
 * inputfs_parser.c: HID parser surface implementation.
 *
 * Stage AD-9.2a (per inputfs/docs/adr/0014-hid-fuzzing-scope.md):
 * extracts the four pure-parser functions plus the
 * inputfs_report_id_matches helper from inputfs.c so they can
 * be compiled in isolation by AD-9.2b's userspace fuzzing
 * harness.
 *
 * This file builds in two contexts:
 *
 *   - Kernel module: included alongside inputfs.c via the
 *     SRCS list in inputfs/sys/modules/inputfs/Makefile.
 *     Pulls in <sys/param.h>, <sys/systm.h>, and FreeBSD's
 *     <dev/hid/hid.h> from the running kernel source.
 *
 *   - Fuzz harness (AD-9.2b): compiled against the kernel_shim.h
 *     and vendored hid.h under inputfs/test/fuzz/. The shim
 *     suppresses <sys/param.h> and <sys/systm.h> via include-guard
 *     pre-definition and provides minimal replacements for the
 *     symbols this file uses (memset, fixed-width types).
 *
 * Production behaviour is unchanged from before AD-9.2a: the
 * functions here are byte-identical to what they were in
 * inputfs.c, only their location in the source tree has moved.
 * inputfs_keyboard_diff_emit stays in inputfs.c per AD-9.1's
 * analysis (mixed parser + event-emission concerns, out of
 * fuzz scope per ADR 0014).
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <dev/hid/hid.h>

#include "inputfs_parser.h"

/*
 * inputfs_report_id_matches -- Stage D.0a helper.
 *
 * Returns 1 if the report buffer's report ID matches the cached
 * report ID for a location. When cached_id == 0, the device does
 * not use report IDs and any non-empty buffer matches. When
 * cached_id != 0, the first byte of the buffer must equal it.
 *
 * Used by inputfs_extract_pointer to dispatch among multiple
 * report IDs on devices that multiplex (e.g. touchpads with
 * separate pointer and gesture reports).
 */
static inline int
inputfs_report_id_matches(uint8_t cached_id, const uint8_t *buf,
    hid_size_t len)
{
	if (len == 0)
		return (0);
	if (cached_id == 0)
		return (1);
	return (buf[0] == cached_id);
}

/*
 * inputfs_pointer_locate -- Stage D.0a.
 *
 * Populate the softc's HID-location cache for descriptor-driven
 * pointer event extraction. Called once at attach, after
 * inputfs_walk_rdesc and before hidbus_set_intr.
 *
 * For each pointer-relevant usage (X, Y, Wheel, and the button
 * range under HUP_BUTTON), call hid_locate against the descriptor
 * and record the resulting location and report ID. Locations
 * whose size is zero indicate the usage is not present in this
 * descriptor; the interrupt path checks size > 0 before extracting.
 *
 * Buttons are special: HID encodes per-button presence as
 * individual usages 1, 2, 3, ... under HUP_BUTTON, but in
 * practice they are emitted as a single packed bit field. We
 * locate button 1 to get the bit-field's start and use the
 * report count (number of buttons) to determine how wide the
 * field is. Up to 32 buttons are supported (one u32 in the
 * wire format); buttons beyond 32 are silently ignored.
 *
 * The location cache is unconditional regardless of role: a
 * keyboard descriptor will simply have all pointer locations
 * report size == 0, and the interrupt path will skip extraction
 * accordingly. This avoids tying cache population to a specific
 * order of role classification.
 */
void
inputfs_pointer_locate(struct inputfs_parser_state *p,
    const void *rdesc, hid_size_t rdesc_len)
{
	uint32_t flags;
	uint8_t id;

	memset(&p->loc_x, 0, sizeof(p->loc_x));
	memset(&p->loc_y, 0, sizeof(p->loc_y));
	memset(&p->loc_wheel, 0, sizeof(p->loc_wheel));
	memset(&p->loc_buttons, 0, sizeof(p->loc_buttons));
	p->loc_x_id = 0;
	p->loc_y_id = 0;
	p->loc_wheel_id = 0;
	p->loc_buttons_id = 0;
	p->button_count = 0;
	p->has_wheel = 0;
	p->pointer_locations_valid = 0;

	if (rdesc == NULL || rdesc_len == 0)
		return;

	/* X axis. */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_X),
	    hid_input, 0, &p->loc_x, &flags, &id) != 0) {
		p->loc_x_id = id;
	}

	/* Y axis. */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_Y),
	    hid_input, 0, &p->loc_y, &flags, &id) != 0) {
		p->loc_y_id = id;
	}

	/* Wheel (optional). */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_WHEEL),
	    hid_input, 0, &p->loc_wheel, &flags, &id) != 0) {
		p->loc_wheel_id = id;
		p->has_wheel = 1;
	}

	/*
	 * Buttons: locate button 1 to get the start of the button
	 * bit field. The HID spec packs buttons sequentially within
	 * a single report field; locating button 1 gives us the
	 * bit-field's location. We then walk the report descriptor
	 * to count how many button usages are present so we know the
	 * field width.
	 */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_BUTTON, 1),
	    hid_input, 0, &p->loc_buttons, &flags, &id) != 0) {
		struct hid_data *s;
		struct hid_item hi;
		uint8_t count = 0;

		p->loc_buttons_id = id;

		s = hid_start_parse(rdesc, rdesc_len,
		    1 << hid_input);
		if (s != NULL) {
			while (hid_get_item(s, &hi) > 0) {
				if (hi.kind == hid_input &&
				    HID_GET_USAGE_PAGE(hi.usage) == HUP_BUTTON) {
					if (count < 32)
						count++;
				}
			}
			hid_end_parse(s);
		}
		p->button_count = count;
	}

	if (p->loc_x.size > 0 || p->loc_y.size > 0 ||
	    p->loc_wheel.size > 0 || p->loc_buttons.size > 0) {
		p->pointer_locations_valid = 1;
	}
}

/*
 * inputfs_extract_pointer -- Stage D.0a.
 *
 * Given an interrupt report buffer of length len (including the
 * leading report ID byte if the device uses report IDs), extract
 * pointer values using the cached locations. Returns 1 if the
 * report matched at least one cached location's report ID and
 * any value was extracted; returns 0 if the report should be
 * ignored (wrong report ID, no cached locations, or empty
 * extraction).
 *
 * Output parameters are populated when their respective location
 * is present in the descriptor and matches the incoming report
 * ID. Outputs not extracted are left untouched; callers should
 * initialise to zero before calling.
 *
 * Report ID matching: hid_locate returns the report ID a usage
 * was associated with. If the device uses report IDs, the first
 * byte of the report is the ID and subsequent bytes are the
 * payload; if not, no leading byte is present and IDs are 0.
 * hid_get_data takes the buffer including any leading ID byte
 * and the field's location knows whether to skip it. The match
 * we perform here is between the first byte of the incoming
 * report and the cached id: if cached id is 0, the device does
 * not use IDs and the byte is part of the data; if cached id
 * is non-zero, the byte must match.
 */
int
inputfs_extract_pointer(struct inputfs_parser_state *p,
    const uint8_t *buf, hid_size_t len,
    int32_t *out_dx, int32_t *out_dy, int32_t *out_dw,
    uint32_t *out_buttons)
{
	int extracted = 0;

	if (!p->pointer_locations_valid || buf == NULL || len == 0)
		return (0);

	if (p->loc_x.size > 0 &&
	    inputfs_report_id_matches(p->loc_x_id, buf, len)) {
		*out_dx = (int32_t)hid_get_data(buf, len, &p->loc_x);
		extracted = 1;
	}

	if (p->loc_y.size > 0 &&
	    inputfs_report_id_matches(p->loc_y_id, buf, len)) {
		*out_dy = (int32_t)hid_get_data(buf, len, &p->loc_y);
		extracted = 1;
	}

	if (p->loc_wheel.size > 0 &&
	    inputfs_report_id_matches(p->loc_wheel_id, buf, len)) {
		*out_dw = (int32_t)hid_get_data(buf, len, &p->loc_wheel);
		extracted = 1;
	}

	if (p->loc_buttons.size > 0 &&
	    inputfs_report_id_matches(p->loc_buttons_id, buf, len)) {
		/*
		 * The cached loc_buttons describes the location of
		 * Button 1 only (size = 1 bit, since hid_locate
		 * returns the location of a single usage). To extract
		 * the full button bitmap, we construct a temporary
		 * location starting at loc_buttons.pos with size =
		 * button_count, which inputfs_pointer_locate
		 * populated from a separate descriptor walk over all
		 * HUP_BUTTON usages in the report. This reads all
		 * declared button bits, not just button 1.
		 *
		 * Without this, mouse buttons 2 and onward would be
		 * silently dropped from every report. Found by AD-9.4
		 * regression check on corpus entry 16-report-truncated
		 * (boot mouse with all three button bits set in a
		 * 1-byte report).
		 */
		struct hid_location buttons_loc = p->loc_buttons;
		if (p->button_count > 0)
			buttons_loc.size = p->button_count;
		*out_buttons = (uint32_t)hid_get_udata(buf, len,
		    &buttons_loc);
		extracted = 1;
	}

	return (extracted);
}

/*
 * inputfs_keyboard_locate -- Stage D.0b.
 *
 * Populate the softc's keyboard location cache. Called once at
 * attach, after inputfs_pointer_locate and before hidbus_set_intr.
 *
 * The HID boot keyboard layout has two pieces:
 *
 *  - The modifier byte: eight individual 1-bit usages
 *    (0xE0..0xE7) declared as a packed bit field. We locate
 *    usage 0xE0 (Left Ctrl), which sits at bit 0 of the byte,
 *    then synthesise an 8-bit-wide location starting at the
 *    same position. hid_get_udata against that location yields
 *    the full modifier byte in one read.
 *
 *  - The keys-held array: typically declared as a single input
 *    item with usage range and report_count > 1. hid_locate
 *    against any usage in that range returns a location whose
 *    size is the per-element bit width and count is the array
 *    length. We locate via usage 0x00 first (the conventional
 *    array-base usage), falling back to a parser walk if that
 *    does not match.
 *
 * The location cache is unconditional regardless of role; a
 * pointer-only descriptor will simply have all keyboard
 * locations report size == 0.
 */
void
inputfs_keyboard_locate(struct inputfs_parser_state *p,
    const void *rdesc, hid_size_t rdesc_len)
{
	uint32_t flags;
	uint8_t id;

	memset(&p->loc_modifiers, 0, sizeof(p->loc_modifiers));
	memset(&p->loc_keys, 0, sizeof(p->loc_keys));
	p->loc_modifiers_id = 0;
	p->loc_keys_id = 0;
	p->prev_modifiers = 0;
	memset(p->prev_keys, 0, sizeof(p->prev_keys));
	p->keyboard_locations_valid = 0;

	if (rdesc == NULL || rdesc_len == 0)
		return;

	/*
	 * Modifiers: locate usage 0xE0 (Left Ctrl) to find the bit
	 * position of bit 0 of the modifier byte. The eight modifiers
	 * are packed sequentially in this byte; we read them as one
	 * 8-bit value.
	 */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_KEYBOARD, 0xE0),
	    hid_input, 0, &p->loc_modifiers, &flags, &id) != 0) {
		p->loc_modifiers_id = id;
		/*
		 * Each modifier is declared as a 1-bit field. Extend
		 * the located size to 8 so a single hid_get_udata
		 * yields the full modifier byte. The pos field already
		 * points at bit 0 of the byte (the LeftCtrl bit).
		 */
		p->loc_modifiers.size = 8;
		p->loc_modifiers.count = 1;
	}

	/*
	 * Keys array: locate via usage 0x00 (the conventional base
	 * of the keyboard usage range used by boot keyboards). For
	 * non-boot keyboards or unusual descriptors, hid_locate may
	 * not find this; the array-walk fallback below catches those.
	 */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_KEYBOARD, 0x00),
	    hid_input, 0, &p->loc_keys, &flags, &id) != 0) {
		p->loc_keys_id = id;
	} else {
		/*
		 * Fallback: walk the descriptor and find the first
		 * input item on HUP_KEYBOARD whose report_count > 1
		 * and that is declared as an array (HIO_VARIABLE not
		 * set). That is the keys-held array.
		 */
		struct hid_data *s;
		struct hid_item hi;

		s = hid_start_parse(rdesc, rdesc_len,
		    1 << hid_input);
		if (s != NULL) {
			while (hid_get_item(s, &hi) > 0) {
				if (hi.kind == hid_input &&
				    HID_GET_USAGE_PAGE(hi.usage) == HUP_KEYBOARD &&
				    hi.loc.count > 1 &&
				    (hi.flags & HIO_VARIABLE) == 0) {
					p->loc_keys = hi.loc;
					p->loc_keys_id =
					    (uint8_t)hi.report_ID;
					break;
				}
			}
			hid_end_parse(s);
		}
	}

	if (p->loc_modifiers.size > 0 || p->loc_keys.size > 0)
		p->keyboard_locations_valid = 1;
}

/*
 * inputfs_extract_keyboard -- Stage D.0b.
 *
 * Extract the modifier byte and up to 6 keys-held entries from
 * an interrupt report. Returns 1 if extraction succeeded for at
 * least one location and the report ID matched; 0 otherwise.
 *
 * out_modifiers receives the 8-bit modifier byte. out_keys is a
 * 6-element array; entries beyond the device's actual array
 * count are zero-filled. The caller has initialised out_keys to
 * all zeros.
 *
 * Each element of the keys array is extracted by cloning the
 * cached location and advancing pos by size * index.
 */
int
inputfs_extract_keyboard(struct inputfs_parser_state *p,
    const uint8_t *buf, hid_size_t len,
    uint8_t *out_modifiers, uint8_t out_keys[6])
{
	int extracted = 0;

	if (!p->keyboard_locations_valid || buf == NULL || len == 0)
		return (0);

	if (p->loc_modifiers.size > 0 &&
	    inputfs_report_id_matches(p->loc_modifiers_id, buf, len)) {
		*out_modifiers = (uint8_t)hid_get_udata(buf, len,
		    &p->loc_modifiers);
		extracted = 1;
	}

	if (p->loc_keys.size > 0 &&
	    inputfs_report_id_matches(p->loc_keys_id, buf, len)) {
		uint32_t i;
		uint32_t array_count = p->loc_keys.count;

		if (array_count > 6)
			array_count = 6;

		for (i = 0; i < array_count; i++) {
			struct hid_location elem = p->loc_keys;

			elem.pos = p->loc_keys.pos +
			    p->loc_keys.size * i;
			elem.count = 1;
			out_keys[i] = (uint8_t)hid_get_udata(buf, len, &elem);
		}
		extracted = 1;
	}

	return (extracted);
}

/*
 * inputfs_digitizer_locate -- Stage AD-1 HUP_DIGITIZERS sub-item, step 3.
 *
 * Populate the parser state's digitizer location cache for
 * descriptor-driven extraction of Win8+ Precision Touchpad fields.
 * Called once at attach, alongside inputfs_pointer_locate and
 * inputfs_keyboard_locate.
 *
 * The Win8+ touchpad descriptor multiplexes multiple Application
 * Collections under one HID interface; in particular the HAILUCK
 * 0x258a:0x000c declares Generic Desktop X and Y both in its Mouse
 * collection (Report ID 1) and inside the HUP_DIGITIZERS Touch Pad
 * collection (Report ID 7). hid_locate returns the first match,
 * which for X/Y is the Mouse occurrence — the wrong one for this
 * locator. We therefore:
 *
 *   1. Find Tip Switch first. Tip Switch is HUP_DIGITIZERS-specific
 *      and only appears in the digitizer collection, so its report
 *      ID is the digitizer's. Record digitizer_report_id from this
 *      locate.
 *   2. Iterate index = 0, 1, 2, ... when locating Generic Desktop
 *      X and Y, picking the first match whose returned report ID
 *      equals digitizer_report_id.
 *   3. Locate other digitizer fields (Confidence, Contact Identifier,
 *      Scan Time, Contact Count) at index 0; these are
 *      HUP_DIGITIZERS-specific and only appear once.
 *   4. Locate Button 1 with the same iteration approach as X/Y;
 *      the Mouse fallback also has Button 1, and the digitizer
 *      collection has its own clickpad-button declaration.
 *
 * digitizer_locations_valid is set to 1 only if Tip Switch and at
 * least X and Y were located inside the digitizer's report.
 * Confidence, Scan Time, Contact Count, and Button are optional —
 * a device that omits any of them still parses correctly, with the
 * corresponding location's size left at zero.
 *
 * touch_x_min/max and touch_y_min/max record the logical-range
 * extents from the descriptor, needed by the parser for converting
 * device units to compositor pixel space (Stage D.3).
 */
void
inputfs_digitizer_locate(struct inputfs_parser_state *p,
    const void *rdesc, hid_size_t rdesc_len)
{
	uint32_t flags;
	uint8_t id;

	memset(&p->loc_tip_switch, 0, sizeof(p->loc_tip_switch));
	memset(&p->loc_confidence, 0, sizeof(p->loc_confidence));
	memset(&p->loc_contact_id, 0, sizeof(p->loc_contact_id));
	memset(&p->loc_touch_x, 0, sizeof(p->loc_touch_x));
	memset(&p->loc_touch_y, 0, sizeof(p->loc_touch_y));
	memset(&p->loc_scan_time, 0, sizeof(p->loc_scan_time));
	memset(&p->loc_contact_count, 0, sizeof(p->loc_contact_count));
	memset(&p->loc_touch_button, 0, sizeof(p->loc_touch_button));
	p->digitizer_report_id = 0;
	p->digitizer_locations_valid = 0;
	p->touch_x_min = 0;
	p->touch_x_max = 0;
	p->touch_y_min = 0;
	p->touch_y_max = 0;

	if (rdesc == NULL || rdesc_len == 0)
		return;

	/*
	 * Step 1: locate Tip Switch. This pins down the digitizer's
	 * report ID. If absent, the descriptor doesn't declare a
	 * Win8+ multi-touch interface and we leave the cache empty.
	 */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_DIGITIZERS, HUD_TIP_SWITCH),
	    hid_input, 0, &p->loc_tip_switch, &flags, &id) == 0) {
		return;
	}
	p->digitizer_report_id = id;

	/*
	 * Step 2: locate Generic Desktop X, iterating index until we
	 * find the occurrence inside the digitizer's report. Bound
	 * the iteration: 8 iterations is far more than any sane
	 * descriptor will need.
	 */
	for (uint8_t idx = 0; idx < 8; idx++) {
		struct hid_location loc;
		uint8_t loc_id;
		if (hid_locate(rdesc, rdesc_len,
		    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_X),
		    hid_input, idx, &loc, &flags, &loc_id) == 0)
			break;
		if (loc_id == p->digitizer_report_id) {
			p->loc_touch_x = loc;
			break;
		}
	}

	for (uint8_t idx = 0; idx < 8; idx++) {
		struct hid_location loc;
		uint8_t loc_id;
		if (hid_locate(rdesc, rdesc_len,
		    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_Y),
		    hid_input, idx, &loc, &flags, &loc_id) == 0)
			break;
		if (loc_id == p->digitizer_report_id) {
			p->loc_touch_y = loc;
			break;
		}
	}

	/*
	 * Step 3: locate digitizer-specific fields (single occurrence
	 * each, so index = 0). Only accept them if they share the
	 * digitizer's report ID.
	 */
	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_DIGITIZERS, HUD_CONFIDENCE),
	    hid_input, 0, &p->loc_confidence, &flags, &id) != 0) {
		if (id != p->digitizer_report_id)
			memset(&p->loc_confidence, 0, sizeof(p->loc_confidence));
	}

	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_DIGITIZERS, HUD_CONTACTID),
	    hid_input, 0, &p->loc_contact_id, &flags, &id) != 0) {
		if (id != p->digitizer_report_id)
			memset(&p->loc_contact_id, 0, sizeof(p->loc_contact_id));
	}

	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_DIGITIZERS, HUD_SCAN_TIME),
	    hid_input, 0, &p->loc_scan_time, &flags, &id) != 0) {
		if (id != p->digitizer_report_id)
			memset(&p->loc_scan_time, 0, sizeof(p->loc_scan_time));
	}

	if (hid_locate(rdesc, rdesc_len,
	    HID_USAGE2(HUP_DIGITIZERS, HUD_CONTACTCOUNT),
	    hid_input, 0, &p->loc_contact_count, &flags, &id) != 0) {
		if (id != p->digitizer_report_id)
			memset(&p->loc_contact_count, 0, sizeof(p->loc_contact_count));
	}

	/*
	 * Step 4: locate Button 1 within the digitizer report. The
	 * Mouse fallback also declares Button 1, so iterate.
	 */
	for (uint8_t idx = 0; idx < 8; idx++) {
		struct hid_location loc;
		uint8_t loc_id;
		if (hid_locate(rdesc, rdesc_len,
		    HID_USAGE2(HUP_BUTTON, 1),
		    hid_input, idx, &loc, &flags, &loc_id) == 0)
			break;
		if (loc_id == p->digitizer_report_id) {
			p->loc_touch_button = loc;
			break;
		}
	}

	/*
	 * Step 5: walk the descriptor for X / Y items inside the
	 * digitizer report and capture their logical range. We can't
	 * get this from hid_locate, which only returns location and
	 * flags; we need a full hid_get_item walk to read
	 * logical_minimum / logical_maximum.
	 */
	{
		struct hid_data *s;
		struct hid_item hi;

		s = hid_start_parse(rdesc, rdesc_len, 1 << hid_input);
		if (s != NULL) {
			while (hid_get_item(s, &hi) > 0) {
				if (hi.kind != hid_input)
					continue;
				if (hi.report_ID != p->digitizer_report_id)
					continue;
				if (hi.usage ==
				    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_X)) {
					p->touch_x_min = hi.logical_minimum;
					p->touch_x_max = hi.logical_maximum;
				} else if (hi.usage ==
				    HID_USAGE2(HUP_GENERIC_DESKTOP, HUG_Y)) {
					p->touch_y_min = hi.logical_minimum;
					p->touch_y_max = hi.logical_maximum;
				}
			}
			hid_end_parse(s);
		}
	}

	/*
	 * Step 6: locate the Device Mode feature field, used to switch
	 * the device into Multi-touch Touchpad mode (value 0x03) per
	 * ADR 0018 section 5. This is a FEATURE field, not input, so
	 * we use hid_feature kind. The field lives in its own Application
	 * Collection (HUP_DIGITIZERS, HUD_CONFIG = 0x0e) and has its
	 * own report ID, distinct from digitizer_report_id (Report ID
	 * 11 vs Report ID 7 on the HAILUCK).
	 *
	 * Failure to locate Device Mode is non-fatal: a device might
	 * have a digitizer input collection but no configuration TLC,
	 * in which case the device is presumably already in MT mode by
	 * default. We zero the cache fields and proceed.
	 */
	{
		struct hid_location loc;
		uint32_t flags;
		uint8_t id;

		memset(&p->loc_device_mode, 0, sizeof(p->loc_device_mode));
		p->device_mode_rid = 0;
		p->device_mode_rlen = 0;
		p->device_mode_valid = 0;

		if (hid_locate(rdesc, rdesc_len,
		    HID_USAGE2(HUP_DIGITIZERS, HUD_INPUT_MODE),
		    hid_feature, 0, &loc, &flags, &id) != 0) {
			int rsize;

			rsize = hid_report_size(rdesc, rdesc_len,
			    hid_feature, id);
			if (rsize > 0 && loc.size > 0) {
				p->loc_device_mode = loc;
				p->device_mode_rid = id;
				p->device_mode_rlen = (hid_size_t)rsize;
				p->device_mode_valid = 1;
			}
		}
	}

	/*
	 * Validity: require Tip Switch (already located, otherwise we
	 * returned early) plus X and Y at the digitizer's report ID.
	 * The other fields are optional.
	 */
	if (p->loc_tip_switch.size > 0 &&
	    p->loc_touch_x.size > 0 &&
	    p->loc_touch_y.size > 0) {
		p->digitizer_locations_valid = 1;
	}
}

/*
 * inputfs_extract_digitizer -- Stage AD-1 HUP_DIGITIZERS sub-item, step 4.
 *
 * Extract digitizer-event fields from a single HID input report.
 * Pattern matches inputfs_extract_pointer / inputfs_extract_keyboard:
 *   - Verify the report ID matches the cached digitizer_report_id.
 *   - For each cached location whose size > 0, call hid_get_udata
 *     against the post-report-ID portion of the buffer.
 *   - Leave out_ values at caller-supplied defaults for absent
 *     locations.
 *
 * The caller (inputfs_intr in inputfs.c) is responsible for
 * stateful interpretation: per-contact lifecycle (tip-switch
 * transitions), confidence-low handling, frame bookkeeping, and
 * device-to-pixel coordinate transforms. This function is purely
 * a wire-format unpacker and stays in scope for the AD-9.2b fuzz
 * harness per ADR 0014.
 *
 * Per the HAILUCK descriptor (one finger collection per Report ID 7
 * arrival, hybrid-mode framing per ADR 0018), each call extracts
 * exactly one contact's worth of per-finger fields plus the
 * per-report fields (scan_time, contact_count, button) which are
 * the same on every report in a frame. The caller derives frame
 * boundaries from the contact_count field of the first report in
 * each frame.
 */
int
inputfs_extract_digitizer(struct inputfs_parser_state *p,
    const uint8_t *buf, hid_size_t len,
    uint8_t *out_tip_switch, uint8_t *out_confidence,
    uint8_t *out_contact_id,
    int32_t *out_x, int32_t *out_y,
    uint32_t *out_scan_time, uint8_t *out_contact_count,
    uint8_t *out_button)
{
	const uint8_t *body;
	hid_size_t body_len;

	if (p == NULL || buf == NULL || len == 0)
		return (0);
	if (!p->digitizer_locations_valid)
		return (0);
	if (!inputfs_report_id_matches(p->digitizer_report_id, buf, len))
		return (0);

	/*
	 * Strip the leading report-ID byte. hid_get_udata's offset
	 * semantics are relative to the payload after the ID.
	 */
	body = buf + 1;
	body_len = (hid_size_t)(len - 1);

	if (p->loc_tip_switch.size > 0) {
		*out_tip_switch = (uint8_t)hid_get_udata(body, body_len,
		    &p->loc_tip_switch);
	}
	if (p->loc_confidence.size > 0) {
		*out_confidence = (uint8_t)hid_get_udata(body, body_len,
		    &p->loc_confidence);
	} else {
		/*
		 * Default to "confident" when descriptor lacks the field.
		 * Devices that don't declare Confidence are assumed to do
		 * their own palm rejection; the parser trusts the report.
		 */
		*out_confidence = 1;
	}
	if (p->loc_contact_id.size > 0) {
		*out_contact_id = (uint8_t)hid_get_udata(body, body_len,
		    &p->loc_contact_id);
	}
	if (p->loc_touch_x.size > 0) {
		*out_x = (int32_t)hid_get_udata(body, body_len,
		    &p->loc_touch_x);
	}
	if (p->loc_touch_y.size > 0) {
		*out_y = (int32_t)hid_get_udata(body, body_len,
		    &p->loc_touch_y);
	}
	if (p->loc_scan_time.size > 0) {
		*out_scan_time = (uint32_t)hid_get_udata(body, body_len,
		    &p->loc_scan_time);
	}
	if (p->loc_contact_count.size > 0) {
		*out_contact_count = (uint8_t)hid_get_udata(body, body_len,
		    &p->loc_contact_count);
	}
	if (p->loc_touch_button.size > 0) {
		*out_button = (uint8_t)hid_get_udata(body, body_len,
		    &p->loc_touch_button);
	}

	return (1);
}
