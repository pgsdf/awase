# 0021 inputfs notification surface (/dev/inputfs_notify)

## Status

Proposed, 2026-05-25.

Tracks AD-41 sub-item AD-41.2. This ADR records the design
decision for a new notification surface that lets userspace
consumers wake on inputfs event publication. It does not
itself land code; AD-41.3 is the implementation step. The
pre-code grep mandate from `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`
applies before any code is written against this ADR.

### Supersedes AD-1's pollable-fd sub-item (added 2026-05-27 evening)

This ADR effectively supersedes the "pollable-fd / kqfilter
for the events ring" sub-item under BACKLOG AD-1. That
sub-item proposed adding `d_kqfilter` to the `/dev/inputfs`
cdev itself, so userspace could wait on the data device for
event arrival. This ADR chose a different design: a separate
notification character device `/dev/inputfs_notify` carries
the `d_poll` and `d_kqfilter` surface, while `/dev/inputfs`
remains the data plane (read + mmap). The reasoning for the
separate-surface design is recorded in the Decision section
below; the short version is that data and notification have
different lifecycle and access patterns and are clearer when
decoupled.

The AD-1 sub-item was marked superseded in BACKLOG on
2026-05-27 evening during the AD-1 audit; the BACKLOG
entry there carries the longer cross-reference, including
why the previous design is not being revisited. This ADR
records the symmetric forward pointer so a reader of ADR
0021 understands that the implementation it specifies
discharges the latency-improvement goal that AD-1's
sub-item described.

The AD-1 audit also found that the original sub-item text
("Effect on AD-2: none. Latency improvement only.") was
stale because AD-2 closed 2026-05-17 independently of any
work on this surface; the BACKLOG correction captures that
too. Neither correction affects this ADR's design content;
both are bookkeeping that ties the AD-1 entry and this ADR
together explicitly.

## Context

`docs/AD36_VERIFICATION.md` (2026-05-24) recorded a finding
that AD-36's harvest implementation is correct on paper but
cannot be demonstrated on the bench because semadrawd's main
loop does not iterate often enough to call the harvest when
motion is present. The substantive cause is that semadrawd's
`posix.poll` set has no fd that becomes readable when inputfs
publishes an event:

- The poll set at `semadraw/src/daemon/semadrawd.zig:1011-1067`
  includes the Unix server socket, optional TCP server, each
  client's socket, and the backend's `getPollFd()`. For the
  drawfs backend that fd is `/dev/draw` (per
  `semadraw/src/backend/drawfs.zig:1397-1401`).

- The inputfs events file at `/var/run/sema/input/events` is
  not in the poll set. It is a regular tmpfs file; mmap is the
  data plane (`shared/src/input.zig:808-849`).

- The comment at `semadrawd.zig:1052-1059` describing
  `/dev/draw` as the input wake source is stale; it dates from
  before AD-2a (2026-05-08) retired semainputd. Under that
  earlier architecture, semainputd injected EVT_KEY/POINTER/
  SCROLL/TOUCH frames into `/dev/draw`. After AD-2a, inputs
  arrive via the inputfs ring, and the poll-set wiring was not
  updated.

AD-41.1 (2026-05-24) closed with the code-read finding that
inputfs has no character device at all: no `cdevsw`, no
`make_dev` call, no `<sys/poll.h>` or `<sys/selinfo.h>`
includes. Events are published by direct memory writes into
`inputfs_events_buf` (see `inputfs_events_publish` at
`inputfs.c:1540-1615`); userspace observes those writes via
mmap. The kernel module has internal `wakeup()` calls for its
own kthreads (`inputfs_state_dirty`, `inputfs_kthread_done`)
but no notification path to userspace pollers.

The wake-source gap therefore cannot be closed by adding the
events file's fd to semadrawd's poll set. A regular file's fd
returns `POLLIN` immediately on every `poll(2)` call, which
would turn the main loop into a busy-spin instead of fixing it.
The gap is closed only by introducing a new notification
surface that userspace can register interest in via standard
`poll`/`select`/`kqueue` mechanisms.

### What is NOT in scope

Three boundary points so the work this ADR mandates does not
quietly grow.

