--
-- pgsd_bootstrap.lua -- AD-59 bootstrap responsibilities (current mechanism)
--
-- This module implements the AD-59 bootstrap responsibilities as a portable
-- unit. Today the mechanism is the FreeBSD Lua loader; local.lua is a thin
-- adapter that requires this module. The module is written to migrate into
-- the future Awase-owned loader (BOOT-PATH-OWNERSHIP): the responsibility
-- structure is loader-agnostic, and the only loader-specific code is the
-- observation producers, which are isolated and marked.
--
-- This file currently implements Discover (AD-59 Part 5), reporting the
-- Loader Observation Model (AD-59 Parts 9 and 10), and Decide (AD-59 Part 6),
-- as the generic evaluator of Part 11 over the ratified Selection Policy v1
-- (Part 12). Bind and Transfer are added as their contracts are implemented.
--

local M = {}

-- The Loader Observation Model version this module implements. The LOM is a
-- versioned data contract (AD-59 Part 10); the observation object carries its
-- version so consumers can rely on a stable identity, not merely "whatever
-- discover() returned."
M.LOM_VERSION = 1

-- Sentinel for an observation whose producer is not implemented at loader
-- stage yet (AD-59 Part 10: absence of a producer is itself observable state;
-- unavailable fields are represented explicitly, never omitted).
M.UNAVAILABLE = "unavailable"

--
-- Roles (AD-59 Part 2).
--
-- Opaque role identities. Decide produces exactly one of these; Bind
-- (Part 7), when implemented, resolves a role to an implementation. Nothing
-- in this module attaches meaning to these values or maps them to boot
-- environments (Decide N2, N5, N6): they are identities the binding will
-- consume.
--
M.ROLE_OPERATIONAL = "operational-role"
M.ROLE_RECOVERY    = "recovery-role"

--
-- Selection Policy v1 (AD-59 Part 12, ratified 2026-07-02).
--
-- The selection policy is DATA, not code: decide() evaluates a policy, it
-- does not contain one (Part 11). This table is the Part 12 artifact
-- rendered as data: ordered rules, first match wins, and a mandatory
-- terminal role, so totality holds by shape. Policy evolution is a new
-- ratified table, never a change to decide().
--
-- lom_version records the LOM version the policy is pinned to (Part 11 W1).
-- Well-formedness was verified at ratification (Part 12 checklist), not at
-- runtime: a policy is a ratified artifact, not untrusted input, so
-- decide() carries no defensive checks (Part 11).
--
M.SELECTION_POLICY_V1 = {
	policy_version = 1,
	lom_version    = 1,
	rules = {
		-- R1: the judgment "recovery is requested," drawn from the
		-- observation "the operator signal is present" (Part 12 value
		-- domain note). The field has no producer today; by E1 this
		-- rule simply fails to match until the AD-11 D4 producer
		-- arrives, and then activates with no code change anywhere.
		{ field = "operator_recovery_request",
		  value = "present",
		  role  = M.ROLE_RECOVERY },
	},
	-- R2: the terminal rule. The Operational default emerges here by
	-- fallthrough; it is not a special case in any code.
	otherwise = M.ROLE_OPERATIONAL,
}

--
-- Decide (AD-59 Part 6): evaluate a selection policy over Discover's
-- observations and produce exactly one role.
--
-- decide() is the generic evaluator of Part 11: it applies the given
-- policy's rules in order, first match wins, and returns the terminal role
-- when no rule matches. It is a pure function over (observations, policy):
-- it consults only Discover's output (P1, N1), reads no loader state, has
-- no side effects, and contains no loader-specific code, so it migrates to
-- the Awase loader unchanged.
--
-- Evaluator ignorance (Part 11):
--   E-N1: no rule, field name, value, or role appears in this function;
--         decide() does not know which policy it evaluates.
--   E-N2: fields are opaque keys; meaning lives in the policy.
--   E-N3: there is no test for the unavailable sentinel anywhere below.
--         E1 (a concrete-value predicate is false against an unavailable
--         observation) is satisfied by plain equality: the sentinel never
--         equals a well-formed concrete value (W2), so the match fails
--         naturally. The sentinel does its job by simply not matching.
--
-- Totality and determinism hold by the policy's shape (ordered rules plus
-- mandatory otherwise), so exactly one role is returned on every input
-- (P2, N3), with no retry, fallback, or alternatives (N4).
--
function M.decide(observations, policy)
	for _, rule in ipairs(policy.rules) do
		if observations[rule.field] == rule.value then
			return rule.role
		end
	end
	return policy.otherwise
end

--
-- Observation producers.
--
-- These are the ONLY loader-specific functions in this module. A port to the
-- Awase loader replaces these producer reads and nothing else; the object
-- shape, the version, and the unavailable handling below are loader-agnostic.
--
-- Each producer performs a read and returns a value. It performs no
-- interpretation (Discover N1), encodes no policy (N2), and has no side
-- effects (N3): these are pure reads.
--

-- selected_boot_environment: the boot environment the loader has selected.
-- Producer: loader environment (zfs_be_active). Available.
local function observe_selected_boot_environment()
	local v = loader.getenv("zfs_be_active")
	if v == nil then
		return M.UNAVAILABLE
	end
	return v
end

-- available_boot_environments: the boot environments the loader can
-- enumerate. Producer: loader (core.bootenvList). Available. Returned raw;
-- classifying any environment by role is Decide's work, not Discover's.
local function observe_available_boot_environments()
	local core = require("core")
	local list = core.bootenvList()
	if list == nil then
		return M.UNAVAILABLE
	end
	return list
end

--
-- Discover (AD-59 Part 5): observe the loader-stage state and return it as a
-- versioned observation object implementing the LOM (AD-59 Part 10).
--
-- Positive obligations: observes (P1) and returns the observations as data
-- (P2); returns exactly the LOM vocabulary, complete against it (P3); and
-- gathers nothing beyond the vocabulary, then stops (P4, N4).
--
-- Negative obligations: no interpretation (N1) -- values are returned as
-- read; no policy (N2) -- no field is weighed or judged; no side effects (N3)
-- -- every producer is a pure read, so discover() is safe to run repeatedly;
-- no collection beyond the LOM (N4) -- exactly the five fields, no more.
--
-- Unavailable fields are represented explicitly with the sentinel, not
-- omitted, so the observation object always has the full LOM shape.
--
function M.discover()
	return {
		lom_version = M.LOM_VERSION,

		-- Available producers (loader-readable today).
		selected_boot_environment   = observe_selected_boot_environment(),
		available_boot_environments = observe_available_boot_environments(),

		-- Unavailable: no loader-stage producer implemented yet. Represented
		-- explicitly (AD-59 Part 10). Producers, when built, replace these
		-- sentinels without changing this object's shape or Discover's
		-- interface:
		--   operator_recovery_request <- AD-11 D4 loader-stage mechanism
		--   promotion_state           <- AD-58 promotion write path
		--   boot_generation           <- boot-completion tracking
		operator_recovery_request   = M.UNAVAILABLE,
		promotion_state             = M.UNAVAILABLE,
		boot_generation             = M.UNAVAILABLE,
	}
end

return M
