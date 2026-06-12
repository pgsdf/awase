# FreeBSD Issues Encountered by UTF

This document catalogues issues UTF has encountered with the
underlying FreeBSD kernel, userland, or development tools. Each
entry records the symptom, the localised cause, the diagnostic
evidence, and the current disposition (unresolved, worked-around,
upstreamed, etc.). The intent is to keep institutional memory
about kernel-side behaviours that affect UTF's design, so future
sessions can recognise familiar symptoms and avoid rediscovering
known issues from scratch.

This is a catalogue, not a list of grievances. FreeBSD is the
substrate UTF runs on; issues here are recorded with respect for
the platform and with the assumption that, where the cause is in
FreeBSD, the right long-term answer involves upstreaming a fix.
Where UTF works around an issue, the entry documents the
workaround and its trade-offs.

## Format

Each issue is numbered sequentially and structured as:

```
## Issue #N: short title  (status; date surfaced)

### Symptom
What was observed.

### Localised cause
What is known about why it happens, as specifically as the
evidence supports.

### Diagnostic evidence
The probe sequence or bench cycle that pinned down the cause.

### Disposition
Open / worked-around / upstreamed / fixed.

### UTF's response
How UTF currently deals with this (or plans to).

### Related
ADRs, BACKLOG entries, or other documents.
```

Status values:
- **Open**: known issue, no decision yet about how to address.
- **Worked-around**: UTF has chosen a workaround that bypasses
  the issue; the underlying problem is unresolved.
- **Upstreamed**: a patch has been sent to FreeBSD; tracking the
  upstream's response.
- **Fixed**: resolved either upstream or by a UTF-side change
  that no longer encounters the issue.

---

## Issue #1: tmpfs mmap staleness for non-root group members  (Open; 2026-05-12)

### Symptom

A process running as a non-root system user (specifically
`_semadraw`, uid 1002) that opens a tmpfs-backed file via
`mmap(MAP_SHARED, PROT_READ)` sees the contents of the file
frozen at whatever value was published at mmap-open time. The
file's actual contents continue to update (a kernel kthread
writes to it via `vn_rdwr(IO_SYNC)`), but the mmap'd pages in
the non-root process never reflect those updates.

A process running as root (uid 0) mmap'ing the same file at the
same time sees updates correctly. The same non-root process
calling `read(2)` on the same fd sees fresh content.

Concretely surfaced in semadrawd: its cursor pump reads
inputfs's published pointer state via `mmap` of
`/var/run/sema/input/state`. After privilege drop to
`_semadraw`, the mmap view freezes at the position the pointer
held at mmap-open time. Composite damage detection sees no
position change; cursor never re-renders despite the cursor
moving across the screen.

### Localised cause

Specific to the combination:

  - Tmpfs-backed file (`/var/run/sema/input/state` lives on a
    `tmpfs` mount).
  - Written by a kernel kthread via `vn_rdwr(UIO_WRITE, ...,
    IO_SYNC)`.
  - Mapped by a non-root process via `mmap(NULL, len,
    PROT_READ, MAP_SHARED, fd, 0)`.
  - Mapping process is in the file's owning group (gid 1002,
    file mode 0640).
  - **The write touches the same pages repeatedly.** This last
    condition was identified 2026-05-12 by a probe of the
    event-ring file (`/var/run/sema/input/events`), which is
    written via the same `vn_rdwr(IO_SYNC)` primitive by the
    same kthread and mapped via the same `mmap` primitives,
    but works correctly for non-root mmaps. The two differ in
    two structural ways: the event-ring writes hit different
    page offsets over time (per-slot partial writes into a
    64 KB ring), while the state-region writes always overwrite
    the same pages (whole-buffer rewrites of a ~5 KB region).

Root mmaps of the same state file under the same conditions
see updates correctly. `read(2)` from the same non-root process
on the same fd returns fresh content (the bytes change between
consecutive reads, including the pointer x/y offsets and the
last_seq field). Non-root mmaps of the **event-ring** file
under structurally similar but page-offset-varying writes see
updates correctly.

The mechanism inside the FreeBSD kernel that produces this
asymmetry has not been investigated; the evidence above is what
we have. The current best guess (recorded here but not
verified) is that vm_object_page_clean or its equivalent is
called only on pages touched after the previous sync, and the
state-region's repeated whole-page rewrites of the same pages
somehow fail to mark those pages dirty in a way that
invalidates non-root mmaps. The event ring escapes this because
each write hits a fresh page offset for that write's lifetime.
A definitive root-cause analysis would require reading
FreeBSD's tmpfs and vm_object source carefully; that work is
captured in **AD-34** which stays open as a kernel-side
investigation track.

Tested on:
  - FreeBSD 15.0-RELEASE-p8
  - amd64 hardware (`pgsd-bare-metal-test-machine`)
  - `kern.hz=1000`
  - `_semadraw` user uid=1002 gid=1002, file mode 0640 gid 1002

### Diagnostic evidence

The bench cycle that produced the localisation, on
`pgsd-bare-metal-test-machine` with semadrawd running and
continuous cursor motion for ~10 seconds:

