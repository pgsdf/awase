# semasound supervision (F.5.f, ADR 0028)

semasound runs as the system audio daemon under the project's existing
AD-20 s6 supervision architecture: the in-tree service directory
`s6/utf/semasound/` (run, finish, log/run) installs to
`/var/service/utf/semasound/`, supervised by s6-svscan under the
utf-supervisor rc service, with a thin rc.d shim translating
`service semasound <verb>` to s6-svc. The supervision architecture as
a whole is to be re-evaluated deliberately after field experience
(ADR 0028 Decision 1; the predecessor was retired under ADR 0029);
the broker's lifecycle
behavior is supervisor-agnostic.

## Installation

The root installer performs everything:

    sh install.sh

For semasound it: builds and deploys the audiofs kernel module to
/boot/modules (audiofs/build.sh install/build/deploy); builds the
broker and installs semasound, semasound-tone, and semasound-dump to
/usr/local/bin; installs the service directory to
/var/service/utf/semasound/ with the AD-20 flap-protection finish;
creates /var/log/utf/semasound/; installs the audiofs rc.d loader
(PROVIDE: audiofs_loaded, REQUIRE: FILESYSTEMS, never loader.conf)
and the semasound rc.d shim (REQUIRE: utf_supervisor audiofs_loaded);
and enables both in rc.conf (audiofs_enable, semasound_enable).

## Operation

    service semasound start|stop|restart|status   # rc.d thin shim
    s6-svstat /var/service/utf/semasound          # status, directly
    s6-svc -d /var/service/utf/semasound          # stop (SIGTERM, prompt)
    s6-svc -u /var/service/utf/semasound          # start
    semasound-dump                                # surfaces (works on a dead broker)

Logs: `/var/log/utf/semasound/current`, rotated by s6-log (AD-20
retention: 3 archives, ~10 MB each; utf-log-cleanup reclaims on
schedule).

## Maintenance takeover protocol (ADR 0030 Decision 4)

Production supervision owns the machine at rest; maintenance and
bench work borrow it. The s6-first rule, in both directions:

To claim the broker or the audiofs module for bench work, down
the supervised service first and verify, never bare pkill (s6
respawns within seconds and the run script reloads the installed
module behind you):

```
sudo s6-svc -dwd -T 5000 /var/service/utf/semasound
```

Hand it back when done:

```
sudo s6-svc -u /var/service/utf/semasound
```

In the other direction, anything that removes what supervision
owns (the scan tree, the daemon binaries) stops utf-supervisor
first; install.sh's uninstall path does this itself. Tooling
that predates this protocol is brought to it before its next
use, not grandfathered. The failure modes this prevents are
cataloged in `docs/FAILURE_MODES.md` ("Maintenance tooling
fights supervision").

The F.5 verification suites do not need a takeover at all in
production mode: `sudo sh f5prod.sh <suite>.sh` runs a suite
against the supervised broker itself (ADR 0030 Decision 5),
no bench_setup, no service down. Bench mode (running a suite
directly after bench_setup.sh) remains the development path
for testing tree builds before installation.

## Behavior under supervision (ADR 0028)

- Crash or kill: s6-supervise restarts the broker; the AD-20
  flap-protection finish bounds restart storms (fast-crash give-up via
  exit 125; `s6-svc -u` resumes after the operator intervenes). The
  restarted broker recovers the stale socket, reopens the device,
  re-seeds election from the device's resting rate, rewrites static
  surfaces, and restarts publish_seq (the documented runtime-instance
  semantics, ADR 0027).
- Stop is PROMPT, with no drain: active clients receive EOF, the same
  protocol-visible ending a crash gives them. Reconnection is client
  policy; the broker does not promise session resurrection.
- Death and stop are observable through staleness: `state` remains
  readable with a stale `publish_ts` while the broker is down; there
  is deliberately no tombstone (one liveness mechanism, not two).
- Boot order: the audiofs rc.d service loads the module after
  FILESYSTEMS; semasound's run script also loads it defensively to
  cover s6-svscan's auto-spawn racing rc order, with the finish
  bounding any retry loop.
