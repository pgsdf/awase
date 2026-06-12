/*-
 * SPDX-License-Identifier: MIT
 *
 * drawfs_drm.c: DRM/KMS display backend for drawfs (DF-3)
 *
 * This file implements the DRM/KMS backend for drawfs.  It is selected
 * when hw.drawfs.backend is set to "drm".  The swap-backed (vm_object)
 * path in drawfs.c is unaffected.
 *
 * FreeBSD DRM KPIs used here:
 *
 *   drm_open_helper / drm_dev_get     : open the DRM device
 *   drmModeGetResources               : enumerate connectors, CRTCs, encoders
 *   drmModeGetConnector               : inspect connector state and modes
 *   drmModeGetEncoder                 : map connector → CRTC
 *   drmIoctl(DRM_IOCTL_MODE_CREATE_DUMB)  : allocate dumb (CPU-accessible) buffer
 *   drmIoctl(DRM_IOCTL_MODE_MAP_DUMB)    : get mmap offset for dumb buffer
 *   drmModeAddFB                      : wrap dumb buffer in a framebuffer object
 *   drmModeSetCrtc                    : initial mode set
 *   drmModePageFlip                   : vblank-synchronised page flip
 *   drmIoctl(DRM_IOCTL_MODE_DESTROY_DUMB) : free dumb buffer
 *   drmModeRmFB                       : remove framebuffer object
 *   drmModeFreeResources              : free resource list
 *   drmModeFreeConnector              : free connector object
 *
 * Build note:
 *   Add drawfs_drm.c to sys/modules/drawfs/Makefile and link against
 *   drm.ko (KMOD depends on drm).
 *
 * Sysctl:
 *   hw.drawfs.backend = "swap"   (default, existing vm_object path)
 *   hw.drawfs.backend = "drm"    (DRM/KMS path, this file)
 *
 * Known limitations in this skeleton:
 *   - Only card0 is opened; multi-GPU support is not implemented.
 *   - Damage rects are not yet applied (full-surface blit always used).
 *   - Page flip completion callback (DRM_MODE_PAGE_FLIP_EVENT) is stubbed.
 *   - Atomic modesetting (drmModeAtomicCommit) is not yet used; legacy
 *     SetCrtc/PageFlip is used for simplicity.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/fcntl.h>
#include <sys/proc.h>
#include <sys/kthread.h>
#include <sys/file.h>
#include <vm/vm.h>
#include <vm/vm_object.h>
#include <vm/vm_page.h>
#include <vm/vm_pager.h>

/*
 * DRM KPI headers: available in FreeBSD 15 when drm.ko is loaded.
 * The exact include path depends on the FreeBSD ports tree version of
 * drm-kmod; the paths below match drm-kmod 6.x.
 */
#include <drm/drm_device.h>
#include <drm/drm_file.h>
#include <drm/drm_ioctl.h>
#include <uapi/drm/drm.h>
#include <uapi/drm/drm_mode.h>

#include "drawfs_internal.h"
#include "drawfs_drm.h"

MALLOC_DECLARE(M_DRAWFS);

/* -------------------------------------------------------------------------
 * Module-level DRM state
 * -------------------------------------------------------------------------
 */

/* File pointer for /dev/dri/card0, opened in drawfs_drm_init(). */
static struct file *g_drm_fp = NULL;
static struct mtx   g_drm_mtx;
MTX_SYSINIT(drawfs_drm_mtx, &g_drm_mtx, "drawfs_drm_global", MTX_DEF);

/* -------------------------------------------------------------------------
 * Helpers: issue DRM ioctls through the kernel file pointer
 * -------------------------------------------------------------------------
 */

/*
 * drm_ioctl_kern(): issue a DRM ioctl from kernel context.
 *
 * Equivalent to kern_ioctl() but used here to call DRM ioctls on g_drm_fp
 * without needing a userspace context.  On FreeBSD 15 the preferred path is
 * to use the drm_ioctl() function pointer directly from the cdevsw of the
 * DRM device, which avoids the copy_to/from_user overhead.
 *
 * For now this is a thin wrapper; in a production implementation replace
 * with direct drm_dev_ioctl() calls via drm_device.driver->ioctls.
 */
