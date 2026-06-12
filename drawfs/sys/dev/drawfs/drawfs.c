/*
 * drawfs.c - FreeBSD character device for graphics protocol
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/conf.h>
#include <sys/module.h>
#include <sys/malloc.h>
#include <sys/errno.h>
#include <sys/uio.h>
#include <sys/selinfo.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/condvar.h>
#include <sys/poll.h>
#include <sys/queue.h>
#include <sys/fcntl.h>
#include <sys/sysctl.h>
#include <vm/vm.h>
#include <vm/vm_object.h>

#include "drawfs.h"
#include "drawfs_proto.h"
#include "drawfs_internal.h"
#include "drawfs_surface.h"
#ifdef DRAWFS_DRM_ENABLED
#include "drawfs_drm.h"
#endif
#include "drawfs_efifb.h"
#include "drawfs_frame.h"

MALLOC_DEFINE(M_DRAWFS, "drawfs", "drawfs session and object memory");

/*
 * Sysctl tunable security settings.
 *
 * These can be set via loader.conf (boot-time) or sysctl (runtime for some).
 * Device permissions are only applied at module load time.
 */
static SYSCTL_NODE(_hw, OID_AUTO, drawfs, CTLFLAG_RW | CTLFLAG_MPSAFE, 0,
    "drawfs driver parameters");

static int drawfs_dev_uid = 0;
SYSCTL_INT(_hw_drawfs, OID_AUTO, dev_uid, CTLFLAG_RWTUN,
    &drawfs_dev_uid, 0,
    "Device node owner UID (applied at module load)");

static int drawfs_dev_gid = 0;
SYSCTL_INT(_hw_drawfs, OID_AUTO, dev_gid, CTLFLAG_RWTUN,
    &drawfs_dev_gid, 0,
    "Device node group GID (applied at module load)");

static int drawfs_dev_mode = 0600;
SYSCTL_INT(_hw_drawfs, OID_AUTO, dev_mode, CTLFLAG_RWTUN,
    &drawfs_dev_mode, 0,
    "Device node permissions (applied at module load)");

static int drawfs_mmap_enabled = 1;
SYSCTL_INT(_hw_drawfs, OID_AUTO, mmap_enabled, CTLFLAG_RW,
    &drawfs_mmap_enabled, 0,
    "Allow mmap of surface memory (1=enabled, 0=disabled)");

/*
 * Tunable resource limits.
 *
 * These can be adjusted at runtime via sysctl. Changes take effect for new
 * operations; existing sessions/surfaces are not retroactively affected.
 */
int drawfs_max_evq_bytes = DRAWFS_MAX_EVQ_BYTES;
SYSCTL_INT(_hw_drawfs, OID_AUTO, max_evq_bytes, CTLFLAG_RW,
    &drawfs_max_evq_bytes, 0,
    "Maximum event queue bytes per session (default: 8192)");

int drawfs_max_surfaces = DRAWFS_MAX_SURFACES;
SYSCTL_INT(_hw_drawfs, OID_AUTO, max_surfaces, CTLFLAG_RW,
    &drawfs_max_surfaces, 0,
    "Maximum surfaces per session (default: 64)");

long drawfs_max_surface_bytes = DRAWFS_MAX_SURFACE_BYTES;
SYSCTL_LONG(_hw_drawfs, OID_AUTO, max_surface_bytes, CTLFLAG_RW,
    &drawfs_max_surface_bytes, 0,
    "Maximum bytes per surface (default: 64MB)");

long drawfs_max_session_surface_bytes = DRAWFS_MAX_SESSION_SURFACE_BYTES;
SYSCTL_LONG(_hw_drawfs, OID_AUTO, max_session_surface_bytes, CTLFLAG_RW,
    &drawfs_max_session_surface_bytes, 0,
    "Maximum cumulative surface bytes per session (default: 256MB)");

static int drawfs_coalesce_events = 1;
SYSCTL_INT(_hw_drawfs, OID_AUTO, coalesce_events, CTLFLAG_RW,
    &drawfs_coalesce_events, 0,
    "Coalesce repeated SURFACE_PRESENTED events (1=enabled, 0=disabled)");

/*
 * Debug counters for vm_object lifecycle tracking.
 *
 * These read-only counters track global vm_object allocations and
 * deallocations across all sessions. Useful for detecting leaks:
 * vmobj_allocs - vmobj_deallocs should equal zero after all sessions close.
 */
volatile u_int drawfs_vmobj_allocs = 0;
SYSCTL_UINT(_hw_drawfs, OID_AUTO, vmobj_allocs, CTLFLAG_RD,
    __DEVOLATILE(u_int *, &drawfs_vmobj_allocs), 0,
    "Total vm_object allocations (debug)");

volatile u_int drawfs_vmobj_deallocs = 0;
SYSCTL_UINT(_hw_drawfs, OID_AUTO, vmobj_deallocs, CTLFLAG_RD,
    __DEVOLATILE(u_int *, &drawfs_vmobj_deallocs), 0,
    "Total vm_object deallocations (debug)");

/*
 * Install-race counter (AD-18.2). Incremented when a concurrent mmap
 * races and installs a vm_object on the same surface during our
 * unlocked vm_pager_allocate window; we deallocate our redundant
 * allocation and use the winner's. Should be 0 on single-threaded
 * workloads; non-zero values quantify install-race frequency.
 */
volatile u_int drawfs_vmobj_install_lost = 0;
SYSCTL_UINT(_hw_drawfs, OID_AUTO, vmobj_install_lost, CTLFLAG_RD,
    __DEVOLATILE(u_int *, &drawfs_vmobj_install_lost), 0,
    "vm_object install races lost to a concurrent mmap (debug)");

/*
 * Inbuf grow-race counter (AD-18.3). Incremented when our
 * pre-allocated grow buffer is unneeded after re-acquiring the lock
 * (because another writer grew the buffer, or try_process_inbuf
 * consumed enough bytes to make room). We free our redundant
 * allocation and append in place. Should be 0 on single-threaded
 * workloads.
 */
volatile u_int drawfs_inbuf_grow_race_lost = 0;
SYSCTL_UINT(_hw_drawfs, OID_AUTO, inbuf_grow_race_lost, CTLFLAG_RD,
    __DEVOLATILE(u_int *, &drawfs_inbuf_grow_race_lost), 0,
    "input-buffer grow races lost to a concurrent writer (debug)");

/*
 * Frame extraction race-loss counter (AD-18.4). Incremented when our
 * pre-allocated extraction buffer is unusable after re-acquiring the
 * lock (because another concurrent extractor consumed the frame at
 * the head of inbuf). We free our buffer and retry the extraction
 * loop. Should be 0 on single-threaded workloads.
 */
volatile u_int drawfs_frame_extract_race_lost = 0;
SYSCTL_UINT(_hw_drawfs, OID_AUTO, frame_extract_race_lost, CTLFLAG_RD,
    __DEVOLATILE(u_int *, &drawfs_frame_extract_race_lost), 0,
    "frame-extraction races lost to a concurrent extractor (debug)");

/*
 * EFI framebuffer geometry sysctls (Stage D.2).
 *
 * Exposes the EFI framebuffer's width, height, stride, and
 * bits-per-pixel under hw.drawfs.efifb.* so other kernel modules
 * (notably inputfs, which needs display dimensions to clamp
 * pointer coordinates to compositor space) can read them via
 * kernel_sysctlbyname without taking a hard module dependency
 * on drawfs.
 *
 * Values are populated by drawfs_efifb_init at module load and
 * do not change during the module's lifetime. The handler reads
 * via the existing accessor functions in drawfs_efifb.h rather
 * than referencing the static drawfs_efifb struct, preserving
 * the encapsulation already in place.
 *
 * If drawfs_efifb_init failed (no EFI framebuffer available, or
 * pmap_mapdev_attr returned 0), the accessors return 0 and the
 * sysctls report 0; consumers must handle that case.
 */
