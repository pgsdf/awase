# 0026 F.5.d: policy

## Status

Accepted, 2026-06-04 (ratified same day as proposed, with
operator amendments recorded inline: fallback is explicitly
admission-only; "active client" is precisely defined for
group evaluation; ducking is reference-counted;
STATUS_PREEMPTED is scoped to group-exclusivity preemption
only; and duck_gain remains grammar version 1, recorded as a
semasound-specific extension to the Phase 12 policy model,
the parity target being the policy model and operator
experience, not parser compatibility with a retired daemon).
Closed, 2026-06-04: all ten closure criteria verified on
pgsd-bare-metal and the operator marked F.5.d complete.

Fourth sub-milestone of F.5 (semasound), scoped under ADR
0020. Depends on F.5.c (ADR 0025, closed): policy acts on the
targets and routing established there, under two inherited
constraints: transparent stream migration is not permitted
(ADR 0025 Decision 3 amendment), and election on any target
is a function of that target's client set alone (ADR 0025
Decision 5 invariant).

## Context

ADR 0020 scopes F.5.d as: preemption, fallback,
priority/ducking, and durable policy persistence (the
`policy.zig` / `policy_state.zig` concern).

The parity reference is semaaud's policy engine through Phase
12: a per-target, line-oriented policy file (grammar version
1) with directives `default=allow|deny`, `deny_label`,
`deny_class`, `allow_class`, `override_class`,
`fallback_target`, and `group`; evaluation precedence
deny_label, then deny_class, then allow_class, then the
default; reload at startup and on every inbound connection
(live-editable); and a never-throwing parser whose
diagnostics are published through `policy-valid` and
`policy-errors` surfaces rewritten atomically on every
reload.

Two translation problems separate semaaud's semantics from a
mixing broker:

First, identity. semaaud policy matches on a client's LABEL
(an instance name) and CLASS (a category such as `music`,
`alert`, `voice`). semasound's Hello carries neither; policy
needs them on the wire.

Second, contention. semaaud's `override_class` (preempt a
busy target) and `group` (mutual exclusivity across targets)
exist because its targets are single-stream: contention is
the normal case and policy arbitrates it by killing streams.
A mixer dissolves stream-level contention, so a literal port
of kill-preemption would reintroduce, as policy, exactly the
behavior mixing was built to remove. The mixing-native
translation of "higher class wins" is priority/ducking, and
the one place stream termination remains irreducible is group
exclusivity, where it must be protocol-visible per the ADR
0025 constraint.

## Decisions

### 1. Client identity: Hello v3 carries label and class

The Hello gains two NUL-padded 16-byte fields, `label` (an
instance name, free-form) and `class` (a category token), and
HELLO_VERSION becomes 3. Empty label defaults to `anon`;
empty class defaults to `none`. v2 Hellos are rejected (same
rationale as ADR 0025 Decision 4: no deployed clients, one
admission shape).

Rationale. Policy matches on label and class in the parity
grammar; they are admission-time properties of a connection
and belong in the admission frame, alongside the target name,
where the connection's full disposition is decided once.

Tradeoff. The Hello grows to 64 bytes. Self-declared identity
is trust-by-declaration (any client may claim any class);
peer-credential binding (LOCAL_PEERCRED to uid/gid) is a real
hardening path but out of scope here, recorded for a future
sub-milestone, since semaaud's parity semantics are also
declaration-based.

### 2. Policy persistence: source of truth in etc, surfaces in run

The durable source of truth is
`/usr/local/etc/semasound/<target>.policy` (hier(7):
operator-edited configuration lives in etc). The validation
and evaluation surfaces live under
`/var/run/sema/audio/<target>/`: `policy-valid`,
`policy-errors`, and `policy-state` (the derived JSON view of
the last evaluation), each rewritten atomically
(write-temp-then-rename) on every reload. A missing policy
file is valid and means `default=allow` with no rules.

Rationale. semaaud put both under `/tmp/draw/audio/<target>/`,
a semadraw-era layout where the operator edits a tmpfs file
that vanishes on reboot, which contradicts "durable" as soon
as the machine restarts. Splitting source of truth (etc) from
derived surfaces (run) is the FreeBSD-idiomatic correction,
and the surface FILENAMES and formats are kept
semaaud-compatible so Phase 12 watchers port by changing a
prefix. The F.6 retirement ADR decides whether a compat
symlink tree is warranted.

Tradeoff. A deliberate parity divergence in layout (recorded
here) in exchange for surviving reboot and honoring hier(7).

### 3. Grammar, precedence, reload: parity verbatim

Grammar version 1 is adopted as specified (line-oriented,
comments, the seven directives, the three diagnostics:
`invalid version field`, `unsupported policy version`,
`unknown directive: <line>`). Evaluation precedence is
deny_label, deny_class, allow_class, default. The policy is
loaded per target at startup and reloaded on every accepted
connection before the routing decision. A policy with errors
is never fatal: the parser collects diagnostics, publishes
them, and evaluation proceeds with whatever parsed (semaaud
behavior).

