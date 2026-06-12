# 0008 HID Report Descriptor Fetch and Validation (Stage B.3)

## Status

Proposed

## Context

Stage B.2 (ADR 0007) established inputfs as a `hidbus`-attached
driver that probes and attaches to HID devices matching Generic
Desktop keyboard, mouse, and pointer TLCs. The current attach
path logs the device by vendor/product ID and returns success,
but does not yet inspect the device's HID report descriptor.
Subsequent stages will need the descriptor to know which input
fields each device actually reports.

Stage B.3 fetches the report descriptor, validates it by walking
its items, and caches the descriptor pointer in the per-device
softc for later stages. No field-level interpretation happens in
this stage; that is Stage B.4's work, and depends on decisions
about which events each role produces.

The goals are narrow on purpose. B.3 exists to prove that the
descriptor-fetch and descriptor-walk paths work correctly against
the full set of HID hardware inputfs might see, so that B.4 can
build interrupt handling on top of a verified parser.

## Decision

1. **Descriptor fetch uses `hid_get_report_descr`.**
   `hid_get_report_descr(dev, &desc, &len)` returns a pointer to
   the descriptor that `hidbus` has already fetched and cached
   at its own attach time. inputfs receives a borrowed pointer;
   no allocation or free is required. inputfs retains this
   pointer for the lifetime of the device attachment.

2. **Descriptor size logging uses `hid_device_info.rdescsize`.**
   The size is already published in `struct hid_device_info`
   obtained via `hid_get_device_info(dev)`. The attach log line
   gains a descriptor-size field without any new call. B.3 also
   sanity-checks that `rdescsize == len` from the
   `hid_get_report_descr` call; a mismatch is logged as a warning
   but does not fail attach.

3. **Descriptor walk via `hid_start_parse` / `hid_get_item`.**
   After the descriptor pointer is obtained, inputfs walks it
   once during attach using the standard FreeBSD HID parser
   loop. The walk counts input items, output items, feature
   items, and the deepest collection nesting level. These counts
   are logged on attach and stored in the per-device softc. The
   walk validates that the descriptor is well-formed by
   requiring `hid_get_item` to complete without error.

4. **Classification is not redone in B.3.** The TLC-based
   classification established in Stage B.2 (via
   `hidbus_get_usage` and our own mapping) remains authoritative.
   inputfs does not call `hid_is_keyboard` or `hid_is_mouse`
   because those inspect the descriptor and could disagree with
   the TLC match. ADR 0004 fixes role classification at the TLC
   level, and B.3 preserves that.

5. **Per-device softc gains descriptor state.** The
   `struct inputfs_softc` declared in B.2 is extended with:
   - `const void *sc_rdesc`: pointer to the cached descriptor.
   - `hid_size_t sc_rdesc_len`: descriptor length in bytes.
   - `uint32_t sc_input_items`: count of input items found in
     the walk.
   - `uint32_t sc_output_items`: count of output items.
   - `uint32_t sc_feature_items`: count of feature items.
   - `uint32_t sc_collection_depth`: maximum observed
     collection nesting depth.

   These fields are populated during attach and are read-only
   for the lifetime of the device. No locking is needed because
   they are written once before `inputfs_attach` returns and
   never mutated afterwards.

6. **Failure modes.** If `hid_get_report_descr` fails, inputfs
   logs a warning and proceeds with attach. The softc fields for
   descriptor data are left zero. The TLC-based classification
   still identifies the device kind. B.3 treats the descriptor
   as informational; B.4 will treat it as required and will fail
   attach if the descriptor cannot be obtained.

   If the walk loop terminates abnormally (for example,
   `hid_get_item` returning zero before reaching the end of the
   descriptor), the partial counts are retained in softc and a
   warning is logged. The walk is cheap; there is no retry.

## Consequences

1. The Stage B.2 attach log line gains descriptor-related
   fields. Today's message:

   ```
   inputfs0: inputfs: attached HID mouse (vendor=0x1532, product=0x0078)
   ```

   becomes:

   ```
   inputfs0: inputfs: attached HID mouse (vendor=0x1532, product=0x0078, desc=71 bytes, 5 input items)
   ```

   The exact format is an implementation detail; the content is
   device kind, vendor/product, descriptor size, and input-item
   count. The full breakdown (input/output/feature items,
   collection depth) is available in softc for diagnostic tools
   but does not clutter the attach line.

