/*-
 * bootcrumb: early-boot progress instrumentation via EFI variables.
 *
 * A console-less kernel that fails before userspace tells you nothing. It
 * is silent by construction: AD-39 removes vt, vt_efifb, sc and vga so
 * that drawfs can own the framebuffer, and the only console left is a
 * UART at a legacy I/O port that Apple hardware does not have. So a
 * kernel that panics, hangs, or blocks at an invisible mountroot> prompt
 * presents identically to one that never started: a blank screen.
 *
 * The L3a bench campaign spent seven armed boots and two reinstalls
 * distinguishing between those cases by inference. Every hour lost was
 * spent reasoning about a machine that could not speak. The two things
 * that actually worked (gdb in emulation; an NVRAM breadcrumb from the
 * loader) each turned a week of guessing into one observation.
 *
 * This is that, from the kernel side. It is deliberately a GENERIC
 * progress facility rather than a fix for any particular failure: the
 * immediate motivation was a root mount that failed invisibly, but the
 * mechanism is useful for any early-boot failure regardless of where it
 * occurs.
 *
 * WHAT IT CANNOT DO, stated plainly.
 *
 * EFI runtime services are not usable until efirt attaches, and efirt is
 * DECLARE_MODULE(efirt, ..., SI_SUB_DRIVERS, SI_ORDER_SECOND). So every
 * stage before SI_SUB_DRIVERS (0x3100000) is unreachable by this
 * mechanism: there is no way to write a variable from early SYSINIT,
 * because the service does not exist yet.
 *
 * That gap is not dark, though. The loader's own NVRAM marker
 * (PgsdBasVerdict = MARK_VMAP_ATTEMPT) proves the jump was taken, so
 * "the kernel was entered" is answered from the other side. What remains
 * unobservable is the window between the jump and SI_SUB_DRIVERS, and
 * this facility does not pretend otherwise.
 *
 * NAMESPACE. These variables are the KERNEL's, in their own GUID, and
 * they never collide with the loader's (PgsdBasVerdict, PgsdModules,
 * which live under the loader's GUID). Who wrote what is never
 * ambiguous.
 *
 * EPHEMERALITY. Each stage overwrites its own variable every boot, and
 * every record carries a boot ID. A stale value from a previous boot is
 * therefore distinguishable from a current one: same variable, different
 * boot ID. Without that, a marker from three boots ago reads exactly like
 * a marker from this one, which is worse than no marker at all.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/efi.h>
#include <sys/sysctl.h>
#include <sys/time.h>

/*
 * The kernel's own vendor GUID, distinct from the loader's
 * (50475344-6261-4c33-8a01-706773646261). Separate namespaces mean the
 * loader and the kernel can never be confused for one another.
 *
 * 50475344-6b72-6e6c-8a02-706773646b72  ("PGSD" + "krnl")
 */
static efi_guid_t bootcrumb_guid = {
	0x50475344,
	0x6b72,
	0x6e6c,
	{ 0x8a, 0x02, 0x70, 0x67, 0x73, 0x64, 0x6b, 0x72 }
};

#define	BOOTCRUMB_ATTR	(EFI_VARIABLE_NON_VOLATILE |			\
			 EFI_VARIABLE_BOOTSERVICE_ACCESS |		\
			 EFI_VARIABLE_RUNTIME_ACCESS)

/*
 * A boot identifier, so a stale marker is distinguishable from a current
 * one. Derived from the boot time, which is set well before
 * SI_SUB_DRIVERS and is unique per boot in practice.
 */
static uint64_t bootcrumb_bootid;

static int bootcrumb_enabled = 1;
SYSCTL_INT(_debug, OID_AUTO, bootcrumb_enabled, CTLFLAG_RWTUN,
    &bootcrumb_enabled, 0,
    "Write early-boot progress breadcrumbs to EFI variables");

/*
 * ASCII to UCS-2, which is what SetVariable takes for a name. Names are
 * short and fixed, so a small fixed buffer is sufficient and avoids
 * allocating in a path that must work when very little is up.
 */
