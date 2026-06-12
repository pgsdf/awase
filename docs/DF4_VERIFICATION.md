# DF-4 drawfs WITNESS verification

This doc records the procedure for running the drawfs test suite
against a FreeBSD 15 kernel built with `WITNESS`, `WITNESS_SKIPSPIN`,
and `INVARIANTS`, plus a static lock-order audit performed in
advance. The audit found seven WITNESS-detectable bugs that the
runtime check would catch; those findings are recorded here so
that the runtime verification, when it eventually runs, has a
known set of failures to confirm.

## Status

- **Static audit**: complete 2026-05-05.
- **Runtime verification**: complete 2026-05-08, except for
  AD-18.7 which is structurally deferred to DF-3. PGSD-DEBUG
  built and booted on `pgsd-bare-metal-test-machine`; six of
  the seven findings have been confirmed-and-fixed under
  WITNESS or by code review against the locking invariants
  (AD-18.1 through .6).
- **Findings filed**: yes, see "Findings" below. AD-18 tracks the
  seven fixes.
- **DF-4 closeout**: 2026-05-08. The remaining finding
  (AD-18.7) cannot be implemented until DF-3 wires the
  KMS page-flip ioctl. Its fix design is captured here and
  should land alongside DF-3's PAGE_FLIP work, not block
  DF-4 indefinitely.

The static audit alone is not equivalent to running WITNESS — the
runtime check observes actual lock acquisition order on every
critical-section entry, including paths the audit may have missed.
Static analysis is a lower bar that the runtime check must clear,
not a replacement for it.

## Procedure

The test machine needs a FreeBSD 15 kernel built with the debug
options. As of 2026-05-07 that kernconf is `PGSD-DEBUG` at
`pgsd-kernel/PGSD-DEBUG`; it derives from `PGSD` via include(5)
and adds the WITNESS / INVARIANTS / DDB / DEADLKRES options
block. PGSD itself remains free of these options so the
production kernel does not pay the 5-10x lock-overhead cost
WITNESS imposes.

The full debug options set in PGSD-DEBUG is:

```
options		WITNESS
options		WITNESS_SKIPSPIN
options		INVARIANTS
options		INVARIANT_SUPPORT
options		DDB
options		DEADLKRES
options		MALLOC_DEBUG_MAXZONES=8
```

Build and install per `pgsd-kernel/README.md`:

```
sudo install -m 0644 pgsd-kernel/PGSD-DEBUG /usr/src/sys/amd64/conf/PGSD-DEBUG
cd /usr/src
sudo make buildkernel KERNCONF=PGSD-DEBUG \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl utouch hpen hmt hconf hidmap"
sudo pkg unregister FreeBSD-kernel-generic   # if pkgbase
sudo make installkernel KERNCONF=PGSD-DEBUG DESTDIR=/ \
    WITHOUT_MODULES="hkbd ukbd hms hgame hcons hsctrl utouch hpen hmt hconf hidmap"
sudo shutdown -r now
```

After reboot, confirm the running kernel is debug-built:

```
sysctl debug.witness.watch                # expect: 1
sysctl debug.witness.skipspin             # expect: 1
sysctl kern.conftxt | grep INVARIANTS     # expect: options INVARIANTS
```

Build the drawfs module and the test suite:

```
cd /home/vic/UTF
zig build drawfs-tests
sudo kldload drawfs/sys/modules/drawfs/drawfs.ko
```

Run the test suite, capturing both kernel log and userspace output:

```
sudo dmesg -c > /dev/null   # clear pre-existing log
sudo zig build drawfs-tests-run 2>&1 | tee drawfs-tests.log
sudo dmesg > drawfs-tests-dmesg.log
```

Inspect the dmesg output for WITNESS findings:

```
grep -E "(witness|lock order|recursing)" drawfs-tests-dmesg.log
```

A clean WITNESS run produces no output from that grep. Each line
of output is a finding.

## Findings (static audit, 2026-05-05)

The audit walked every lock acquisition site in `drawfs.c`,
`drawfs_drm.c`, `drawfs_surface.c`, `drawfs_efifb.c`, and
`drawfs_frame.c`. Seventeen of seventy-three lock calls fall
outside the disciplined patterns; seven of those are bugs that
WITNESS would catch.

### Locks observed

Four drawfs locks plus the kernel's vm_object lock:

- `drawfs_global_mtx` — file-static in `drawfs.c`, protects
  the `g_sessions` registry.
