/*
 * inputfs-fuzz: HID parser fuzz harness.
 *
 * This is the AD-9.2b harness driver per
 * inputfs/docs/adr/0014-hid-fuzzing-scope.md.
 *
 * Reads a binary fuzz blob from stdin or a file argument,
 * splits it into a HID report descriptor and (optionally) a
 * single HID report, and exercises inputfs's parser surface:
 *
 *   1. inputfs_pointer_locate  (descriptor walk: pointer)
 *   2. inputfs_extract_pointer (report parse:    pointer)
 *   3. inputfs_keyboard_locate (descriptor walk: keyboard)
 *   4. inputfs_extract_keyboard(report parse:    keyboard)
 *   5. inputfs_digitizer_locate (descriptor walk: digitizer)
 *      (the extract counterpart lands in a later commit per
 *      the AD-1 HUP_DIGITIZERS sub-item plan)
 *
 * Wire format of the input blob:
 *
 *   offset 0..1    big-endian uint16: rdesc_len
 *   offset 2..    rdesc_len bytes: HID descriptor
 *   offset 2+rdesc_len..3+rdesc_len   big-endian uint16: report_len
 *   offset 4+rdesc_len..              report_len bytes: HID report
 *
 * If report_len is 0, only the locate phase runs. If the
 * input blob ends before the report-length prefix, only the
 * locate phase runs (a deliberately short input is a valid
 * fuzz pattern: "what does locate do with this descriptor
 * alone?").
 *
 * The harness exits 0 if the parsers ran without crashing.
 * AddressSanitizer (linked in via -fsanitize=address) prints
 * its own report and exits with non-zero on a detected fault
 * (out-of-bounds read, use-after-free, etc.). The fuzz oracle
 * is therefore "non-zero exit = bug; zero exit = no bug found".
 *
 * The harness deliberately does NOT validate descriptors or
 * reports for semantic correctness. We are testing crash
 * resistance, not parse correctness. Garbage in -> garbage
 * out is acceptable; garbage in -> crash is the bug we hunt.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Parser surface declarations. The fuzz harness includes
 * inputfs_parser.h directly; the shim provides hid_size_t and
 * struct hid_location through the vendored hid.h.
 */
#include "inputfs_parser.h"

#define MAX_BLOB_BYTES (64 * 1024)

static int
read_all(FILE *fp, uint8_t *buf, size_t cap, size_t *out_len)
{
	size_t total = 0;
	while (total < cap) {
		size_t got = fread(buf + total, 1, cap - total, fp);
		if (got == 0) {
			if (feof(fp))
				break;
			return (-1);
		}
		total += got;
	}
	*out_len = total;
	return (0);
}

static uint16_t
read_be16(const uint8_t *p)
{
	return ((uint16_t)p[0] << 8) | (uint16_t)p[1];
}

