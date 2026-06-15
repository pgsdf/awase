# shared 0002: Concurrency and timing primitive boundary

## Status

Accepted 2026-06-15 (operator), with review revisions: the `compat.time.sleep`
rationale strengthened to run parallel to the mutex argument (Context), an
explicit growth policy added to scope (Decision 5), and the closure record
corrected to state that the tree has no `std.Thread.Condition` consumer rather
than describing one in the relative (Context, Decision 5, and closure criterion
2). The second ADR in the shared series, drafted during the Zig 0.15.2 to 0.16.0
migration as a sibling instance of shared 0001. It was surfaced, not anticipated: the filesystem and console
boundary established under 0001 held through the chronofs conversion (the
converted code compiled and the next layer of breakage appeared elsewhere), and
that next layer is the concurrency and timing surface. Per ADR-before-code, no
`compat.sync` or `compat.time` module lands before this ratification. The work
it authorizes lands next, under the normal forward-only, operator-ratified flow:
the two boundary modules, then the chronofs conversion that proves them, then
`shared/src/clock.zig`, after which audiofs consumes the established boundary
rather than solving the same problem a second time.

## Context

The 0.16 cycle relocated synchronization and timing under `std.Io`, the same way
it relocated the filesystem. `std.Thread.Mutex` is removed; the replacement is
`std.Io.Mutex`, whose `lock` and `unlock` now take an `Io` handle.
`std.Thread.sleep` is removed; the replacement is `std.Io.sleep`, which takes an
`Io` handle, a duration, and a clock. `std.Thread.Condition` is removed on the
same pattern. Thread lifecycle is the exception: `std.Thread.spawn` and `join`
survive 0.16 unchanged and are not coupled to `Io`.

Seen alongside the rest of the migration (args moved under startup
infrastructure, the filesystem and console moved under `std.Io`, and now mutexes
and sleep moved under `std.Io`), the theme is not that these APIs disappeared. It
is that Zig is pulling more of the runtime under a unified I/O and scheduling
model. That is a coherent direction for Zig. It is not necessarily the dependency
direction Awase should adopt.

Shared 0001 absorbed volatility in the shape of std surfaces Awase already
depends on. The concurrency surface is a different case. Here the volatile
replacement does not merely change shape; it injects a dependency. A mutex is not
I/O. A sleep is not I/O. A ring-buffer lock is not I/O. Adopting `std.Io.Mutex`
and `std.Io.sleep` directly would make `Io` a transitive dependency of every data
structure that happens to contain a lock or a timer:

    ring buffer    event queue    stream    clock    scheduler    daemon
         \             \            |          /          /          /
          \             \           |         /          /          /
                         all inherit a transitive Io dependency

At that point the migration stops being about filesystem churn and becomes an
architectural inversion in which synchronization depends on I/O infrastructure.
Shared 0001 does not point in that direction; its principle is that Awase code
depends on Awase-owned interfaces, not that Awase adopts whatever dependency the
volatile surface now carries.

The point about sleep runs parallel to the point about the mutex, and is worth
stating directly. Sleeping is not volatile by nature, and the boundary does not
exist because timing is unstable. It exists because 0.16 relocated sleep behind
the same `Io` dependency the boundary is meant to keep out of code that has no
I/O concern. A poll loop that waits a few milliseconds between reads is not doing
I/O, and it should not acquire an `Io` handle to express a delay.

The blast radius is contained, which makes the choice cheap. The concurrency
surface is four files using `Mutex` and fourteen using `sleep`. There is no
`std.Thread.Condition` consumer: the one apparent match is a comment in
`semasound/src/ring.zig` recording that the ring deliberately uses a mutex and a
sleep in place of a condition variable. At that scale a small owned boundary
costs less than carrying `Io` through the rest of the system permanently. If the
counts were in the hundreds, a direct adoption might be tolerable for expediency;
at four and fourteen it is not.

## Decisions

### 1. The principle: std.Io is accepted for I/O, not for synchronization

Awase accepts `std.Io` as the implementation of file and socket operations, as
established by shared 0001. Awase does not accept `std.Io` as the ownership model
for general synchronization and timing primitives. Synchronization and timing are
not I/O, and `Io` must not become a transitive dependency of data structures
whose only relationship to it is that they contain a lock or a timer.

This refines the 0001 layering rule for a surface where the volatile std
replacement carries an unwanted dependency rather than only an unwanted shape.
The rule is unchanged in direction: dependence flows downward only, from Awase
code to an Awase-owned interface to an external surface, never from Awase code
directly to a volatile external surface, and never in a way that inverts the
direction by pulling I/O infrastructure underneath synchronization.

### 2. Owned interfaces for synchronization and timing

Awase owns its synchronization and timing primitives behind the compatibility
boundary. Two thin, single-purpose interfaces are introduced:

- `compat.sync`: owns in-process mutual exclusion. It provides a `Mutex` with
  `lock`, `unlock`, and `tryLock`, default-initializable, with no `Io` parameter.
  A `Condition` is added only if and when a call site requires it.
- `compat.time`: owns blocking timing. It provides `sleep` over a duration, with
  no `Io` parameter.

Callers depend on these interfaces. They do not reference `std.Io.Mutex`,
`std.Io.sleep`, or the removed `std.Thread` equivalents.

### 3. Interface, not implementation

