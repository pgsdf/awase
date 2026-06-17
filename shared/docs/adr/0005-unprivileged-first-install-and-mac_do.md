# shared 0005: Unprivileged-first installation and mac_do elevation model

## Status

Accepted 2026-06-17 (operator).

Implementation lands per its own bench (see Record-keeping and closure). The
kernel-module compilation privilege question (Open questions) is investigated as
part of the implementation bench, not as a prerequisite to starting the work; the
Phase 1 implementation preserves existing all-root behavior for those steps until
the bench resolves it.

## Context

`install.sh` is invoked today as `sudo ./install.sh`, so every operation in it
runs as root. Most of those operations genuinely require privilege: the
dependency `pkg install`, the three kernel-module `build.sh install/build/deploy`
steps (operating in `/usr/src` and `/boot/modules`), the installed-state
migration from shared 0004, the binary installs, the rc.d and s6 trees, the
devfs ruleset, the rc.conf knobs, the `_semadraw` system user, the periodic
hooks, and service activation.

Five operations do not. The userland Zig builds for semadraw, chronofs, the
inputfs userland, pgsd-sessiond, and semasound compile through `zig build` and
emit into the operator's own checkout (`.zig-cache/` and `zig-out/`). Run as
root, they leave root-owned cache and output files inside the checkout. The
operator then cannot rebuild as themselves without first clawing ownership back
(`chown -R`), and a second `sudo` run re-roots the tree again. This is the
ratchet observed in prior sessions.

The fix is not to minimize root operations for their own sake. It is to honor a
small set of architectural goals, against which any installation model is
measured:

1. Never build user artifacts as root.
2. Never write into a user's checkout as root.
3. Keep privilege boundaries obvious and auditable.
4. Make reruns idempotent.

FreeBSD provides a base-system mechanism well suited to this. `mac_do(4)` and its
userland front end `mdo(1)` ship in the base system on 15.0 and are available on
14.x. The kernel swaps process credentials in place after checking a ruleset;
there is no setuid binary, no daemon, no PAM stack, and no password prompt by
default. Two properties of `mac_do` shape the decisions below. First, the absence
of a password prompt makes repeated in-script elevation seamless, with no
`NOPASSWD` sudoers entry and no timestamp caching. Second, `mac_do` gates *which
identities a user may assume*, not *which programs they may run*: there is no
per-command allowlist, and no entry in `/var/log/auth.log`. The model adopted
here therefore treats `mdo` as a clean credential transition, not as a
command-level authorization layer.

## Decisions

### D1. Unprivileged-first execution model

`install.sh` SHALL be invoked as a regular user, not through `sudo` and not as
root. Privilege is the exception, acquired explicitly and locally, never the
ambient default. The four goals in Context are the standard the script is held
to; in particular, goals 1 and 2 are invariants, not aspirations.

### D2. Userland Zig builds execute without privilege

The five userland builds (semadraw, chronofs, inputfs userland, pgsd-sessiond,
semasound) SHALL execute as the invoking user, with no elevation. They are the
only operations that write into the operator's checkout, and running them
unprivileged eliminates the root-owned-cache ratchet by construction rather than
by post-hoc `chown` repair.

### D3. Privileged operations execute through mac_do

Operations that require privilege SHALL acquire it through a single indirection,
so the elevation tool is named in exactly one place and the boundary stays
legible. The indirection is:

```sh
PRIV="${PRIV:-mdo}"
priv() { "$PRIV" "$@"; }
```

`mac_do` (`mdo`) is the default and preferred mechanism: base-system, no setuid
helper, no password prompt, and seamless for repeated in-script elevation. The
`PRIV` override exists for portability to hosts without `mac_do` (pre-14, or the
module not loaded), where `PRIV=sudo ./install.sh` works with no change to the
installer. Selecting an alternative substitutes only the credential-transition
tool; it changes no other decision here. (This resolves what was an open
question in draft: the sudo fallback is supported because the indirection makes
it nearly free, while leaving `mdo` the default.)

