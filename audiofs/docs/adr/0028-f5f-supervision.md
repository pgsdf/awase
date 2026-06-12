# 0028 F.5.f: supervision and lifecycle

## Status

Accepted, 2026-06-04 (ratified with one operator reversal of
the proposal: Decision 1 retains s6 as the F.5.f realization
per ADR 0020's explicit scoping, the rc(8)/daemon(8)
alternative being recorded as considered and deferred; the
supervision architecture as a whole is to be evaluated
deliberately in a later phase, after semaaud retirement and
field experience, rather than reinterpreted now as a local
optimization. All other decisions ratified as proposed.)
Closed, 2026-06-04: all ten closure criteria verified on
pgsd-bare-metal and the operator marked F.5.f complete.

Sixth and final sub-milestone of F.5 (semasound), scoped
under ADR 0020. Depends on the functional core F.5.a-d (ADRs
0021, 0024-0026, closed) and the observability layer F.5.e
(ADR 0027, closed). Feeds F.6 (semaaud retirement): this is
the lifecycle work that makes the cutover actionable.

## Context

ADR 0020 scopes F.5.f as: s6 service integration and
fresh-install enablement so semasound runs as the system
audio daemon.

One scoping conflict must be ruled on first. ADR 0020 names
s6, but the parity reference, semaaud's actual deployed
supervision, is an rc(8) script (`scripts/rc.d/semaaud`:
PROVIDE/REQUIRE/KEYWORD headers, rc.conf enablement, a
prestart creating the run directory), and the platform,
FreeBSD and GhostBSD, ships rc(8) as its init with no s6 in
base. Adopting s6 would mean importing a supervision suite
the target systems do not carry, to supervise one daemon
whose predecessor is rc-managed.

What the broker itself lacks today to be supervisable: it
runs foreground with no signal handling (SIGTERM kills it
abruptly mid-syscall), and it has no notion of being
restarted by machinery rather than an operator at a bench.
What it already has: stale-socket recovery (the socket path
is unlinked before bind, so a crashed predecessor does not
block a restart), and the F.5.e liveness signal
(`publish_ts` in `state`), which makes broker death and
staleness externally observable by design.

semaaud's rc shape, for parity: REQUIRE chronofs (its clock
dependency); pidfile under the run directory; prestart
creating the rundir; rc.conf knobs for enable, flags, user.
semasound's analogous startup dependency is the audiofs
kernel module and its device node, not chronofs.

## Decisions

### 1. s6 realizes "service integration" (operator ruling)

F.5.f delivers an s6 service directory in-tree,
`scripts/s6/semasound/`: a `run` script (loads the audiofs
module with `kldload -n audiofs`, creates the run
directories, redirects stderr to stdout, and execs the
broker), a `finish` script (a bounded sleep providing the
restart delay), and a `log/run` (s6-log with built-in
rotation into /var/log/semasound/). The service is managed
by s6-supervise under an s6-svscan scan directory; operator
verbs are `s6-svc -u/-d` and `s6-svstat`. ADR 0020's "s6
service integration" is implemented as written.

Rationale (operator ruling). ADR 0020 explicitly scoped s6,
and the commitment is preserved rather than reinterpreted
before the scoped approach has been exercised. The
rc(8)/daemon(8) alternative was analyzed (platform-native,
parity with semaaud's deployed mechanism, zero imported
infrastructure) and is RECORDED AS CONSIDERED AND DEFERRED:
once semaaud retirement is complete and semasound has field
experience, supervision strategy is to be evaluated as a
whole, deliberately, and a migration to rc/daemon(8), s6
system-wide, or another mechanism decided then. The cost of
carrying s6 for this milestone is manageable (one package,
sysutils/s6, plus its svscan enablement).

Tradeoff. s6 is imported infrastructure on a platform whose
base init is rc(8): fresh-install enablement gains a package
dependency and an svscan bootstrap step (Decision 5). The
lifecycle behavior the broker implements (Decisions 3 and 4)
is supervisor-agnostic by design, so the deferred evaluation
swaps scripts, not broker code.

