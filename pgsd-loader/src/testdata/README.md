# testdata

`mod.o` is a real ELF64 relocatable object, the same class as a FreeBSD
`.ko`. It exists so `module_elf.zig`'s parser is tested against a real
ELF file rather than a synthetic one.

Regenerate with:

    zig cc -c -o mod.o mod.c

It earned its place immediately: testing against it caught an alignment
bug (a pointer cast into an unaligned byte slice) that would have been a
silent misaligned read in the loader, on a machine with no console.