static SYSCTL_NODE(_hw_drawfs, OID_AUTO, efifb,
    CTLFLAG_RD | CTLFLAG_MPSAFE, 0,
    "EFI framebuffer geometry");

static int
drawfs_efifb_sysctl_width(SYSCTL_HANDLER_ARGS)
{
	u_int v = drawfs_efifb_width();
	return (sysctl_handle_int(oidp, &v, 0, req));
}
SYSCTL_PROC(_hw_drawfs_efifb, OID_AUTO, width,
    CTLTYPE_UINT | CTLFLAG_RD | CTLFLAG_MPSAFE,
    NULL, 0, drawfs_efifb_sysctl_width, "IU",
    "EFI framebuffer width in pixels");

static int
drawfs_efifb_sysctl_height(SYSCTL_HANDLER_ARGS)
{
	u_int v = drawfs_efifb_height();
	return (sysctl_handle_int(oidp, &v, 0, req));
}
SYSCTL_PROC(_hw_drawfs_efifb, OID_AUTO, height,
    CTLTYPE_UINT | CTLFLAG_RD | CTLFLAG_MPSAFE,
    NULL, 0, drawfs_efifb_sysctl_height, "IU",
    "EFI framebuffer height in pixels");

static int
drawfs_efifb_sysctl_stride(SYSCTL_HANDLER_ARGS)
{
	u_int v = drawfs_efifb_stride();
	return (sysctl_handle_int(oidp, &v, 0, req));
}
SYSCTL_PROC(_hw_drawfs_efifb, OID_AUTO, stride,
    CTLTYPE_UINT | CTLFLAG_RD | CTLFLAG_MPSAFE,
    NULL, 0, drawfs_efifb_sysctl_stride, "IU",
    "EFI framebuffer stride in bytes per scanline");

static int
drawfs_efifb_sysctl_bpp(SYSCTL_HANDLER_ARGS)
{
	u_int v = drawfs_efifb_bpp();
	return (sysctl_handle_int(oidp, &v, 0, req));
}
SYSCTL_PROC(_hw_drawfs_efifb, OID_AUTO, bpp,
    CTLTYPE_UINT | CTLFLAG_RD | CTLFLAG_MPSAFE,
    NULL, 0, drawfs_efifb_sysctl_bpp, "IU",
    "EFI framebuffer bits per pixel");

/*
 * Locking model:
 *
 * Each session has a mutex (s->lock) that protects:
 *   - Event queue (evq, evq_bytes)
 *   - Session state (closing flag, active_display_*, map_surface_id)
 *   - Input buffer (inbuf, in_len, in_cap)
 *   - Statistics counters (stats.*)
 *   - Condition variable and select info (cv, sel)
 *
 * Surface list (s->surfaces) is also protected by s->lock. See drawfs_surface.c.
 *
 * DF-6 (ADR 0002): the DRM display lock order is
 *     s->lock  ->  dd->drm_mtx
 * The SURFACE_PRESENT path holds s->lock across the DRM present so
 * the surface and its vm_object stay alive; the present acquires
 * dd->drm_mtx inside that hold. No DRM path acquires a session lock,
 * so the order cannot invert. drawfs_drm_display_mtx (guarding the
 * global display pointer) is a leaf taken only briefly and never
 * held with s->lock.
 *
 * Locking rules:
 *   - Never hold s->lock while calling malloc() with M_WAITOK
 *   - Never hold s->lock when calling vm_pager_allocate or vm_object_deallocate
 *   - Never hold s->lock when calling drawfs_reply_*, drawfs_send_reply,
 *     or drawfs_enqueue_event; they acquire s->lock internally. Stats
 *     updates around such calls use the take-update-release pattern:
 *     mtx_lock; s->stats.X++; mtx_unlock; reply_call();
 *   - Callbacks (d_open, d_close, d_read, d_write, d_poll) acquire lock as needed
 *   - Helper functions document whether they acquire lock or expect caller to hold it
 */

static int drawfs_open(struct cdev *dev, int oflags, int devtype, struct thread *td);
static int drawfs_close(struct cdev *dev, int fflag, int devtype, struct thread *td);
static int drawfs_read(struct cdev *dev, struct uio *uio, int ioflag);
static int drawfs_write(struct cdev *dev, struct uio *uio, int ioflag);
static int drawfs_poll(struct cdev *dev, int events, struct thread *td);
static int drawfs_mmap_single(struct cdev *dev, vm_ooffset_t *offset, vm_size_t size, struct vm_object **objp, int nprot);
static int drawfs_ioctl(struct cdev *dev, u_long cmd, caddr_t data, int fflag, struct thread *td);

static void drawfs_session_free(struct drawfs_session *s);
static int drawfs_enqueue_event(struct drawfs_session *s, const void *buf, size_t len);
static int drawfs_try_coalesce_presented(struct drawfs_session *s, uint32_t surface_id, uint64_t new_cookie);

static int drawfs_reply_error(struct drawfs_session *s, uint32_t msg_id, uint32_t err_code, uint32_t err_offset);
static int drawfs_reply_hello(struct drawfs_session *s, uint32_t msg_id);
static int drawfs_reply_display_list(struct drawfs_session *s, uint32_t msg_id);
static int drawfs_reply_display_open(struct drawfs_session *s, uint32_t msg_id, const uint8_t *payload, size_t payload_len);
static int drawfs_reply_surface_create(struct drawfs_session *s, uint32_t msg_id, const uint8_t *payload, size_t payload_len);
static int drawfs_reply_surface_destroy(struct drawfs_session *s, uint32_t msg_id, const uint8_t *payload, size_t payload_len);
static int drawfs_reply_surface_present(struct drawfs_session *s, uint32_t msg_id, const uint8_t *payload, size_t payload_len);

static int drawfs_process_frame(struct drawfs_session *s, const uint8_t *buf, size_t n);

static int drawfs_ingest_bytes(struct drawfs_session *s, const uint8_t *buf, size_t n);
static int drawfs_try_process_inbuf(struct drawfs_session *s);

static int drawfs_send_reply(struct drawfs_session *s, uint16_t msg_type,
    uint32_t msg_id, const void *payload, size_t payload_len);

static struct cdev *drawfs_dev;

/*
 * Global session registry.
 *
 * All open sessions are linked here so that DRAWFSGIOC_INJECT_INPUT can
 * find the session that owns a given surface_id without requiring the
 * injector to hold the target fd.
 *
 * drawfs_global_mtx protects g_sessions. Session-local state is still
 * protected by the per-session s->lock.
 */
static struct mtx drawfs_global_mtx;
MTX_SYSINIT(drawfs_global, &drawfs_global_mtx, "drawfs_global", MTX_DEF);

static TAILQ_HEAD(, drawfs_session) g_sessions =
    TAILQ_HEAD_INITIALIZER(g_sessions);

#ifdef DRAWFS_DRM_ENABLED
/*
 * DF-6 (ADR 0002, D1): the DRM display is a single global resource.
 * One compositor owns one screen and all sessions present through
 * it, so the display is global rather than per-session. The pointer
 * is opened lazily on the first SET_DISPLAY while the backend is
 * "drm" and closed at module unload. drawfs_drm_display_mtx guards
 * the pointer and is kept separate from drawfs_global_mtx so the
 * session-registry lock order stays independent of the display lock.
 * drawfs_backend is defined with the backend sysctl far below; it is
 * declared here so the present/SET_DISPLAY paths can gate on it.
 */
