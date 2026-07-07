# pgsd-loader

From-scratch Zig EFI boot loader for PGSD, replacing FreeBSD's
stock loader.efi incrementally. The designated successor to
pgsd-boot/ and its lua shims.

Start with docs/adr/0001-architecture-and-staged-replacement.md:
the parent architecture ADR defining the purpose, the chainload
coexistence mechanism, the L0-L5 milestones, and the fallback
invariant every stage must preserve. Stage ADRs live beneath it
in docs/adr/ and are ratified individually, ADR-before-code.

Status: architecture ratified (ADR 0001 revision 2,
2026-07-07); no stage ADR ratified; no code.
