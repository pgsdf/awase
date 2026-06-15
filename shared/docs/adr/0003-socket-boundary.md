# shared 0003: Socket system-call boundary (compat.posix)

## Status

Proposed (draft for operator review), drafted 2026-06-15 during the Zig 0.15.2 to
0.16.0 migration; revised 2026-06-15 per operator review, pending ratification.
Review revisions in this round: the error model made an explicit AD-6 ownership
decision (compat.posix owns a small Awase-owned error surface rather than
reproducing the historical std.posix error sets, Decision 6); the accept4 form
recorded as the owned shape with no parallel three-argument variant unless a call
site requires it (Decision 6); a handle-type convention fixed (socket_t for
socket handles including the socketpair output, fd_t reserved for generic
descriptor APIs, Decision 6); and the setsockopt exclusion tied back to the 0001
scope rule that surviving APIs stay outside compat.* until removal or instability
justifies ownership (Decision 2). The third ADR in the shared series and the instance that closes
shared 0001 criterion 3 (the socket boundary). Like 0002, it was surfaced rather
than anticipated: the filesystem, console, concurrency, and timing boundaries
established under 0001 and 0002 held through the chronofs, inputfs, semainput, and
full shared conversions (every shared/src file now builds and benches green under
the vendored 0.16.0 toolchain), and the one std surface still removed and not yet
owned is the socket-wrapper family (Class D). 0001 deliberately deferred this
instance until the socket-free units cleared and the pure socket surface was
visible. It is now visible: a 2026-06-15 graph survey inventoried the entire
socket closure across semadraw and semasound. Per ADR-before-code, no compat.posix
module lands before this ratification. The closure gate is semadraw, semasound,
and pgsd-sessiond building and benching green under the vendored toolchain through
this boundary.

## Context

The survey established one structural fact that shapes every decision below: the
socket surface is concentrated, not distributed. Across 103 Zig files and roughly
46,000 lines in the two socket-bearing subprojects, the entire socket closure
lives in seven files and resolves to about a dozen distinct system calls. This is
the opposite of the Class E filesystem surface, which 0001 recorded as 51 files
and the dominant migration cost. The socket boundary is small enough to design in
full rather than discover while coding.

The second fact is the split between removed verbs and surviving types. The 0.16
cycle removed nearly the entire std.posix socket-wrapper family but kept the
socket data types. That split is what keeps this boundary inside the 0001
principle rather than turning it into something larger. Awase code does not need
a new socket abstraction. It needs the removed verbs owned at a stable local
interface while it continues to speak in the native socket types the std surface
still provides. compat.posix is therefore an ownership boundary over volatile
entry points, exactly as 0001 intended, and not a transport or networking layer.

The third fact concerns the one case 0001 named as hard, descriptor passing
(SCM_RIGHTS). The survey shows it is narrower than feared. The ancillary-data
machinery in semadraw already exists, is locally owned, and does not depend on
the removed surface. The hard case reduces to two removed verbs operating on a
message structure that otherwise survives intact.

## Decisions

### 1. The boundary owns verbs, not protocol semantics

compat.posix owns the removed socket system-call verbs and nothing above them.
Unix-domain sockets, TCP sockets, socketpairs, and descriptor passing remain
visible and distinct at every call site. The boundary does not normalize them
into a common transport abstraction, does not hide address families, and does not
introduce a connection or channel type. A reader of a call site after migration
sees the same socket program it saw before, with the removed verbs sourced from
compat.posix instead of std.posix.

This is the direct application of the 0001 principle (dependence flows downward
from Awase code to compatibility interface to external surface) to the socket
surface, and it is recorded as a standing constraint because socket work invites
the opposite: the temptation to build a networking framework. The survey argues
against that. We are not abstracting networking. We are absorbing stdlib
volatility in a fixed set of verbs.

### 2. Removed-verb inventory (what the boundary owns)