extern char drawfs_backend[16];
static struct mtx drawfs_drm_display_mtx;
MTX_SYSINIT(drawfs_drm_display, &drawfs_drm_display_mtx,
    "drawfs_drm_display", MTX_DEF);
static struct drawfs_drm_display *g_drm_display = NULL;
#endif

/*
 * Find the session that owns surface_id.
 * Caller must hold drawfs_global_mtx.
 * Returns a session with its lock held, or NULL if not found.
 *
 * AD-18.1: previously called drawfs_surface_lookup() while holding
 * s->lock, which recurses on the non-recursive mutex and panics under
 * INVARIANTS. Switched to drawfs_surface_lookup_locked() which expects
 * the caller to hold the lock and asserts it.
 */
static struct drawfs_session *
drawfs_find_session_for_surface_locked(uint32_t surface_id)
{
    struct drawfs_session *s;
    TAILQ_FOREACH(s, &g_sessions, g_link) {
        mtx_lock(&s->lock);
        if (!s->closing && drawfs_surface_lookup_locked(s, surface_id) != NULL)
            return (s);   /* return with s->lock held */
        mtx_unlock(&s->lock);
    }
    return (NULL);
}

static struct cdevsw drawfs_cdevsw = {
    .d_version = D_VERSION,
    .d_open = drawfs_open,
    .d_close = drawfs_close,
    .d_read = drawfs_read,
    .d_write = drawfs_write,
    .d_ioctl = drawfs_ioctl,
    .d_mmap_single = drawfs_mmap_single,
    .d_poll = drawfs_poll,
    .d_name = DRAWFS_DEVNAME,
};

/*
 * Step 11: mmap backing store for a selected surface.
 * Gated by hw.drawfs.mmap_enabled sysctl for security.
 */
static int
drawfs_mmap_single(struct cdev *dev, vm_ooffset_t *offset, vm_size_t size,
    struct vm_object **objp, int nprot)
{
    struct drawfs_session *s;
    vm_object_t obj;
    int status;

    (void)dev;
    (void)nprot;

    /* Check sysctl gate before allowing mmap. */
    if (!drawfs_mmap_enabled)
        return (EPERM);

    if (offset == NULL || objp == NULL)
        return (EINVAL);

    if (*offset != 0)
        return (EINVAL);

    if (size == 0)
        return (EINVAL);

    if (devfs_get_cdevpriv((void **)&s) != 0 || s == NULL)
        return (ENXIO);

    obj = drawfs_surface_get_vmobj(s, size, &status);
    if (obj == NULL)
        return (status);

    *objp = obj;
    return (0);
}

static void
drawfs_priv_dtor(void *data)
{
    struct drawfs_session *s = (struct drawfs_session *)data;
    drawfs_session_free(s);
}

/*
 * Step 10B: SURFACE_DESTROY
 */
static int
drawfs_reply_surface_destroy(struct drawfs_session *s, uint32_t msg_id,
    const uint8_t *payload, size_t payload_len)
{
    struct drawfs_surface_destroy_req req;
    struct drawfs_surface_destroy_rep rep;
    int err;

    rep.status = 0;
    rep.surface_id = 0;

    if (payload_len < sizeof(req)) {
        rep.status = EINVAL;
        goto send_reply;
    }

    memcpy(&req, payload, sizeof(req));
    rep.surface_id = req.surface_id;

    err = drawfs_surface_destroy(s, req.surface_id);
    if (err != 0)
        rep.status = err;

send_reply:
    return drawfs_send_reply(s, DRAWFS_RPL_SURFACE_DESTROY, msg_id, &rep, sizeof(rep));
}

/*
 * Step 12: SURFACE_PRESENT
 */
static int
drawfs_reply_surface_present(struct drawfs_session *s, uint32_t msg_id,
    const uint8_t *payload, size_t payload_len)
{
    struct drawfs_req_surface_present req;
    struct {
        uint32_t surface_id;
        uint64_t cookie;
    } __packed req12;
    struct drawfs_surface *surf;
    struct drawfs_rpl_surface_present rep;
    struct drawfs_evt_surface_presented evt;
    uint32_t surface_id;
    uint64_t cookie;
    int err;

    bzero(&rep, sizeof(rep));
    bzero(&req, sizeof(req));
    bzero(&req12, sizeof(req12));
    surface_id = 0;
    cookie = 0;

    /*
     * Accept two encodings for SURFACE_PRESENT payload:
     *   - 16 bytes: { uint32 surface_id, uint32 rsv, uint64 cookie }
     *   - 12 bytes: { uint32 surface_id, uint64 cookie } (legacy tests)
     */
    if (payload_len >= sizeof(req)) {
        bcopy(payload, &req, sizeof(req));
        surface_id = req.surface_id;
        cookie = req.cookie;
    } else if (payload_len >= sizeof(req12)) {
        bcopy(payload, &req12, sizeof(req12));
        surface_id = req12.surface_id;
        cookie = req12.cookie;
    } else {
        rep.status = EINVAL;
        rep.surface_id = 0;
        rep.cookie = 0;
        goto send_reply;
    }

    if ((s->active_display_id == 0 && s->active_display_handle == 0) || surface_id == 0) {
        rep.status = EINVAL;
        rep.surface_id = 0;
        rep.cookie = cookie;
        goto send_reply;
    }

    surf = drawfs_surface_lookup(s, surface_id);
    if (surf == NULL) {
        rep.status = ENOENT;
        rep.surface_id = 0;
        rep.cookie = cookie;
        goto send_reply;
    }

    /* Success */
    rep.status = 0;
    rep.surface_id = surface_id;
    rep.cookie = cookie;

#ifdef DRAWFS_DRM_ENABLED
    /*
     * DF-6 (ADR 0002, D2/D3): when the backend is "drm" and the
     * global display is open, drive a real page flip. The reply and
     * the SURFACE_PRESENTED event below are sent regardless of
     * backend, so client protocol behaviour is unchanged; only the
     * pixel destination differs. surf was found by the unlocked
     * drawfs_surface_lookup above, whose pointer is not lifetime-safe
     * once s->lock is dropped, so we re-find it under a held s->lock
     * (drawfs_surface_lookup_locked, AD-18.1) and keep the lock
     * across the present. This establishes the documented order
     * s->lock -> dd->drm_mtx (the DRM backend never takes a session
     * lock, so no inversion exists).
     */
    {
        struct drawfs_drm_display *dd;

        mtx_lock(&drawfs_drm_display_mtx);
        dd = (strncmp(drawfs_backend, "drm", 3) == 0) ? g_drm_display : NULL;
        mtx_unlock(&drawfs_drm_display_mtx);

        if (dd != NULL) {
            struct drawfs_surface *psurf;

            mtx_lock(&s->lock);
            psurf = drawfs_surface_lookup_locked(s, surface_id);
            if (psurf != NULL)
                (void)drawfs_drm_surface_present(dd, psurf, NULL, 0);
            mtx_unlock(&s->lock);
        }
    }
#endif

send_reply:
    err = drawfs_send_reply(s, DRAWFS_RPL_SURFACE_PRESENT, msg_id, &rep, sizeof(rep));
    if (err != 0)
        return (err);

    /* Only emit the async "presented" event on success. */
    if (rep.status != 0)
        return (0);

    evt.surface_id = surface_id;
    evt.reserved = 0;
    evt.cookie = cookie;

    /*
     * Try to coalesce with existing SURFACE_PRESENTED event for same surface.
     * This reduces queue pressure when userland is slow to drain.
     */
    mtx_lock(&s->lock);
    if (drawfs_try_coalesce_presented(s, surface_id, cookie) == 0) {
        mtx_unlock(&s->lock);
        return (0);  /* Coalesced - no new event needed */
    }
    mtx_unlock(&s->lock);

    (void)drawfs_send_reply(s, DRAWFS_EVT_SURFACE_PRESENTED, 0, &evt, sizeof(evt));

    return (0);
}