### 2. Crash supervision: s6-supervise restart-on-exit with a finish delay

s6-supervise restarts the broker on any exit by design; the
`finish` script's bounded sleep (default 2 s) paces restart
storms. The `log/run` s6-log service captures the broker's
output with size-bounded automatic rotation (no newsyslog
integration needed). `s6-svc -d` sends SIGTERM for clean
stop; system shutdown stops svscan, which downs the tree.

Rationale. Restart-on-exit is s6's native semantics, and
restart correctness is already underwritten by prior work:
the stale socket is unlinked at startup, the kernel reclaims
the device fd so the single-open device reopens, GET_FORMAT
seeding handles the lazy rest state's arbitrary resting rate
(ADR 0024), static surfaces are rewritten at startup, and
`publish_seq` restarting with the process is exactly ADR
0027's documented runtime-instance semantics.

Tradeoff. Clients of a crashed broker see EOF/EPIPE and must
reconnect; reconnection is CLIENT policy, deliberately (the
broker does not promise session resurrection, consistent
with the no-migration constraint). A restart also re-elects
from scratch on the next 0-to-1 admission, which is the
designed Stage 2 behavior, not a defect.

### 3. Clean shutdown: prompt, signal-driven, bounded

The broker gains SIGTERM and SIGINT handlers performing
signal-safe immediate teardown: write a one-line shutdown
notice, unlink the socket path, and _exit(0). The process
terminates promptly (well under the 2 s target) regardless
of active clients, whose threads die with the process while
the kernel reclaims every fd. The handler deliberately does
NOT attempt cooperative unwinding: waking a blocked accept
or a blocked device write portably from a handler is exactly
the fragile machinery prompt termination avoids, and
Decision 2's analysis already established that everything a
cooperative path would clean up is crash-safe. No drain: a
stopping audio daemon that lingers to finish songs is a hang
in disguise; active clients receive EOF, which is the same
protocol-visible ending a crash gives them, and a stop verb
must mean stopped.

Rationale. Promptness is the property supervision needs
(rc stop and shutdown(8) both wait on it); everything else
(socket, device, threads) is already crash-safe by Decision
2's analysis, so clean shutdown needs to add only the prompt
exit, not a ceremony.

Tradeoff. In-flight audio is cut. A future graceful-drain
mode (finish the current chunk, fade) would be policy
gold-plating today; recorded as out of scope.

### 4. Stop and death are observable through F.5.e, no tombstone

No "stopped" marker is written. The last-published `state`
remains on disk with a stale `publish_ts`, and staleness IS
the stop/death signal, exactly what the F.5.e liveness
amendment was for; semasound-dump on a dead broker prints
the last state, itself diagnostic. The next start rewrites
the static surfaces and resumes the heartbeat.

Rationale. One liveness mechanism, not two. A tombstone
written on clean stop would make crash and stop look
different to consumers for no operational gain, and would be
a lie after a crash anyway (no one writes it).

### 5. Fresh-install enablement: the tree carries everything needed

Delivered in-tree: `scripts/s6/semasound/` (run, finish,
log/run) and `docs/SUPERVISION.md` documenting installation:
`pkg install s6`, enabling the s6-svscan rc bootstrap the
port provides, installing the binary to
`/usr/local/sbin/semasound`, copying or linking the service
directory into the scan directory, and the operator verbs
(s6-svc, s6-svstat). Log rotation is s6-log's, configured in
log/run; no newsyslog integration. Packaging and GhostBSD
image integration remain F.6 cutover work; F.5.f's bar is
that a fresh system with the tree and the s6 package can be
enabled with documented commands.

### 6. Scope fences

NOT in scope: the deferred supervision-architecture
evaluation (Decision 1); client auto-reconnect (client
policy); graceful drain (Decision 3); a stop tombstone
(Decision 4); packaging (F.6); privilege separation
(semasound_user defaults to root because /dev/audiofs0 and
the kld require it today; a dedicated user plus devfs rules
is recorded as future hardening alongside the ADR 0026
credential-binding note).

