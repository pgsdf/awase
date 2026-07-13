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
#include <machine/cpu.h>	/* get_cyclecount */

/*
 * The kernel's own vendor GUID, distinct from the loader's
 * (50475344-6261-4c33-8a01-706773646261). Separate namespaces mean the
 * loader and the kernel can never be confused for one another.
 *
 * 50475344-6b72-6e6c-8a02-706773646b72  ("PGSD" + "krnl")
 */
static efi_guid_t bootcrumb_guid = {
	.Data1 = 0x50475344,
	.Data2 = 0x6b72,
	.Data3 = 0x6e6c,
	.Data4 = { 0x8a, 0x02, 0x70, 0x67, 0x73, 0x64, 0x6b, 0x72 }
};

/*
 * UEFI variable attributes.
 *
 * Defined here rather than included: the kernel does not export these.
 * sys/sys/efi.h has none of them, and the only definitions in the tree
 * are in sys/contrib/edk2/Include/Uefi/UefiMultiPhase.h, which is an
 * EDK2 contrib header a driver has no business including. The existing
 * kernel EFI code (sys/dev/efidev/efidev.c) does not define them either:
 * it passes the attribute word straight through from userspace.
 *
 * These are the values from the UEFI specification and they are stable.
 *
 * NON_VOLATILE is the one that matters: without it the variable does not
 * survive the reboot, and a breadcrumb that does not survive the reboot
 * answers nothing, because the reboot is exactly when we come to read it.
 */
#define	BC_VAR_NON_VOLATILE		0x00000001
#define	BC_VAR_BOOTSERVICE_ACCESS	0x00000002
#define	BC_VAR_RUNTIME_ACCESS		0x00000004

#define	BOOTCRUMB_ATTR	(BC_VAR_NON_VOLATILE |				\
			 BC_VAR_BOOTSERVICE_ACCESS |			\
			 BC_VAR_RUNTIME_ACCESS)

/*
 * A boot identifier, so a stale marker is distinguishable from a current
 * one.
 *
 * NOT derived from time_second, which was the first attempt and was
 * wrong. sys/kern/kern_tc.c declares `volatile time_t time_second = 1`,
 * and it only becomes wall-clock time when inittodr() runs, which is
 * AFTER SI_SUB_DRIVERS. At marker time it is a tick counter, not a
 * timestamp: the first boot recorded "boot=466227", which is plainly not
 * a Unix epoch.
 *
 * Worse, it made the id USELESS for its actual purpose. Userspace
 * computed its own id from a real clock, so the kernel's id and the rc.d
 * id could never match, and matching them is the entire point: an id you
 * cannot correlate across markers cannot tell you whether two markers
 * came from the same boot.
 *
 * So the kernel generates the id ONCE, from the cycle counter (which is
 * running long before SI_SUB_DRIVERS and differs every boot), and
 * publishes it as a sysctl. Userspace READS it rather than inventing its
 * own. One id, one source, correlatable across every marker.
 */
static uint64_t bootcrumb_bootid;

SYSCTL_U64(_debug, OID_AUTO, bootcrumb_bootid, CTLFLAG_RD,
    &bootcrumb_bootid, 0,
    "Boot identifier stamped into the bootcrumb EFI variables");

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
static void
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

	/*
	 * get_cyclecount() is running long before SI_SUB_DRIVERS and its
	 * low bits differ on every boot, which is all a boot id needs: it
	 * must distinguish THIS boot's markers from a previous boot's, not
	 * be a timestamp.
	 */
	bootcrumb_bootid = (uint64_t)get_cyclecount();
	bootcrumb_mark("EarlyInit", NULL);
}
SYSINIT(bootcrumb_early, SI_SUB_DRIVERS, SI_ORDER_MIDDLE, bootcrumb_early,
    NULL);

/*
 * Stage: the root mount is about to begin.
 *
 * PLACEMENT, and the first attempt got this wrong in a way worth
 * recording, because the mistake was to violate a constraint documented
 * three paragraphs above it in this same file.
 *
 * The marker was first placed at SI_SUB_CREATE_INIT, on the reasoning
 * that create_init() is what leads to start_init() and thus to
 * vfs_mountroot(). That is true, and it does not matter, because
 * SI_SUB_CREATE_INIT is 0x2500000 and SI_SUB_DRIVERS is 0x3100000: it
 * runs BEFORE efirt attaches. efi_rt_ok() returned ENXIO, the marker
 * correctly did nothing, and the variable never appeared. The facility
 * behaved exactly as designed; the placement was wrong.
 *
 * The right anchor is kick_init(), which is what makes the init process
 * RUNNABLE and therefore what actually starts start_init() and the mount:
 *
 *     SYSINIT(kickinit, SI_SUB_KTHREAD_INIT, SI_ORDER_MIDDLE,
 *             kick_init, NULL);       (sys/kern/init_main.c:874)
 *
 * SI_SUB_KTHREAD_INIT is 0xe000000, comfortably after SI_SUB_DRIVERS. So
 * SI_ORDER_FIRST at that subsystem runs after efirt is up and before init
 * is kicked, which is precisely "the mount is about to begin".
 *
 * A marker here means the kernel got all the way to the point where the
 * root mount starts. If it is present and the system did not come up, the
 * fault is at or after the root mount.
 *
 * The OTHER half of the discriminator lives in userspace, and it has to:
 * the only thing that proves root was mounted is that something living on
 * root ran. See the bootcrumb rc.d service, which writes
 * PgsdKernelRootMounted. PreMountRoot present with RootMounted absent is
 * the signature of the entire F13/F15 class (a stale boot environment; a
 * ZFS root with no zfs.ko), and that single distinction would have
 * replaced days of inference.
 */
static void
bootcrumb_premount(void *arg __unused)
{

	bootcrumb_mark("PreMountRoot", NULL);
}
SYSINIT(bootcrumb_premount, SI_SUB_KTHREAD_INIT, SI_ORDER_FIRST,
    bootcrumb_premount, NULL);