**Probe 1: pump's mmap view (semadrawd, post-privilege-drop)**

39,992 `pump_diagnostic` events captured (AD-34 E1
instrumentation). **1** unique `(ps_x, ps_y)` tuple across all
events: `(461, 273)`. The pump's mmap view of the state region
was frozen for the entire bench window.

**Probe 2: root's mmap view (`sudo inputdump state --watch
--interval-ms 50`)**

Many `=== changed ===` records visible, pointer position
varying across the full framebuffer (x ∈ [1960, 3337],
y ∈ [106, 1641] over ~10s). Root sees live updates via mmap.

**Probe 3: non-root mmap view (`sudo -u _semadraw inputdump
state --watch --interval-ms 50`)**

Initial `=== snapshot ===` block fires, then nothing for
~10 seconds of continuous cursor motion. Same staleness as
the pump. The privilege boundary is reproduced outside
semadrawd.

**Probe 4: non-root `read(2)` view (`sudo -u _semadraw xxd
/var/run/sema/input/state`, taken twice with a cursor move
between)**

First read:
```
00000000: 5453 4e49 0101 2000 e24e 0000 0000 0000  TSNI.. ..N......
00000010: 7127 0000 0000 0000 0000 0000 0000 0000  q'..............
00000020: e909 0000 1b03 0000 0000 0000 0800 0000  ................
```

Second read (after a cursor move):
```
00000000: 5453 4e49 0101 2000 b44f 0000 0000 0000  TSNI.. ..O......
00000010: da27 0000 0000 0000 0000 0000 0000 0000  .'..............
00000020: d20c 0000 ef02 0000 0000 0000 0800 0000  ................
```

Differences at offsets 0x08 (timestamp), 0x10 (last_seq), and
0x20-0x27 (pointer x, pointer y). The same non-root process
sees fresh bytes via `read(2)` while its mmap view stays
frozen.

**Probe 5: non-root mmap view of the *event ring* (`sudo -u
_semadraw inputdump events --watch --interval-ms 50`)**

Captures hundreds of `pointer.motion` events flowing at the
hardware rate (~115 events/sec under cursor motion). Each event
payload includes absolute `x, y` coordinates that vary across
the framebuffer as the cursor moves. **The non-root mmap of
the event-ring file works correctly.**

This probe was run to verify a candidate fix direction
(see ADR 0008 / AD-35). Its result reshaped the
characterisation of the bug: the staleness is not caused by
"tmpfs + mmap + non-root" in general; it is caused by that
combination plus the **specific write pattern of the
state-region kernel writes** (whole-buffer overwrites of the
same pages on each sync). The event ring's per-slot partial
writes at varying offsets do not trigger the bug.

### Disposition

**Worked around (UTF side).** No upstream FreeBSD investigation
has been performed yet, but UTF's affected consumer
(semadrawd's cursor pump) is being migrated to a code path that
avoids the broken access pattern. See **ADR 0008** for the
decision and **AD-36 onward** for the implementation. The
underlying kernel-side question remains open as **AD-34**.

### UTF's response

**ADR 0008 (Accepted, 2026-05-12)** selects Direction 2:
switch semadrawd to consume the inputfs event ring instead
of polling the state region. The event ring exhibits no
staleness for non-root mmaps under the bench conditions that
trigger the bug for the state region; semadrawd can read fresh
absolute pointer coordinates from event payloads at hardware
rate, and the ring's pollable notification also closes the
busy-spin question recorded as AD-32.

Direction 3 (root cursor helper daemon) was rejected because
the privilege boundary turned out not to be the issue; the
access pattern is.

Direction 1 (FreeBSD-side fix) is retained as a kernel-side
investigation track (AD-34); the workaround does not depend on
it landing, and other inputfs consumers may benefit from the
underlying fix if it eventually arrives.

### Related

  - **AD-34**: the investigation entry in `BACKLOG.md` that
    produced this finding. Stays open as a kernel-investigation
    track.
  - **AD-35**: the design-decision entry. Closes when ADR 0008
    lands plus its D3 BACKLOG breakdown.
  - **ADR 0008**: records the design decision (Direction 2,
    event-ring consumption).
  - **AD-25**: the user-visible symptom (cursor motion
    smoothness) that AD-34 was opened to investigate. AD-25
    closes contingent on the AD-36 implementation that ADR
    0008 schedules.
  - **AD-32**: a sibling concern (semadrawd main loop
    busy-spin); ADR 0008's Direction 2 closes this as a side
    effect once AD-37 lands.
  - **ADR 0007**: AD-25's discovery-plan ADR; its second
    addendum documents the bench cycle that surfaced AD-34.
  - **inputfs source**: `inputfs/sys/dev/inputfs/inputfs.c`
    `inputfs_state_sync_to_file` (line 1494) is the
    kernel-side write path.
  - **semadrawd source**: `semadraw/src/daemon/semadrawd.zig`
    `pumpCursorPosition` (line 645) is the affected
    consumer; the `StateReader` it uses is in
    `shared/src/input.zig`.
