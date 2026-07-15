# Screen capture: design

Status: DESIGN AGREED (operator, 2026-07-13). IMPLEMENTED AND
BENCH-VERIFIED (2026-07-15): commits 1 through 4 (recvmsg transport,
FrameSnapshot API, capture request and reply, semadraw-ctl capture
writing PPM), with the ADR 0021 Section 8 amendment in place. Commit
5 (PNG) remains, later and optionally, as a change to one function
in semadraw-ctl. Audit item SA-4's framebuffer half closes with
this; its SDCS-capture half stays open.

## Bench record (pgsd-bare-metal, 2026-07-15)

    $ sudo semadraw-ctl capture-info
    frame: 3840x2160 stride=15360 format=1
    $ sudo semadraw-ctl capture /tmp/screen.ppm
    wrote /tmp/screen.ppm: 3840x2160

The file was byte-exact at 24,883,217 (17-byte P6 header plus
3840 * 2160 * 3) and opened cleanly in GIMP; the sessiond navy
palette (#12375c) rendering as navy confirms the BGRX byte order,
since a swapped conversion turns it muddy brown. stride was exactly
width * 4 on this panel, so the shear-handling path was not
exercised by the hardware and rests on the poison-byte unit test in
semadraw_ctl.zig. Every classed error path except
capture_no_descriptor and capture_buffer_too_small remains
unexercised on metal; the daemon-side unit story for those is the
SM-TEST-1 harness when it lands.

Deploy recipe, correcting commit 4's bench line as first written:
the s6 run script execs /usr/local/bin/semadrawd, so the rebuilt
daemon and tool deploy via install.sh (which stops semadrawd to
replace binaries); the rc.d shim's restart is the s6-svc path under
AD-20. Building in the checkout alone leaves the supervised daemon
on the old binary, which would answer the new opcodes by dropping
the connection.

Recorded because the architectural questions are settled and the
implementation is not, and the two should not be conflated. The next
session starts from a decision rather than a blank page.

---

## The capability

`semadraw-ctl capture <path>` writes the composited screen to a file.

## Where capture lives, and why

**semadrawd, not drawfs.**

The compositor is the only component with a coherent view of the scene.
drawfs exposes per-client surfaces; it is not responsible for the
composed result. A framebuffer readback ioctl would expand the kernel API
and blur that separation, and the kernel interface's smallness is the
point of drawfs's design.

The pixels already exist in userspace. `backend/drawfs.zig` composites
into `self.surface_map` and `blitToEfifb()` sends exactly that buffer to
the display. Capture is serializing a buffer semadrawd already holds, not
introducing a new readback path.

**On the control socket, not the client protocol.**

Screen capture is inherently privileged: on the client protocol, any
client could screenshot any other. ADR 0021 Section 8 established the
control socket (`semadraw.ctl`, root-owned, 0600) as the place for
privileged compositor operations, and reading the screen is at least as
sensitive as blanking it.

This is an implementation of ADR 0021's decision rather than a new
architectural direction, so it needs no new ADR. ADR 0021 Section 8 carries the amendment
naming CAPTURE as another operation on the control socket
(2026-07-15, with commit 3).

Reusing an IPC mechanism (the shared-memory primitives in `ipc/shm.zig`,
built for the client protocol) is not the same as expanding an
interface's authority.

## The transport: shared memory, not a file

The daemon does not write the output file, and does not receive the
output file's descriptor either.

  1. `semadraw-ctl` creates an anonymous shared-memory object
     (`shm_open(SHM_ANON, ...)`; FreeBSD has no `memfd_create`).
  2. It passes the fd with SCM_RIGHTS on the control socket.
  3. semadrawd maps it, copies the composited frame in, and replies with
     metadata only (`CaptureHeader`: width, height, stride, format).
  4. `semadraw-ctl` maps the buffer, converts BGRX, and writes the file
     **as the invoking user**.

**One addition beyond the agreed sketch: `capture_info`, a sizing
probe (commit 3, operator-ratified error grammar).** The client must
size the shared-memory object before sending it, and it has no
channel to learn stride and height: the reply that carries them is
the reply to the capture it cannot yet size. `capture_info` replies
with the same `CaptureHeader` metadata, takes no descriptor, and
copies nothing. A display change between probe and capture is caught
by the capture-time size check, which fails with
`capture_buffer_too_small`; the client re-probes and retries. Failure
replies use the existing `ctl_error` mechanism with distinct codes,
classed so a client can tell "fix the request" (no descriptor, bad
descriptor, buffer too small) from "retry later" (no snapshot
available) from "system fault" (mapping failed).

**Why not stream the pixels over the socket.** A 4K frame is ~33 MB. The
control socket is a control socket, and streaming that through it means
partial writes, backpressure, cancellation, clients that stop reading,
and framing for multi-megabyte replies: a great deal of machinery for
something that is not a control message. The ctl path is synchronous, and
a blocking bulk write there stalls the display.

**Why not pass the output file's fd.** SCM_RIGHTS on the output file
would solve the arbitrary-path problem, and it would still make the
daemon responsible for emitting a file format. Every new format (PNG,
JPEG) would then be a change to a privileged daemon. With a shared buffer,
semadrawd never learns what a filename is and never learns that PNG
exists.

**The resulting split is the project's own posture.** Privileged
components provide capabilities; unprivileged tools decide presentation.

    semadrawd      exposes the framebuffer, copies pixels.
                   Knows nothing about image formats.
    semadraw-ctl   owns filenames, serialization, image formats.

## The backend API: one snapshot, not several getters

    pub const FrameSnapshot = struct {
        width: u32,
        height: u32,
        stride: u32,
        format: PixelFormat,   // bgrx8888
        pixels: []const u8,
    };

    snapshot: ?*const fn (ctx: *anyopaque) ?FrameSnapshot = null,

Deliberately one call rather than `getPixels()` plus geometry getters.
Separate getters invite a tear: read width, the display resizes, read
stride, and the two now describe different frames, which produces a
sheared or out-of-bounds capture. The compositor's execution model
probably prevents that today; representing the snapshot as one thing makes
it true by construction rather than by luck, and the abstraction being
exposed IS a snapshot.

Optional in the vtable, following the established pattern for
backend-specific ops (`clearRegion`, `flush`, `getKeyEvents`). A backend
that cannot produce a coherent snapshot cannot be captured, and saying so
is a truthful answer rather than a guessed one.

**stride is carried explicitly**, in the struct and on the wire, because
it may exceed `width * 4`. A padded surface captured as if it were tight
produces a sheared image: the classic screenshot bug. The backend knows
its stride; nothing else can infer it.

## Format: PPM first

Validate the pipeline before committing to a format. PPM is ten lines
(`P6\n<w> <h>\n255\n` then RGB triples). If the buffer read, the stride
handling, or the byte order is wrong, a wrong PPM is VISIBLY wrong; a
wrong PNG is a corrupt deflate stream. PNG becomes a change to one
function afterwards.

The architectural decision is where capture lives, not which format ships
first.

## Implementation plan

Five commits, each with a single reason to exist. The transport refactor
lands independently so that a regression has an unambiguous owner.

  1. **Convert the control receive path to `recvmsg()`/SCM_RIGHTS.**
     No behavioural change. Every existing verb must work unchanged.

     The ctl loop currently uses plain `read()` (semadrawd.zig
     `handleCtlMessage`), so an fd passed with SCM_RIGHTS would be
     silently dropped. On a unix socket `recvmsg()` with no ancillary
     data behaves exactly like `read()`, so this is safe for every
     existing verb. `ipc/shm.zig` already has `sendFd`/`recvFd`, built
     and exercised for the client protocol, so this reduces the number of
     IPC patterns in the codebase rather than adding one.

  2. **Introduce the `FrameSnapshot` backend API.** Backend interface,
     drawfs implementation, vtable registration.

  3. **Add the capture request and reply**, using the shared-memory
     transport above.

  4. **`semadraw-ctl capture <path>`**, writing PPM.

  5. **PNG**, later and optionally.

## Atomicity: decided (operator, 2026-07-15, with commit 2)

The snapshot represents the same "current" surface state the
compositor would read if it composited at that point in the event
loop. The guarantee rests on two things together: the daemon's
single-threaded event-loop topology (the snapshot is taken from the
ctl handler, which runs in the same loop as compositing, so no
composite mutates the buffer concurrently) and the ADR 0022
pending/current surface state model (a commit promotes state
atomically, so "current" is never half-applied). If the compositor
architecture ever changes, multi-threaded or asynchronous
composition, the frameSnapshot implementation must preserve this
invariant or explicitly weaken the contract; it must not drift into
falsehood silently. The normative statement lives on FrameSnapshot in
backend.zig, alongside the lifetime contract: pixels is a borrowed
view, valid until the backend's next mutating operation, never
retained beyond the current loop turn, which is what makes the
capture path's copy into shared memory mandatory rather than an
implementation choice.