- **The events data plane is unchanged.** The tmpfs file at
  `/var/run/sema/input/events`, the `inputfs_events_buf` kernel
  buffer, the slot layout in `shared/src/input.zig`, the mmap
  protocol, the writer_seq/earliest_seq publication scheme,
  and the EventRingReader consumer-side code all remain
  exactly as they are. The new cdev carries no event data;
  it is purely a wake signal.

- **The 100 ms poll-timeout under-firing is a separate item.**
  AD-41.5 tracks that. Even after the new wake source is in
  place, the timeout is the fallback path; it should fire
  reliably for diagnostic purposes and for any case where the
  wake source is unavailable. Fixing it is independent of this
  ADR's surface.

- **No per-consumer state in the kernel.** This ADR adopts a
  single `struct selinfo` for all pollers (option (a) from
  AD-41.2). The alternative (per-consumer socketpair or pipe
  registry, option (c) from AD-41.2) is explicitly rejected:
  it would require an ioctl-based registration protocol, a
  list of consumer fds in inputfs, lifecycle management for
  the per-consumer state on consumer death, and a per-event
  `write` syscall per registered consumer. The single-selinfo
  approach has none of that complexity and the broadcast-wake
  semantics it provides are exactly what the consumer pattern
  needs.

- **The new cdev does not implement read or write.** Consumers
  poll it for wake signals and consume event data via the
  existing mmap. `d_read` and `d_write` are unimplemented; a
  call to `read(2)` or `write(2)` on `/dev/inputfs_notify`
  returns `EOPNOTSUPP`. This is enforced rather than left
  ambiguous so that future code does not grow a parallel data
  path through the cdev that would diverge from the mmap path.

- **The kqueue path is provided alongside poll.** Both
  `d_poll` and `d_kqfilter` are implemented in the new cdev.
  semadrawd currently uses `posix.poll`; future migration to
  kqueue (whether for semadrawd or other consumers) is not
  blocked by this ADR. Implementing both is a small additional
  cost (the FreeBSD pattern is well-established) and avoids a
  forced-migration step later. EVFILT_VNODE / EVFILT_AIO
  approaches against the events file itself, as enumerated in
  AD-41.2's option (b), are not pursued: their semantics are
  subtler (EVFILT_VNODE NOTE_WRITE fires on userspace writes
  too) and the explicit cdev surface is cleaner.

## Decision

### 1. A new character device `/dev/inputfs_notify` is added

The cdev's purpose is purely to wake pollers on event
publication. It is created by `make_dev_p` in the inputfs
module's load path, alongside whatever post-`inputfs_events_open_file`
setup currently exists. It is destroyed by `destroy_dev` in
the unload path.

Naming: `/dev/inputfs_notify`. Parallel to the existing
`/var/run/sema/input/events` file's naming convention (the
events file is the data plane; the notify cdev is the
notification side-channel). The `inputfs_` prefix matches the
module name and disambiguates from any future PGSD cdev.

Ownership and mode: parallel to the events file's policy
established by ADR 0013 (publication permissions). Specifically:

- uid = `inputfs_dev_uid` (default `root`)
- gid = `inputfs_dev_gid` (default `_semadraw`, the consumer
  group)
- mode = `inputfs_dev_mode` (default `0640`, group-readable)

Read-only access at file-system level. Consumers do not need
to write to the notify cdev; only open for polling.

The same sysctls that govern the events file's perms
(`hw.inputfs.dev_uid`, `hw.inputfs.dev_gid`, `hw.inputfs.dev_mode`)
also govern the notify cdev. This is intentional: any consumer
that can mmap the data plane should be able to register for
notifications, and any restriction on the data plane should
apply equally to the notification surface. Adding a separate
set of sysctls would be a foot-gun (an operator could
asymmetrically gate the two surfaces with surprising results).

### 2. cdevsw entries

The cdev's `cdevsw` declares:

- `.d_version = D_VERSION`
- `.d_name = "inputfs_notify"`
- `.d_open`: increments an open count, no other state. May be
  used for diagnostics (a count of current pollers).
- `.d_close`: decrements the open count.
- `.d_poll`: implements the level + selrecord pattern (see
  decision 4).
- `.d_kqfilter`: implements the kqueue filter (see decision 5).

`d_read`, `d_write`, `d_ioctl`, `d_mmap` are unimplemented.
Calls return `EOPNOTSUPP` via the default handler. The
unimplemented status is documented in a comment on the
cdevsw struct so future readers do not assume an oversight.

