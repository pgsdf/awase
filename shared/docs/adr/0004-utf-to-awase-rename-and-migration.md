# shared 0004: UTF to Awase rename and installed-state migration

## Status

Accepted 2026-06-17 (operator).

Amended 2026-06-17 (operator) to reconcile with the prior ratified
`docs/RENAME-PLAN.md` (see Context): the leave-alone set is extended (D5), the
path-pointer decision is added (D7), and external coordination including NLnet is
recorded (Open questions).

Tranche A (cosmetic) may land now. Tranche B (migration) additionally requires a
green upgrade-from-UTF bench on bare metal before it is considered closed (see
Record-keeping and closure).

## Context

The project is being renamed from UTF to Awase. A tree-wide census was run
first, and it changed the shape of the task: this is not primarily a
source-tree rename, it is an installed-state migration with a much smaller
cosmetic surface attached.

This rename was first scoped in `docs/RENAME-PLAN.md`, ratified 2026-06-12
(operator), which classified the work R1 (living prose) through R4 (external
coordination) over a permanent leave-alone set. This ADR supersedes that plan as
the authoritative governance for the rename: in particular the plan's R3
(operational paths) is replaced by Tranche B and its migration contract (D4, D6),
which the plan only sketched. The plan is retained as the subordinate operational
checklist: its R1 doc-by-doc list is the worklist for the Tranche A docs pass,
and its R4 is folded into the Open questions below. Where the two ever disagree,
this ADR governs.

Two findings drive this ADR.

First, a repository-wide text replacement is not a safe plan of record. The
string `utf` appears as a substring inside `inputfs` (inp-utf-s), so the raw
hit counts were dominated by `inputfs`, `inputfs_state_buf`, `M_INPUTFS`, and
similar identifiers in the input subsystem. A blind `utf -> awase` sweep would
corrupt the entire input driver long before it finished renaming the project.
Only the standalone `UTF` / `utf` token is the project name, and `UTF-8` /
Unicode references must also be preserved. All replacement work is therefore
scoped to the whole-word token, never the substring.

Second, with the substring noise removed, the real project-name surface falls
into three categories that must be treated differently:

1. Historical records: ratified ADRs, dated session memos, and backlog history.
   These describe decisions made under the UTF name. The bulk of the remaining
   hits live here.
2. Cosmetic and forward-facing references: banners, code comments, README and
   INSTALL material, design-doc prose, and debug instrument names. Low risk.
3. Migration-sensitive installed-state identifiers: on-disk paths, rc.d service
   names, and rc.conf / system-configuration knobs. These are load-bearing on
   any deployed system.

The third category is where the risk lives, and it is not source churn. A
running install has admin-created configuration at `/etc/utf/users/`, an s6
supervision tree rooted at `/var/service/utf/`, logs under `/var/log/utf/`, rc.d
services `utf-supervisor` and `utf-log-cleanup`, and rc.conf knobs in the
`utf_*` namespace. Renaming any of these without a migration breaks the
deployed system: the supervisor cannot find its tree, pgsd-sessiond cannot find
`/etc/utf/users/<name>.conf`, and the operator's `utf_*` rc.conf settings are
orphaned. This ADR is therefore about migration policy, not text replacement.

## Decisions

### D1. Awase is the canonical namespace, not only branding

Awase becomes the canonical name for paths, services, and configuration knobs,
not merely the displayed brand. New installs are fully Awase-named. The UTF
forms become deprecated aliases recognized only for the duration of the
compatibility window in D3.

### D2. Compatibility migration, not flag-day cutover

Existing UTF-named installed state is migrated forward in place by the
installer/upgrader, and compatibility aliases are provided where required during
the compatibility window. A flag-day cutover that required operators to
hand-migrate deployed systems is rejected: the cost of the migration logic is
bounded and one-time, whereas a flag day puts every existing deployment at risk
on upgrade.

### D3. Canonical mapping and compatibility window

The canonical mapping is the whole-word token transform:

- Prose / branding: `UTF` -> `Awase`
- Lowercase identifiers, paths, service names: `utf` -> `awase`
- Macro / environment prefixes: `UTF_` -> `AWASE_`