static void
bootcrumb_widen(const char *src, uint16_t *dst, size_t dstlen)
{
	size_t i;

	for (i = 0; i < dstlen - 1 && src[i] != '\0'; i++)
		dst[i] = (uint16_t)(unsigned char)src[i];
	dst[i] = 0;
}

/*
 * Record a stage.
 *
 * Fails silently and completely. This is instrumentation: it must never
 * be the reason a boot fails. A machine that panics because its
 * breadcrumb could not be written has been made worse, not better.
 */
void
bootcrumb_mark(const char *stage, const char *detail)
{
	uint16_t name16[32];
	char payload[128];
	char varname[32];
	int len;

	if (!bootcrumb_enabled)
		return;

	/*
	 * efi_rt_ok() is the whole reason this is safe to call from any
	 * SYSINIT at or after SI_SUB_DRIVERS: before efirt attaches it
	 * returns ENXIO and we simply do nothing. A caller does not have
	 * to know whether the service is up.
	 */
	if (efi_rt_ok() != 0)
		return;

	snprintf(varname, sizeof(varname), "PgsdKernel%s", stage);
	bootcrumb_widen(varname, name16, nitems(name16));

	if (detail != NULL)
		len = snprintf(payload, sizeof(payload), "boot=%ju %s",
		    (uintmax_t)bootcrumb_bootid, detail);
	else
		len = snprintf(payload, sizeof(payload), "boot=%ju",
		    (uintmax_t)bootcrumb_bootid);
	if (len < 0)
		return;

	(void)efi_var_set(name16, &bootcrumb_guid, BOOTCRUMB_ATTR,
	    (size_t)len + 1, payload);
}

/*
 * Stage: EFI runtime services are usable.
 *
 * This is the EARLIEST stage this mechanism can record, and it is a fact
 * worth recording in itself: its presence means the kernel got at least
 * as far as SI_SUB_DRIVERS with a working efirt, which (given F9) is not
 * something to take for granted.
 *
 * SI_ORDER_MIDDLE at SI_SUB_DRIVERS puts this after efirt's
 * SI_ORDER_SECOND.
 */
static void
bootcrumb_early(void *arg __unused)
{

	bootcrumb_bootid = (uint64_t)time_second;
	bootcrumb_mark("EarlyInit", NULL);
}
SYSINIT(bootcrumb_early, SI_SUB_DRIVERS, SI_ORDER_MIDDLE, bootcrumb_early,
    NULL);

/*
 * Stage: init is created, and the root mount is imminent.
 *
 * This is as close to the mount as a MODULE can get, and the limitation
 * is worth stating precisely rather than papering over.
 *
 * vfs_mountroot() is not a SYSINIT. It is called directly from
 * start_init() (sys/kern/init_main.c:746), which runs inside the init
 * process, created by SYSINIT(init, SI_SUB_CREATE_INIT, SI_ORDER_FIRST).
 * So there is no SYSINIT that runs immediately after the mount, and a
 * module cannot bracket it. Bracketing would mean editing
 * vfs_mountroot.c, which AD-57 forbids: the pinned FreeBSD source is not
 * modified.
 *
 * A marker here therefore means: the kernel reached the point where init
 * is created and the root mount is about to be attempted. If this marker
 * is present and the system did not come up, the fault is at or after
 * the root mount.
 *
 * The OTHER half of that discriminator lives in userspace, and it has to:
 * the only thing that proves root was mounted is that something on root
 * ran. See the bootcrumb rc.d service, which writes PgsdKernelRootMounted
 * as early as rc.d allows. PreMountRoot present with no RootMounted is the
 * signature of the entire F13/F15 class (a stale boot environment; a ZFS
 * root with no zfs.ko), and that single distinction would have replaced
 * days of inference.
 *
 * SI_ORDER_ANY at SI_SUB_CREATE_INIT: after create_init's
 * SI_ORDER_FIRST, before the process is scheduled.
 */
static void
bootcrumb_premount(void *arg __unused)
{

	bootcrumb_mark("PreMountRoot", NULL);
}
SYSINIT(bootcrumb_premount, SI_SUB_CREATE_INIT, SI_ORDER_ANY,
    bootcrumb_premount, NULL);