Confirmed against the vendored 0.16.0 stdlib (sdk/zig/current/lib/std/posix.zig).
Every verb the tree uses, except setsockopt, is removed and must be owned:

    verb           0.16 status   used by (tree)
    socket         removed       all seven files
    socketpair     removed       ipc/tcp_server.zig (wakeup/self-pipe shape)
    bind           removed       the three servers
    listen         removed       the three servers
    accept         removed       the three servers (4-arg accept4 form, CLOEXEC)
    connect        removed       the three clients plus a socket_server probe
    shutdown       removed       semasound/src/main.zig
    sendmsg        removed       ipc/shm.zig, ipc/socket_server.zig
    recvmsg        removed       ipc/shm.zig
    send           removed       ipc/socket_server.zig, ipc/tcp_server.zig
    setsockopt     SURVIVES      ipc/tcp_server.zig (used directly, not owned)

The wider removed family that the tree does not currently use (recv, sendto,
recvfrom, getsockopt, getsockname) is removed on the same basis. It is not built
speculatively (Decision 5), but the interface shape is chosen so that adding any
of these later is a single thin wrapper, not a redesign.

Note for review: setsockopt survives in 0.16 and is the only socket verb the tree
uses that does not need ownership. It stays outside compat.posix and is called
directly, which follows the 0001 scope rule rather than being a one-off
exception: the boundary owns a std surface only when that surface is volatile, so
a surviving API remains outside compat.* until its removal or demonstrated
instability justifies ownership. If a later 0.16.x or 0.17 cycle removes or
reshapes setsockopt, it is brought into the boundary then, as a single thin
wrapper, on the same evidence-driven basis as the rest. The capability list
discussed before drafting mentioned getsockopt and getsockname; the survey finds
no call site for either in the current tree (tcp_server uses setsockopt twice and
no getsockopt). They are therefore treated as capability to preserve (Decision
5), not as surface to land now.

### 3. Surviving-type inventory (what stays native at the call site)

Confirmed present at posix.* in the vendored stdlib, used unchanged by call sites
and by compat.posix signatures:

    sockaddr (with sockaddr.un and sockaddr.in)
    AF, SOCK, SO, SCM, MSG
    msghdr, msghdr_const   (aliases of system.msghdr / system.msghdr_const)
    iovec, iovec_const
    socket_t, fd_t, socklen_t

One type left posix.*: cmsghdr now has zero declarations under posix and lives at
std.c.cmsghdr. This does not affect the tree, because the one consumer of cmsghdr
(ipc/shm.zig) sources it from a local @cImport, not from posix.* (Decision 4).
Because the address and message types survive, compat.posix takes and returns
them directly. It defines no socket types of its own.

### 4. SCM_RIGHTS analysis (ipc/shm.zig)

shm.zig passes a file descriptor over a unix-domain socket using SCM_RIGHTS
ancillary data. The survey of its current form shows the descriptor-passing
problem is almost entirely outside the removed surface:

- The control-message macros (CMSG_ALIGN, CMSG_SPACE, CMSG_LEN, CMSG_DATA) are
  hand-rolled in shm.zig as pure arithmetic over @sizeOf(c.cmsghdr). They depend
  on no std.posix wrapper and survive unchanged.
- c.cmsghdr, c.SOL_SOCKET, and c.SCM_RIGHTS come from a local @cImport at the top
  of the file. This is C interop, unaffected by the std reorganization, and stays.
- The message is built from posix.msghdr / posix.msghdr_const and posix.iovec /
  posix.iovec_const, all of which survive (Decision 3). The .control and
  .controllen fields are the surviving system.msghdr layout and are unchanged.

What remains are exactly two removed verbs: posix.sendmsg and posix.recvmsg. The
descriptor-passing migration is therefore: route those two verbs through
compat.posix taking the surviving msghdr types, and leave the ancillary-data
machinery in place. Descriptor passing is first-class in this ADR (it is a named
member of the public surface, Decision 6), but the survey shows it is a narrow
design problem, not an open-ended one.

### 5. Capability preservation, and the thin-shim rule

The interface must not make any expression harder than the surviving types
already allow. It exposes, as first-class members, every shape the tree actually
uses:

- accept in its 4-argument accept4 form, so CLOEXEC is set atomically at accept
  time rather than via a separate fcntl.
- socketpair.
- sendmsg and recvmsg taking msghdr ancillary data (the SCM_RIGHTS path).
- shutdown taking the how enum.
- send.

Against that, the boundary stays thin. It is a wrapper over the removed verbs
routed through posix.system.*, and nothing more. It does not add a verb the tree
does not use, does not wrap the surviving setsockopt merely for symmetry (it is
used directly), and does not introduce state. Capability preservation and
thinness are reconciled by the shape of the wrappers: because each is a direct
pass-through that preserves native types and the native return contract, the
unused members of the removed family (getsockopt, getsockname, recv, sendto,
recvfrom) can be added one line at a time when a call site first needs one. This
matches the explicit growth policy recorded in 0002 Decision 5. The boundary
grows by demonstrated need, and the cost of growth is fixed at one thin wrapper.

### 6. Proposed public surface of compat.posix

The verbs below are the proposed surface. Each is a thin wrapper over
posix.system.* (which on FreeBSD is std.c, since the tree always links libc),
translating the raw return into an error union. Types are the surviving posix.*
types from Decision 3; this ADR fixes intent and shape, and the exact errno
handling is finalized against the vendored stdlib at implementation.

Error model. compat.posix owns its error contract. It does not reproduce the
historical std.posix wrapper error sets verbatim. Reproducing them would couple
the boundary to exactly the surface volatility it exists to isolate: the std
error sets are part of the shape that 0.16 churned, and binding to them would
defeat the ownership the boundary is taking. Instead, following the AD-6 pattern
established for read/write in posix_safe, each wrapper exposes a small,
Awase-owned error set covering only the failure modes its call sites act on, and
maps errno into that set without panicking via unexpectedErrno. The owned sets
are deliberately narrow; a call site that today switches on a handful of errno
cases keeps switching on the named subset it handles, and unhandled errno values
collapse to a single owned catch-all rather than widening the contract. The
concrete per-verb error sets are defined at implementation against the actual
call-site handling, the same way posix_safe's read/write error surface was.

This is, by design, the one decision in this ADR that defines a new contract
rather than relocating an existing one. Every other decision transfers ownership
of a verb while holding its observable behaviour constant, so a migrated call
site reads as it did before. The error surface is the deliberate exception: it is
the one place the boundary is opinionated rather than transparent, and it is so
on purpose, because an error contract inherited from the volatile surface is not
actually owned. The cost is recorded honestly: at each of the seven files the
error handling is read and re-pointed at the owned set, so the conversions carry
an error-handling pass and are not a pure verb substitution. The faithfulness
rule above (named cases for what call sites distinguish, catch-all only for what
none of them act on) is what keeps that pass behaviour-preserving where behaviour
matters.

    pub fn socket(domain: u32, sock_type: u32, protocol: u32) !posix.socket_t
    pub fn socketpair(domain: u32, sock_type: u32, protocol: u32,
                      fds: *[2]posix.socket_t) !void
    pub fn bind(fd: posix.socket_t, addr: *const posix.sockaddr,
                len: posix.socklen_t) !void
    pub fn listen(fd: posix.socket_t, backlog: u31) !void
    pub fn accept(fd: posix.socket_t, addr: ?*posix.sockaddr,
                  addr_len: ?*posix.socklen_t, flags: u32) !posix.socket_t
    pub fn connect(fd: posix.socket_t, addr: *const posix.sockaddr,
                   len: posix.socklen_t) !void
    pub fn shutdown(fd: posix.socket_t, how: posix.ShutdownHow) !void
    pub fn send(fd: posix.socket_t, buf: []const u8, flags: u32) !usize
    pub fn sendmsg(fd: posix.socket_t, msg: *const posix.msghdr_const,
                   flags: u32) !usize
    pub fn recvmsg(fd: posix.socket_t, msg: *posix.msghdr, flags: u32) !usize