static int
drm_ioctl_kern(unsigned long request, void *arg)
{
    int error;
    if (g_drm_fp == NULL)
        return (ENXIO);
    error = fo_ioctl(g_drm_fp, request, (caddr_t)arg, curthread->td_ucred,
        curthread);
    return (error);
}

/* -------------------------------------------------------------------------
 * drawfs_drm_init
 * -------------------------------------------------------------------------
 */
int
drawfs_drm_init(void)
{
    int error;

    /*
     * Open /dev/dri/card0 from kernel context.
     *
     * kern_openat() opens the device and returns a file descriptor in the
     * calling thread's file descriptor table.  We then retrieve the struct
     * file * via fget() so we can hold a reference independently of the
     * thread's fd table.
     *
     * Production note: on a system with multiple GPUs, enumerate
     * /dev/dri/card0..N and select based on capability flags.
     */
    int td_fd = -1;
    error = kern_openat(curthread, AT_FDCWD, "/dev/dri/card0",
        UIO_SYSSPACE, O_RDWR | O_CLOEXEC, 0);
    if (error != 0) {
        printf("drawfs_drm: cannot open /dev/dri/card0: %d\n", error);
        return (error);
    }
    td_fd = curthread->td_retval[0];

    error = fget(curthread, td_fd, &cap_ioctl_rights, &g_drm_fp);
    kern_close(curthread, td_fd); /* release fd; fget holds a reference */
    if (error != 0) {
        printf("drawfs_drm: fget failed: %d\n", error);
        return (error);
    }

    /*
     * Verify that the DRM device supports dumb buffers (CPU-accessible
     * buffers that do not require GPU command submission).  This is the
     * only buffer type we use; GPU-accelerated paths are future work.
     */
    struct drm_get_cap cap_req = {
        .capability = DRM_CAP_DUMB_BUFFER,
        .value      = 0,
    };
    error = drm_ioctl_kern(DRM_IOCTL_GET_CAP, &cap_req);
    if (error != 0 || cap_req.value == 0) {
        printf("drawfs_drm: device does not support dumb buffers\n");
        fdrop(g_drm_fp, curthread);
        g_drm_fp = NULL;
        return (ENODEV);
    }

    printf("drawfs_drm: DRM backend initialised on /dev/dri/card0\n");
    return (0);
}

/* -------------------------------------------------------------------------
 * drawfs_drm_fini
 * -------------------------------------------------------------------------
 */
void
drawfs_drm_fini(void)
{
    mtx_lock(&g_drm_mtx);
    if (g_drm_fp != NULL) {
        fdrop(g_drm_fp, curthread);
        g_drm_fp = NULL;
    }
    mtx_unlock(&g_drm_mtx);
    printf("drawfs_drm: DRM backend shut down\n");
}

/* -------------------------------------------------------------------------
 * drawfs_drm_display_open
 * -------------------------------------------------------------------------
 */
/*
 * DF-6 (ADR 0002, D5): page-flip completion kthread (SKELETON).
 *
 * The lifecycle here is correct and joinable: display_open creates
 * the thread, display_close requests stop (completion_run = 0) and
 * polls until the thread marks itself exited (completion_run = 2).
 *
 * The body is intentionally a stub. The production form reads the
 * DRM event queue on dd->drm_fd and, on DRM_EVENT_FLIP_COMPLETE,
 * takes dd->drm_mtx, sets dd->flip_pending = 0, and releases, so the
 * next present proceeds. That read is driver-and-event-queue
 * specific and is deferred to the hardware bench; until it lands,
 * flip_pending is NOT cleared here (no fabrication), so on real
 * hardware presents will drop after the first flip. This is the
 * known-incomplete half called out in ADR 0002 D5.
 */
static void
drawfs_drm_completion_thread(void *arg)
{
    struct drawfs_drm_display *dd = arg;

    while (dd->completion_run == 1) {
        /*
         * TODO (DF-6 D5, hardware): read dd->drm_fd's event queue;
         * on DRM_EVENT_FLIP_COMPLETE, clear dd->flip_pending under
         * dd->drm_mtx.
         */
        pause("drmflip", hz / 10);
    }

    dd->completion_run = 2;   /* mark exited for the joiner */
    kproc_exit(0);
}