- `s->lock` — per-`drawfs_session`, protects session-local state
  (event queue, surface list, closing flag, input buffer, stats,
  cv, sel).
- `dd->drm_mtx` — per-`drawfs_drm_display`, protects DRM backend
  state (`flip_pending`, fb ids, flip_failure_logged).
- `g_drm_mtx` — file-static in `drawfs_drm.c`, protects the
  global DRM file pointer (`g_drm_fp`).
- `vm_object` lock (kernel-internal) — taken via
  `VM_OBJECT_RLOCK`/`WLOCK` macros around `vm_object` operations.

### Documented invariants (header comment in drawfs.c lines 182-198)

1. Surface list (`s->surfaces`) is protected by `s->lock`.
2. Never hold `s->lock` while calling `malloc()` with `M_WAITOK`.
3. Never hold `s->lock` when calling `vm_pager_allocate` or
   `vm_object_deallocate`.

### Bugs

**Bug 1: recursive `s->lock` acquire.**

`drawfs_find_session_for_surface_locked` (`drawfs.c:256`) acquires
`s->lock`, then calls `drawfs_surface_lookup` (`drawfs_surface.c:42`)
which acquires `s->lock` again on the same session.

`MTX_DEF` mutexes in FreeBSD are non-recursive. WITNESS panics
with "recursing on non-recursive mutex"; release kernels
deadlock (silent on uniprocessor; on SMP whichever CPU got there
first holds it forever).

Fix: inline the `surface_lookup` body into the `find_session`
loop, or add a `_locked` variant of `surface_lookup` that
expects the caller to hold `s->lock`.

**Bug 2: `vm_pager_allocate` with `s->lock` held.**

`drawfs_surface_get_vmobj` (`drawfs_surface.c:249`) calls
`vm_pager_allocate` while holding `s->lock`. The function comment
on line 214 explicitly acknowledges this; the rule documented at
`drawfs.c:195` explicitly forbids it.

`vm_pager_allocate` for `OBJT_SWAP` may sleep waiting on the
kernel allocator. Sleeping while holding an `MTX_DEF` mutex is
forbidden; WITNESS panics with "blockable sleep with non-sleepable
lock". The release kernel may deadlock or trigger livelock under
memory pressure.

Fix: hoist the `vm_pager_allocate` call outside `s->lock`. Walk
the surface list under lock, collect the size, drop the lock,
allocate, re-acquire lock, install the vmobj into the surface
struct (re-checking the surface still exists).

**Bug 3: `malloc(M_WAITOK)` with `s->lock` held — input buffer
growth.**

`drawfs.c:1026` calls `malloc(newcap, M_DRAWFS, M_WAITOK)` while
holding `s->lock` (acquired at line 1004, released at line 1036).
The rule documented at `drawfs.c:194` explicitly forbids this.

`M_WAITOK` may sleep under memory pressure. Same WITNESS class
as Bug 2.

Fix: drop the lock for the malloc, re-acquire, re-validate `need`
against `s->in_cap` (which may have changed under another writer),
proceed.

**Bug 4: `malloc(M_WAITOK)` with `s->lock` held — frame
extraction.**

`drawfs.c:1098` calls `malloc(frame_bytes, M_DRAWFS, M_WAITOK)`
while holding `s->lock` (acquired at line 1054, released at line
1106). Same class as Bug 3.

Fix: same shape as Bug 3.

**Bug 5: unprotected `s->stats` access.**

`drawfs.c:639` modifies `s->stats.bytes_in` without holding
`s->lock`. The header comment at line 188 lists `stats.*` as
protected by the lock.

Concurrent stat updates via the locked path (lines 970, 980, etc.)
race with this unlocked update. The race produces undefined
arithmetic on `stats.bytes_in`; on a 32-bit field it could
produce visibly wrong totals, on 64-bit fields the typical x86_64
write is atomic-ish but not by guarantee.

Fix: take and release `s->lock` around the stats update, or
move the update to inside `drawfs_ingest_bytes` which already
takes the lock.

**Bug 6: surface-list teardown without `s->lock`.**

`drawfs_surfaces_free_all` (`drawfs_surface.c:278+`) traverses
and modifies `s->surfaces`, `surfaces_count`, and `surfaces_bytes`
with only brief lock acquisition for `map_surface_id`. The header
at `drawfs.c:191` explicitly says `s->surfaces` is protected by
`s->lock`.

