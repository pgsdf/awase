/*
 * opt_hid.h shim for the AD-9 fuzz harness.
 *
 * Empty: the FreeBSD kernel build generates this header with
 * "#define HID_DEBUG 1" only when the kernel config includes
 * "options HID_DEBUG". The harness intentionally compiles
 * with HID_DEBUG undefined so the DPRINTF/DPRINTFN macros in
 * <dev/hid/hid.h> expand to no-ops (matching the production
 * kernel's default).
 */