/*
 * Step 10A: SURFACE_CREATE
 */
static int
drawfs_reply_surface_create(struct drawfs_session *s, uint32_t msg_id,
    const uint8_t *payload, size_t payload_len)
{
    struct drawfs_surface_create_req req;
    struct drawfs_surface_create_rep rep;
    int err;

    rep.status = 0;
    rep.surface_id = 0;
    rep.stride_bytes = 0;
    rep.bytes_total = 0;

    if (payload_len < sizeof(req)) {
        rep.status = EINVAL;
        goto send_reply;
    }

    memcpy(&req, payload, sizeof(req));

    err = drawfs_surface_create(s, req.width_px, req.height_px, req.format,
        &rep.surface_id, &rep.stride_bytes, &rep.bytes_total);
    if (err != 0)
        rep.status = err;

send_reply:
    return drawfs_send_reply(s, DRAWFS_RPL_SURFACE_CREATE, msg_id, &rep, sizeof(rep));
}

static int
drawfs_reply_display_open(struct drawfs_session *s, uint32_t msg_id, const uint8_t *payload, size_t payload_len)
{
    struct drawfs_display_open_req req;
    struct drawfs_display_open_rep rep;

    rep.status = 0;
    rep.display_handle = 0;
    rep.active_display_id = 0;

    if (payload_len < sizeof(req)) {
        rep.status = EINVAL;
        goto send_reply;
    }

    memcpy(&req, payload, sizeof(req));

    /* Validate display_id against current stub list (Step 8). */
    if (req.display_id != 1) {
        rep.status = ENODEV;
        goto send_reply;
    }

    /* Bind session to display. */
    mtx_lock(&s->lock);
    s->active_display_id = req.display_id;
    if (s->active_display_handle == 0)
        s->active_display_handle = s->next_display_handle++;
    rep.display_handle = s->active_display_handle;
    rep.active_display_id = s->active_display_id;
    mtx_unlock(&s->lock);

#ifdef DRAWFS_DRM_ENABLED
    /*
     * DF-6 (ADR 0002, D1): lazily open the single global DRM display
     * on the first successful bind while the backend is "drm". Done
     * outside s->lock: drawfs_drm_display_open performs DRM ioctls
     * (mode set, dumb-buffer allocation) and must not run under a
     * session mutex. A failed open leaves g_drm_display NULL and the
     * present path falls through to the swap backend (no regression).
     */
    if (strncmp(drawfs_backend, "drm", 3) == 0) {
        mtx_lock(&drawfs_drm_display_mtx);
        if (g_drm_display == NULL) {
            uint32_t dw = 0, dh = 0, dstride = 0;
            struct drawfs_drm_display *dd =
                drawfs_drm_display_open(req.display_id, &dw, &dh, &dstride);
            if (dd != NULL) {
                g_drm_display = dd;
                printf("drawfs_drm: display opened %ux%u (stride %u)\n",
                    dw, dh, dstride);
            } else {
                printf("drawfs_drm: display open failed; "
                    "falling back to swap backend for present\n");
            }
        }
        mtx_unlock(&drawfs_drm_display_mtx);
    }
#endif

send_reply:
    return drawfs_send_reply(s, DRAWFS_RPL_DISPLAY_OPEN, msg_id, &rep, sizeof(rep));
}

static int
drawfs_open(struct cdev *dev, int oflags, int devtype, struct thread *td)
{
    struct drawfs_session *s;

    (void)dev;
    (void)oflags;
    (void)devtype;
    (void)td;

    s = malloc(sizeof(*s), M_DRAWFS, M_WAITOK | M_ZERO);
    mtx_init(&s->lock, "drawfs_session", NULL, MTX_DEF);
    cv_init(&s->cv, "drawfs_cv");
    TAILQ_INIT(&s->evq);
    TAILQ_INIT(&s->surfaces);

    s->active_display_id = 0;
    s->active_display_handle = 0;
    s->next_display_handle = 1;
    s->next_surface_id = 1;

    s->closing = false;
    s->evq_bytes = 0;
    s->next_out_frame_id = 1;

    s->in_cap = 4096;
    s->inbuf = malloc(s->in_cap, M_DRAWFS, M_WAITOK | M_ZERO);
    s->in_len = 0;

    mtx_lock(&drawfs_global_mtx);
    TAILQ_INSERT_TAIL(&g_sessions, s, g_link);
    mtx_unlock(&drawfs_global_mtx);

    return (devfs_set_cdevpriv(s, drawfs_priv_dtor));
}

static int
drawfs_close(struct cdev *dev, int fflag, int devtype, struct thread *td)
{
    (void)dev;
    (void)fflag;
    (void)devtype;
    (void)td;
    return (0);
}

static int
drawfs_read(struct cdev *dev, struct uio *uio, int ioflag)
{
    struct drawfs_session *s;
    struct drawfs_event *ev;
    int error;

    (void)dev;

    error = devfs_get_cdevpriv((void **)&s);
    if (error != 0)
        return (error);

    mtx_lock(&s->lock);

    for (;;) {
        if (s->closing) {
            mtx_unlock(&s->lock);
            return (ENXIO);
        }

        if (!TAILQ_EMPTY(&s->evq))
            break;

        if ((ioflag & O_NONBLOCK) != 0) {
            mtx_unlock(&s->lock);
            return (EWOULDBLOCK);
        }

        error = cv_wait_sig(&s->cv, &s->lock);
        if (error != 0) {
            mtx_unlock(&s->lock);
            return (error);
        }
    }

    ev = TAILQ_FIRST(&s->evq);
    TAILQ_REMOVE(&s->evq, ev, link);
    s->evq_bytes -= ev->len;

    mtx_unlock(&s->lock);

    error = uiomove(ev->bytes, (int)ev->len, uio);

    free(ev->bytes, M_DRAWFS);
    free(ev, M_DRAWFS);

    return (error);
}

static int
drawfs_write(struct cdev *dev, struct uio *uio, int ioflag)
{
    struct drawfs_session *s;
    int error;
    size_t n;
    uint8_t *buf;

    (void)dev;
    (void)ioflag;

    error = devfs_get_cdevpriv((void **)&s);
    if (error != 0)
        return (error);

    n = uio->uio_resid;
    if (n == 0)
        return (0);

    if (n > DRAWFS_MAX_FRAME_BYTES)
        return (EFBIG);

    buf = malloc(n, M_DRAWFS, M_WAITOK);
    error = uiomove(buf, (int)n, uio);
    if (error != 0) {
        free(buf, M_DRAWFS);
        return (error);
    }

    /*
     * AD-18.5: bytes_in increment is performed inside
     * drawfs_ingest_bytes, under s->lock, where the rest of
     * the bookkeeping for this byte stream lives. The lock
     * is required by the locking-model invariant
     * (drawfs.c:218-235: stats.* protected by s->lock).
     */
    error = drawfs_ingest_bytes(s, buf, n);

    free(buf, M_DRAWFS);
    return (error);
}

