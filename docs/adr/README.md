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

ADR 0001 (boot artifact deployment architecture) is ratified at
revision 2, 2026-07-08: deployment, publication, and durability
contracts; split authority for artifact location; boot
environment interaction as relationship properties; recovery
invariants; and the content, publication, and selection
authority triad. It was drafted after stage L0 completed on the
bench, per the operator sequencing that created this venue, and
every requirement in it traces to a ratified document or a
recorded bench observation.

ADR 0002 (the Awase artifact contract) is ratified 2026-07-10:
building Awase and installing PGSD as independent systems
communicating only through a published artifact contract; the
Publish, Don't Infer and Authority Owns Truth principles as project
law; manifest and inventory as distinct abstractions with identity as
a content hash over filesystem contents; authority factoring between
producer facts and consumer policy; convergence on the Axiom artifact
contract; and a five-milestone, format-first migration whose first
increment separates the kernel build from install.sh.

This README carries no decisions.