The operator provisions the `mac_do` rule out of band, before running the
installer. The reference rule granting `wheel` the ability to become root is
`gid=0>uid=0,gid=*,+gid=*`, set via `security.mac.do.rules` and persisted in
`/etc/sysctl.conf`, with the module loaded via `mac_do_load="YES"` or
`kld_list`. The installer does not write system security policy on the
operator's behalf (see Open questions on whether it should detect and refuse to
proceed when the rule is absent).

This decision accepts `mac_do`'s two known tradeoffs knowingly, under the default
`mdo` mechanism: it grants identity rather than command scope, so the same rule
that lets the installer elevate also lets the operator become root generally, and
elevated steps are not recorded in `auth.log`. Both are acceptable on a
single-operator development and bench host, which is the target environment. (A
`PRIV=sudo` run trades these away for sudo's own properties; the architecture is
indifferent to which is used.)

### D4. Phase 1 implementation is a two-phase re-execution

The first implementation of this model SHALL use a two-phase re-execution
structure, chosen for the smallest diff and the lowest migration risk:

- Phase 1 runs primarily as the invoking user: the dependency check and the
  five userland Zig builds. Any required dependency installation is elevated
  independently, before the userland builds begin; it is the one privileged step
  that cannot sit in Phase 2, since the build depends on its result. One more
  independently elevated step precedes the builds, discovered on the
  2026-06-17 bench: a `clean.sh --force` run under `$PRIV` that removes any
  `.zig-cache/` and `zig-out/` left in the checkout. A tree previously built by
  the old sudo-everything installer carries root-owned caches, and an
  unprivileged Zig build cannot write into them (it fails with `AccessDenied`).
  The elevated clean removes those leftovers so the first unprivileged build
  succeeds; on an already-clean tree it is a no-op. A companion guard repairs
  `sdk/` ownership: `tools/zig` bootstraps the vendored toolchain into
  `sdk/zig/current`, and a pre-ADR bootstrap that ran under sudo left `sdk/`
  root-owned, which a later toolchain swap (writing into `sdk/zig/`) could not
  override unprivileged. The guard `chown`s `sdk/` back to the invoking user when
  it finds any root-owned entry there, and is likewise a no-op once ownership is
  correct. Phase 1 then re-executes the script with a sanitized, root-owned
  environment:

  ```sh
  exec env \
      HOME=/root \
      PATH=/usr/local/bin:/usr/bin:/bin \
      AWASE_PHASE=deploy \
      "$PRIV" "$0" "$@"
  ```

- Phase 2 runs as root under `mdo`: kernel-module components, binary installs,
  configuration, and service activation. A guard on `AWASE_PHASE` ensures the
  root pass does not repeat the Phase 1 userland builds, whose output is already
  present in `zig-out/` and is read (never rewritten) by the privileged phase.

### D5. Elevated execution uses a root-owned environment

The installer SHALL ensure that the elevated phase runs with `HOME=/root` and a
sanitized `PATH`. `mdo` tends to carry the calling user's environment, including
`HOME`. Without this, a tool invoked in the privileged phase that caches under
`$HOME` would write root-owned files into the operator's home directory,
reintroducing the very ratchet this model exists to prevent. Forcing `HOME=/root`
in the elevated environment closes that path. This decision is the environmental
counterpart to D2: D2 keeps the checkout clean, D5 keeps the home directory
clean.

### D6. The installer never creates root-owned files in a user's checkout

The installer SHALL never intentionally create root-owned files inside a user's
source checkout. This is the load-bearing invariant of the model (goals 1 and 2
made operational). The privileged phase may read user-owned build artifacts;
it must not write into the checkout. Any future change that would have the
privileged phase emit into the tree is a defect against this ADR, not a tuning
choice.

### D7. Sanctioned evolution toward per-operation elevation

The two-phase re-execution of D4 is explicitly a Phase 1 implementation, adopted
for risk reduction, not the end state. A future revision MAY move toward
per-operation elevation, in which a `priv()` indirection wraps each privileged
command:

```sh
priv() { mdo "$@"; }
# ...
priv install -m 555 -o root -g wheel "$tmp" "$dest"
priv sysrc awase_supervisor_enable=YES
priv service awase-supervisor start
```