int
main(int argc, char **argv)
{
	uint8_t blob[MAX_BLOB_BYTES];
	size_t blob_len = 0;
	FILE *fp = stdin;
	int verbose = (getenv("INPUTFS_FUZZ_VERBOSE") != NULL);

	if (argc > 1) {
		fp = fopen(argv[1], "rb");
		if (fp == NULL) {
			perror(argv[1]);
			return (2);
		}
	}

	if (read_all(fp, blob, sizeof(blob), &blob_len) != 0) {
		perror("read");
		if (fp != stdin)
			fclose(fp);
		return (2);
	}
	if (fp != stdin)
		fclose(fp);

	/*
	 * Phase 1: parse the wire format. If the prefix is
	 * malformed (truncated, length out of bounds), we skip
	 * the corresponding phase silently. The harness should
	 * never crash on a malformed blob; that is, after all,
	 * the bug class we are testing for. Crashes from THIS
	 * code (the wire-format parser) would be harness bugs,
	 * not parser bugs.
	 */
	const uint8_t *rdesc = NULL;
	uint16_t rdesc_len = 0;
	const uint8_t *report = NULL;
	uint16_t report_len = 0;

	if (blob_len >= 2) {
		rdesc_len = read_be16(blob);
		if ((size_t)rdesc_len <= blob_len - 2) {
			rdesc = blob + 2;
			size_t after = 2 + (size_t)rdesc_len;
			if (after + 2 <= blob_len) {
				report_len = read_be16(blob + after);
				if ((size_t)report_len <= blob_len - after - 2) {
					report = blob + after + 2;
				} else {
					report_len = 0;
				}
			}
		} else {
			rdesc_len = 0;
		}
	}

	if (verbose) {
		printf("blob_len=%zu\n", blob_len);
		printf("rdesc_len=%u\n", (unsigned)rdesc_len);
		printf("report_len=%u\n", (unsigned)report_len);
	}

	/*
	 * Phase 2: pointer locate + extract.
	 */
	struct inputfs_parser_state pstate;
	memset(&pstate, 0, sizeof(pstate));

	inputfs_pointer_locate(&pstate, rdesc, rdesc_len);

	if (verbose) {
		printf("pointer_locations_valid=%u\n",
		    (unsigned)pstate.pointer_locations_valid);
		printf("loc_x_pos=%u loc_x_size=%u loc_x_count=%u\n",
		    (unsigned)pstate.loc_x.pos,
		    (unsigned)pstate.loc_x.size,
		    (unsigned)pstate.loc_x.count);
		printf("loc_y_pos=%u loc_y_size=%u loc_y_count=%u\n",
		    (unsigned)pstate.loc_y.pos,
		    (unsigned)pstate.loc_y.size,
		    (unsigned)pstate.loc_y.count);
		printf("loc_wheel_pos=%u loc_wheel_size=%u\n",
		    (unsigned)pstate.loc_wheel.pos,
		    (unsigned)pstate.loc_wheel.size);
		printf("loc_buttons_pos=%u loc_buttons_size=%u\n",
		    (unsigned)pstate.loc_buttons.pos,
		    (unsigned)pstate.loc_buttons.size);
		printf("button_count=%u\n", (unsigned)pstate.button_count);
		printf("has_wheel=%u\n", (unsigned)pstate.has_wheel);
	}

	if (report != NULL && pstate.pointer_locations_valid) {
		int32_t dx = 0, dy = 0, dw = 0;
		uint32_t buttons = 0;
		int rc = inputfs_extract_pointer(&pstate, report, report_len,
		    &dx, &dy, &dw, &buttons);
		if (verbose) {
			printf("extract_pointer_rc=%d\n", rc);
			printf("out_dx=%d out_dy=%d out_dw=%d "
			    "out_buttons=0x%08x\n",
			    (int)dx, (int)dy, (int)dw, (unsigned)buttons);
		}
	} else if (verbose) {
		printf("extract_pointer_skipped=1\n");
	}

	/*
	 * Phase 3: keyboard locate + extract.
	 *
	 * Re-zero the parser state. Locate functions zero their
	 * own portion of the struct, but we want to test each
	 * phase in isolation rather than relying on the previous
	 * call's state.
	 */
	memset(&pstate, 0, sizeof(pstate));

	inputfs_keyboard_locate(&pstate, rdesc, rdesc_len);

	if (verbose) {
		printf("keyboard_locations_valid=%u\n",
		    (unsigned)pstate.keyboard_locations_valid);
		printf("loc_modifiers_pos=%u loc_modifiers_size=%u\n",
		    (unsigned)pstate.loc_modifiers.pos,
		    (unsigned)pstate.loc_modifiers.size);
		printf("loc_keys_pos=%u loc_keys_size=%u loc_keys_count=%u\n",
		    (unsigned)pstate.loc_keys.pos,
		    (unsigned)pstate.loc_keys.size,
		    (unsigned)pstate.loc_keys.count);
	}

	if (report != NULL && pstate.keyboard_locations_valid) {
		uint8_t modifiers = 0;
		uint8_t keys[6] = { 0 };
		int rc = inputfs_extract_keyboard(&pstate, report, report_len,
		    &modifiers, keys);
		if (verbose) {
			printf("extract_keyboard_rc=%d\n", rc);
			printf("out_modifiers=0x%02x\n", (unsigned)modifiers);
			printf("out_keys=%02x,%02x,%02x,%02x,%02x,%02x\n",
			    (unsigned)keys[0], (unsigned)keys[1],
			    (unsigned)keys[2], (unsigned)keys[3],
			    (unsigned)keys[4], (unsigned)keys[5]);
		}
	} else if (verbose) {
		printf("extract_keyboard_skipped=1\n");
	}

	/*
	 * Phase 4: digitizer locate + extract (AD-1 HUP_DIGITIZERS).
	 *
	 * The locator populates the per-finger and per-report field
	 * caches plus the Device Mode feature-report cache. The
	 * extractor is exercised against the supplied report bytes
	 * if a report is present in the fuzz blob; otherwise locate
	 * runs alone. Both phases are exercised so the harness
	 * covers crash-resistance for the full descriptor walk and
	 * the report-parse path.
	 */
	memset(&pstate, 0, sizeof(pstate));

	inputfs_digitizer_locate(&pstate, rdesc, rdesc_len);

	if (verbose) {
		printf("digitizer_locations_valid=%u\n",
		    (unsigned)pstate.digitizer_locations_valid);
		printf("digitizer_report_id=%u\n",
		    (unsigned)pstate.digitizer_report_id);
		printf("loc_tip_switch_pos=%u loc_tip_switch_size=%u\n",
		    (unsigned)pstate.loc_tip_switch.pos,
		    (unsigned)pstate.loc_tip_switch.size);
		printf("loc_confidence_pos=%u loc_confidence_size=%u\n",
		    (unsigned)pstate.loc_confidence.pos,
		    (unsigned)pstate.loc_confidence.size);
		printf("loc_touch_x_pos=%u loc_touch_x_size=%u\n",
		    (unsigned)pstate.loc_touch_x.pos,
		    (unsigned)pstate.loc_touch_x.size);
		printf("loc_touch_y_pos=%u loc_touch_y_size=%u\n",
		    (unsigned)pstate.loc_touch_y.pos,
		    (unsigned)pstate.loc_touch_y.size);
		printf("loc_contact_id_pos=%u loc_contact_id_size=%u\n",
		    (unsigned)pstate.loc_contact_id.pos,
		    (unsigned)pstate.loc_contact_id.size);
		printf("loc_scan_time_pos=%u loc_scan_time_size=%u\n",
		    (unsigned)pstate.loc_scan_time.pos,
		    (unsigned)pstate.loc_scan_time.size);
		printf("loc_contact_count_pos=%u loc_contact_count_size=%u\n",
		    (unsigned)pstate.loc_contact_count.pos,
		    (unsigned)pstate.loc_contact_count.size);
		printf("loc_touch_button_pos=%u loc_touch_button_size=%u\n",
		    (unsigned)pstate.loc_touch_button.pos,
		    (unsigned)pstate.loc_touch_button.size);
		printf("touch_x_range=[%d..%d]\n",
		    (int)pstate.touch_x_min, (int)pstate.touch_x_max);
		printf("touch_y_range=[%d..%d]\n",
		    (int)pstate.touch_y_min, (int)pstate.touch_y_max);
		printf("device_mode_valid=%u device_mode_rid=%u "
		    "device_mode_rlen=%u\n",
		    (unsigned)pstate.device_mode_valid,
		    (unsigned)pstate.device_mode_rid,
		    (unsigned)pstate.device_mode_rlen);
		printf("loc_device_mode_pos=%u loc_device_mode_size=%u\n",
		    (unsigned)pstate.loc_device_mode.pos,
		    (unsigned)pstate.loc_device_mode.size);
	}

	if (report != NULL && pstate.digitizer_locations_valid) {
		uint8_t tip = 0, conf = 0, cid = 0, ccount = 0, btn = 0;
		int32_t tx = 0, ty = 0;
		uint32_t stime = 0;
		int rc = inputfs_extract_digitizer(&pstate, report, report_len,
		    &tip, &conf, &cid, &tx, &ty,
		    &stime, &ccount, &btn);
		if (verbose) {
			printf("extract_digitizer_rc=%d\n", rc);
			printf("out_tip=%u out_conf=%u out_cid=%u\n",
			    (unsigned)tip, (unsigned)conf, (unsigned)cid);
			printf("out_x=%d out_y=%d\n", (int)tx, (int)ty);
			printf("out_scan_time=%u out_contact_count=%u "
			    "out_button=%u\n",
			    (unsigned)stime, (unsigned)ccount, (unsigned)btn);
		}
	} else if (verbose) {
		printf("extract_digitizer_skipped=1\n");
	}

	return (0);
}
