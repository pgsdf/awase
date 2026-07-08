# pgsd-loader

From-scratch Zig EFI boot loader for PGSD, replacing FreeBSD's
stock loader.efi incrementally. This is the AD-56 Phase 3
implementation, tracked as AD-62.

This component owns boot MECHANISM: parsing the kernel, building
the memory map, owning the framebuffer, and performing the kernel
handoff. It is distinct from pgsd-boot/, which owns recovery
POLICY (the AD-59 Lua pipeline that selects a boot environment
from inside the stock loader). The two do not overlap; AD-59's
policy is written to migrate onto this loader in time, at which
point only its loader-specific observation producers change.

Start with docs/adr/0001-architecture-and-staged-replacement.md:
the parent architecture ADR defining the purpose, the chainload
coexistence mechanism, the L0-L5 milestones, and the fallback
invariant every stage must preserve. Stage ADRs live beneath it
in docs/adr/ and are ratified individually, ADR-before-code.

Status: ADR 0001 (parent architecture) ratified, open until
L5. ADR 0002 (kernel sources, loader capability) ratified. ADR
0003 (stage L0) CLOSED 2026-07-08, campaign complete: the L0
loader, deployment tooling, and emulation harnesses are in
service. Project ADR 0001 (boot artifact deployment
architecture) ratified at the repository root. ADR 0004 (stage
L3a) ratified with BOOT-ARTIFACT-STORE 0.3, invariants I1
through I5. Current work: L3a.1, the kernel handoff study
(KERNEL-HANDOFF.md).