### 3. A `struct selinfo` is added to the inputfs module's global state

A single static `struct selinfo inputfs_notify_selinfo` is
declared alongside the other global state at the top of
`inputfs.c`. It is `selinit`-initialised in the module load
path, before the cdev is created and before any thread can
call `selrecord` against it. It is `seldrain`-released in
the module unload path, after the cdev is destroyed and no
thread can call `selrecord` against it any more.

A single selinfo serves all pollers. selwakeup against a
selinfo wakes all threads that have called selrecord against
it, which is the right semantic for broadcasting event
arrival to multiple consumers.

### 4. d_poll implementation

```
static int
inputfs_notify_poll(struct cdev *dev, int events, struct thread *td)
{
    int revents = 0;

    if (events & (POLLIN | POLLRDNORM)) {
        /* Level check: are there events the caller has not
         * yet observed? Without per-fd tracking we cannot
         * answer that precisely; the level we report is
         * "writer_seq has advanced past zero", i.e., any
         * event has ever been published. Combined with the
         * edge wakeups from selwakeup in inputfs_events_publish,
         * this gives correct edge-triggered behaviour for
         * any consumer that drains its view of the ring on
         * each wake. */
        if (atomic_load_acq_64(...writer_seq...) > 0)
            revents |= events & (POLLIN | POLLRDNORM);
        else
            selrecord(td, &inputfs_notify_selinfo);
    }
    return revents;
}
```

The level check is deliberately permissive: any non-zero
writer_seq returns POLLIN. The rationale: consumers track
their own consumption position (`last_consumed` in
EventRingReader) against the kernel's writer_seq via the
mmap; the cdev does not duplicate that tracking. A consumer
that polls, sees POLLIN, drains, and polls again will get
POLLIN again immediately if the cdev returned it on the
basis of writer_seq > 0. That is fine: the consumer's drain
returns zero new events, and the consumer's next poll waits
on selrecord until the next publish.

This trades off some calls returning spurious POLLIN
(consumer wakes, drains zero events, sleeps) against the
cost of per-fd state in the kernel. The trade is correct:
the spurious-wake cost is the cost of one extra drain that
returns zero events; the per-fd state cost is per-consumer
registration and lifecycle complexity. For inputfs's
expected consumer count (small, single-digit, mostly
semadrawd) the spurious-wake cost is negligible.

### 5. d_kqfilter implementation

`d_kqfilter` accepts `EVFILT_READ` and rejects others. The
filter's `f_event` callback returns 1 (event ready) whenever
writer_seq > last_observed_seq, where last_observed_seq is
attached to the knote at filter-attach time. The knote is
linked into `inputfs_notify_selinfo.si_note`'s knote list via
`knlist_add`, and removed via `knlist_remove` on `f_detach`.

The kqueue path is structurally parallel to the poll path but
permits per-knote sequence tracking, which gives a more
precise level check. This is incidental, not the reason for
implementing kqueue; the primary reason is to avoid forcing a
poll-only contract on future consumers.

### 6. selwakeup hook in inputfs_events_publish

A single line is added to `inputfs_events_publish` (at
`inputfs.c:1540-1615`), after the step 6 earliest_seq update
at line 1607 and before the existing `wakeup(&inputfs_state_dirty)`
at line 1614:

```
/* Wake userspace pollers waiting on /dev/inputfs_notify. */
selwakeup(&inputfs_notify_selinfo);
KNOTE_UNLOCKED(&inputfs_notify_selinfo.si_note, 0);
```

Co-locating selwakeup with the slot publish is important:
userspace sees the slot's new contents via mmap as soon as
the step 4 atomic store at line 1589-1591 completes. If
selwakeup happened later (e.g. in the state-sync kthread),
there would be a window where pollers had not woken yet but
the data was already visible, and consumers polling on the
notify cdev would experience higher-than-necessary wake
latency.

selwakeup is documented (per `selwakeup(9)`) as
interrupt-safe and acquires/releases sellock internally;
it is safe to call from `inputfs_events_publish`'s call
context, which already holds locks appropriate for slot
publication. `KNOTE_UNLOCKED` is the standard companion call
for kqueue notification when the caller does not hold the
knote lock.

