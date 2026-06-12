/*
 * sys/malloc.h shim for the AD-9 fuzz harness.
 *
 * Empty: the symbols this header would have provided come
 * from kernel_shim.h, which is force-included before any
 * other header. This file exists so #include <sys/malloc.h>
 * resolves without bringing in kernel API surface.
 */
