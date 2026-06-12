/*
 * kernel_shim.h: kernel-symbol shim for the AD-9 fuzz harness.
 *
 * This header is force-included via -include kernel_shim.h on
 * every translation unit in the harness build. It does two
 * things:
 *
 *   1. Suppresses FreeBSD kernel headers that the vendored
 *      hid.c and inputfs_parser.c try to #include, by
 *      pre-defining each header's include guard.
 *
 *   2. Provides minimal userspace replacements for the
 *      kernel symbols those translation units reference,
 *      using <stdlib.h>, <string.h>, etc. underneath.
 *
 * Strategy is documented in
 * inputfs/docs/adr/0014-hid-fuzzing-scope.md (AD-9.2). The
 * gist: define _STANDALONE so hid.h emits its kernel-side
 * type declarations, then provide stubs for everything those
 * declarations and hid.c's body reference.
 *
 * This header MUST be force-included before any other
 * include processes. Order inside the harness build:
 *   cc -include kernel_shim.h -D_STANDALONE \
 *      -I shim_includes -I vendored \
 *      -I ../../sys/dev/inputfs \
 *      -fsanitize=address \
 *      ...
 *
 * shim_includes/ provides opt_hid.h and hid_if.h replacements
 * (-I order means our shim_includes is searched before
 * vendored/, so our hid_if.h overrides any kernel-build-system
 * version that might otherwise be found).
 */

#ifndef _UTF_KERNEL_SHIM_H_
#define _UTF_KERNEL_SHIM_H_

/*
 * Pre-define `sys/...` include guards so the corresponding
 * #include lines in hid.c become no-ops. We need these
 * because the kernel `sys/...` headers reference identifiers
 * (pcpu_t, struct thread, etc.) that have no userspace
 * meaning; even if they compiled, they would pull in vast
 * amounts of kernel API surface we cannot satisfy.
 *
 * The guard names match what FreeBSD's headers use; see
 * /usr/src/sys/sys/{param,bus,kdb,kernel,malloc,module,
 * sysctl,systm}.h for confirmation.
 */
#define _SYS_PARAM_H_
#define _SYS_BUS_H_
#define _SYS_KDB_H_
#define _SYS_KERNEL_H_
#define _SYS_MALLOC_H_
#define _SYS_MODULE_H_
#define _SYS_SYSCTL_H_
#define _SYS_SYSTM_H_

/*
 * Now bring in the real userspace headers we use to
 * replace the suppressed kernel ones.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/*
 * _STANDALONE activates the gated declarations in
 * <dev/hid/hid.h> (see hid.h's `#if defined(_KERNEL) ||
 * defined(_STANDALONE)` block) without dragging in
 * kernel-mode semantics from `sys/...` headers.
 *
 * Defined at the top of this header rather than via -D on
 * the command line so the kernel-shim discipline is
 * documented in one place.
 */
#ifndef _STANDALONE
#define _STANDALONE
#endif

/*
 * Minimal device-tree types and functions referenced by
 * hid.c's wrapper functions. The harness never calls those
 * wrappers, but they must compile; the wrappers expand the
 * HID_* macros from shim_includes/hid_if.h with these
 * arguments.
 */
typedef void *device_t;

static inline device_t
device_get_parent(device_t dev)
{
	(void)dev;
	return ((device_t)NULL);
}

/*
 * MALLOC family: hid.c calls
 *   malloc(size, M_TEMP, M_WAITOK | M_ZERO)
 *   free(ptr, M_TEMP)
 *
 * In userspace we replace with calloc/free that ignore the
 * type and flag arguments, except that M_ZERO requests
 * zero-initialised memory (which we get from calloc). We
 * cannot use a function-style replacement because the kernel
 * malloc/free have different signatures; we use macros that
 * shadow them at the source level. The arguments are
 * evaluated exactly once.
 *
 * Note: <stdlib.h> declares the userspace malloc and free.
 * Our macros below shadow those names within this
 * translation unit. inputfs_parser.c uses memset/sizeof
 * only, not malloc; vendored hid.c is the only consumer.
 */
#define M_TEMP   ((void *)0)
#define M_WAITOK 0
#define M_ZERO   1

/*
 * Implementation note: kernel malloc evaluates `flags` for
 * M_ZERO at runtime. We honour that by using calloc when
 * M_ZERO is set, malloc otherwise. The expression is
 * evaluated once via a temporary.
 */
static inline void *
__shim_malloc(size_t size, void *type, int flags)
{
	(void)type;
	if (flags & M_ZERO)
		return calloc(1, size);
	return malloc(size);
}

static inline void
__shim_free(void *ptr, void *type)
{
	(void)type;
	free(ptr);
}

#define malloc(size, type, flags) __shim_malloc((size), (type), (flags))
#define free(ptr, type)           __shim_free((ptr), (type))

/* MALLOC_DECLARE / MALLOC_DEFINE: declare/define a memory type. No-ops. */
#define MALLOC_DECLARE(type) \
	extern char __shim_malloc_unused_##type
#define MALLOC_DEFINE(type, name, desc) \
	char __shim_malloc_unused_##type

/*
 * SYSCTL family: hid.c declares a sysctl tree and an int
 * variable for hid_debug at file scope. None of these have
 * any effect in the harness; we make them all no-ops.
 *
 * SYSCTL_NODE and SYSCTL_INT both take a long argument list
 * and are used at file scope, so they must expand to
 * something a C compiler accepts at file scope. We use a
 * static-storage stub variable per macro invocation,
 * disambiguated by the OID name.
 */
#define SYSCTL_DECL(name)
#define SYSCTL_NODE(parent, nbr, name, access, handler, descr) \
	static const int __shim_sysctl_node_##name = 0
#define SYSCTL_INT(parent, nbr, name, access, ptr, val, descr) \
	static const int __shim_sysctl_int_##name = 0
#define CTLFLAG_RW    0
#define CTLFLAG_RWTUN 0
#define OID_AUTO      0

/*
 * Module registration: no-op.
 */
#define MODULE_VERSION(name, version) \
	static const int __shim_modver_##name = (version)

/*
 * KASSERT / kdb hooks: hid.c does not call KASSERT directly,
 * but hid.h defines HID_IN_POLLING_MODE() in terms of
 * SCHEDULER_STOPPED() and kdb_active. inputfs_parser.c does
 * not reference HID_IN_POLLING_MODE either, but if it did,
 * the answer in userspace is "no, never": we are not a
 * panicking kernel, and we are not in a debugger.
 */
#define SCHEDULER_STOPPED() (0)
static const int kdb_active = 0;

/*
 * pause / hz: referenced by hid_quirk_unload (which the
 * harness never calls). Make pause a no-op and hz a
 * non-zero placeholder so any "tick count" arithmetic
 * elsewhere in hid.c does not divide by zero.
 */
#define hz 100
static inline void
pause(const char *wmesg, int timo)
{
	(void)wmesg;
	(void)timo;
}

/*
 * bootverbose: a kernel global controlling whether boot-time
 * messages are printed. Always false in the harness.
 */
static const int bootverbose = 0;

/*
 * nitems: FreeBSD's <sys/param.h> defines nitems(x) as
 * (sizeof(x) / sizeof((x)[0])). hid.c uses it once in
 * hid_item_resolution.
 */
#ifndef nitems
#define nitems(x) (sizeof(x) / sizeof((x)[0]))
#endif

#endif /* _UTF_KERNEL_SHIM_H_ */