Rationale. This is the durable-policy contract Phase 12
locked; parity means honoring it, including the live-edit
property (an operator edit takes effect on the next
connection with no restart) and the never-throw property.

Tradeoff. Reload-per-connection costs a small file read per
admission; admissions are rare and the file is capped at
64 KiB. Watching with kqueue is an optimization not taken.

### 4. Admission control: deny/allow translate directly

`deny_label`, `deny_class`, `allow_class`, and
`default=allow|deny` are pure admission control and translate
unchanged: evaluated at accept time against the Hello's label
and class, after target resolution and before election. A
denied client receives STATUS_REJECTED and a
`error: denied by policy` line.

Rationale. Admission control is mixer-agnostic; nothing to
translate.

### 5. override_class translates to priority/ducking, not kill-preemption

While at least one override-class client is active on a
target, every non-override client on that target is ducked:
its samples are scaled by a configured factor during mixing.
A new v1-compatible directive `duck_gain=F` (float in [0,1],
default 0.25) sets the factor per target. Duck state is
REFERENCE-COUNTED over the override set (operator amendment):
ducking engages when the count of active override-class
clients on the target rises above zero and restores only when
it returns to zero; overlapping override clients never cause
early restore. No client is disconnected, nothing migrates,
election is untouched, and STATUS_PREEMPTED is NEVER emitted
for ducking (operator amendment): ducking is a gain change,
not a lifecycle event.

Rationale. This is ADR 0020's "priority/ducking" and the
mixing-native meaning of "override": the alert speaks over
the music instead of killing it, which is strictly more
useful than semaaud's preemption and is what mixing exists to
enable. Kill-preemption's motivating condition (single-stream
busyness) no longer exists; porting it literally would be
cargo cult.

Tradeoff. A recorded parity divergence: semaaud terminates,
semasound ducks. Requires per-client gain in the mix path (a
seam in the ADR 0021-verified mixer: gain applied at
summation, bit-exact passthrough preserved when gain is 1.0
and a single source is present). `duck_gain` is a
semasound-specific extension to the Phase 12 policy model and
a recorded parity divergence; the grammar stays version 1
(operator ruling): grammar versioning earns its keep when
multiple implementations consume the same files, and
semasound is the successor implementation of a per-daemon
file format, so the compatibility objective is the semantics
of the parity directives, precedence, reload, and
diagnostics, not consumption of future semasound files by the
parser of a daemon being retired.

### 6. group translates to admission exclusivity; preemption is protocol-visible disconnect

Targets sharing a `group=G` are mutually exclusive at
admission: a client is denied on target A if another target
in A's group has active clients ("group busy"), subject to
fallback (Decision 7). "Active client" is defined precisely
(operator amendment) as an admitted connection whose slot has
not yet been reaped, the same definition the 0-to-1 election
uses; a finished-but-draining client therefore keeps its
group member busy until its ring drains and the reaper frees
the slot, consistent with every other lifecycle boundary in
the broker. The one irreducible preemption case:
an OVERRIDE-class client admitted to a group-locked target
preempts the other group member, every client there receives
a new STATUS_PREEMPTED disconnect (a status byte written
before close, the protocol-visible mechanism the ADR 0025
amendment requires), the slots are reaped, and the override
client is admitted.

Rationale. Group exclusivity is the speaker-vs-headphone
shape and stays meaningful under mixing (the group is
exclusive even though each member mixes internally).
Preemption within a group cannot be expressed as ducking
(the group invariant is "only one member active"), so it is
the one place stream termination survives, and it does so
visibly, never silently.

Tradeoff. STATUS_PREEMPTED is new protocol surface, and the
tone client must learn to report it (exit 3). Group semantics
are synthetic on current hardware (default+null), but the
mechanism is fully exercisable and a second real device
inherits it unchanged.

### 7. fallback_target: one-hop admission redirection

When a client is denied on its requested target (by rule or
by group busyness) and that target's policy names
`fallback_target=T`, the client is evaluated once against T's
policy and admitted there if allowed; otherwise rejected. One
hop, no chains, no cycles. The accept log records the
redirection (`requested=X admitted=Y`). Fallback is
ADMISSION-ONLY (operator amendment): it participates in no
runtime migration and no retry behavior; once a connection is
admitted anywhere, fallback never touches it again, and a
denial after the one hop is final for that connection.

Rationale. This is admission-time redirection, explicitly
permitted by the ADR 0025 Decision 3 amendment, and it is
semaaud's fallback semantics expressed without touching a
live connection.

Tradeoff. The client is not told it was redirected beyond
the broker log until F.5.e publishes per-stream state; adding
a "routed-to" byte to the accept response is deferred as
protocol surface F.5.e may want anyway.

### 8. Scope fences and code shape

`policy.zig` (grammar, load, evaluate), `policy_state.zig`
(the three surfaces, atomic rewrite), per-target wiring in
`target.zig`/`main.zig`, per-client gain in `client.zig` and
the mixer seam, STATUS_PREEMPTED in `protocol.zig`, Hello v3.
NOT in scope: per-stream/target state publication beyond the
three policy surfaces (F.5.e), supervision (F.5.f),
credential-bound identity (future), kqueue policy watching
(optimization), policy-driven mid-life re-routing (forbidden
by ADR 0025).