This ADR defines the boundary interface, not the backing implementation. The
interface is `Io`-free by design; that is the property being preserved. The
implementation behind it may evolve without caller change. Today it is expected
to be `std.atomic` for the mutex and a posix sleep for timing, the latter routed
through the posix surface that AD-6 and `posix_safe` already own. Tomorrow it may
be `std.Thread` primitives, future Zig runtime primitives, or a
platform-specific implementation. Callers must not depend on the backing choice,
only on the interface.

A minimal sketch of the intended public surface, to fix the boundary shape and
nothing more:

    // compat.sync
    pub const Mutex = struct {
        pub fn lock(self: *Mutex) void;
        pub fn unlock(self: *Mutex) void;
        pub fn tryLock(self: *Mutex) bool;
    };

    // compat.time
    pub fn sleep(nanoseconds: u64) void;

The `sleep` signature mirrors the displaced `std.Thread.sleep` nanosecond
argument so the fourteen call sites change only the call name. If a typed
duration is preferred at the boundary, that is a refinement the operator may
direct; it does not change the principle.

### 4. Module layout

The two modules live under `shared/src/compat/`, alongside the existing
`compat.args`, `compat.io`, and `compat.fs`, and are re-exported by the
`shared/src/compat.zig` aggregator:

    tool / data structure (ring, queue, stream, clock)
              |                          |
        compat.sync.Mutex          compat.time.sleep
              |                          |
        std.atomic (today)         posix sleep (today, via the posix surface)

Thread lifecycle is not part of the boundary. `std.Thread.spawn` and `join`
survive 0.16 unchanged and are not `Io`-coupled, so Awase continues to use them
directly. The boundary governs synchronization and timing, not thread creation.

### 5. Scope of the boundary

The boundary is deliberately narrow. It covers only the synchronization and
timing primitives current call sites require: a mutex and a sleep. As a standing
growth policy, the boundary begins with the minimum surface that existing
consumers require and expands only when a concrete call site demands it, never
speculatively. A condition variable is a case in point: no file in the tree uses
`std.Thread.Condition` today, so none is included, and one is added to
`compat.sync` only if a real consumer later introduces the need. It is not a
runtime layer, a thread pool, a scheduler, or an async framework, and it does not
attempt to reproduce the scheduling and cancellation facilities that motivate
`std.Io`'s own concurrency primitives. Stable std facilities continue to be used
directly. The goal is not to replace Zig's runtime; it is to prevent `Io` from
becoming a transitive dependency of every locked or timed data structure in the
tree.

### 6. Relationship to shared 0001 and AD-6

This ADR is a sibling instance of the boundary principle, not a replacement for
any prior decision. Shared 0001 remains the general statement of the principle
and governs the filesystem, console, args, and socket surfaces. AD-6 and
`posix_safe` remain the owner of the raw posix syscall surface, and
`compat.time`'s sleep backing is expected to route through that surface rather
than introduce a second posix entry point. The reasoning chain is preserved and
extended: AD-6, then `posix_safe`, then shared 0001 for shape volatility, then
this ADR for the case where the volatile replacement would invert the dependency
direction by pulling I/O underneath synchronization.

## Consequences

The intended effect is that `Io` stays confined to actual I/O. Files and sockets
reach `std.Io` through the 0001 boundary; locks and timers do not touch it at
all. Synchronization and timing become independent of the I/O context, the
backing implementation can change without caller churn, and `shared/src/clock.zig`
and audiofs consume one already-established boundary instead of each absorbing
the concurrency churn separately.

The trade-off is explicit. An owned mutex, atomic-backed, does not integrate with
a future `Io` scheduler's blocking, cancellation, or green-thread yielding the
way `std.Io.Mutex` is designed to. This is acceptable for the short
critical-section locks the tree actually has (ring buffers, event queues, the
clock reader), where contention is brief and a lock does not need to yield to a
scheduler. If a future site genuinely needs a lock that yields under contention
because it is held across a long or blocking operation, that specific site may use
`std.Io.Mutex` directly with a recorded justification. The boundary governs the
general case; it is not an absolute prohibition. `compat.time.sleep` is likewise a
blocking sleep suited to poll loops and backoff, not a scheduler yield point.

Outside the `compat.sync` and `compat.time` backing, Awase code does not
reference `std.Io.Mutex`, `std.Io.sleep`, `std.Thread.Mutex`, `std.Thread.sleep`,
or `std.Thread.Condition`.

## Record-keeping and closure

The per-file before and after detail and the port status remain in the working
notebook (`docs/ZIG_016_MIGRATION.md`), which gains the concurrency and timing
surface alongside the existing class inventory and a reference to this ADR. This
ADR does not restate individual call-site changes.

Closure criteria:

1. This ADR is ratified, and `compat.sync` and `compat.time` land behind it.
2. All current `Mutex` consumers (four files) and `sleep` consumers (fourteen
   files) are migrated to `compat.sync` and `compat.time`. No
   `std.Thread.Condition` consumer exists in the tree, so none is in scope; one
   is added to `compat.sync` only if a later consumer introduces the need, under
   the growth policy in Decision 5.
3. chronofs builds and benches green under the vendored 0.16.0 toolchain, proving
   `compat.sync` and `compat.time` in a real subproject. `shared/src/clock.zig`
   then converts under the same boundary, after which audiofs consumes it, so the
   concurrency surface is solved once rather than per subsystem.