struct drawfs_drm_display *
drawfs_drm_display_open(uint32_t display_id,
    uint32_t *out_width, uint32_t *out_height, uint32_t *out_stride)
{
    struct drm_mode_card_res    res   = { 0 };
    struct drm_mode_get_connector conn  = { 0 };
    struct drm_mode_get_encoder  enc   = { 0 };
    struct drm_mode_modeinfo    mode  = { 0 };
    struct drm_mode_create_dumb  create = { 0 };
    struct drm_mode_map_dumb     map    = { 0 };
    struct drm_mode_fb_cmd       fb_cmd = { 0 };
    struct drm_mode_crtc         crtc   = { 0 };
    struct drawfs_drm_display   *dd;
    uint32_t *connector_ids = NULL;
    uint32_t *crtc_ids      = NULL;
    int       error;

    (void)display_id; /* future: map display_id to connector index */

    /*
     * Step 1: enumerate DRM resources.
     *
     * First call with count fields = 0 fills in the actual counts.
     * Second call with allocated arrays fills in the IDs.
     */
    error = drm_ioctl_kern(DRM_IOCTL_MODE_GETRESOURCES, &res);
    if (error != 0) {
        printf("drawfs_drm: GETRESOURCES failed: %d\n", error);
        return (NULL);
    }

    if (res.count_connectors == 0 || res.count_crtcs == 0) {
        printf("drawfs_drm: no connectors or CRTCs\n");
        return (NULL);
    }

    connector_ids = malloc(res.count_connectors * sizeof(uint32_t),
        M_DRAWFS, M_WAITOK | M_ZERO);
    crtc_ids = malloc(res.count_crtcs * sizeof(uint32_t),
        M_DRAWFS, M_WAITOK | M_ZERO);

    res.connector_id_ptr = (uint64_t)(uintptr_t)connector_ids;
    res.crtc_id_ptr      = (uint64_t)(uintptr_t)crtc_ids;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_GETRESOURCES, &res);
    if (error != 0) {
        printf("drawfs_drm: GETRESOURCES (2nd) failed: %d\n", error);
        goto fail_ids;
    }

    /*
     * Step 2: find the first connected connector and its preferred mode.
     */
    uint32_t selected_connector = 0;
    uint32_t selected_encoder   = 0;
    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_modeinfo *modes;

        conn.connector_id = connector_ids[i];
        conn.count_modes  = 0;
        error = drm_ioctl_kern(DRM_IOCTL_MODE_GETCONNECTOR, &conn);
        if (error != 0) continue;

        if (conn.connection != DRM_MODE_CONNECTED) continue;
        if (conn.count_modes == 0) continue;

        /* Fetch mode list. */
        modes = malloc(conn.count_modes * sizeof(*modes),
            M_DRAWFS, M_WAITOK | M_ZERO);
        conn.modes_ptr = (uint64_t)(uintptr_t)modes;
        error = drm_ioctl_kern(DRM_IOCTL_MODE_GETCONNECTOR, &conn);
        if (error != 0) {
            free(modes, M_DRAWFS);
            continue;
        }

        /* Use the first (preferred/highest) mode. */
        mode = modes[0];
        free(modes, M_DRAWFS);

        selected_connector = connector_ids[i];
        selected_encoder   = conn.encoder_id;
        break;
    }

    if (selected_connector == 0) {
        printf("drawfs_drm: no connected connector found\n");
        goto fail_ids;
    }

    /*
     * Step 3: find the CRTC for this connector via its encoder.
     */
    uint32_t selected_crtc = 0;
    if (selected_encoder != 0) {
        enc.encoder_id = selected_encoder;
        error = drm_ioctl_kern(DRM_IOCTL_MODE_GETENCODER, &enc);
        if (error == 0)
            selected_crtc = enc.crtc_id;
    }
    /* Fall back: use first available CRTC. */
    if (selected_crtc == 0 && res.count_crtcs > 0)
        selected_crtc = crtc_ids[0];

    if (selected_crtc == 0) {
        printf("drawfs_drm: no CRTC available\n");
        goto fail_ids;
    }

    free(connector_ids, M_DRAWFS);
    free(crtc_ids, M_DRAWFS);
    connector_ids = crtc_ids = NULL;

    /*
     * Step 4: allocate two dumb buffers (front + back) at the selected
     * mode resolution.
     *
     * DRM_IOCTL_MODE_CREATE_DUMB returns:
     *   handle  : GEM object handle
     *   pitch   : bytes per row (hardware-aligned stride)
     *   size    : total allocation size in bytes
     */
    create.width  = mode.hdisplay;
    create.height = mode.vdisplay;
    create.bpp    = 32; /* XRGB8888 */
    error = drm_ioctl_kern(DRM_IOCTL_MODE_CREATE_DUMB, &create);
    if (error != 0) {
        printf("drawfs_drm: CREATE_DUMB (front) failed: %d\n", error);
        return (NULL);
    }
    uint32_t front_handle = create.handle;
    uint32_t stride       = create.pitch;
    uint64_t buf_size     = create.size;

    /* Back buffer, same dimensions. */
    create.handle = 0;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_CREATE_DUMB, &create);
    if (error != 0) {
        printf("drawfs_drm: CREATE_DUMB (back) failed: %d\n", error);
        /* Destroy front buffer before returning. */
        struct drm_mode_destroy_dumb destroy = { .handle = front_handle };
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        return (NULL);
    }
    uint32_t back_handle = create.handle;

    /*
     * Step 5: get mmap offsets for both dumb buffers.
     *
     * DRM_IOCTL_MODE_MAP_DUMB returns an offset suitable for use with
     * mmap(2).  In kernel context we use pmap_mapdev() or vm_mmap_object()
     * to get a kernel VA.
     *
     * NOTE: In the FreeBSD KPI the dumb buffer memory is typically accessed
     * in kernel space via the GEM object's backing store.  The mmap offset
     * returned here is for userspace use.  For kernel-side pixel copies we
     * access the GEM object's vm_object pages directly via vm_page_lookup()
     * and pmap_mapdev_attr().  This skeleton uses the mmap offset for
     * clarity; the production path should use vm_page access.
     */
    map.handle = front_handle;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_MAP_DUMB, &map);
    if (error != 0) {
        printf("drawfs_drm: MAP_DUMB (front) failed: %d\n", error);
        goto fail_bufs;
    }
    /* Map front buffer into kernel VA. */
    uint8_t *front_map = (uint8_t *)pmap_mapdev(map.offset, buf_size);

    map.handle = back_handle;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_MAP_DUMB, &map);
    if (error != 0) {
        printf("drawfs_drm: MAP_DUMB (back) failed: %d\n", error);
        pmap_unmapdev((vm_offset_t)front_map, buf_size);
        goto fail_bufs;
    }
    uint8_t *back_map = (uint8_t *)pmap_mapdev(map.offset, buf_size);

    /*
     * Step 6: create framebuffer objects wrapping the dumb buffers.
     *
     * drmModeAddFB associates a GEM handle with display dimensions,
     * format, and stride so the CRTC can scan out from it.
     */
    fb_cmd.width  = mode.hdisplay;
    fb_cmd.height = mode.vdisplay;
    fb_cmd.pitch  = stride;
    fb_cmd.bpp    = 32;
    fb_cmd.depth  = 24; /* X8R8G8B8 */
    fb_cmd.handle = front_handle;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_ADDFB, &fb_cmd);
    if (error != 0) {
        printf("drawfs_drm: ADDFB (front) failed: %d\n", error);
        goto fail_maps;
    }
    uint32_t front_fb_id = fb_cmd.fb_id;

    fb_cmd.handle = back_handle;
    fb_cmd.fb_id  = 0;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_ADDFB, &fb_cmd);
    if (error != 0) {
        printf("drawfs_drm: ADDFB (back) failed: %d\n", error);
        struct drm_mode_fb_cmd rm = { .fb_id = front_fb_id };
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_RMFB, &rm);
        goto fail_maps;
    }
    uint32_t back_fb_id = fb_cmd.fb_id;

    /*
     * Step 7: initial mode set.
     *
     * drmModeSetCrtc binds a framebuffer to a CRTC and connector, sets the
     * video mode, and starts scanout.  After this call the display shows
     * the contents of front_fb_id (initially zeroed = black).
     */
    crtc.crtc_id  = selected_crtc;
    crtc.fb_id    = front_fb_id;
    crtc.x = crtc.y = 0;
    crtc.count_connectors = 1;
    /* connector_set_ptr must point to an array of connector IDs */
    uint32_t conn_array[1] = { selected_connector };
    crtc.set_connectors_ptr = (uint64_t)(uintptr_t)conn_array;
    crtc.mode     = mode;
    crtc.mode_valid = 1;
    error = drm_ioctl_kern(DRM_IOCTL_MODE_SETCRTC, &crtc);
    if (error != 0) {
        printf("drawfs_drm: SETCRTC failed: %d\n", error);
        goto fail_fbs;
    }

    /*
     * Step 8: allocate and populate the display descriptor.
     */
    dd = malloc(sizeof(*dd), M_DRAWFS, M_WAITOK | M_ZERO);
    mtx_init(&dd->drm_mtx, "drawfs_drm_display", NULL, MTX_DEF);
    dd->connector_id  = selected_connector;
    dd->crtc_id       = selected_crtc;
    dd->mode_fb_id    = front_fb_id;
    dd->back_fb_id    = back_fb_id;
    dd->front_handle  = front_handle;
    dd->back_handle   = back_handle;
    dd->width_px      = mode.hdisplay;
    dd->height_px     = mode.vdisplay;
    dd->stride_bytes  = stride;
    dd->front_map     = front_map;
    dd->back_map      = back_map;
    dd->flip_pending  = 0;
    dd->flip_failure_logged = 0;

    /*
     * DF-6 (ADR 0002, D5): start the completion kthread. Non-fatal
     * on failure: present still works, but flip_pending will not be
     * cleared (which is already the skeleton's state), so this is
     * logged and the display still opens.
     */
    dd->completion_run = 1;
    if (kproc_create(drawfs_drm_completion_thread, dd,
        &dd->completion_proc, 0, 0, "drawfs_drm_flip") != 0) {
        dd->completion_proc = NULL;
        dd->completion_run = 2;
        printf("drawfs_drm: completion kthread create failed; "
            "flip completion will not be serviced\n");
    }

    *out_width  = dd->width_px;
    *out_height = dd->height_px;
    *out_stride = dd->stride_bytes;

    printf("drawfs_drm: display open: %ux%u stride=%u crtc=%u connector=%u\n",
        dd->width_px, dd->height_px, dd->stride_bytes,
        dd->crtc_id, dd->connector_id);

    return (dd);