setsockopt is not listed: it survives and is used directly. getsockopt,
getsockname, recv, sendto, and recvfrom are not listed: they are not used
(Decision 5). The interface is otherwise complete for the current tree.

Handle-type convention. The signatures use posix.socket_t, not posix.fd_t, for
every socket the boundary produces or operates on, including the pair that
socketpair fills. On FreeBSD the two are the same underlying integer, but the
distinction documents intent and keeps the boundary from drifting into ambiguous
handle typing as it grows: socket-producing calls return posix.socket_t, socket
operations take posix.socket_t, and posix.fd_t is reserved for generic descriptor
APIs (the read/write surface in posix_safe, and any future non-socket wrapper).

accept ownership. compat.posix owns the four-argument accept4 form the tree uses
today, where CLOEXEC is set atomically at accept time. A simpler three-argument
accept wrapper is not introduced unless a real call site requires it; per the
thin-shim rule (Decision 5) the boundary does not carry parallel accept variants
for hypothetical consumers.

Two items to anchor at implementation, not now: the precise posix.system.sendmsg
and recvmsg signatures (they are not top-level pub extern fn in c.zig and need a
quick vendored anchor when the wrappers are written), and the exact shape of the
accept flags and ShutdownHow types as the call sites pass them.

### 7. Module placement

Per 0001 Decision 3, compat.posix is a submodule under shared/src/compat/,
re-exported by shared/src/compat.zig, so socket consumers reach it through the
compat aggregator and the one-module-per-compilation rule is respected (a consumer
imports compat, never a standalone socket module). It is a sibling of the existing
posix_safe read/write surface (AD-6), which keeps its determinism-boundary role
unchanged; this ADR does not consolidate the two, and any future merge of the
posix surfaces is explicitly out of scope here. The submodule defines no types and
holds only the verb wrappers of Decision 6.

### 8. Migration order for the seven files

The boundary lands first, then is proven on the smallest closure before the
careful case, each step benched green before the next, smallest-closure-first per
the chronofs lesson:

1. compat.posix lands behind this ADR (wrappers only, no consumer yet).
2. Prove the boundary on the smallest client: semasound/src/tone_client.zig
   (socket + connect, unix). Smallest socket consumer in the tree.
3. semadraw/src/client/connection.zig (socket + connect, unix; the path
   pgsd-sessiond transitively pulls) and client/remote_connection.zig (socket +
   connect, TCP).
4. The servers: semadraw/src/ipc/socket_server.zig (socket, bind, listen, accept,
   connect probe, send, sendmsg), semadraw/src/ipc/tcp_server.zig (socket,
   socketpair, bind, listen, accept, send, setsockopt), and
   semasound/src/main.zig (socket, bind, listen, accept, shutdown).
5. semadraw/src/ipc/shm.zig last: the SCM_RIGHTS descriptor-passing path
   (sendmsg, recvmsg over surviving msghdr; ancillary machinery unchanged). It is
   the most careful conversion and benefits from the boundary being proven on the
   simpler verbs first.
6. The subprojects then build green in dependency order: semadraw, then semasound.
   pgsd-sessiond follows: it owns no sockets and is blocked solely by its
   transitive semadraw client dependency, so once semadraw is green its remaining
   surface is the routine leaf pass recorded in the notebook.

### 9. Record-keeping and closure

The per-file before/after detail and the socket-surface survey remain in the
working notebook (docs/ZIG_016_MIGRATION.md); this ADR does not restate individual
sites beyond the inventories above. The notebook is updated to reference this ADR
as the architectural decision the migration surfaced for Class D, and to carry the
seven-file migration order.

Closure criteria:

1. This ADR is ratified and compat.posix lands behind it.
2. The seven socket-bearing files are migrated to compat.posix and benched, each
   in the order of Decision 8.
3. semadraw, semasound, and pgsd-sessiond build and bench green under the vendored
   0.16.0 toolchain, at which point shared 0001 criterion 3 is satisfied, the
   compatibility boundary has its final concrete instance, and the Zig 0.16
   migration is structurally complete.