Applied to the installed-state surface:

| UTF form | Awase form |
| --- | --- |
| `/etc/utf/users/` | `/etc/awase/users/` |
| `/var/service/utf/` | `/var/service/awase/` |
| `/var/log/utf/` | `/var/log/awase/` |
| `/var/run/utf-supervisor.pid` | `/var/run/awase-supervisor.pid` |
| rc.d `utf-supervisor` | rc.d `awase-supervisor` |
| rc.d `utf-log-cleanup` | rc.d `awase-log-cleanup` |
| rc.conf `utf_supervisor_enable` (and the rest of the `utf_*` knob set) | `awase_*` equivalents |
| `UTF_*_INSTRUMENT` env / macros | `AWASE_*_INSTRUMENT` |

Compatibility window: the UTF aliases (path compatibility aliases, installer
migration detection, and compatibility handling of existing rc.conf knobs) are
retained through the next tagged release and removed in a dedicated follow-up ADR once a bench
confirms no surviving install still references the UTF forms. The exact removal
horizon is an operator decision recorded at ratification (see Open questions).

### D4. Alias and migration semantics

This section defines the compatibility semantics each surface must provide
during the window. It does not prescribe the mechanism: dual-read, an installer
move-with-fallback, a compatibility symlink, or another approach is chosen per
surface in the Tranche B survey (D6), whichever is cleanest for that surface.

- Daemon-read paths: a daemon that opens a fixed location must continue to
  resolve it whether the deployed system carries the surface under the Awase or
  the UTF name, for the duration of the window. Covers `/etc/awase/users/`
  (pgsd-sessiond user attributes) and any other fixed-location path. Whether
  this is met by reading the Awase path with a UTF fallback, by relocating the
  surface and leaving a UTF compatibility symlink, or otherwise, is an
  implementation choice for the tranche.
- rc.conf and system-config knobs: any value an operator has set under a `utf_*`
  name must take effect under its `awase_*` equivalent after upgrade, and the
  stale `utf_*` entry must not be left to rot. The installer is the natural
  place to carry the value forward and remove the old entry; no long-lived code
  alias is required.
- Services and supervision tree: the upgrade must end with the Awase-named
  supervision tree active and the UTF-named tree and rc.d scripts removed, with
  no interval in which nothing supervises the daemons. The existing install.sh
  AD-12.1 stop/restart discipline governs the daemon bounce.
- Logs: new logs are written under `/var/log/awase/`. Existing `/var/log/utf/`
  contents are left in place; they are disposable and are not migrated.
- Debug instruments: a developer invocation that sets the UTF `*_INSTRUMENT` env
  name must keep working for the window; `AWASE_*_INSTRUMENT` is the canonical
  form going forward.

Idempotence requirement: every migration step must be safe to re-run. Re-running
install.sh after a partially completed or interrupted migration must not corrupt
state, duplicate supervision trees, double-migrate or lose configuration, or
leave the system unsupervised. Each step checks for its own completion and is a
no-op when already applied. Given the amount of stateful install.sh work D4
implies, this is a binding requirement, not a convention.

### D5. Historical records are not rewritten

Ratified ADRs, dated session memos (`docs/sessions/`, `*/docs/sessions/`),
backlog history (`BACKLOG-history.md`), verification records (`*_VERIFICATION*.md`),
and fuzz findings are left exactly as written. They are a forward-only record of
decisions made under the UTF name, and rewriting them would rewrite that record.
Forward-facing documents (top-level READMEs, INSTALL.md, current architecture
docs) may add a one-line note that the project was formerly named UTF. This ADR,
authored under the rename, refers to the UTF forms as the prior names by design.
The sole exception to this section is path pointers, handled in D7.

### D6. Implementation staging

The work separates into two tranches with different risk and bench profiles:

- Tranche A (cosmetic, pure text that no code or tooling reads): code comments,
  C banners, forward-facing doc prose, the `docs/UTF_*.md` filenames and the
  references to them, README and INSTALL material. No runtime behavior changes;
  this tranche must bench as a no-op (`zig build` / `zig build test` unchanged).
