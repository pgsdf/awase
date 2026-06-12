# Vendored FreeBSD HID source

This directory contains verbatim copies of FreeBSD's HID library
source files, used by the AD-9 fuzz harness to compile the same
parser logic the kernel runs against.

Files in this directory match the contents of the corresponding
files in `/usr/src/sys/dev/hid/` on PGSD-bare-metal at the time
this directory was first vendored:

- `hid.c`: the HID descriptor walker and parser library.
- `hid.h`: types, constants, and prototypes.
- `hidquirk.h`: the HQ_ enum (used by hid.c's hid_test_quirk path).

`hidquirk.c` is deliberately NOT vendored; the harness does not
compile or link it. hid.c's `hid_test_quirk_p` function pointer
keeps its default initialiser (`&hid_test_quirk_w`, returns false),
which is correct for the parser path we exercise.

Per ADR 0014's AD-9.2 strategy, these files are compiled
byte-identical to FreeBSD upstream. The shim header
(`../../kernel_shim.h`) supplies the kernel symbols hid.c
references; the shim_includes directory (`../../shim_includes/`)
supplies replacements for `opt_hid.h` and `hid_if.h`.

To resync with a newer FreeBSD upstream:

    cp /usr/src/sys/dev/hid/hid.c       hid.c
    cp /usr/src/sys/dev/hid/hid.h       hid.h
    cp /usr/src/sys/dev/hid/hidquirk.h  hidquirk.h

then rebuild the harness (`make` in `inputfs/test/fuzz/`) and
run the corpus through it (AD-9.4) to confirm no behavioural
drift.