fail_fbs:
    {
        struct drm_mode_fb_cmd rm;
        rm.fb_id = back_fb_id;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_RMFB, &rm);
        rm.fb_id = front_fb_id;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_RMFB, &rm);
    }
fail_maps:
    pmap_unmapdev((vm_offset_t)back_map,  buf_size);
    pmap_unmapdev((vm_offset_t)front_map, buf_size);
fail_bufs:
    {
        struct drm_mode_destroy_dumb destroy;
        destroy.handle = back_handle;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        destroy.handle = front_handle;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
    return (NULL);

fail_ids:
    if (connector_ids) free(connector_ids, M_DRAWFS);
    if (crtc_ids)      free(crtc_ids,      M_DRAWFS);
    return (NULL);
}

/* -------------------------------------------------------------------------
 * drawfs_drm_display_close
 * -------------------------------------------------------------------------
 */
void
drawfs_drm_display_close(struct drawfs_drm_display *dd)
{
    if (dd == NULL) return;

    /*
     * DF-6 (ADR 0002, D5): stop and join the completion kthread
     * before tearing down the buffers it may reference. Request stop
     * and poll until the thread marks itself exited. Bounded by the
     * thread's pause interval (hz/10).
     */
    if (dd->completion_proc != NULL) {
        dd->completion_run = 0;
        while (dd->completion_run != 2)
            pause("drmflipj", hz / 10);
        dd->completion_proc = NULL;
    }

    uint64_t buf_size = (uint64_t)dd->stride_bytes * dd->height_px;

    /* Unmap kernel VAs. */
    if (dd->back_map)  pmap_unmapdev((vm_offset_t)dd->back_map,  buf_size);
    if (dd->front_map) pmap_unmapdev((vm_offset_t)dd->front_map, buf_size);

    /* Remove framebuffer objects. */
    struct drm_mode_fb_cmd rm;
    if (dd->back_fb_id) {
        rm.fb_id = dd->back_fb_id;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_RMFB, &rm);
    }
    if (dd->mode_fb_id) {
        rm.fb_id = dd->mode_fb_id;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_RMFB, &rm);
    }

    /* Destroy GEM handles (releases dumb buffer memory). */
    struct drm_mode_destroy_dumb destroy;
    if (dd->back_handle) {
        destroy.handle = dd->back_handle;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
    if (dd->front_handle) {
        destroy.handle = dd->front_handle;
        (void)drm_ioctl_kern(DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }

    mtx_destroy(&dd->drm_mtx);
    free(dd, M_DRAWFS);
}

/* -------------------------------------------------------------------------
 * drawfs_drm_surface_present
 * -------------------------------------------------------------------------
 */
int
drawfs_drm_surface_present(struct drawfs_drm_display *dd,
    struct drawfs_surface *surf,
    const struct drawfs_damage_rect *damage, uint32_t damage_count)
{
    uint8_t        *dst;
    vm_object_t     obj;
    vm_page_t       pg;
    vm_offset_t     kva;
    uint32_t        copy_w, copy_h, copy_stride;
    int             error = 0;

    mtx_lock(&dd->drm_mtx);

    if (dd->flip_pending) {
        /*
         * A page flip is already in flight.  Skip this present to avoid
         * queuing a second flip before the first vblank.  The client still
         * receives a successful reply; the frame is simply dropped.
         *
         * Production: maintain a pending-present flag and re-issue the flip
         * once the flip completion event fires.
         */
        mtx_unlock(&dd->drm_mtx);
        return (0);
    }

    dst = dd->back_map;
    if (dst == NULL) {
        mtx_unlock(&dd->drm_mtx);
        return (ENXIO);
    }

    /*
     * Copy pixels from the drawfs surface vm_object into the back dumb
     * buffer.
     *
     * The surface vm_object holds XRGB8888 pixels at the drawfs stride
     * (surf->stride_bytes).  The dumb buffer stride may differ
     * (dd->stride_bytes ≥ surf->stride_bytes due to hardware alignment).
     *
     * We walk the vm_object page-by-page, map each page into kernel VA
     * temporarily, and memcpy the relevant rows.
     *
     * If damage_count > 0, copy only the damaged rectangles.
     * This skeleton performs a full-surface copy (damage support is TODO).
     */
    (void)damage;
    (void)damage_count;

    copy_w      = min(surf->width_px,  dd->width_px);
    copy_h      = min(surf->height_px, dd->height_px);
    copy_stride = min(surf->stride_bytes, dd->stride_bytes);

    obj = surf->vmobj;
    if (obj == NULL) {
        mtx_unlock(&dd->drm_mtx);
        return (ENXIO);
    }

    VM_OBJECT_RLOCK(obj);
    for (uint32_t row = 0; row < copy_h; row++) {
        /*
         * Calculate the byte offset of this row in the vm_object.
         * Map the vm_page containing it into kernel VA and copy.
         */
        vm_pindex_t pindex = (vm_pindex_t)(row * surf->stride_bytes) / PAGE_SIZE;
        pg = vm_page_lookup(obj, pindex);
        if (pg == NULL) {
            /* Unallocated page; zero the destination row. */
            memset(dst + row * dd->stride_bytes, 0, copy_stride);
            continue;
        }

        kva = PHYS_TO_DMAP(VM_PAGE_TO_PHYS(pg));
        size_t page_off = (row * surf->stride_bytes) % PAGE_SIZE;
        size_t avail    = PAGE_SIZE - page_off;
        size_t to_copy  = min(copy_stride, avail);

        memcpy(dst + row * dd->stride_bytes,
               (uint8_t *)kva + page_off, to_copy);

        /* Handle rows that span page boundaries. */
        if (to_copy < copy_stride) {
            vm_page_t pg2 = vm_page_lookup(obj, pindex + 1);
            if (pg2 != NULL) {
                vm_offset_t kva2 = PHYS_TO_DMAP(VM_PAGE_TO_PHYS(pg2));
                memcpy(dst + row * dd->stride_bytes + to_copy,
                       (uint8_t *)kva2, copy_stride - to_copy);
            }
        }
    }
    VM_OBJECT_RUNLOCK(obj);

    /*
     * Clamp rows not covered by the surface (display larger than surface).
     */
    for (uint32_t row = copy_h; row < dd->height_px; row++)
        memset(dst + row * dd->stride_bytes, 0, dd->stride_bytes);

    /*
     * Issue the page flip.
     *
     * DRM_MODE_PAGE_FLIP_EVENT requests a vblank-synchronised flip with an
     * event notification on completion.  When the flip completes, the DRM
     * event queue will contain a DRM_EVENT_FLIP_COMPLETE event.
     *
     * Production: read this event from a dedicated kthread and toggle
     * dd->flip_pending back to 0, then re-present if a frame was queued.
     *
     * Here we use the back framebuffer as the new scanout buffer and then
     * swap front/back so the next call renders into the old front.
     */
    /*
     * AD-18.7 (ADR 0002, D4): the page-flip ioctl must not run under
     * dd->drm_mtx. Capture the flip parameters, CLAIM the in-flight
     * slot by setting flip_pending before dropping the lock (a
     * concurrent present on another session then sees the claim at
     * the top of this function and drops its frame), release the
     * lock, issue the ioctl unlocked, then re-acquire to install the
     * swap on success or roll the claim back on failure. Same
     * capture/claim, release, slow-call, re-acquire,
     * install-or-rollback shape as AD-18.2/.3/.4.
     */
    struct drm_mode_crtc_page_flip flip = {
        .crtc_id   = dd->crtc_id,
        .fb_id     = dd->back_fb_id,
        .flags     = DRM_MODE_PAGE_FLIP_EVENT,
        .user_data = (uint64_t)(uintptr_t)dd,
    };
    dd->flip_pending = 1;            /* claim before dropping the lock */
    mtx_unlock(&dd->drm_mtx);

    error = drm_ioctl_kern(DRM_IOCTL_MODE_PAGE_FLIP, &flip);

    mtx_lock(&dd->drm_mtx);
    if (error != 0) {
        dd->flip_pending = 0;        /* roll the claim back */
        /*
         * AD-13.3: log at most once per error state. surface_present
         * runs at compositor frame rate; without the gate, a
         * persistent flip failure produces one console write per
         * frame and competes with the framebuffer surface itself.
         */
        if (!dd->flip_failure_logged) {
            printf("drawfs_drm: PAGE_FLIP failed: %d\n", error);
            dd->flip_failure_logged = 1;
        }
        mtx_unlock(&dd->drm_mtx);
        return (error);
    }

    /*
     * Successful flip; clear the suppression flag so that a
     * subsequent failure will log once again. flip_pending stays 1
     * until the completion kthread (D5) observes the vblank event.
     */
    dd->flip_failure_logged = 0;

    /* Swap front and back. */
    uint32_t tmp_fb  = dd->mode_fb_id;
    uint32_t tmp_gem = dd->front_handle;
    uint8_t *tmp_map = dd->front_map;

    dd->mode_fb_id   = dd->back_fb_id;
    dd->front_handle = dd->back_handle;
    dd->front_map    = dd->back_map;

    dd->back_fb_id   = tmp_fb;
    dd->back_handle  = tmp_gem;
    dd->back_map     = tmp_map;

    mtx_unlock(&dd->drm_mtx);
    return (0);
}