- Tranche B (migration, anything code or tooling reads): the paths, service
  names, rc.conf knobs, and `*_INSTRUMENT` env names from D3, plus the
  install.sh migration logic and the compatibility semantics from D4. Breaking;
  benched on bare metal across an upgrade from a UTF-named install, including a
  supervisor restart and a completed login through pgsd-sessiond reading
  `/etc/awase/users/`.

  Prerequisite: before Tranche B implementation begins, the complete `utf_*`
  knob inventory (rc.conf, devfs rules, loader.conf, and any other
  system-configuration namespace) must be enumerated from the census and
  attached to the tranche survey. The migration is not complete until every
  enumerated knob is accounted for; discovering a knob after implementation has
  started is a defect in the survey, not an acceptable late find.

Tranche A may land on ratification of this ADR. Tranche B lands per its own bench.

### D7. Path pointers in historical files are updated when their targets move

Tranche A renames the `docs/UTF_*.md` boundary documents (and
`does-awase-have-a-framebuffer.md`) to their Awase names. Roughly twenty historical
and ratified files reference those documents by path. A path is a pointer, not
prose: a reference that no longer resolves is a defect, not a preserved decision.
So when a target file is renamed, its references update even inside otherwise
frozen historical files (ratified ADRs, backlog history). This is the sole
exception to D5, and it changes only the pointer, never the surrounding recorded
language. The alternative available to the operator is to leave redirect stubs at
the old `docs/UTF_*.md` paths and update no historical file; the default is to
update pointers.

## Consequences

- New installs are fully Awase-named. Existing installs upgrade in place: the
  installer migrates `/etc/utf/users`, the supervision tree, rc.d services, and
  rc.conf knobs forward, and the operator sees `awase_*` knobs afterward.
- The highest-risk operation is the Tranche B upgrade path that stops the
  supervisor, rebuilds `/var/service/awase/`, and rewrites rc.conf during an
  upgrade. It is gated on a real bare-metal upgrade bench, not a fresh-install
  bench, because fresh install never exercises the migration branch.
- The code carries small dual-read fallbacks (paths and instrument env names)
  and the installer carries `utf_*` detection until the D3 window closes. Their
  removal is a tracked follow-up ADR, not an open-ended maintenance cost.
- Historical records remain accurate to their time. A reader of an old ADR sees
  UTF, which is correct for when it was written.
- A substring-based rename is explicitly out of bounds; all tooling for the
  rename operates on the whole-word token and preserves `UTF-8` / Unicode.

## Record-keeping and closure

This ADR closes when all of the following hold:

1. Tranche A is committed and benches as a no-op on `pgsd-bare-metal` (or the
   designated bench host).
2. Tranche B is committed and verified on bare metal across an upgrade from a
   UTF-named install: supervisor restarts under the new tree, a login completes
   through pgsd-sessiond reading `/etc/awase/users/`, and the migrated `awase_*`
   rc.conf knobs are in effect.
3. A follow-up ADR is filed scheduling removal of the UTF aliases at the horizon
   chosen in Open questions.

## Open questions (to resolve at ratification)

1. Removal horizon for the UTF aliases. Proposed: deprecated through the next
   tagged release, removed in the follow-up ADR once a bench confirms no
   surviving install references the UTF forms. Confirm the concrete release or
   milestone.
2. NLnet coordination (time-sensitive). The submitted NLnet proposal names the
   project UTF. If the application is still under review, the public rename and
   the proposal must not silently disagree: either hold the public-facing rename
   (repo slug, site) until the funding decision, or send NLnet a one-line
   renaming notice. This gates the timing of item 3, not the source-tree work.
3. External coordination (RENAME-PLAN.md R4), operator-executed: the GitHub slug
   `pgsdf/UTF` to `pgsdf/awase` (GitHub redirects old URLs; local remotes update
   at leisure), `pgsdf.org` references, and the NDE repository's references.
   Sequence the slug rename with the forward-facing docs so they agree from the
   first public moment.

The full `utf_*` knob set is no longer an open question: D6 makes its complete
enumeration a required prerequisite artifact attached to the Tranche B survey
before that tranche begins. The disposition of existing `/var/log/utf/` logs is
also settled in D4: they are left in place and not migrated.