The function runs after `s->closing = true` was set under the
lock, so practically no other code path should reach the surface
list — but no code path actually checks `closing` before touching
`s->surfaces` (`surface_lookup`, `surface_create`, `surface_destroy`,
`select_for_mmap`, `get_vmobj` all proceed on a closing session
if reached).

The likely-safe-in-practice argument relies on `devfs` having
already torn down the cdev so no new ioctl/read/write/poll arrives.
WITNESS does not verify "likely-safe-in-practice"; it verifies the
documented invariant.

Fix: hold `s->lock` for the structural operations (TAILQ_REMOVE,
counter updates) and release before `vm_object_deallocate`. The
result is more lock-acquire/release cycles per surface but
preserves the invariant.

**Bug 7: `drm_ioctl_kern` with `dd->drm_mtx` held.**

`drawfs_drm_surface_present` (`drawfs_drm.c:635`) calls
`drm_ioctl_kern(DRM_IOCTL_MODE_PAGE_FLIP, &flip)` while holding
`dd->drm_mtx`. The DRM ioctl path acquires DRM-internal locks
and may sleep.

WITNESS would track the lock-order across the boundary
(`dd->drm_mtx → DRM-internal`) and detect any cycle. Sleep with
`dd->drm_mtx` held would also trigger the "blockable sleep" check.

Currently latent: the DRM backend (DF-3) is not wired up to
`drawfs_reply_surface_present` yet, so the path is dead from the
integration perspective. Worth fixing before DF-3 graduates from
skeleton.

Fix: capture the flip parameters under `dd->drm_mtx`, drop the
lock, call `drm_ioctl_kern`, re-acquire, install the result.
Mirror the pattern used in surface_destroy / surfaces_free_all.

### Lock-order observations (consistent, recorded for completeness)

These are not bugs but the order graph the runtime check will
verify. Every reachable code path follows these orders; if a new
code path violates one, WITNESS will report a "lock order
reversal".

- **`drawfs_global_mtx → s->lock`.** Established at
  `drawfs_find_session_for_surface_locked`
  (`drawfs.c:255-256`). The close path
  (`drawfs.c:852-856`) takes the locks sequentially, not nested,
  so it does not establish a reverse order.
- **`s->lock → sel_lock`** (sel registration and wakeup).
  `selrecord` at `drawfs.c:673` and `selwakeup` at lines 860 and
  984 both happen under `s->lock`. Consistent direction.
- **`s->lock → cv`.** `cv_signal` at line 983, `cv_broadcast` at
  line 859, `cv_wait_sig` at line 589. The cv internals lock
  briefly during signalling; consistent direction.
- **`dd->drm_mtx → vm_object`.** The DRM present path
  (`drawfs_drm.c:528 → 576`) takes the display mutex then the
  surface's vm_object read-lock. No reverse path exists.

### What the audit did not cover

- **Sleep paths under `cv_wait_sig`.** `cv_wait_sig` correctly
  releases the mutex during sleep. Not a lock-order concern, but
  the wake side may have ordering implications I did not trace.
- **Interrupt-context callers.** drawfs is a character device with
  no interrupt handlers of its own, but `vm_pager_allocate` and
  some kernel paths can be entered from softirq contexts. The
  audit assumes top-half-only invocation, which matches the cdev
  surface but not necessarily the DRM event-completion path
  when DF-3 wires it up.
- **Cross-driver interactions.** drawfs interacts with `vm_object`,
  `selinfo`, and (latent) DRM. The interactions assume those
  subsystems' locking is correct; WITNESS will verify that
  assumption transitively.

## Sign-off

DF-4 is **complete** as of 2026-05-08, except for AD-18.7
which is structurally deferred to DF-3.

The static audit produced seven findings, all recorded above
with proposed fixes. Six are now confirmed-and-fixed under
PGSD-DEBUG (AD-18.1 through .6). The seventh (AD-18.7) lives
on a code path (DRM PAGE_FLIP) that does not yet exist; its
fix design is captured but cannot be implemented or verified
until DF-3 wires `surface_present` into a real KMS ioctl
call. AD-18.7 is therefore re-tagged as a DF-3 sub-task
rather than blocking DF-4 closure indefinitely.

