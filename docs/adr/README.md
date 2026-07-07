# Project architecture ADRs

The project-level ADR series, established 2026-07-07 by operator
ruling. Decisions recorded here are product architecture: they
affect the installer, deployment tooling, activation, rollback,
recovery semantics, and only then individual components. The
dependency direction is one way: subproject ADR series
(pgsd-loader, and in time installer, deployment tooling, recovery
architecture, and future boot-related components) consume the
decisions ratified here; they do not originate them. A subproject
ADR that embeds a product decision is reopened on those grounds
(pgsd-loader ADR 0002 Decision 1 states the rule for its series;
the same rule applies to every series beneath this one).

First planned ADR: the deployment architecture and operational
policy decision deferred by pgsd-loader ADR 0002 Decision 6,
covering whether the boot environment is the canonical upgrade
unit, the deployment publication model, the authoritative kernel
source per environment, and the rollback contract. Per operator
sequencing it is drafted after stage L0 has been demonstrated on
the bench.

Numbering begins at 0001 with the first ADR; this README carries
no decisions.
