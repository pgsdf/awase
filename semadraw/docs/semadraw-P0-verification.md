# Semadraw Phase 0 verification artifact: post-wiring compat map

Status: Generated from semadraw/build.zig after the Phase 0 wiring pass,
parsed from the file (not hand-written) so the record cannot drift from the
source. Date: 2026-06-15.

## What this pass added (16 wiring points)

Modules newly wiring compat (named import in their createModule):
    events_mod
    ipc_socket_mod
    ipc_tcp_mod
    software_mod
    drm_backend_mod
    drawfs_backend_mod
    backend_process_mod
    frame_scheduler_mod
    compositor_mod
    client_connection_mod
    client_remote_mod

Bare modules newly wiring compat (addImport after definition):
    ipc_shm_mod
    term_pty_mod
    semadraw_mod

Targets newly wiring compat:
    sdcs_test_malformed   (exe; fs.cwd surface)
    client_connection_tests (test target; closes the D1 connection.zig gap)

## Already wiring compat before this pass (unchanged, for completeness)

Exe/lib targets: semadrawd, gesture_inspect, idle_probe, semadraw_term,
semadraw_demo, sdcs_dump, sdcs_replay, sdcs_fuzz, and the 26 sdcs_make_* tools.

## Deliberately NOT wired (and why)

- lib, client_lib, hello: their root closures carry no compat surface, or
  (hello) only semadraw which is itself wired. No compat-routed code reaches
  them. If the census were wrong, the bench would show it; it does not.
- inputfs_input.zig: close/kqueue/kevent/*Absolute route to posix.system
  (raw libc), which needs no compat import.
- The 12 already-green shared/semainput dependency modules.

## Bench expectation for Phase 0 (narrow by design)

No source file changed in this pass, so the tree still does NOT build: it
still carries the full removed surface from the D2 census. The ONLY thing this
phase proves is module resolution. Pass condition:

    zig build      -> fails on removed APIs (fs.cwd, time, sockets, ...),
                      NOT on 'no module named compat'
    zig build test -> same: removed-surface errors, no module-resolution errors

If any 'no module named compat' error appears, a consumer file imports compat
whose module this pass missed; that is a wiring bug to fix before conversion.
If a removed-surface error appears, that is expected and is conversion work for
Phases 1-5, not a Phase 0 failure.

## Structural checks (sandbox, pre-bench)

    zig ast-check build.zig : clean
    brace balance           : 252 open / 252 close
    wiring points added     : 16 (verified each landed in its intended module)