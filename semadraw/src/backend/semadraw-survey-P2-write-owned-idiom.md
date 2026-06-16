# semadraw P2 survey: write owned-idiom class (raw fd-ops)

Status: survey complete, awaiting ratification. No code applied. Baseline
re-based; T2/T3 confirmed present.

This is the next P2 class after sockets (T1) and time/Thread (T2/T3): the
raw file-descriptor operations that Zig 0.16 removed from std.posix, which
get file-local owned idioms following the socket_server/connection.zig
precedent (closeFd, writeOnce already live in socket_server).

## 1. Removed fd-op set (verified against vendored 0.16)

Removed from std.posix: write, pwrite, writev, close, open, lseek,
ftruncate, mkdir, mkdirat, fchmodat, pread, unlink, unlinkat, rename.

Survive (no action): openat, openatZ, read (24 sites), setsockopt, errno,
toPosixPath, AT (incl AT.FDCWD), and all types/constants.

Of the removed set, only five appear in semadraw: write, close, open,
ftruncate, fchmodat. No lseek/mkdir/unlink/rename/pwrite/writev sites
exist, so the class is bounded to those five (plus two adjacent items in
section 4).

## 2. Census (semadraw)

| fn | daemon closure | standalone track | idiom |
|---|---|---|---|
| close | 36 | 6 | closeFd helper |
| write | 5 | 9 | writeAll helper |
| open | 7 | 1 | openat drop-in |
| ftruncate | 1 | 0 | ftruncateFd helper |
| fchmodat | 1 | 0 | system.fchmodat + pathZ |

Daemon-closure total: 50 sites. Per file:

- ipc: shm (close 4, ftruncate 1), surface_registry (close 1),
  socket_server (fchmodat 1, the T1 straggler).
- backend: process (write 4, close 11), drawfs (write 1, close 2, open 1),
  drm (close 2, open 1), bsdinput (close 6, open 4), evdev (close 2,
  open 1), inputfs_input (close 3, via std.posix.close).
- daemon: semadrawd (close 2), events (close 2).

Standalone track (deferred, 16 sites): tools/idle_probe (write 3),
tools/gesture_inspect (write 3), apps/term/pty (write 1, close 4, open 1),
client/remote_connection (write 2, close 2).

## 3. Idiom per fn (file-local, duplicated per file, precedent-aligned)

1. close -> file-local closeFd (already in socket_server):
   ```zig
   fn closeFd(fd: posix.fd_t) void { _ = posix.system.close(fd); }
   ```
   `posix.close(fd);` -> `closeFd(fd);`; `defer/errdefer posix.close(fd)`
   -> `defer/errdefer closeFd(fd)`. inputfs_input's `std.posix.close` ->
   `closeFd`. This is the bulk (36 daemon sites) and is purely mechanical.

2. write -> file-local writeAll over system.write (extends the socket_server
   writeOnce precedent to loop to completion):
   ```zig
   fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
       var off: usize = 0;
       while (off < bytes.len) {
           const rc = posix.system.write(fd, bytes[off..].ptr, bytes.len - off);
           if (rc < 0) {
               if (posix.errno(rc) == .AGAIN) continue;
               return error.WriteFailed;
           }
           off += @intCast(rc);
       }
   }
   ```
   `try posix.write(fd, buf)` -> `try writeAll(fd, buf)`. drawfs already has
   a manual partial loop; it folds into the helper. (All 5 daemon write
   sites; the 9 standalone ones follow on the standalone track.)

3. open -> direct openat drop-in (no helper). openat survives with an
   identical signature `(dir_fd, path, flags: O, mode: mode_t) OpenError!fd_t`:
   ```zig
   posix.open(path, flags, mode)  ->  posix.openat(posix.AT.FDCWD, path, flags, mode)
   ```
   Same error set, same O flags struct, same mode_t, same fd_t return, so
   `catch` sites are unchanged. See the class boundary in section 4.

