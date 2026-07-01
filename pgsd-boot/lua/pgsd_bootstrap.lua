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
-- Loader Observation Model (AD-59 Parts 9 and 10). Decide, Bind, and Transfer
-- are added as their contracts are implemented.
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
