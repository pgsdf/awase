# Awase supervision tree (s6)

This directory holds the s6 service-directory layout that
`install.sh` copies to `/var/service/utf/` on installation.
Tracks AD-20 in BACKLOG.md.

## Layout

```
awase/
├── .s6-svscan/
│   └── finish         # exits 0 on s6-svscan exit; FreeBSD has
│                        no /bin/true so we don't exec one
├── finish.template    # shared flap-protection template (copied
│                        into each service's ./finish at install)
├── semasound/
│   ├── run            # exec semasound in foreground (AD-3 broker)
│   ├── finish         # copy of finish.template
│   └── log/run        # s6-log writing to /var/log/utf/semasound
└── semadrawd/
    ├── run            # also runs framebuffer detection (AD-15.1/AD-17)
    ├── finish
    └── log/run
```

A `semainputd/` subtree existed in earlier versions of this
directory but was removed 2026-05-08 when the `semainputd` daemon
was retired (AD-2 Phase 3 step 2). The compositor now reads input
directly from the inputfs kernel ring; no input daemon is
supervised. Operator-side cleanup of any stale
`/var/service/utf/semainputd/` directory left from a pre-2026-05-08
install is handled by `install.sh` on the next run.

**Status (F.6, ADR 0029)**: `semaaud` is RETIRED. Its successor
`semasound` is the supervised audio broker (installed enabled;
F.5 complete, ADRs 0021/0024-0028). `install.sh` reaps any stale
`/var/service/utf/semaaud/` directory (with its supervise state,
down marker, log dir, binary, and rc.conf key) from upgraded
systems, the same pattern as the semainputd cleanup above. The
s6 control-surface examples in this document use `semasound` and
`semadrawd`.

## How s6 supervises this tree

A single `s6-svscan /var/service/utf` process is launched by the
`utf-supervisor` rc.d entry. `s6-svscan` spawns one
`s6-supervise` per service directory, which spawns and watches
the corresponding `./run` script. When `./run` exits,
`s6-supervise` invokes `./finish` (the flap detector) and then
either restarts `./run` (default) or marks the service down (if
`./finish` exits 125).

Each service has a `./log` subdirectory; `s6-svscan` notices it
and spawns an `s6-log` process whose stdin is piped from the
parent service's stdout. `s6-log` writes to `/var/log/utf/<name>/`
with 3-file rotation at 1 MB.

## How operators interact

Through the standard rc.d interface, by design (AD-20 chose the
"compose, not replace" approach for operator familiarity):

```
service utf-supervisor start    # bring up s6-svscan
service semasound start          # s6-svc -u /var/service/utf/semasound
service semasound restart        # s6-svc -r ...
service semasound status         # s6-svstat ...
service semasound stop           # s6-svc -d ...
```

The thin rc.d wrappers in `/usr/local/etc/rc.d/` translate to
`s6-svc` commands. Operators can also use `s6-svc`, `s6-svstat`,
or `s6-svscanctl` directly if they prefer.

## Flap protection

`finish.template` (copied into each service's `./finish`)
implements time-windowed flap detection:

- If `./run` exits within 10 seconds of starting, count it as a
  fast crash (timestamp appended to
  `./supervise/awase_crash_log`).
- Crash log entries older than 45 seconds are pruned on each
  `./finish` invocation.
- If 5+ fast crashes accumulate in the window, exit 125 to tell
  s6-supervise not to restart the service.

Tunables (override via environment in the run script):
`FAST_CRASH_LIFETIME_S`, `FAST_CRASH_WINDOW_S`,
`FAST_CRASH_THRESHOLD`.

When operator intervention has resolved the underlying problem,
`service <name> start` (or `s6-svc -u`) brings the service back
up; the crash log clears on the next clean run.

## Notes for editors

- Run scripts must NOT auto-background. s6-supervise tracks the
  pid of the run script's process; backgrounding makes it lose
  track. Always `exec` the daemon.
- Run scripts should be world-readable and executable (mode 755).
- The shared `finish.template` is plain `/bin/sh`, not execline,
  for editor familiarity. The arithmetic for the flap detector
  is clearer in shell.
- Under the AD-15.1 / AD-17 design, `semadrawd/run` performs
  framebuffer-resolution detection via `sysctl hw.drawfs.efifb.*`
  before exec'ing the daemon. This must be preserved if the run
  script is regenerated.