2. inputfs depends on `hidbus` having already cached the
   descriptor. This is the case for all current transport
   backends (`usbhid`, Bluetooth HID, I2C HID), which fetch the
   descriptor during their own attach paths and hand it to
   `hidbus`. inputfs does not need to handle the case of a
   device that has not yet had its descriptor read; `hidbus`
   ensures that by the time a child driver's `attach` runs, the
   descriptor is available.

3. The softc fields added in B.3 are a foundation for Stage C's
   device inventory in the state region. `shared/INPUT_STATE.md`
   specifies a `name`, `usb_vendor`, `usb_product`, and a
   `lighting_caps` descriptor but does not currently include
   per-device item counts or descriptor length. When Stage C
   wires the softc to the state region, we may decide to expose
   these counts or keep them internal to the kernel module. This
   ADR does not commit to either choice; it commits only to
   having the counts available.

4. Walking the descriptor on attach is O(N) in descriptor bytes,
   where N is typically under 200. The walk runs once per attach
   and does not affect runtime performance. `hid_start_parse`
   allocates a small parse-state structure; `hid_end_parse`
   releases it. Both are called within `inputfs_attach`.

5. The ADR commits inputfs to reading but not modifying the
   descriptor. Report-descriptor overloading (as `hms_identify`
   does for boot-protocol mice without a proper descriptor) is
   out of scope for B.3 and for inputfs generally. If a future
   device requires descriptor overloading, a follow-on ADR
   addresses it; the assumption for now is that every device
   inputfs sees arrives with a valid descriptor.

6. Stage B.3 does not yet register an interrupt handler via
   `hidbus_set_intr`. That is Stage B.4. Attaching inputfs to a
   device and parsing its descriptor does not cause any events
   to flow; the device remains quiescent from inputfs's point of
   view.

## Stage B.3 Scope

Stage B.3 establishes:

1. Descriptor fetch via `hid_get_report_descr` inside
   `inputfs_attach`.
2. Descriptor walk via `hid_start_parse` / `hid_get_item` /
   `hid_end_parse`.
3. Softc extension with descriptor pointer, length, and item
   counts.
4. Augmented attach log line showing descriptor size and input-
   item count.
5. Graceful handling of descriptor-fetch failure and malformed
   descriptors.

### Success Criteria

With inputfs loaded and hms/hkbd/hgame/hcons/hsctrl/utouch
unloaded, attaching a USB HID keyboard or mouse produces a
dmesg line along the lines of:

```
inputfs0: <inputfs HID device> on hidbus5
inputfs0: inputfs: attached HID mouse (vendor=0x1532, product=0x0078, desc=71 bytes, 5 input items)
```

`sysctl` or `devinfo` inspection of the attached device shows
the same counts (delivery mechanism for this is out of scope;
the softc fields exist and are populated, which is enough for
B.3).

## Implementation Plan

1. Extend `struct inputfs_softc` with the new fields.

2. Add descriptor fetch at the top of `inputfs_attach`:

   ```c
   const void *rdesc = NULL;
   hid_size_t rdesc_len = 0;
   error = hid_get_report_descr(dev, (void **)&rdesc, &rdesc_len);
   if (error != 0) {
       device_printf(dev, "inputfs: descriptor fetch failed (error=%d)\n", error);
       /* proceed with attach; softc rdesc fields stay zero */
   } else {
       sc->sc_rdesc = rdesc;
       sc->sc_rdesc_len = rdesc_len;
   }
   ```

