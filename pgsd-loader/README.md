# pgsd-loader

From-scratch Zig EFI boot loader for PGSD, replacing FreeBSD's
stock loader.efi incrementally. The designated successor to
pgsd-boot/ and its lua shims.

Start with docs/adr/0001-architecture-and-staged-replacement.md:
the parent architecture ADR defining the purpose, the chainload
coexistence mechanism, the L0-L5 milestones, and the fallback
invariant every stage must preserve. Stage ADRs live beneath it
in docs/adr/ and are ratified individually, ADR-before-code.

Status: ADR 0001 (parent architecture) ratified, open until
L5. ADR 0002 (kernel sources, loader capability) ratified. ADR
0003 (stage L0) CLOSED 2026-07-08, campaign complete: the L0
loader, deployment tooling, and emulation harnesses are in
service. Next: the product architecture ADR (docs/adr at the
repository root), then stage L3a with BOOT-ARTIFACT-STORE.