The motivation is auditability: `priv install ...` documents at the call site
that an operation requires privilege, whereas an `AWASE_PHASE` guard requires the
reader to reason about execution state. Moving from the re-exec to a `priv()`
model, in whole or in part, is pre-approved under this ADR and does not require a
new one; it requires only the same bench. Heredoc-generated root-owned files
(the rc.d scripts) under that model are produced by writing to a user-owned
temporary file and then `priv install`-ing it into place, never by redirecting a
root-owned `cat` from an unprivileged shell.

## Consequences

The ratchet is eliminated by construction: build artifacts and caches are
user-owned because the builds that produce them never run as root (D2), and the
home directory stays clean because the elevated phase does not inherit the user's
`HOME` (D5). Because build outputs remain user-owned across runs, repeated
installer executions no longer require ownership repair and therefore directly
support the idempotent rerun objective (goal 4). The privilege boundary becomes
explicit and, under the eventual D7 model, self-documenting at each call site. No
`sudoers` entry, `NOPASSWD` grant, or setuid binary is involved in the default
path, and the mechanism is base-system on both 14.x and 15.0.

The costs are accepted deliberately. The operator must provision the `mac_do`
rule before the first run; the installer treats this as a precondition rather
than configuring security policy itself. Elevated steps produce no `auth.log`
record. The `mac_do` rule grants identity, not command scope, so it is not a
least-authority grant in the `sudoers` sense; this is acceptable for a
single-operator host and would need revisiting for a multi-tenant one. The
re-execution runs the script body twice with a phase guard, so guard correctness
is now a thing that can be got wrong, and is part of the bench. The dependency
`pkg install` is elevated up front, slightly ahead of the otherwise-unprivileged
Phase 1, because the build depends on it.

## Record-keeping and closure

This ADR closes when all of the following hold:

1. `install.sh` is refactored to the D4 two-phase model and committed.
2. It benches green on bare metal: a fresh install completes and activates
   services; a second run is idempotent (goal 4); and an upgrade from a prior
   install still succeeds, preserving the shared 0004 migration behavior.
3. Post-install inspection confirms goals 1 and 2 hold in practice: no
   root-owned files or directories exist in the checkout (`find . -user root`
   over the tree is empty) and none in the operator's home cache.
4. The kernel-module compilation privilege question in Open questions is either
   resolved on the bench or explicitly deferred with the current behavior
   preserved.

## Open questions

1. **Kernel-module compilation privilege (resolved on the bench
   2026-06-17).** The trial settled it: `./inputfs/build.sh build` refuses to
   run unprivileged ("This script must run as root"), and `/usr/src` and
   `/usr/obj` are root-owned (`drwxr-xr-x root wheel` and `drwxrwxr-x root
   wheel`). This is the "all three to root" case: `install`, `build`, and
   `deploy` all require privilege. The kernel compile therefore stays in Phase 2
   as implemented; it does not move to the unprivileged phase under D7. The
   build.sh `sudo $0` usage banners were correct.

2. **Rule-presence detection (resolved on the bench 2026-06-17).** A fresh
   FreeBSD 15.1 host without a provisioned rule failed obscurely at the first
   `mdo` (`mdo: setcred(): Operation not permitted`) after the dependency check
   had already run. Resolved by an elevation preflight near the top of the
   script: a functional probe (`"$PRIV" true`, ground truth rather than sysctl
   parsing) gated on not-`--check` and not-already-root. On failure, an
   interactive run shows the exact provisioning commands in a `bsddialog` box
   (plain stderr plus an Enter prompt when `bsddialog` is absent) and re-checks
   after the operator applies them in a root shell, looping until elevation
   works or the operator aborts; a non-interactive run (`--yes` or no tty) fails
   fast with the same recipe. The installer never writes security policy itself,
   preserving D3.

3. **sudo fallback (resolved in D3).** Support for `PRIV=sudo ./install.sh` on
   hosts without `mac_do` is decided in D3 rather than left open: the
   single-indirection requirement makes it a one-variable change, `mdo` stays
   the default, and the architecture is indifferent to the tool chosen. Recorded
   here only as a pointer to that decision.

4. **Elevated-step audit.** `mac_do` does not write `auth.log`. If auditing of
   privileged installer steps is later required, that is script-level logging of
   the privileged operations and is out of scope for this ADR.
