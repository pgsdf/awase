# Maintenance capability: design exploration

Status: Design exploration (non-ratified). Purpose: establish what
maintenance capability the architecture requires, then evaluate candidate
realizations of that capability, of which a dedicated Maintenance Environment
is one. This document is exploratory and may change. It establishes no
durable architecture and amends no ADR. If it concludes that a particular
realization is correct, that realization is ratified separately.

## Why this exploration, and what it must not assume

Discussion of a Maintenance Environment (ME) reached a coherent candidate: a
third boot destination, alongside the Operational Environment (OE) and the
Recovery Environment (RE), providing rescue-shell and installer capabilities.
Before that candidate is ratified, one prior question must be answered, because
promoting the candidate first would assume the conclusion:

  Is a Maintenance Environment an architectural REQUIREMENT, or is it one
  REALIZATION of maintenance functionality the architecture requires?

Those are different. If the architecture requires a maintenance environment,
a dedicated ME is the right move. If the architecture requires maintenance
CAPABILITIES, a dedicated ME is one realization among several, and it must be
chosen against alternatives rather than assumed.

This note therefore does two things in order: it establishes the required
maintenance capabilities (what must be true), grounded in the concrete
failure that motivated AD-58; then it evaluates candidate realizations
against those capabilities. It does not begin from the ME candidate and
justify it. Terminology follows the AD-58 addendum: PGSD is the operating
system, AD-58 is the PGSD lifecycle, awase be is the lifecycle's Boot
Environment implementation, AD-59 is the bootloader.

## The required maintenance capability, grounded in the founding failure

AD-58 was forced by a concrete failure: a kernel change hung the display
substrate at framebuffer init on every boot, and because no clean recovery
environment had been prepared, the bench had to be reinstalled. AD-58 records
two lifecycle mistakes from this (promoting on completion rather than
verification, and assuming rather than verifying the recovery path) and its
Recovery state answers them: a known-good state, captured before change,
whose purpose is rollback.

But the failure record contains a second consequence AD-58's Recovery does
not address, and it is the origin of the maintenance requirement:

  "the bench had to be reinstalled. The broken environment, which was the
  only thing that reproduced the failure, was destroyed in the process, so
  the root cause could not be examined afterward."

Two capabilities were absent, and rollback provides neither:

  - The ability to repair or reinstall without a full, destructive
    reinstall. The only available response was to reinstall the whole bench.

  - The ability to act upon the damaged system non-destructively, so the
    broken state can be examined, diagnosed, and repaired rather than
    obliterated. The reinstall destroyed the only reproduction of the
    failure.

Rollback (becoming a known-good state) does not provide these. Rolling back
moves operation to a good environment; it does not give a workspace from
which to inspect, diagnose, or repair the broken environment, and a naive
"start over" is exactly the destructive reinstall that lost the evidence.

From this, the required maintenance capability is stated as what must be
true, independent of how it is realized:

  M1. Independent bootability. The maintenance capability is available when
      the Operational Environment cannot boot. It does not depend on OE being
      functional, because the case that needs it is precisely OE being
      broken.

  M2. Act-upon, not become. It provides a workspace from which to operate on
      the system (inspect storage and pools, examine and repair boot
      environments and boot configuration, reinstall or repair the operating
      system) rather than a system to boot into and run as the operational
      system. This is the distinction from Recovery: Recovery exists to
      BECOME the running system; maintenance exists to ACT UPON it.

  M3. Non-destruction of user data. Its operations preserve the user's /home
      dataset. Repair and reinstall do not require destroying user data.

  M4. Non-destruction of evidence. It can act upon a damaged environment
      without obliterating it, so a broken state can be examined and its root
      cause diagnosed rather than destroyed by a start-over. This capability
      is named directly from the founding failure's second consequence.

  M5. The maintenance toolset. It provides the facilities these operations
      require: the operating system installer, storage and filesystem
      management utilities, boot environment management tools, and diagnostic
      and repair utilities.

  M6. Explicit entry only. Whatever realizes the capability, it is entered
      only by explicit operator intent, never automatically and never as an
      automatic escalation from a failed recovery. A maintenance workspace
      that can reinstall and repartition must not be entered by inference.

These are capabilities, not a mechanism. M1 through M6 are what any
realization must provide; the next section evaluates realizations against
them.

## The architectural integration objective (separate from the capabilities)