static int
drawfs_poll(struct cdev *dev, int events, struct thread *td)
{
    struct drawfs_session *s;
    int error;
    int revents;

    (void)dev;

    error = devfs_get_cdevpriv((void **)&s);
    if (error != 0)
        return (events & (POLLERR | POLLHUP));

    revents = 0;

    mtx_lock(&s->lock);

    if (s->closing) {
        revents |= (events & (POLLHUP | POLLERR)) ? (events & (POLLHUP | POLLERR)) : POLLHUP;
        mtx_unlock(&s->lock);
        return (revents);
    }

    if ((events & (POLLIN | POLLRDNORM)) != 0) {
        if (!TAILQ_EMPTY(&s->evq))
            revents |= events & (POLLIN | POLLRDNORM);
        else
            selrecord(td, &s->sel);
    }

    mtx_unlock(&s->lock);

    return (revents);
}

static int
drawfs_ioctl(struct cdev *dev, u_long cmd, caddr_t data, int fflag, struct thread *td)
{
    struct drawfs_session *s;
    int error;

    (void)dev;
    (void)fflag;
    (void)td;

    error = devfs_get_cdevpriv((void **)&s);
    if (error != 0)
        return (error);

    switch (cmd) {

    case DRAWFSGIOC_INJECT_INPUT: {
        struct drawfs_inject_input *req;
        struct drawfs_session *target;
        uint16_t evt_type;
        int err;

        req = (struct drawfs_inject_input *)data;
        evt_type = req->event_type;

        /* Validate event type. */
        switch (evt_type) {
        case DRAWFS_EVT_KEY:
        case DRAWFS_EVT_POINTER:
        case DRAWFS_EVT_SCROLL:
        case DRAWFS_EVT_TOUCH:
            break;
        default:
            return (EINVAL);
        }

        /* Find the session that owns the target surface. */
        mtx_lock(&drawfs_global_mtx);
        target = drawfs_find_session_for_surface_locked(req->surface_id);
        /* target is returned with target->lock held if non-NULL. */
        mtx_unlock(&drawfs_global_mtx);

        if (target == NULL)
            return (ENOENT);

        /* target->lock is held; release before calling drawfs_send_reply
         * which acquires it internally via drawfs_enqueue_event. */
        mtx_unlock(&target->lock);

        err = drawfs_send_reply(target, evt_type, 0,
            req->payload, DRAWFS_INPUT_PAYLOAD_MAX);
        return (err == ENOSPC ? ENOSPC : err);
    }

    case DRAWFSGIOC_MAP_SURFACE: {
        struct drawfs_map_surface *ms;
        int err;

        ms = (struct drawfs_map_surface *)data;
        ms->status = 0;
        ms->stride_bytes = 0;
        ms->bytes_total = 0;

        err = drawfs_surface_select_for_mmap(s, ms->surface_id,
            &ms->stride_bytes, &ms->bytes_total);
        if (err != 0)
            ms->status = err;

        break;
    }

    case DRAWFSGIOC_STATS: {
        struct drawfs_stats *out = (struct drawfs_stats *)data;

        mtx_lock(&s->lock);

        *out = s->stats;

        out->inbuf_bytes = (uint32_t)s->in_len;

        uint32_t depth = 0;
        struct drawfs_event *ev;
        TAILQ_FOREACH(ev, &s->evq, link) {
            depth++;
        }
        out->evq_depth = depth;

        /* Observability: current resource usage */
        out->evq_bytes = (uint32_t)s->evq_bytes;
        out->surfaces_count = s->surfaces_count;
        out->surfaces_bytes = s->surfaces_bytes;

        mtx_unlock(&s->lock);
        return (0);
    }

    case DRAWFSGIOC_GET_EFIFB_INFO: {
        struct drawfs_efifb_info *info;

        if (!drawfs_efifb_available())
            return (ENODEV);

        info = (struct drawfs_efifb_info *)data;
        info->fb_width  = drawfs_efifb_width();
        info->fb_height = drawfs_efifb_height();
        info->fb_stride = drawfs_efifb_stride();
        info->fb_bpp    = drawfs_efifb_bpp();
        info->fb_size   = (uint64_t)info->fb_height * info->fb_stride;
        info->_pad      = 0;
        return (0);
    }

    case DRAWFSGIOC_BLIT_TO_EFIFB: {
        struct drawfs_blit_to_efifb *req;
        uint8_t *row_buf;
        uint8_t *dst;
        uint32_t row, copy_bytes, bpp_bytes;
        int err;

        if (!drawfs_efifb_available())
            return (ENODEV);

        req = (struct drawfs_blit_to_efifb *)data;
        bpp_bytes  = drawfs_efifb_bpp() / 8;
        copy_bytes = req->width * bpp_bytes;

        if (copy_bytes == 0 || req->height == 0)
            return (EINVAL);

        row_buf = malloc(copy_bytes, M_DRAWFS, M_WAITOK);

        for (row = 0; row < req->height; row++) {
            /* Copy one row from userspace */
            err = copyin(req->src + (uint64_t)row * req->src_stride,
                row_buf, copy_bytes);
            if (err != 0) {
                free(row_buf, M_DRAWFS);
                return (err);
            }

            /* Write to EFI framebuffer */
            dst = drawfs_efifb_dst_row(req->dst_y + row);
            if (dst != NULL)
                memcpy(dst + req->dst_x * bpp_bytes, row_buf, copy_bytes);
        }

        free(row_buf, M_DRAWFS);
        return (0);
    }

    default:
        return (ENOTTY);
    }

    return (0);
}

/*
 * Free all session resources.
 * Acquires s->lock to set closing flag and drain queues; releases before
 * destroying surfaces (which may sleep on VM object deallocation).
 */
static void
drawfs_session_free(struct drawfs_session *s)
{
    struct drawfs_event *ev, *tmp;

    if (s == NULL)
        return;

    /* Remove from global registry before acquiring session lock. */
    mtx_lock(&drawfs_global_mtx);
    TAILQ_REMOVE(&g_sessions, s, g_link);
    mtx_unlock(&drawfs_global_mtx);

    mtx_lock(&s->lock);
    s->closing = true;

    cv_broadcast(&s->cv);
    selwakeup(&s->sel);

    TAILQ_FOREACH_SAFE(ev, &s->evq, link, tmp) {
        TAILQ_REMOVE(&s->evq, ev, link);
        free(ev->bytes, M_DRAWFS);
        free(ev, M_DRAWFS);
    }
    s->evq_bytes = 0;

    if (s->inbuf != NULL) {
        free(s->inbuf, M_DRAWFS);
        s->inbuf = NULL;
        s->in_len = 0;
        s->in_cap = 0;
    }

    mtx_unlock(&s->lock);

    /* Free all surfaces (uses its own locking). */
    drawfs_surfaces_free_all(s);

    seldrain(&s->sel);
    cv_destroy(&s->cv);
    mtx_destroy(&s->lock);
    free(s, M_DRAWFS);
}

/*
 * Try to coalesce a SURFACE_PRESENTED event with an existing one in the queue.
 * Must be called with s->lock held.
 * Returns 0 if coalesced (caller should not enqueue new event), ENOENT otherwise.
 */
static int
drawfs_try_coalesce_presented(struct drawfs_session *s, uint32_t surface_id,
    uint64_t new_cookie)
{
    struct drawfs_event *ev;
    struct drawfs_msg_hdr mh;
    uint32_t ev_surface_id;
    size_t payload_off;

    if (!drawfs_coalesce_events)
        return (ENOENT);

    /*
     * Search queue for existing SURFACE_PRESENTED event for same surface.
     * Frame format: frame_hdr(16) + msg_hdr(16) + payload(16)
     * Payload: surface_id(4) + reserved(4) + cookie(8)
     */
    TAILQ_FOREACH(ev, &s->evq, link) {
        if (ev->len < sizeof(struct drawfs_frame_hdr) +
            sizeof(struct drawfs_msg_hdr) + 16)
            continue;

        /* Check msg_type at offset 16 */
        memcpy(&mh, ev->bytes + sizeof(struct drawfs_frame_hdr),
            sizeof(mh));
        if (mh.msg_type != DRAWFS_EVT_SURFACE_PRESENTED)
            continue;

        /* Check surface_id at offset 32 */
        payload_off = sizeof(struct drawfs_frame_hdr) +
            sizeof(struct drawfs_msg_hdr);
        memcpy(&ev_surface_id, ev->bytes + payload_off, sizeof(uint32_t));
        if (ev_surface_id != surface_id)
            continue;

        /* Found match - update cookie at offset 40 (payload_off + 8) */
        memcpy(ev->bytes + payload_off + 8, &new_cookie, sizeof(uint64_t));
        return (0);
    }

    return (ENOENT);
}