4. ftruncate -> file-local ftruncateFd over system.ftruncate (1 site, shm):
   ```zig
   fn ftruncateFd(fd: posix.fd_t, len: i64) !void {
       if (posix.system.ftruncate(fd, len) != 0) return error.Truncate;
   }
   ```

5. fchmodat -> owned idiom over system.fchmodat (1 site, socket_server).
   Raw fchmodat takes a sentinel path `[*:0]const u8`, so convert via
   posix.toPosixPath:
   ```zig
   var pathz = try posix.toPosixPath(path);
   _ = posix.system.fchmodat(posix.AT.FDCWD, &pathz, 0o660, 0);
   ```

## 4. Class boundaries

- posix.read SURVIVES (24 sites) and is NOT part of this class. No action.
- The open sites are DEVICE fd opens: /dev/sysmouse, the DRM and drawfs
  device nodes, evdev nodes, the pty slave. openat keeps them as raw fds,
  which is correct. They deliberately do NOT route through compat.fs; that
  is P3 (regular-file std.Io). Device fd opens stay in P2 via openat. This
  is a real boundary, not an oversight.
- Two adjacent raw-fd items live in the same files and are worth folding in
  so those files close the raw-fd class completely:
  - posix.pipe is REMOVED (events:426, process:38, process:44). Raw
    `posix.system.pipe(&fds) c_int` is available, so a small `pipeFds()`
    owned idiom fits the same family. Recommend folding into the write
    class; it unblocks process and events.
  - posix.memfd_create SURVIVES but its flags changed from a struct to a
    u32 (shm:133). One-line fix: `.{ .CLOEXEC = true }` -> `posix.MFD.CLOEXEC`.
    A flags-encoding micro-class, but trivial; recommend folding into shm's
    tranche.
  - Folding these clears the shm:133 and events:426 reds noted during
    T2/T3.

## 5. Recommended tranche split

Per-file within leaf-to-daemon tiers, so each file gets its file-local
helpers added once and closes the whole raw-fd class in a single pass
(ownership boundary, not fn boundary):

- WT1 (ipc leaf, ~8 sites): shm (close 4, ftruncate 1, memfd_create 1),
  surface_registry (close 1), socket_server (fchmodat 1). Establishes
  closeFd reuse, ftruncateFd, the fchmodat idiom, and the memfd fix.
- WT2 (backends, ~40 sites). Large; recommend sub-splitting:
  - WT2a: process (write 4, close 11, pipe 2), drawfs (write 1, close 2,
    open 1). The writers plus pipe; establishes writeAll.
  - WT2b: drm (close 2, open 1), bsdinput (close 6, open 4), evdev
    (close 2, open 1), inputfs_input (close 3). close + openat only.
- WT3 (daemon, ~5 sites): semadrawd (close 2), events (close 2, pipe 1).
- Standalone track (deferred): tools, apps/term, client write/close/open.

Alternative: a single by-fn close sweep (36 sites) first, then write/open/
ftruncate/fchmodat. Cleaner per-idiom but touches most files twice.

## 6. Open questions for ratification

Q1. open -> openat(AT.FDCWD) direct drop-in for the device opens (vs a
    raw system.open idiom or compat.fs). Recommend openat.
Q2. Fold in pipe (system.pipe owned idiom) and memfd_create (u32 flags) so
    shm, process, and events fully close the raw-fd class. Recommend fold.
Q3. File-local helpers closeFd / writeAll / ftruncateFd duplicated per file
    per the migration discipline. Recommend yes.
Q4. Tranche granularity: WT1, WT2a, WT2b, WT3 per-file/tier. Recommend yes.
Q5. fchmodat now (WT1) via system.fchmodat + toPosixPath, closing the last
    socket_server straggler, vs deferring further. Recommend now.

## 7. Exit criterion

Each WT exits when its files' write-class sites are converted and the
existing test/regression checks stay green. Files remain red on later
classes (P3 filesystem, P4 std.Io/kqueue, P5 SCM_RIGHTS) per the standing
class-boundary discipline; that is not a regression.
