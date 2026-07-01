# AD-59 Part 10: Concrete Loader Observation Model (LOM v1)

Status: DRAFT MODEL (concrete).

This document makes the Loader Observation Model (Part 9) concrete: it fixes
the observation vocabulary and records, per field, the current producer. It
separates two things that must not be conflated:

  - The observation VOCABULARY is architectural and stable. It defines what
    observations the model exposes.
  - The PRODUCER of each observation is an implementation fact. It records
    which observations currently have a source.

The absence of a producer is itself observable state. A field with no
producer is reported as unavailable; it is not removed from the vocabulary.
This keeps Discover's interface stable: a producer added later fills in an
unavailable field without changing the interface, and versioning is additive.

The producer table was established by read-only reconnaissance on the bench,
which asked, per field: what is its current producer?

## Amendment: recovery_be_present removed (derived fact, not observation)

This revision removes recovery_be_present from the LOM vocabulary. It was
initially listed as an observation, but classifying a boot environment as the
one filling the Recovery role is interpretation over
available_boot_environments plus the binding, which makes it a derived fact,
not a loader-stage observation. By the Part 9 observation/conclusion rule,
derived facts do not belong in the LOM. Discover reports the raw
available_boot_environments; Decide derives whether a Recovery environment is
present, using the binding (Part 7), when policy requires it. This keeps
Discover purely observational and the layering intact. The removal is a
vocabulary change and is recorded as such; it is the LOM's first amendment.

## The observation vocabulary (stable)

LOM v1 defines these observations. Each is a loader-stage observation, stated
as a fact the loader can observe, per the Part 9 observation/conclusion rule.
Each field's value may be a concrete value or the sentinel "unavailable"
(when no producer exists at loader stage yet).

  selected_boot_environment
      The boot environment the loader currently has selected.

  available_boot_environments
      The set of boot environments the loader can enumerate.

  operator_recovery_request
      Whether a loader-stage operator signal requesting recovery is present.
      This is the observation "the signal is present/absent/unavailable," not
      the conclusion "recovery is requested," which is a policy judgment.

  promotion_state
      Loader-readable state reflecting promotion status (per AD-58, owned by
      the promotion authority), as an observed value.

  boot_generation
      A loader-readable identifier distinguishing boot attempts or
      generations, as an observed value.

The vocabulary is finite and versioned. This is LOM v1. Adding an
observation is a new version, an explicit act, not an implicit consequence
of a policy wanting more data.

## Producer table (implementation progress)

Established by read-only bench reconnaissance. This table is implementation
state, not architecture: it will change as producers are implemented, while
the vocabulary above stays stable.

  Observation                  Producer today                    Status
  ---------------------------  --------------------------------  -----------
  selected_boot_environment    loader (currdev, zfs_be_active)   Available
  available_boot_environments  loader (bootenvs[], BE datasets)  Available
  operator_recovery_request    none (AD-11 D4 mechanism unbuilt) Unavailable
  promotion_state              none (AD-58 write path unbuilt)   Unavailable
  boot_generation              none (no boot-completion tracking Unavailable
                               produces a loader-readable id)

Reconnaissance notes:

  - The Available rows were confirmed present in loader-readable form:
    currdev, zfs_be_active, vfs.root.mountfrom, and bootenvs[] appear in
    kenv, and the boot environment datasets are enumerable. These are the
    same loader variables Experiment 3 observed.

  - The Unavailable rows were confirmed to have no producer today. No kenv
    variable reflects recovery request, promotion, or boot generation (the
    only matches for those terms were substrings of the boot environment
    name, not markers). No custom ZFS user property exists on the boot
    environment dataset; only standard properties are present. So these
    observations have no loader-readable source yet.

  - recovery_be_present was removed from the vocabulary (amendment below).
    Whether a boot environment fills the Recovery role is a DERIVED FACT, not
    an observation: it requires classifying a boot environment by role, which
    is interpretation over available_boot_environments plus the binding.
    Classification is Decide/policy work (with Bind's binding), not Discover's.
    Discover reports the raw available_boot_environments; Decide derives
    whether a Recovery environment is present when it needs to. Keeping a
    derived fact out of the LOM preserves the observation/conclusion rule
    (Part 9) and keeps Discover purely observational.

## What this makes implementable now

discover() can be implemented now against the full vocabulary: it reports all
six observations, with the Available fields carrying values from their loader
producers and the Unavailable fields carrying the "unavailable" sentinel.
This is a complete implementation of the LOM, not a partial one; the
vocabulary is fully reported, and unavailability is a legitimate reported
value.

decide() consumes the same vocabulary and must handle unavailable
observations explicitly. The initial policy is a pure function over the
observations that are available, and it must define its behavior when an
observation is unavailable. For example, a minimal initial policy might
select the Recovery role only on operator_recovery_request == requested;
since that observation is unavailable today, such a policy defaults to the
Operational role. That is a complete policy over the current observations,
and it honestly reflects that the operator-signal producer is not yet built,
rather than assuming a producer that does not exist.

## Producers as future work (not part of LOM v1's vocabulary change)

Adding a producer for an Unavailable field is future implementation work that
does NOT change the vocabulary. Each connects to already-identified deferred
work:

  - operator_recovery_request producer: the AD-11 D4 loader-stage mechanism
    (a loader-set variable or menu selection), when built, becomes this
    field's producer.

  - promotion_state producer: the AD-58 promotion write path, when it writes
    loader-readable state, becomes this field's producer. Part 2 fixes the
    promotion authority as the owner; the write path is the deferred
    mechanism.

  - boot_generation producer: a boot-completion tracking mechanism that
    writes a loader-readable identifier, when built, becomes this field's
    producer.

When each producer is implemented, its field moves from Unavailable to
Available in the producer table, with no change to the vocabulary, Discover's
interface, or Decide's contract. Only Decide's policy may then choose to
consume the newly available observation.

## Relationship to the contracts

This concrete LOM is the shared input set Discover's contract (Part 5) and
Decide's contract (Part 6) point to. Discover returns the vocabulary (its P1
to P4); Decide consumes it (its P1, N1). Discover's N4 is bounded by this
vocabulary: gathering an observation not in the LOM violates N4; a field
being unavailable does not (reporting unavailability is reporting the
vocabulary). The vocabulary is loader-stage only; AD-11's post-kernel
machinery remains outside it.

Status: DRAFT MODEL (concrete); LOM v1 vocabulary fixed, producer table
recorded. discover() and decide() are implementable against it now.

Bench: producer table established by read-only reconnaissance on
bare-metal-test-bench (kenv and ZFS property inspection).