/*
 * Enqueue an event (frame) to the session's read queue.
 * Acquires and releases s->lock internally.
 */
static int
drawfs_enqueue_event(struct drawfs_session *s, const void *buf, size_t len)
{
    struct drawfs_event *ev;

    if (len == 0)
        return (0);

    if (len > DRAWFS_MAX_EVENT_BYTES)
        return (EFBIG);

    ev = malloc(sizeof(*ev), M_DRAWFS, M_WAITOK | M_ZERO);
    ev->bytes = malloc(len, M_DRAWFS, M_WAITOK);
    ev->len = len;
    memcpy(ev->bytes, buf, len);

    mtx_lock(&s->lock);

    /*
     * Step 19: event queue backpressure.
     * Limit is tunable via hw.drawfs.max_evq_bytes sysctl.
     */
    if (s->evq_bytes + len > (size_t)drawfs_max_evq_bytes) {
        s->stats.events_dropped++;
        mtx_unlock(&s->lock);
        free(ev->bytes, M_DRAWFS);
        free(ev, M_DRAWFS);
        return (ENOSPC);
    }

    if (s->closing) {
        s->stats.events_dropped++;
        mtx_unlock(&s->lock);
        free(ev->bytes, M_DRAWFS);
        free(ev, M_DRAWFS);
        return (ENXIO);
    }

    TAILQ_INSERT_TAIL(&s->evq, ev, link);
    s->evq_bytes += len;

    s->stats.events_enqueued++;
    s->stats.bytes_out += (uint64_t)len;

    cv_signal(&s->cv);
    selwakeup(&s->sel);

    mtx_unlock(&s->lock);

    return (0);
}

/*
 * Append incoming bytes to session's input buffer and try to process.
 *
 * AD-18.3: malloc(M_WAITOK) must NOT be called with s->lock held
 * (see locking rules in drawfs.c:182-198). The lock is released
 * around any necessary allocation. Race profile during the unlocked
 * window:
 *
 *   - Concurrent writers on the same fd may take the lock and either
 *     grow s->inbuf themselves (so our pre-allocated buffer is no
 *     longer needed, or its size prediction is now too small) or
 *     append more bytes (advancing s->in_len, possibly past what our
 *     pre-allocated buffer can hold).
 *   - Concurrent try_process_inbuf invocations may consume frames,
 *     decreasing s->in_len (so our buffer is now larger than needed,
 *     which is harmless).
 *
 * The fix is a loop: each iteration takes the lock, decides whether
 * to fast-path (existing in_cap fits), install our pre-allocated nb
 * (if any), or compute a new newcap and allocate (next iteration).
 * Loop bound: log2(DRAWFS_MAX_FRAME_BYTES / initial in_cap) iterations
 * worst case (~8 for 1 MB / 4 KB), almost always 0 (fast path) or 1
 * (one grow, no race) in practice.
 *
 * s->closing cannot flip during this call (set only in
 * drawfs_session_free, after all in-flight syscalls return), but we
 * re-check it each iteration anyway for cleanliness.
 *
 * Acquires and releases s->lock internally (potentially multiple
 * times across the loop).
 */
static int
drawfs_ingest_bytes(struct drawfs_session *s, const uint8_t *buf, size_t n)
{
    uint8_t *nb = NULL;
    size_t newcap = 0;
    size_t need;
    bool counted = false;

    if (n == 0)
        return (0);

    if (n > DRAWFS_MAX_FRAME_BYTES)
        return (EFBIG);

    for (;;) {
        mtx_lock(&s->lock);

        if (s->closing) {
            mtx_unlock(&s->lock);
            if (nb != NULL)
                free(nb, M_DRAWFS);
            return (ENXIO);
        }

        /*
         * AD-18.5: count bytes_in here, under the lock, exactly
         * once per call. The flag prevents double-counting on
         * grow-race retries (we may iterate the loop several
         * times before installing). The session-closing exit
         * above does NOT count, because bytes_in tracks bytes
         * accepted for ingestion, and a closing session does
         * not accept them. This is a slight semantic refinement
         * over the pre-AD-18.5 behavior, which counted bytes
         * before checking closing state.
         */
        if (!counted) {
            s->stats.bytes_in += (uint64_t)n;
            counted = true;
        }

        need = s->in_len + n;
        if (need > DRAWFS_MAX_FRAME_BYTES) {
            s->in_len = 0;
            mtx_unlock(&s->lock);
            if (nb != NULL)
                free(nb, M_DRAWFS);
            (void)drawfs_reply_error(s, 0, DRAWFS_ERR_OVERFLOW, 0);
            return (0);
        }

        /*
         * Fast path: existing buffer has room. Also covers "another
         * writer already grew us during our window"; count that as
         * a grow-race-lost if we had a pre-allocated buffer.
         */
        if (need <= s->in_cap) {
            memcpy(s->inbuf + s->in_len, buf, n);
            s->in_len += n;
            mtx_unlock(&s->lock);
            if (nb != NULL) {
                free(nb, M_DRAWFS);
                atomic_add_int(&drawfs_inbuf_grow_race_lost, 1);
            }
            return drawfs_try_process_inbuf(s);
        }

        /*
         * Need to grow. Do we already have a sufficient buffer from
         * a prior iteration?
         */
        if (nb != NULL && newcap >= need) {
            memcpy(nb, s->inbuf, s->in_len);
            free(s->inbuf, M_DRAWFS);
            s->inbuf = nb;
            s->in_cap = newcap;
            nb = NULL;
            memcpy(s->inbuf + s->in_len, buf, n);
            s->in_len += n;
            mtx_unlock(&s->lock);
            return drawfs_try_process_inbuf(s);
        }

        /*
         * Either no pre-allocated buffer, or it's too small for the
         * current need. Compute a new target and go allocate.
         */
        newcap = s->in_cap;
        while (newcap < need)
            newcap *= 2;
        if (newcap > DRAWFS_MAX_FRAME_BYTES)
            newcap = DRAWFS_MAX_FRAME_BYTES;

        mtx_unlock(&s->lock);

        if (nb != NULL) {
            free(nb, M_DRAWFS);
            atomic_add_int(&drawfs_inbuf_grow_race_lost, 1);
        }
        nb = malloc(newcap, M_DRAWFS, M_WAITOK);
        /* Loop back to re-acquire and re-evaluate. */
    }
}

/*
 * Try to process complete frames from the input buffer.
 *
 * AD-18.4: malloc(M_WAITOK) for the per-frame extraction buffer must
 * NOT be called with s->lock held. The lock is released around the
 * malloc, then re-acquired to validate that the frame at the head of
 * s->inbuf is still the one we read the header for.
 *
 * Race profile during the unlocked window:
 *
 *   - Concurrent writers append to s->inbuf (s->in_len grows; bytes
 *     past frame_bytes change). Harmless to our extraction; the
 *     first frame_bytes are unchanged because writers only append.
 *   - Concurrent try_process_inbuf invocations may extract the SAME
 *     frame we were about to. They memcpy + memmove + shrink. After
 *     our re-acquire, s->in_len is smaller and s->inbuf[0..fh] no
 *     longer holds our frame.
 *
 * We detect the second case by re-reading the frame header after
 * re-acquiring and comparing it to the pinned copy. A mismatch (or
 * insufficient bytes) means we lost the extract race; free our
 * buffer, bump the counter, and continue the loop to re-evaluate
 * inbuf state.
 *
 * Acquires s->lock for each iteration; releases for malloc and again
 * before calling drawfs_process_frame.
 */
