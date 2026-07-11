# f7probe

A one-shot F7 diagnostic for pgsd-loader. It stages the
transfer-armed real-kernel boot, discovers the trampoline address
from the loader's NVRAM breadcrumb, runs QEMU halted under a gdb
stub, drives gdb through the transfer and a set of early-kernel
landmark breakpoints, and captures the **complete** gdb and serial
streams. It then prints a single structured report and writes the
full unfiltered transcripts to disk.

It exists because the ad hoc `gdb-transfer.sh` modes filtered gdb
output through greps that repeatedly hid the diagnostic they were
meant to surface (a missing `continue`, a `commands`-binding subtlety,
breakpoints that may not resolve). f7probe keeps everything and
presents it, so one run answers "how far did boot get, and where did
it stop."

Emulation only. It observes a QEMU run and never touches metal; the
bench remains sole authority (parent ADR 0001 Decision 7).

## Build

Requires Go 1.21+ and the module dependencies (Charm's lipgloss and
its transitive deps). On a machine with network:

```
cd pgsd-loader/tools/f7probe
go build -o f7probe .
```

If the bench has no network for module download, build on a connected
machine and copy the static binary over, or run `go mod download`
once where network is available (the module cache then serves offline
builds).

## Run

```
PGSD_REAL_KERNEL=/boot/kernel/kernel \
OVMF_CODE=/usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd \
OVMF_VARS=/usr/local/share/edk2-qemu/QEMU_UEFI_VARS-x86_64.fd \
./f7probe
```

`OVMF_CODE`/`OVMF_VARS` are auto-probed from the usual FreeBSD
(`/usr/local/share/edk2-qemu`) and Linux (`/usr/share/OVMF`)
locations; set them only to override. `PGSD_LOADER_DIR` defaults to
two levels up from the binary; set it if running the binary from
elsewhere. `QEMU` and `GDB` override the tool names.

Do not run as root.

## Output

A structured report with four sections:

- **Transfer**: trampoline and entry addresses, the cr3 switch, and
  whether the kernel entry was reached.
- **Kernel bring-up**: a checklist of early-boot landmarks
  (`amd64_loadaddr`, `hammer_time`, `native_parse_preload_data`,
  `getmemsize`, `init_param1`, `cninit`) with hit/miss.
- **Verdict**: a reasoned read of how far boot got and where the
  fault is, including the final rip and its symbol.
- **Evidence**: the NVRAM markers and the serial tail.

Full transcripts are written to `/tmp/f7probe-gdb.log` and
`/tmp/f7probe-serial.log`, unfiltered, so nothing is hidden.

## Interpreting the verdict

- **Entry not reached**: fault in the loader trampoline (unexpected;
  the transfer is otherwise proven).
- **Entry reached, no landmark hit**: either the fault is in btext
  locore before `hammer_time`, or the landmark breakpoints did not
  resolve to the running kernel's addresses. The gdb transcript shows
  which (look for breakpoint-resolution errors).
- **Stopped after landmark X**: the fault is between X and the next
  landmark; read that span in the FreeBSD source and check the loader
  contract it requires.
- **Reached cninit**: early init completed. If no banner on serial,
  the issue is console/UART config, not the handoff.