3. Add the walk after the fetch. FreeBSD's `hid_start_parse`
   accepts only one item-kind bit at a time, so walk three times,
   once per kind. Collection and endcollection items come through
   on any walk, so collection nesting depth is tracked during the
   input pass:

   ```c
   if (sc->sc_rdesc != NULL) {
       struct hid_data *s;
       struct hid_item hi;
       uint32_t depth = 0, max_depth = 0;
       int ii = 0, oi = 0, fi = 0;

       /* First pass: input items and collection depth. */
       s = hid_start_parse(sc->sc_rdesc, sc->sc_rdesc_len,
           1 << hid_input);
       if (s != NULL) {
           while (hid_get_item(s, &hi) > 0) {
               switch (hi.kind) {
               case hid_input: ii++; break;
               case hid_collection:
                   depth++;
                   if (depth > max_depth) max_depth = depth;
                   break;
               case hid_endcollection:
                   if (depth > 0) depth--;
                   break;
               default: break;
               }
           }
           hid_end_parse(s);
       }

       /* Second pass: output items. */
       s = hid_start_parse(sc->sc_rdesc, sc->sc_rdesc_len,
           1 << hid_output);
       if (s != NULL) {
           while (hid_get_item(s, &hi) > 0) {
               if (hi.kind == hid_output) oi++;
           }
           hid_end_parse(s);
       }

       /* Third pass: feature items. */
       s = hid_start_parse(sc->sc_rdesc, sc->sc_rdesc_len,
           1 << hid_feature);
       if (s != NULL) {
           while (hid_get_item(s, &hi) > 0) {
               if (hi.kind == hid_feature) fi++;
           }
           hid_end_parse(s);
       }

       sc->sc_input_items = ii;
       sc->sc_output_items = oi;
       sc->sc_feature_items = fi;
       sc->sc_collection_depth = max_depth;
   }
   ```

4. Update the attach log line to include descriptor size and
   input-item count.

5. Update `inputfs_detach` to zero the descriptor fields (defensive;
   softc is freed regardless).

6. The `kindset` argument to `hid_start_parse` is a bitmask, but
   the parser requires exactly one bit set. Passing multiple bits
   causes the parser to emit "Only one bit can be set in the
   kindset" and return a parser in an invalid state. This is
   documented here because the constraint is not visible in
   `hid.h`'s declaration of the function; it is enforced at
   runtime in `sys/dev/hid/hid.c`. Reference drivers
   `sys/dev/hid/hidbus.c` and `sys/dev/hid/hidmap.c` follow the
   single-bit pattern consistently.

## Testing

The test sequence from Stage B.2 applies without modification.
The additional verification is that the attach log line carries
descriptor-size and input-item-count fields, and that values are
sensible for the tested device (e.g., a basic three-button mouse
has ~5 input items: X, Y, wheel, button array, padding).

The live-system cost noted during B.2 testing applies. Testing
B.3 on a primary-input device disrupts the desktop session; a
dedicated USB HID device or a test environment without a desktop
session is preferable for iterative testing.

## Notes

`hid_start_parse` takes a `kindset` bitmask per `hid.h`, but the
FreeBSD implementation enforces that exactly one bit must be set.
The three counts (input, output, feature) are obtained by walking
the descriptor three times. Each walk is O(N) in descriptor
bytes, typically under 200 bytes, so the cost is negligible.

`hid_item.kind` identifies what the returned item is. Collections
(`hid_collection`) and their terminators (`hid_endcollection`)
arrive through the loop regardless of which kind bit is set, so
collection-depth tracking happens during the input walk only.
This is the same pattern used in `hidbus.c` for its own
descriptor walks.

The `hid_get_item` return value is documented as ">0 on success",
with zero or negative values indicating end-of-descriptor or
malformed input. The parse state allocated by `hid_start_parse`
is freed by `hid_end_parse` regardless of how the loop
terminates.

Stage B.4 will add `hidbus_set_intr(dev, handler, context)` to
register a report-delivery callback, allocate a buffer sized per
`hid_report_size_max`, and log incoming reports as hex dumps to
dmesg. No event publication to userspace happens until Stage C.

## Errata

The initial draft of this ADR specified a single walk of the
descriptor with a multi-bit kindset argument to `hid_start_parse`
(`(1 << hid_input) | (1 << hid_output) | (1 << hid_feature)`).
The implementation followed the draft literally. On first test
against a VirtualBox USB Tablet, the parser
emitted `hid_start_parse: Only one bit can be set in the
kindset` to dmesg and returned a parser in a state where
`hid_get_item` produced zero results. The resulting log line
showed a non-empty 85-byte descriptor with zero items counted.

The FreeBSD `hid_start_parse` implementation requires exactly
one item-kind bit in the kindset argument. This constraint is
enforced at runtime in `sys/dev/hid/hid.c` and is not visible
in `hid.h`'s function declaration. Reference drivers
(`sys/dev/hid/hidbus.c`, `sys/dev/hid/hidmap.c`) follow the
single-bit pattern consistently.

The Implementation Plan and Notes sections of this ADR have
been updated to reflect the three-pass walk that was shipped.
The original draft is preserved in the git history as the
pre-correction state.