### 7. Per-event rate, no coalescing

Every call to `inputfs_events_publish` calls selwakeup +
KNOTE_UNLOCKED. No coalescing, no batching, no debouncing.
Rationale:

- selwakeup with a single selinfo waking N waiters has cost
  roughly O(N). For inputfs's consumer count (small, in the
  single-digit range), the per-event cost is microseconds
  at most.

- The benefit of per-event wake is exact: userspace observes
  each kernel event with the minimum possible latency that
  the wake mechanism can provide. This is the AD-36 closure
  criterion's underlying intent.

- Coalescing schemes (publish at most once per N ms; publish
  once and re-arm after consumer drains; etc.) introduce
  policy decisions about latency-vs-overhead that have no
  current motivation. If at some future point the consumer
  count grows or the publish rate becomes pathological, a
  coalescing scheme can be added without changing the
  cdev's external contract.

The per-event rate decision is on the record so that future
changes to inputfs's publish rate (e.g. higher-rate touch
events, gesture stream introduction) do not re-open the
coalescing question without recording why.

## Userspace consumer changes

Out of scope for this ADR (which covers the kernel-side
notification surface) but flagged here for AD-41.3's
implementation work:

- `semadraw/src/backend/inputfs_input.zig`: a new
  `notify_fd` field, opened from `/dev/inputfs_notify` at
  `InputfsInput.init` time. Closed at `deinit`. Exposed via
  a getter parallel to the existing mmap fd handling.

- `semadraw/src/backend/drawfs.zig`: a new backend method
  `getInputfsPollFd()` returning the notify_fd. The existing
  `getPollFd()` continues to return `/dev/draw` for backend
  events.

- `semadraw/src/backend/backend.zig`: the new method on the
  backend interface.

- `semadraw/src/daemon/semadrawd.zig:1052-1067`: the stale
  comment is replaced; the notify_fd is added to the
  per-iteration poll-fd list. The pollEvents call after
  selwakeup-driven wake drains the inputfs ring via the
  existing harvest path. No other changes to the loop body.

These changes are listed in AD-41 sub-item AD-41.3 in
BACKLOG.md.

## Pre-code verification

Per `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`, before any code
is written for AD-41.3:

- A grep against `inputfs.c` for `selinfo`, `selrecord`,
  `selwakeup`, `selinit`, `seldrain`, `KNOTE`, `knlist_add`,
  `knlist_remove`, `cdevsw`, `make_dev`, `destroy_dev` should
  confirm none currently exist. This is the precondition
  that AD-41.1 established; re-confirming at implementation
  time guards against drift.

- A grep against `inputfs.c` for `<sys/poll.h>`,
  `<sys/selinfo.h>`, `<sys/event.h>` should confirm none of
  the relevant includes currently exist. The implementation
  adds them.

- The userspace fd-management code in
  `inputfs_input.zig` should be reviewed for the cleanup
  path on `deinit`; the new notify_fd needs `posix.close` in
  the same path as the existing events file fd.

## Open questions

- **Devfs rule integration.** The current devfs setup
  (`scripts/devfs/`) handles `/dev/inputfs` (the absent
  device) and probably needs a parallel entry for
  `/dev/inputfs_notify`. AD-41.3 should confirm what the
  current ruleset does and whether the `_semadraw` group
  read access is automatic from the default mode or requires
  an explicit rule.

- **selwakeup call context.** `inputfs_events_publish` is
  called from `inputfs_state_worker` (the kthread) and
  potentially from other contexts. selwakeup is documented
  as interrupt-safe but not as MPSAFE in all kernel-locking
  regimes. AD-41.3 should verify the call context matches
  what selwakeup expects; if there is a context that
  forbids selwakeup, the publish path needs to defer the
  wake to a safe context.

- **knlist locking.** `KNOTE_UNLOCKED` assumes the caller
  does not hold the relevant lock. If `inputfs_events_publish`
  is in a path that does hold the knote lock for any
  reason, `KNOTE` (the locked variant) is the right call.
  AD-41.3 should verify and pick the right macro; the wrong
  one is a LOR (lock-order-reversal) bug, not a
  doesn't-compile bug, so this requires care.

Each of these is a small implementation-time question, not a
design-level decision. The ADR records them so they are
visible at the start of AD-41.3's work.