M1 through M6 state what the maintenance capability must provide. They do
not state how a realization must FIT the architecture the project is
building. That is a separate concern, and conflating the two would make the
capability list impure: a realization can fully satisfy the maintenance
capability yet not fit the architecture, or vice versa. The project has one
architectural integration objective that bears on this decision, stated
separately and explicitly so it is not mistaken for a capability:

  A1. Unified destination selection. Supported boot destinations, including
      any maintenance facility that is reached by booting it, should
      participate in the same policy-driven boot-selection mechanism as the
      Operational and Recovery Environments, rather than through a separate
      selection path outside AD-59. This is the direction of replacing the
      boot menu with a single destination-selection mechanism: one component
      resolves what to boot, whatever its purpose.

A1 is an architectural goal, not a maintenance requirement. A realization can
satisfy every maintenance capability (M1 through M6) and still fail A1 by
standing outside the unified selection mechanism. The evaluation below charges
integration failures to A1 and capability failures to M1 through M6, keeping
the two kinds of judgment distinct.

## Candidate realizations

Each candidate is evaluated against M1 through M6. The question is which best
satisfies the capabilities against architectural goals, not which is most
convenient to build.

### Candidate A: a dedicated Maintenance Environment (ME)

A third boot destination beside OE and RE: a purpose-built environment
containing the maintenance toolset (M5), booted to act upon the system.

  - M1 (independent bootability): satisfied. ME is its own boot destination,
    bootable when OE is not, resolved through the same boot-selection path as
    OE and RE.
  - M2 (act-upon): satisfied by construction. ME's purpose is to act upon the
    system, distinct from RE's purpose to become it.
  - M3, M4 (non-destruction of data and evidence): satisfied. Booted into a
    separate environment, ME mounts and inspects OE, RE, and pools without
    running or destroying them; repair and reinstall are selective operations
    the operator directs.
  - M5 (toolset): satisfied by construction; ME is built to contain it.
  - M6 (explicit entry): satisfied as a policy target that is eligible but
    never automatic (the eligible-target versus automatic-outcome
    distinction), entered only on explicit maintenance intent.

  Cost: ME is a new architectural concept with its own lifecycle (build,
  verify, update, rebuild). The maintenance toolset must be kept current
  enough to import current pools and support current hardware, which is a
  staleness concern relocated into ME's lifecycle (tractable as deliberate
  periodic refresh, but real). This is genuinely new machinery, not a
  clarification of an existing responsibility.

### Candidate B: maintenance capabilities hosted by Recovery (RE)

Extend RE to carry the maintenance toolset, so the single Recovery
environment serves both rollback and maintenance.

  - M1 (independent bootability): satisfied; RE is independently bootable.
  - M2 (act-upon): in TENSION with AD-58. RE's ratified purpose is "only
    rollback": become the running system. Hosting maintenance in RE means RE
    both becomes the system (rollback) and acts upon it (maintenance),
    reintroducing exactly the conflation this exploration separated. It would
    require amending AD-58's "only purpose is rollback," and it re-muddies the
    become-versus-act-upon line that makes the roles clean.
  - M3, M4: achievable, but RE is defined as frozen and captured before
    change; loading it with a maintenance toolset makes it no longer a minimal
    clean capture, weakening the property that makes RE trustworthy as a
    rollback target.
  - M5 (toolset): would require RE to carry the toolset, contradicting RE's
    clean-minimal-capture construction.
  - M6: satisfiable.

  Cost: this candidate saves a new environment but at the price of
  re-conflating two purposes AD-58 deliberately keeps separate, amending
  AD-58's Recovery definition, and diluting the minimal-clean-capture property
  that makes RE a trustworthy rollback target. It trades new machinery for
  architectural muddiness.

### Candidate C: maintenance capabilities hosted elsewhere (OE, or external media)

Host maintenance in the Operational Environment, or on external or live
media.

  - Maintenance in OE fails M1 outright: the case needing maintenance is OE
    being unbootable, and maintenance hosted in OE is unavailable exactly
    then. This is the founding failure repeating.
  - External or live media SATISFIES the maintenance capability (M1 through
    M5): it is the traditional rescue-media model, independently bootable and
    carrying the toolset. It fails A1, not the capability: it is not
    resolvable through the unified boot-selection mechanism, it stands outside
    the PGSD lifecycle and AD-59, and it is not always present (it must be
    produced and kept on hand). This distinction matters: external media is
    not rejected because it cannot perform maintenance, but because it does
    not participate in the unified destination selection the architecture
    seeks.

  Cost: OE-hosting fails M1, the core capability. External media satisfies the
  capability but fails A1 and is not guaranteed present. Neither participates
  in the unified boot-selection mechanism the project is moving toward.