## Closure criteria

  1. Startup loads per-target policy (absent file = valid,
     default allow) and writes all three surfaces atomically;
     topology and policy state logged.
  2. Live reload: editing a policy file takes effect on the
     next connection with no restart (a deny_class added live
     denies the next matching client).
  3. Precedence verified: deny_label beats deny_class beats
     allow_class beats default, on crafted policies.
  4. Validation parity: unknown directive and version=2 each
     produce policy-valid=false and the exact diagnostic
     lines; a clean, comment-only, or absent file produces
     policy-valid=true and empty policy-errors; a malformed
     policy never crashes the broker and evaluation proceeds
     with what parsed.
  5. Ducking: with duck_gain configured, an override-class
     client audibly ducks a concurrent music-class client on
     default, and full level returns when the override client
     exits (aural + accept-log evidence).
  6. Bit-exactness preserved: a lone passthrough client with
     no override active mixes at unity gain (F.5.b criterion 4
     spot-check unchanged).
  7. Group + preemption: with default and null grouped, a
     client on one denies a normal client on the other
     (fallback honored if configured); an override-class
     client preempts the other member's clients, each
     receiving STATUS_PREEMPTED (tone client exits 3), broker
     surviving with slots reaped.
  8. Policy engine inertness: with no policy files present,
     the full f5b_election and f5c_targets suites pass
     unchanged (the engine at rest changes nothing, including
     election isolation).
  9. No fd/memory leak across policy reload, denial,
     fallback, ducking, and preemption cycles.
 10. Operator marks F.5.d `[x]`.
     VERIFIED 2026-06-04: operator confirmed after the full
     bench cycle, including the aural ducking check (criterion
     5) and the inertness gate (criterion 8, both prior suites
     unchanged with no policy files present).

## References

  - ADR 0020: scope; binding constraints inherited.
  - ADR 0025: targets, immutable routing, the no-migration
    constraint and election-isolation invariant this design
    operates under.
  - ADR 0021: the mixer whose summation gains a gain seam.
  - semaaud SemaAud-Phase12-DurablePolicy-Spec.md,
    `policy.zig`, `policy_state.zig`: the parity contract.

## Revision history

  - 2026-06-04: proposed. Eight decisions: Hello v3 identity
    (label/class); etc-sourced, run-surfaced durable policy;
    grammar/precedence/reload parity verbatim; admission
    control direct; override_class as ducking (parity
    divergence from kill-preemption, with rationale); group
    as admission exclusivity with protocol-visible
    STATUS_PREEMPTED preemption; one-hop fallback
    redirection; scope fences.
  - 2026-06-04: ratified with operator amendments, recorded
    inline: fallback admission-only (no migration, no retry);
    "active client" for group evaluation defined as
    admitted-and-not-reaped (the election definition);
    ducking reference-counted over the override set;
    STATUS_PREEMPTED scoped to group preemption only, never
    ducking; duck_gain kept at grammar version 1 as a
    semasound-specific extension to the Phase 12 policy
    model. The operator's litmus test is recorded as the
    Decision 5 rationale: had semaaud possessed a mixer,
    override_class would not have killed the stream; its
    purpose was keeping higher-priority audio audible, which
    ducking preserves while exploiting the architecture being
    built.
  - 2026-06-04: implementation landed and bench-verified
    (f5d_policy harness, all scripted cases, plus the aural
    ducking check). Criteria 1-9 evidenced: surfaces written
    atomically with an absent policy valid and default-allow;
    live reload denying the next connection with no restart;
    precedence exact (deny_label beat allow_class, deny_class
    denied, allow_class admitted under default=deny, the
    default was the fallthrough); validation parity exact
    ('unsupported policy version' and 'unknown directive:
    frobnicate=yes' verbatim in policy-errors, policy-valid
    false, the client still admitted under what parsed, the
    parsed deny still enforced, broker alive); ducking
    aurally confirmed (440 Hz ducked under the 880 Hz
    override-class client and returned to full on its exit)
    with the [override] admission logged; the lone-44.1k
    unity passthrough spot-check unchanged (bit-exactness
    additionally pinned by the mixGains unity test);
    group-busy denied a normal client and the override-class
    client preempted the grouped peer protocol-visibly (tone
    exit 3, preemption logged, broker surviving); INERTNESS
    verified: with no policy files present the full
    f5b_election and f5c_targets suites passed unchanged,
    every count identical; fd count and RSS exactly stable
    across deny/allow policy cycles. First-pass bench cycle,
    no rework. Remaining: criterion 10 (operator mark).
  - 2026-06-04: criterion 10 confirmed by the operator.
    F.5.d closed. Next: F.5.e (state publication), which grows
    the /var/run/sema/audio/<target>/ surface tree begun here
    into the full per-target and per-stream observability
    layout; then F.5.f (supervision) and F.6 (semaaud
    retirement).