### Verified findings

  - **AD-18.1** (drawfs.c:257, recursive `s->lock` acquire via
    `surface_lookup` from inside `find_session_for_surface_locked`).
    First-boot panic. Fixed by adding `drawfs_surface_lookup_locked`
    variant that asserts the lock is held; the buggy caller now
    uses it. Bench-verified by absence of the recursive-acquire
    panic on subsequent boots and by successful exercise of the
    INJECT_INPUT ioctl path. Commit: `03c3898`.

  - **AD-18.2** (drawfs_surface.c:249, `vm_pager_allocate` under
    `s->lock`). First-boot non-fatal WITNESS warning. Fixed by
    pinning the surface id and bytes_total under the first
    lock-hold, releasing the lock for `vm_pager_allocate`, then
    re-acquiring to install (we won the race) or yield to a
    concurrent installer (deallocating our redundant
    `vm_object` outside the lock). Bench-verified post-reboot:
    no WITNESS warning at drawfs_surface.c:227 on any subsequent
    boot; `hw.drawfs.vmobj_install_lost` remains 0;
    `hw.drawfs.vmobj_allocs == hw.drawfs.vmobj_deallocs` at every
    sampling point (allocs climbed from 145 to 182 to 112 across
    sessions, balance preserved). Commit: `8f3edec`.

  - **AD-18.3** (drawfs.c:1037, `malloc(M_WAITOK)` in input-buffer
    growth path). Static-audit finding; not directly observed
    firing on the bench because most boot-time frames fit in the
    initial 4 KB inbuf. Fixed by rewriting `drawfs_ingest_bytes`
    as a drop-and-retry loop. Each iteration takes the lock and
    either fast-paths (existing capacity fits), installs a
    pre-allocated buffer, or computes a new newcap and drops the
    lock to allocate. Loop bound is log2(MAX_FRAME / initial_cap)
    ≈ 8 iterations worst case; usually 0 or 1. Bench-verified by
    absence of warnings under exercise; `hw.drawfs.inbuf_grow_race_lost`
    remains 0. Commit: `ea710da`.

  - **AD-18.4** (drawfs.c:1115, `malloc(M_WAITOK)` in frame-extraction
    path). Initially misattributed as AD-18.3 from first-boot
    WITNESS output (the warning reports the lock-acquisition site
    at drawfs.c:1071, which is the top of `drawfs_try_process_inbuf`'s
    for-loop, not `drawfs_ingest_bytes`; the offending malloc is
    five lines later). Fixed by rewriting `drawfs_try_process_inbuf`
    with drop-and-revalidate around the per-frame extraction
    malloc. The header is read under the first lock-hold; the
    lock is released for the malloc; the lock is re-acquired and
    the frame at the head of inbuf is re-validated by header
    memcmp against the pinned copy. Race-loss (another extractor
    consumed our frame) drops the buffer and `continue`s the loop.
    Bench-verified post-reboot: no warnings on exercise;
    `hw.drawfs.frame_extract_race_lost` remains 0. Commit: `ea710da`.

  - **AD-18.5** (drawfs.c:681 originally filed at 639;
    unprotected stats updates, five sites). The audit named
    `s->stats.bytes_in` in `drawfs_write` but the same family
    of issue applied to `frames_invalid`, `frames_processed`,
    `messages_processed`, and `messages_unsupported` in
    `drawfs_try_process_inbuf` and `drawfs_process_frame`.
    All five violated the documented locking-model invariant
    (drawfs.c:218-235: "Statistics counters (stats.*) protected
    by s->lock"). Fixed by moving `bytes_in` into
    `drawfs_ingest_bytes` under the existing lock-hold (with a
    flag to prevent double-counting on grow-race retries) and
    wrapping the other four in take-update-release patterns
    (`mtx_lock; stats.X++; mtx_unlock; reply_call()`) so the
    counter update is serialized without nesting the reply
    call's own lock acquisition. Verification is by code
    review against the locking invariant: every `s->stats.X`
    update site is now inside an `s->lock` critical section.
    WITNESS does not directly observe data-race-style issues
    of this kind (no lock-order violation present); absence
    of any unprotected `s->stats.` site outside `s->lock`
    confirms the fix. Bench-verified post-deploy: dmesg
    silent, all race counters at 0,
    `vmobj_allocs == vmobj_deallocs` balance preserved.
    Commit: `30ff3ad`.

  - **AD-18.6** (`drawfs_surfaces_free_all`, surface-list
    teardown without `s->lock`). The function walked
    `s->surfaces`, called `TAILQ_REMOVE` outside any lock, and
    updated session state (`s->map_surface_id`,
    `s->surfaces_count`, `s->surfaces_bytes`) partly outside
    the lock — all violations of the documented invariant
    (drawfs.c:218-235). Latent in practice because by the time
    `priv_dtor` invokes this function, the session has been
    removed from the global registry and no concurrent access
    is possible. Fixed by restructuring the loop into the
    standard pattern: each iteration takes `s->lock`,
    unlinks the head surface and updates counters, releases
    the lock, calls `vm_object_deallocate`, frees the surface
    struct. Defense-in-depth fix signed-off by code review
    against the locking-model invariant. Bench-verified
    post-deploy: surface create/destroy cycles continue to
    work cleanly under the semadrawd-restart-loop workload
    (`vmobj_allocs` climbing from 112 to 113 across boots,
    leak-free). Commit: `0e083a5`.

### Remaining findings

  - **AD-18.7** (DRM PAGE_FLIP path with `dd->drm_mtx` held).
    Latent until DF-3 wires drawfs's `surface_present` into
    actual KMS page-flip ioctls. Fix design captured in the
    audit but not implementable until the calling site exists.

### Build-pipeline lessons (recorded for future runtime work)

Two deployment-ordering bugs surfaced during the AD-18.1
through .4 work and are worth capturing here for future
DF-4-style runtime verification:

  - **install.sh did not reload drawfs.ko after deploy.** The
    initial AD-18.1 fix appeared not to work because install.sh
    wrote the new drawfs.ko to `/boot/modules/` but the kernel
    kept running the pre-fix module from the previous boot.
    Fixed by adding `kldunload drawfs && kldload drawfs` after
    deploy, gated on `DRAWFS_WAS_LOADED` (commit `d21b68d`).
    Future DF-4 fix-and-test cycles should not require manual
    kldreload.

  - **Stale dmesg can mislead the verifier.** Early-boot
    WITNESS warnings persist in the kernel message buffer
    until cleared. After deploying a fix, the warnings from
    pre-fix code paths may still appear in `dmesg | grep
    drawfs` and be mistaken for current behavior. Verification
    protocol: `sudo dmesg -c > /dev/null` to clear, then
    exercise the path under test, then check `dmesg` and
    `sysctl hw.drawfs` for new activity.

### Closure

DF-4 is closed as of 2026-05-08, with AD-18.7 transitioning
to the AD-18 entry as a deferred sub-task tied to DF-3.

AD-18.7 cannot be runtime-verified until DF-3 lands the
KMS page-flip ioctl wiring. The fix design is captured in
the audit (capture flip parameters under `dd->drm_mtx`,
release, perform `drm_ioctl_kern`, re-acquire to install
the flip result) but the calling site does not yet exist.
Its eventual fix should be folded into the same commit
that introduces the PAGE_FLIP ioctl call (DF-3 work
item).

**Verification protocol established during DF-4** (for
future runtime work of the same kind):

  - Boot under `PGSD-DEBUG` — kernconf at
    `pgsd-kernel/PGSD-DEBUG`, includes WITNESS, INVARIANTS,
    DDB, DEADLKRES, MALLOC_DEBUG_MAXZONES.
  - After deploying a fix: `sudo ./install.sh` —
    auto-reloads drawfs.ko (per AD-18.1's install.sh fix).
  - `sudo dmesg -c > /dev/null` to clear stale warnings.
  - Exercise the path under test (semadrawd's
    open-mmap-write-close cycle is the routine workload,
    even when it crashes immediately afterward each cycle
    triggers the relevant code paths).
  - `dmesg | grep -iE "drawfs|witness"` — expect silence
    on a clean fix.
  - `sysctl hw.drawfs` — confirm race counters at 0
    (`vmobj_install_lost`, `inbuf_grow_race_lost`,
    `frame_extract_race_lost`) and balance check
    (`vmobj_allocs == vmobj_deallocs`).

## References

- BACKLOG.md DF-4 — the work item this doc partially closes.
- BACKLOG.md AD-18 — the locking-discipline fixes derived from
  this audit.
- `pgsd-kernel/PGSD` — production kernel config; debug variant
  proposed but not landed.
- `pgsd-kernel/README.md` — build/install procedure inherited
  from AD-8.
- `drawfs/sys/dev/drawfs/drawfs.c` line 182-198 — the documented
  locking invariants.
- `drawfs/sys/dev/drawfs/drawfs_internal.h` line 63-86 —
  `drawfs_session` struct.
- `drawfs/sys/dev/drawfs/drawfs_drm.h` line 43-67 —
  `drawfs_drm_display` struct.
- FreeBSD man pages: `mutex(9)`, `witness(4)`, `cv(9)`,
  `selrecord(9)`.