## Closure criteria

  1. The service starts under s6 supervision (s6-svscan
     picks up the service directory): s6-svstat reports up,
     the log service captures broker output, surfaces are
     live (publish_seq advancing), a client plays.
  2. The run script works from cold: with audiofs not
     loaded, service start loads it and the broker comes up.
  3. `s6-svc -d` stops the broker within 2 s even with an
     active client streaming (the client sees EOF promptly);
     s6-svstat reports down; `s6-svc -u` brings it back.
  4. SIGTERM directly to the broker exits it cleanly within
     2 s with active clients; the socket path is unlinked;
     s6-supervise restarts it (the finish delay observed).
  5. Crash supervision: kill -9 the broker; s6-supervise
     restarts it after the finish delay; the restarted
     broker serves a new client (stale socket recovered,
     device reopened, election re-seeded via GET_FORMAT);
     publish_seq restarted (the documented runtime-instance
     semantics).
  6. Death observability: while the service is down, `state`
     remains readable with a stale publish_ts; semasound-dump
     prints it.
  7. The full suite set (f5b_election, f5c_targets,
     f5d_policy, f5e_state) passes against an s6-managed
     broker, unchanged.
  8. Ten down/up cycles plus ten kill-9 restart cycles leave
     no socket or surface litter and a working broker;
     fd/RSS of the final broker nominal.
  9. Enablement documentation verified by use: a transcript
     of the documented commands on the bench matches
     SUPERVISION.md, including the s6 package and svscan
     bootstrap steps.
 10. Operator marks F.5.f `[x]`.
     VERIFIED 2026-06-04: operator confirmed satisfaction
     with F.5.f as completed, with criteria 1-8 verified by
     the supervised-bench harness and suite set and criterion
     9 by the two-transcript enablement walk on canonical
     paths including an unattended cold boot.

## References

  - ADR 0020: scope, implemented as written per the operator
    ruling.
  - ADR 0024/0025/0027: the restart-correctness properties
    Decision 2 relies on (lazy rest seeding, stale-socket
    unlink, runtime-instance seq, liveness staleness).
  - semaaud `scripts/rc.d/semaaud`: the predecessor's
    mechanism, part of the recorded rc alternative.
  - s6-supervise(8), s6-svscan(8), s6-svc(8), s6-log(8).