static int
drawfs_try_process_inbuf(struct drawfs_session *s)
{
    for (;;) {
        struct drawfs_frame_hdr fh;
        uint32_t err_off;
        int v;
        size_t frame_bytes;
        uint8_t *frame;

        mtx_lock(&s->lock);

        if (s->closing) {
            mtx_unlock(&s->lock);
            return (ENXIO);
        }

        if (s->in_len < sizeof(struct drawfs_frame_hdr)) {
            mtx_unlock(&s->lock);
            return (0);
        }

        memcpy(&fh, s->inbuf, sizeof(fh));

        if (fh.magic != DRAWFS_MAGIC) {
            s->stats.frames_received += 1;
            s->stats.frames_invalid += 1;
            s->in_len = 0;
            mtx_unlock(&s->lock);
            (void)drawfs_reply_error(s, 0, DRAWFS_ERR_INVALID_FRAME, 0);
            return (0);
        }

        if (fh.header_bytes != sizeof(struct drawfs_frame_hdr)) {
            s->stats.frames_received += 1;
            s->in_len = 0;
            mtx_unlock(&s->lock);
            (void)drawfs_reply_error(s, 0, DRAWFS_ERR_INVALID_FRAME, offsetof(struct drawfs_frame_hdr, header_bytes));
            return (0);
        }

        frame_bytes = fh.frame_bytes;

        if (frame_bytes == 0 || frame_bytes > DRAWFS_MAX_FRAME_BYTES || (frame_bytes & 3u) != 0) {
            s->stats.frames_received += 1;
            s->in_len = 0;
            mtx_unlock(&s->lock);
            (void)drawfs_reply_error(s, 0, DRAWFS_ERR_INVALID_FRAME, offsetof(struct drawfs_frame_hdr, frame_bytes));
            return (0);
        }

        if (s->in_len < frame_bytes) {
            mtx_unlock(&s->lock);
            return (0);
        }

        /*
         * Header is valid and the full frame is present. Drop the
         * lock to allocate the extraction buffer (AD-18.4: malloc
         * must not run with s->lock held).
         */
        mtx_unlock(&s->lock);

        frame = malloc(frame_bytes, M_DRAWFS, M_WAITOK);

        mtx_lock(&s->lock);

        /*
         * Re-validate after the unlocked window. Three failure
         * modes, all handled by retry:
         *   - session closing (drop our buffer, return ENXIO)
         *   - in_len shrunk below frame_bytes (race-loss: another
         *     extractor consumed our frame; the new contents at
         *     offset 0 may or may not be a complete frame)
         *   - header at offset 0 no longer matches (race-loss: a
         *     different frame is at the head now)
         */
        if (s->closing) {
            mtx_unlock(&s->lock);
            free(frame, M_DRAWFS);
            return (ENXIO);
        }
        if (s->in_len < frame_bytes ||
            memcmp(s->inbuf, &fh, sizeof(fh)) != 0) {
            mtx_unlock(&s->lock);
            free(frame, M_DRAWFS);
            atomic_add_int(&drawfs_frame_extract_race_lost, 1);
            continue;
        }

        /*
         * Re-validation passed. The frame is unchanged at offset 0
         * (writers only append; consuming-extractors would have
         * changed the header). Extract it.
         *
         * Increment frames_received only now, after we've committed
         * to extracting this specific frame. Doing it earlier would
         * double-count on race-loss retries.
         */
        s->stats.frames_received += 1;
        memcpy(frame, s->inbuf, frame_bytes);

        size_t remain = s->in_len - frame_bytes;
        if (remain > 0)
            memmove(s->inbuf, s->inbuf + frame_bytes, remain);
        s->in_len = remain;

        mtx_unlock(&s->lock);

        v = drawfs_frame_validate(frame, frame_bytes, &fh, &err_off);
        if (v != DRAWFS_ERR_OK) {
            /*
             * AD-18.5: stats.frames_invalid update under s->lock,
             * per the locking-model invariant. Take, update,
             * release; reply call must be made unlocked because
             * drawfs_reply_error → drawfs_send_reply →
             * drawfs_enqueue_event acquires s->lock internally.
             */
            mtx_lock(&s->lock);
            s->stats.frames_invalid += 1;
            mtx_unlock(&s->lock);
            (void)drawfs_reply_error(s, 0, (uint32_t)v, err_off);
            free(frame, M_DRAWFS);
            continue;
        }

        v = drawfs_process_frame(s, frame, frame_bytes);
        /*
         * AD-18.5: stats.frames_processed under s->lock. Same
         * pattern as frames_invalid above; drawfs_process_frame
         * itself takes the lock for its own updates so cannot
         * be called with the lock already held.
         */
        mtx_lock(&s->lock);
        s->stats.frames_processed += 1;
        mtx_unlock(&s->lock);
        free(frame, M_DRAWFS);

        /* Propagate backpressure errors to write() caller */
        if (v != 0)
            return (v);
    }
}

static int
drawfs_process_frame(struct drawfs_session *s, const uint8_t *buf, size_t n)
{
    struct drawfs_frame_hdr fh;
    uint32_t err_off;
    int v;

    v = drawfs_frame_validate(buf, n, &fh, &err_off);
    if (v != DRAWFS_ERR_OK) {
        (void)drawfs_reply_error(s, 0, (uint32_t)v, err_off);
        return (0);
    }

    uint32_t pos = (uint32_t)sizeof(struct drawfs_frame_hdr);
    uint32_t end = fh.frame_bytes;

    while (pos + sizeof(struct drawfs_msg_hdr) <= end) {
        struct drawfs_msg_hdr mh;
        memcpy(&mh, buf + pos, sizeof(mh));

        if (mh.msg_bytes < sizeof(struct drawfs_msg_hdr)) {
            (void)drawfs_reply_error(s, mh.msg_id, DRAWFS_ERR_INVALID_MSG, pos);
            return (0);
        }
        if (mh.msg_bytes > DRAWFS_MAX_MSG_BYTES) {
            (void)drawfs_reply_error(s, mh.msg_id, DRAWFS_ERR_INVALID_MSG, pos);
            return (0);
        }

        uint32_t msg_end = pos + mh.msg_bytes;
        if (msg_end > end) {
            (void)drawfs_reply_error(s, mh.msg_id, DRAWFS_ERR_INVALID_MSG, pos);
            return (0);
        }

        const uint8_t *payload = buf + pos + sizeof(struct drawfs_msg_hdr);
        uint32_t payload_len = mh.msg_bytes - (uint32_t)sizeof(struct drawfs_msg_hdr);

        (void)payload;

        /*
         * AD-18.5: stats.messages_processed update under s->lock,
         * per the locking-model invariant (drawfs.c:218-235).
         * Reply functions in the switch below cannot be called
         * with the lock held (they acquire it internally), so we
         * take/update/release here, then release before
         * dispatching.
         */
        mtx_lock(&s->lock);
        s->stats.messages_processed += 1;
        mtx_unlock(&s->lock);

        switch (mh.msg_type) {
        case DRAWFS_REQ_HELLO:
            if (payload_len < sizeof(struct drawfs_req_hello)) {
                (void)drawfs_reply_error(s, mh.msg_id, DRAWFS_ERR_INVALID_ARG, pos);
                break;
            }
            (void)drawfs_reply_hello(s, mh.msg_id);
            break;

        case DRAWFS_REQ_DISPLAY_LIST:
            (void)drawfs_reply_display_list(s, mh.msg_id);
            break;

        case DRAWFS_REQ_DISPLAY_OPEN:
            (void)drawfs_reply_display_open(s, mh.msg_id, payload, payload_len);
            break;

        case DRAWFS_REQ_SURFACE_CREATE:
            (void)drawfs_reply_surface_create(s, mh.msg_id, payload, payload_len);
            break;

        case DRAWFS_REQ_SURFACE_DESTROY:
            (void)drawfs_reply_surface_destroy(s, mh.msg_id, payload, payload_len);
            break;

        case DRAWFS_REQ_SURFACE_PRESENT: {
            int error;

            error = drawfs_reply_surface_present(s, mh.msg_id, payload, payload_len);
            if (error != 0)
                return (error);
            break;
        }

        default:
            /*
             * AD-18.5: stats.messages_unsupported under s->lock.
             * Reply call must be unlocked.
             */
            mtx_lock(&s->lock);
            s->stats.messages_unsupported += 1;
            mtx_unlock(&s->lock);
            (void)drawfs_reply_error(s, mh.msg_id, DRAWFS_ERR_UNSUPPORTED_CAP, pos);
            break;
        }

        pos = drawfs_align4(msg_end);
    }

    return (0);
}