### Candidate D: another model

Considered for completeness: maintenance as something other than a boot
destination (for example a service within OE, or a network-booted
environment). Service-within-OE fails M1 (independent bootability), as in
Candidate C's OE case. Network boot may satisfy the capability but fails A1
(it is outside the unified selection mechanism) and adds a network dependency
and the same not-always-present concern as external media. Neither is pursued
further here; they are recorded so the option space is not artificially
closed. That this candidate exists is also why the assessment below does not
claim uniqueness: the design space is not exhaustively closed.

## Assessment

Measured against M1 through M6 and A1, a dedicated Maintenance Environment
(Candidate A) is the strongest realization identified in this exploration. It
satisfies all six capabilities (independently bootable, M1; act-upon by
construction, M2; non-destructive of data and evidence, M3 and M4; carries the
toolset, M5; eligible-but-not-automatic entry, M6) AND satisfies A1, being
resolved through the same unified boot-selection mechanism as OE and RE.

The alternatives each fail on architectural grounds rather than convenience,
and the distinction between capability failure and integration failure is
kept explicit: RE-hosting (B) re-conflates become and act-upon and would amend
AD-58's Recovery; OE-hosting (C) fails M1, the core capability; external or
live media (C) satisfies the capability but fails A1 and is not guaranteed
present; other models (D) fail M1 or A1 similarly. This exploration does not
claim to have exhausted the design space (Candidate D is open by
construction), so the conclusion is that a dedicated ME is the strongest
realization evaluated here, not that it is the only possible one.

This assessment supports, but does not yet ratify, the three-environment
model (OE, RE, ME). It earns the conclusion from the capabilities rather than
assuming it: the capabilities M1 through M6 are the requirement, and a
dedicated ME is the realization that best satisfies them.

## If ratified: what would follow (not decided here)

If the three-environment model is ratified on the strength of this
assessment, the durable architectural decision would establish: AD-59's
responsibility is to select the boot destination (OE, RE, or ME), not to
select an operating system; ME is a boot destination that is an eligible
policy target but never an automatic policy outcome (M6); and ME has its own
lifecycle distinct from OE's and RE's. The bounded design work that would then
follow, each against that ratified architecture: how explicit maintenance
intent is expressed (parallel to the operator_recovery_request producer); how
ME is represented in the LOM and binding model; whether ME requires its own
published authority or is a fixed destination; and ME's lifecycle (build,
verify, update, rebuild), where the M5 toolset staleness concern is managed.

None of that is decided here. This note establishes the required capabilities
and assesses that a dedicated ME best realizes them; ratifying the
three-environment model, and designing its mechanics, are the next steps if
the assessment is accepted.

## Emerging observation: durability domains (a working hypothesis)

The following is recorded as an EMERGING OBSERVATION, not a ratified
conclusion or a new architectural foundation. It arose while considering
where a Maintenance Environment must live, and it may be a foundational
principle or may be an over-generalization; it is treated here as a working
hypothesis to be tested by whether subsequent design decisions continue to
reinforce it. It is not a decision, and nothing is implemented on its basis.

### The sharpened durability requirement

The maintenance capability requires independent bootability (M1) and
non-destruction of evidence (M4). Considering the installer, which is part of
the maintenance toolset (M5), sharpens these: a Maintenance Environment must
survive the destructive operations it is itself responsible for performing. If
the supported reinstall model destroys and recreates the operational storage,
then a Maintenance Environment stored in that same storage cannot survive the
reinstall it performs. This is not an implementation preference; it is a direct
consequence of M1 and M4 once the maintenance toolset includes an installer
that can destroy the operational storage. A maintenance capability that reaches
into the operational storage to reinstall it must not itself reside in what it
destroys.

### The observation: three durability domains

The sharpened requirement, together with the pre-existing need for persistent
user state to survive operational-system replacement, suggests that a PGSD
system may separate three durability domains, defined not by where data is
stored but by its destruction semantics and the responsibility it serves:

  - Operational execution. Intentionally disposable: the lifecycle is
    permitted to destroy and recreate it during reinstall or replacement. Its
    defining property is that it is replaceable.

  - Lifecycle management. Survives destructive operations on the operational
    domain precisely because it performs them. It holds the maintenance
    capability and the lifecycle tooling. Its defining property is that it
    survives operational-domain destruction because it is the agent of that
    destruction.

  - Persistent user state. Survives destructive operations on the operational
    domain because it must persist across them. Its defining property is
    continuity of user data across replacement of the operational system.