## Revision history

  - 2026-06-04: proposed with rc(8)/daemon(8) as the
    realization.
  - 2026-06-04: operator ruling reverses Decision 1: s6 is
    retained as scoped by ADR 0020, the commitment exercised
    rather than reinterpreted; the rc/daemon analysis is
    recorded as considered and deferred to a deliberate
    whole-of-project supervision evaluation after semaaud
    retirement and field experience. Decisions 2 and 5
    reworked to s6 mechanics (s6-supervise restart with a
    finish-script delay; s6-log rotation; svscan bootstrap
    in enablement); Decision 3's shutdown realized as
    signal-safe immediate teardown (notice, socket unlink,
    _exit), avoiding fragile cooperative-wakeup machinery.
    All other decisions ratified as proposed.
  - 2026-06-04: implementation bench-verified, criteria 1-8
    (f5f_super harness, transient s6-svscan, plus the full
    suite set). Cold start loaded the in-tree module and
    brought the broker up; s6-svstat reported correctly in
    both states; stop via s6-svc -d completed within 2 s with
    an active client streaming; direct SIGTERM exited within
    2 s, unlinked the socket, logged the shutdown notice, and
    s6-supervise restarted after the finish delay; kill -9
    restarted likewise with a new client served and
    publish_seq restarted (the documented runtime-instance
    semantics); while down, state remained readable with a
    stale publish_ts and semasound-dump printed it; ten
    down/up plus ten kill -9 cycles left exactly one socket,
    no litter, and a functional broker (final fd count 12,
    the bench's nominal 11 plus the run script's log
    redirection). Criterion 7: f5b_election, f5c_targets,
    f5d_policy, and f5e_state all passed unchanged against
    the s6-supervised broker, ear checks included. Three
    earlier harness defects were repaired during
    verification (module presence checked by device node
    rather than kldstat -m; the publish_seq comparison given
    an adequate pre-kill window; the dump check capturing
    stderr); one enablement gap found and fixed: the
    documentation now installs audiofs.ko to /boot/modules,
    and the test harness cold-starts the IN-TREE module, the
    bench's truth. Two Zig 0.15 idioms corrected during the
    build (callconv(.c); posix.sigemptyset()). Remaining:
    criterion 9 (the operator's enablement transcript on
    canonical paths) and criterion 10 (operator mark).
  - 2026-06-04: enablement realization corrected during
    criterion 9 preparation, at the operator's direction
    ("have install.sh perform the install"). Discovery: the
    project ALREADY operates a whole-of-project s6
    supervision architecture (AD-20: in-tree services under
    s6/utf/, the /var/service/utf scan tree, utf-supervisor,
    rc.d thin shims, flap-protection finish, s6-log with
    utf-log-cleanup retention), which the operator's Decision
    1 ruling correctly preserved where the rc(8) proposal
    would have diverged from the project's own architecture.
    F.5.f is therefore realized INSIDE that architecture
    rather than beside it: the service directory moved from
    scripts/s6/semasound to s6/utf/semasound in AD-20 style
    (start marker, flap-protection finish superseding the
    bare-sleep restart delay, s6-log to /var/log/utf/
    semasound); install.sh gained semasound end to end
    (audiofs module build/deploy mirroring inputfs, broker
    and tool binaries, service-tree and log-dir enumeration,
    install-time stop, uninstall, rc.conf enablement); rc.d
    thin shims added for audiofs (PROVIDE audiofs_loaded,
    REQUIRE FILESYSTEMS, rc-deferred loading per the inputfs
    /var hazard pattern, never loader.conf) and semasound
    (REQUIRE utf_supervisor audiofs_loaded; deliberately NOT
    providing utf_clock, a capability transfer reserved for
    the F.6 cutover). SUPERVISION.md rewritten accordingly:
    installation is `sh install.sh`. Criterion 9 is restated
    as: the install.sh transcript on the bench matches
    SUPERVISION.md, and the rc verbs operate the supervised
    service. The AD-42.1 semaaud down-marker context is
    noted: install.sh has been defaulting semaaud to
    disabled since snd(4) removal, and semasound now installs
    enabled as the AD-3 successor, staging the F.6 cutover.
  - 2026-06-04: criterion 9 verified by operator transcript on
    canonical paths. Two full install.sh runs (one pre-reboot,
    one post-reboot) showed the audiofs module
    install/build/deploy alongside its siblings, all three
    semasound binaries installed, both rc.d shims installed,
    the service tree and log directory created, rc.conf
    enablement persisted, and idempotency (the semaaud
    down-marker preserved on both runs). The post-reboot run's
    "stopping semasound (was running)" line evidenced the
    unattended cold-boot chain: FILESYSTEMS, the audiofs rc
    service, utf-supervisor, svscan auto-spawn. Operation
    verbs against the boot-started service: the rc shim
    reported up (355 s); a tone client played through the
    canonical socket; semasound-dump printed both targets'
    full surface trees with internally consistent telemetry
    (publish_seq 400 matching uptime, frames_written matching
    at the hardware rate, the tone's reaped event as
    last-event); s6-log captured the broker's reporting at
    /var/log/utf/semasound/current. Remaining: criterion 10
    (operator mark).
  - 2026-06-04: criterion 10 confirmed by the operator;
    F.5.f closed, completing the F.5 sub-milestone set (ADRs
    0021, 0024-0028). semasound is installed, enabled, and
    boot-supervised under the AD-20 architecture while
    semaaud remains present but dormant (semaaud_enable=NO,
    AD-42.1 down marker): the cutover is staged. Remaining
    AD-3 work is F.6 (semaaud retirement): the parity audit
    of the recorded gaps (control plane, session tokens,
    layout prefix), the utf_clock capability ruling
    (deliberately not claimed by semasound in this ADR), and
    the removal itself, with the semainputd reap pattern as
    the upgraded-system template. The deferred
    whole-of-project supervision evaluation follows field
    experience, per Decision 1.