/*
 * Build and enqueue a reply frame.
 * Does not hold s->lock; calls drawfs_enqueue_event which acquires it.
 */
static int
drawfs_send_reply(struct drawfs_session *s, uint16_t msg_type,
    uint32_t msg_id, const void *payload, size_t payload_len)
{
    uint8_t *frame;
    size_t frame_len;
    int err;

    frame = drawfs_frame_build(s->next_out_frame_id++, msg_type, msg_id,
        payload, payload_len, &frame_len);

    err = drawfs_enqueue_event(s, frame, frame_len);
    free(frame, M_DRAWFS);
    return (err);
}

static int
drawfs_reply_error(struct drawfs_session *s, uint32_t msg_id, uint32_t err_code, uint32_t err_offset)
{
    struct drawfs_rpl_error ep;

    ep.err_code = err_code;
    ep.err_detail = 0;
    ep.err_offset = err_offset;

    return drawfs_send_reply(s, DRAWFS_RPL_ERROR, msg_id, &ep, sizeof(ep));
}

static int
drawfs_reply_hello(struct drawfs_session *s, uint32_t msg_id)
{
    struct drawfs_rpl_hello hp;

    hp.status = 0;
    hp.server_major = 1;
    hp.server_minor = 0;
    hp.server_flags = 0;
    hp.max_reply_bytes = 0;

    return drawfs_send_reply(s, DRAWFS_RPL_HELLO, msg_id, &hp, sizeof(hp));
}

static int
drawfs_reply_display_list(struct drawfs_session *s, uint32_t msg_id)
{
    struct {
        int32_t  status;
        uint32_t count;
        struct drawfs_display_desc desc;
    } payload;

    payload.status = 0;
    payload.count = 1;
    payload.desc.display_id = 1;
    /*
     * Use the EFI framebuffer's actual dimensions when EFI init
     * succeeded; fall back to a 1920x1080 default when it did not
     * (i.e. swap backend, no real display info available). The
     * original stub returned 1920x1080 unconditionally, which on
     * 4K-class hardware caused semadrawd's compositor to render
     * at 1920x1080 against a 3840x2160 framebuffer per AD-17's
     * "prefer backend-detected size" path in
     * semadraw/src/compositor/compositor.zig:155-164. With the
     * stub's hardcoded value, the operator's -r argument was also
     * overridden (the override is one-way: backend-reported wins
     * over CLI flag). Reporting the real size lets the
     * compositor configure the framebuffer at the actual
     * physical resolution.
     */
    if (drawfs_efifb_available()) {
        payload.desc.width_px = drawfs_efifb_width();
        payload.desc.height_px = drawfs_efifb_height();
    } else {
        payload.desc.width_px = 1920;
        payload.desc.height_px = 1080;
    }
    payload.desc.refresh_mhz = 60000;
    payload.desc.flags = 0;

    return drawfs_send_reply(s, DRAWFS_RPL_DISPLAY_LIST, msg_id,
        &payload, sizeof(payload));
}

/*
 * hw.drawfs.backend: display backend selector.
 * "swap" uses the existing vm_object path (default).
 * "drm"  uses the DRM/KMS path from drawfs_drm.c.
 * Changes take effect for new DISPLAY_OPEN calls.
 */
char drawfs_backend[16] = "swap";
SYSCTL_STRING(_hw_drawfs, OID_AUTO, backend, CTLFLAG_RW,
    drawfs_backend, sizeof(drawfs_backend),
    "Display backend: \"swap\" (default) or \"drm\"");

static int
drawfs_modevent(module_t mod, int type, void *data)
{
    int error;

    (void)mod;
    (void)data;
    error = 0;

    switch (type) {
    case MOD_LOAD:
        drawfs_dev = make_dev(&drawfs_cdevsw, 0,
            (uid_t)drawfs_dev_uid,
            (gid_t)drawfs_dev_gid,
            drawfs_dev_mode,
            DRAWFS_DEVNAME);
        uprintf("drawfs loaded, device %s created (uid=%d gid=%d mode=%04o)\n",
            DRAWFS_NODEPATH, drawfs_dev_uid, drawfs_dev_gid, drawfs_dev_mode);

        /* Attempt EFI framebuffer init; non-fatal, falls back to swap. */
        if (drawfs_efifb_init() == 0) {
            printf("drawfs: EFI framebuffer mapped %ux%u\n",
                drawfs_efifb_width(), drawfs_efifb_height());
            strlcpy(drawfs_backend, "efifb", sizeof(drawfs_backend));
        } else {
            printf("drawfs: EFI framebuffer unavailable, using swap backend\n");
        }

        /* Attempt DRM init; failure is non-fatal, falls back to swap. */
#ifdef DRAWFS_DRM_ENABLED
        if (strncmp(drawfs_backend, "drm", 3) == 0) {
            if (drawfs_drm_init() != 0) {
                printf("drawfs: DRM init failed, falling back to swap\n");
                strlcpy(drawfs_backend, "swap", sizeof(drawfs_backend));
            }
        }
#endif
        break;

    case MOD_UNLOAD:
        drawfs_efifb_fini();
#ifdef DRAWFS_DRM_ENABLED
        /*
         * DF-6 (ADR 0002, D1): close the global display (which stops
         * its completion kthread and frees dumb buffers) before
         * tearing down the DRM subsystem. By MOD_UNLOAD all sessions
         * are gone, so no present can race this.
         */
        mtx_lock(&drawfs_drm_display_mtx);
        if (g_drm_display != NULL) {
            drawfs_drm_display_close(g_drm_display);
            g_drm_display = NULL;
        }
        mtx_unlock(&drawfs_drm_display_mtx);
        if (strncmp(drawfs_backend, "drm", 3) == 0)
            drawfs_drm_fini();
#endif
        if (drawfs_dev != NULL)
            destroy_dev(drawfs_dev);
        uprintf("drawfs unloaded\n");
        break;

    default:
        error = EOPNOTSUPP;
        break;
    }

    return (error);
}

DEV_MODULE(drawfs, drawfs_modevent, NULL);
MODULE_VERSION(drawfs, 1);