The observation of interest is that the lifecycle-management domain and the
user-state domain both survive operational-domain destruction, but for
different reasons (one is the agent of destruction, one is the data that must
outlive it). Independent requirements converging on the same durability
boundary is the kind of evidence that suggests the boundary is real rather than
imposed. The storage boundaries would then align with responsibility
boundaries: operational execution, lifecycle management, and user state.

On a workstation this decomposition would be realized as three ZFS pools (for
example zroot for operational, maintenance for lifecycle, and zhome for user
state), but the pools are a REALIZATION of the durability-domain separation,
not the observation itself. Whether the same separation holds across other form
factors (servers, appliances, virtual machines), and how it is realized on
each, is open; the observation is stated at the level of the separation, with
the three-pool workstation form as one realization.

### What this clarifies about Recovery and Maintenance

If the durability-domain separation holds, Recovery and Maintenance are
complementary rather than competing, addressing different scopes of failure:

  - Recovery is the designated fallback WITHIN the operational durability
    domain: the response to an operational installation that has broken but
    whose storage is intact, handled by booting a known-good boot environment
    within that domain.

  - Maintenance is the durable capability OUTSIDE the operational durability
    domain: the response to needing to repair or replace the operational
    storage itself, performed from a domain that survives that replacement.

This resolves the earlier become-versus-act-upon distinction into a
storage-grounded one: Recovery becomes the running system from within the
disposable domain; Maintenance acts upon the system from the durable domain.

### The Recovery identity question (routed to the establishment event)

The decomposition raises a question about the Recovery designation, which this
note deliberately does NOT answer here, because it is an establishment-event
and lifecycle-identity question, not a publication-mechanism or
storage-placement one.

The precise framing: replacing the operational storage does not change the
identity of the operational DOMAIN (the domain persists as an architectural
role, before and after). What changes is the identity of the operational
INSTALLATION occupying that domain. The previous operational installation, and
the Recovery Boot Environments belonging to it, cease to exist.

Therefore Recovery is not "whatever the designation points at." Recovery is the
designated Recovery Boot Environment BELONGING TO a particular operational
installation. When that installation is destroyed, Recovery ceases to exist
with it, and the designation cannot remain valid, not because the publication
mechanism failed, but because its referent has ceased to exist. Persisting the
designation beyond destruction of its referent (for example by placing the
publication on a domain that survives the reinstall) would preserve a pointer
to something that no longer exists, which is worse than the designation being
absent.

The consequence is a lifecycle matter, not a storage placement: installation
replacement introduces a lifecycle event whose Recovery-designation semantics
must be defined. The identity discussion establishes WHY the event matters (it
destroys the installation to which any existing designation belongs), and
therefore that the event requires designation semantics; it does not settle
what those semantics are. The candidate outcomes (establish a new designation,
explicitly leave none until establishment, or another lifecycle-defined
outcome) remain policy, deferred to the establishment-event design. This is why
the question belongs to the establishment-event design (where the establishment
contract's authority and verification precondition already live) and not to the
choice of publication mechanism or its storage location. This note records that
installation replacement introduces such an event and routes the definition of
its semantics there; it neither settles those semantics nor decides where the
publication property lives, which follows only after the identity question is
answered.

### Status of this observation

This is a working hypothesis, not a ratified principle and not a new
architectural document. The intended test is whether subsequent Maintenance
and Recovery design decisions continue to be explained by the durability-domain
separation. If they do, the separation will have earned promotion into its own
storage-architecture document as a ratifiable principle. Until then it is
recorded here as an emerging observation that is increasingly explaining
multiple independent design decisions, and nothing (installer changes, pool
creation, import policy, boot flow) is implemented on its basis.

Status: Design exploration (non-ratified). It establishes the maintenance
capabilities M1 through M6 and the separate architectural integration
objective A1, evaluates candidate realizations against both (keeping
capability failures and integration failures distinct), and assesses that a
dedicated Maintenance Environment is the strongest realization identified,
without claiming uniqueness and without ratifying the three-environment model
or designing its mechanics.
