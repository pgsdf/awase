/*
 * drawfs_surface.c - Surface lifecycle management for drawfs
 *
 * This module handles creation, destruction, lookup, and mmap support
 * for drawing surfaces within a session.
 *
 * Locking: All functions acquire s->lock internally unless noted otherwise.
 * VM object operations (allocate/deallocate) are done outside the lock to
 * avoid sleeping with mutex held.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/errno.h>
#include <sys/lock.h>
#include <sys/rwlock.h>
#include <sys/pctrie.h>
#include <sys/mutex.h>
#include <machine/atomic.h>
#include <vm/vm.h>
#include <vm/vm_param.h>
#include <vm/vm_page.h>
#include <vm/vm_object.h>
#include <vm/vm_pager.h>

#include "drawfs.h"
#include "drawfs_proto.h"
#include "drawfs_internal.h"
#include "drawfs_surface.h"

/*
 * Lookup a surface by ID, with caller holding s->lock.
 *
 * Returns the surface pointer or NULL if not found.
 * Caller MUST hold s->lock; the function asserts this and walks the
 * surface list without acquiring/releasing the lock.
 *
 * Use this from code paths that have already acquired s->lock — e.g.
 * drawfs_find_session_for_surface_locked, which holds the lock while
 * checking each session in the global registry. Calling
 * drawfs_surface_lookup() from such a context recurses on the
 * non-recursive s->lock and panics under INVARIANTS (AD-18.1).
 */
struct drawfs_surface *
drawfs_surface_lookup_locked(struct drawfs_session *s, uint32_t surface_id)
{
    struct drawfs_surface *it;

    mtx_assert(&s->lock, MA_OWNED);
    TAILQ_FOREACH(it, &s->surfaces, link) {
        if (it->id == surface_id)
            return (it);
    }
    return (NULL);
}

/*
 * Lookup a surface by ID.
 * Acquires and releases s->lock internally.
 */
struct drawfs_surface *
drawfs_surface_lookup(struct drawfs_session *s, uint32_t surface_id)
{
    struct drawfs_surface *it;

    mtx_lock(&s->lock);
    it = drawfs_surface_lookup_locked(s, surface_id);
    mtx_unlock(&s->lock);
    return (it);
}

/*
 * Create a new surface.
 * Acquires and releases s->lock internally.
 * Returns 0 on success, or an errno on failure.
 */
int
drawfs_surface_create(struct drawfs_session *s,
    uint32_t width_px, uint32_t height_px, uint32_t format,
    uint32_t *out_surface_id, uint32_t *out_stride_bytes,
    uint32_t *out_bytes_total)
{
    struct drawfs_surface *sf;
    uint64_t stride64, total64;

    *out_surface_id = 0;
    *out_stride_bytes = 0;
    *out_bytes_total = 0;

    /* Must bind a display first. */
    if (s->active_display_id == 0)
        return (EINVAL);

    if (width_px == 0 || height_px == 0)
        return (EINVAL);

    if (format != DRAWFS_FMT_XRGB8888)
        return (EPROTONOSUPPORT);

    /*
     * Step 18 hardening: compute size in 64-bit and clamp.
     * Limits are tunable via hw.drawfs.max_surface_bytes and
     * hw.drawfs.max_session_surface_bytes sysctls.
     */
    stride64 = (uint64_t)width_px * 4ULL;
    total64 = stride64 * (uint64_t)height_px;
    if (stride64 == 0 || total64 == 0 ||
        total64 > (uint64_t)drawfs_max_surface_bytes)
        return (EFBIG);

    /* Allocate surface object. */
    sf = malloc(sizeof(*sf), M_DRAWFS, M_WAITOK | M_ZERO);

    mtx_lock(&s->lock);

    /* Check resource limits (tunable via hw.drawfs.max_surfaces sysctl). */
    if (s->surfaces_count >= (uint32_t)drawfs_max_surfaces ||
        s->surfaces_bytes + total64 > (uint64_t)drawfs_max_session_surface_bytes) {
        mtx_unlock(&s->lock);
        free(sf, M_DRAWFS);
        return (ENOSPC);
    }

    sf->id = s->next_surface_id++;
    sf->width_px = width_px;
    sf->height_px = height_px;
    sf->format = format;
    sf->stride_bytes = (uint32_t)stride64;
    sf->bytes_total = (uint32_t)total64;
    sf->vmobj = NULL;

    TAILQ_INSERT_TAIL(&s->surfaces, sf, link);

    s->surfaces_count++;
    s->surfaces_bytes += total64;

    *out_surface_id = sf->id;
    *out_stride_bytes = sf->stride_bytes;
    *out_bytes_total = sf->bytes_total;

    mtx_unlock(&s->lock);

    return (0);
}

/*
 * Destroy a surface by ID.
 * Acquires s->lock to detach surface; releases before deallocating VM object.
 * Returns 0 on success, EINVAL if surface_id is 0, ENOENT if not found.
 */
int
drawfs_surface_destroy(struct drawfs_session *s, uint32_t surface_id)
{
    struct drawfs_surface *sf;

    if (surface_id == 0)
        return (EINVAL);

    /* Find and detach from session list under lock. */
    sf = NULL;
    mtx_lock(&s->lock);
    TAILQ_FOREACH(sf, &s->surfaces, link) {
        if (sf->id == surface_id)
            break;
    }
    if (sf != NULL) {
        TAILQ_REMOVE(&s->surfaces, sf, link);

        if (s->surfaces_count > 0)
            s->surfaces_count--;
        if (s->surfaces_bytes >= sf->bytes_total)
            s->surfaces_bytes -= sf->bytes_total;
        else
            s->surfaces_bytes = 0;

        /* If this surface was selected for mmap, clear selection. */
        if (s->map_surface_id == sf->id)
            s->map_surface_id = 0;
    }
    mtx_unlock(&s->lock);

    if (sf == NULL)
        return (ENOENT);

    /* Release backing VM object, if any. */
    if (sf->vmobj != NULL) {
        atomic_add_int(&drawfs_vmobj_deallocs, 1);
        vm_object_deallocate(sf->vmobj);
        sf->vmobj = NULL;
    }

    free(sf, M_DRAWFS);
    return (0);
}

/*
 * Select a surface for mmap on this session.
 * Acquires and releases s->lock internally.
 */
int
drawfs_surface_select_for_mmap(struct drawfs_session *s,
    uint32_t surface_id, uint32_t *out_stride_bytes, uint32_t *out_bytes_total)
{
    struct drawfs_surface *sf;

    *out_stride_bytes = 0;
    *out_bytes_total = 0;

    if (surface_id == 0)
        return (EINVAL);

    sf = NULL;
    mtx_lock(&s->lock);
    TAILQ_FOREACH(sf, &s->surfaces, link) {
        if (sf->id == surface_id)
            break;
    }
    if (sf != NULL) {
        s->map_surface_id = surface_id;
        *out_stride_bytes = sf->stride_bytes;
        *out_bytes_total = sf->bytes_total;
    }
    mtx_unlock(&s->lock);

    if (sf == NULL)
        return (ENOENT);

    return (0);
}

/*
 * Get or allocate the VM object for the currently selected mmap surface.
 *
 * AD-18.2: vm_pager_allocate must NOT be called with s->lock held
 * (see locking rules in drawfs.c:182-198). The lock is released
 * around the allocation. Two race windows are handled on re-acquire:
 *
 *   - The selected surface may have been destroyed during our
 *     unlocked window (concurrent SURFACE_DESTROY ioctl). We re-find
 *     by the surface id we pinned at first lock-hold; if absent,
 *     we deallocate our redundant vm_object and return ENOENT.
 *
 *   - Another mmap on the same fd may have raced ahead and installed
 *     a vm_object on the same surface (install race). We use the
 *     winner's vm_object, deallocate ours, and bump
 *     drawfs_vmobj_install_lost for observability. Both
 *     vm_object_deallocate calls happen after mtx_unlock, per the
 *     "no vm_object_deallocate with s->lock held" rule.
 *
 * Pinning by surface id rather than pointer is safe because surface
 * ids are monotonic (s->next_surface_id++ in drawfs_surface_create)
 * and never reused. Surface bytes_total is immutable post-create,
 * so the pinned size remains correct across the unlocked window.
 *
 * s->closing cannot flip during this call: it is set only in
 * drawfs_session_free, which runs from devfs's priv_dtor after all
 * in-flight syscalls return.
 *
 * Returns vm_object with reference added on success, NULL on failure.
 * Sets *status_out to 0 on success or an errno on failure.
 */
vm_object_t
drawfs_surface_get_vmobj(struct drawfs_session *s, vm_size_t size,
    int *status_out)
{
    struct drawfs_surface *sf;
    vm_object_t obj, new_obj;
    uint32_t pinned_id;
    vm_size_t pinned_bytes;

    *status_out = 0;
    sf = NULL;
    new_obj = NULL;

    mtx_lock(&s->lock);

    if (s->map_surface_id != 0) {
        TAILQ_FOREACH(sf, &s->surfaces, link) {
            if (sf->id == s->map_surface_id)
                break;
        }
    }

    if (sf == NULL) {
        mtx_unlock(&s->lock);
        *status_out = ENOENT;
        return (NULL);
    }

    if (size > (vm_size_t)sf->bytes_total) {
        mtx_unlock(&s->lock);
        *status_out = EINVAL;
        return (NULL);
    }

    /* Fast path: vmobj already exists, just take a reference. */
    if (sf->vmobj != NULL) {
        vm_object_reference(sf->vmobj);
        obj = sf->vmobj;
        mtx_unlock(&s->lock);
        return (obj);
    }

    /*
     * Slow path: vmobj needs allocation. Pin the surface id and
     * its (immutable) bytes_total, drop the lock for the
     * vm_pager_allocate call, then re-validate on re-acquire.
     */
    pinned_id = sf->id;
    pinned_bytes = (vm_size_t)sf->bytes_total;
    mtx_unlock(&s->lock);

    new_obj = vm_pager_allocate(OBJT_SWAP, NULL, pinned_bytes,
        VM_PROT_DEFAULT, 0, NULL);
    if (new_obj == NULL) {
        *status_out = ENOMEM;
        return (NULL);
    }

    mtx_lock(&s->lock);

    /* Re-find the surface by pinned id. */
    sf = NULL;
    TAILQ_FOREACH(sf, &s->surfaces, link) {
        if (sf->id == pinned_id)
            break;
    }

    if (sf == NULL) {
        /* Surface was destroyed during our unlocked window. */
        mtx_unlock(&s->lock);
        vm_object_deallocate(new_obj);
        atomic_add_int(&drawfs_vmobj_deallocs, 1);
        *status_out = ENOENT;
        return (NULL);
    }

    if (sf->vmobj != NULL) {
        /*
         * Install race: another mmap raced us and installed first.
         * Use theirs; deallocate ours.
         */
        vm_object_reference(sf->vmobj);
        obj = sf->vmobj;
        mtx_unlock(&s->lock);
        vm_object_deallocate(new_obj);
        atomic_add_int(&drawfs_vmobj_deallocs, 1);
        atomic_add_int(&drawfs_vmobj_install_lost, 1);
        return (obj);
    }

    /* We won the install race. */
    sf->vmobj = new_obj;
    atomic_add_int(&drawfs_vmobj_allocs, 1);
    vm_object_reference(sf->vmobj);
    obj = sf->vmobj;

    mtx_unlock(&s->lock);
    return (obj);
}

/*
 * Free all surfaces in a session.
 * Called during session teardown after s->closing is set.
 *
 * AD-18.6: hold s->lock for all structural operations on
 * s->surfaces (TAILQ_REMOVE) and for all updates of session
 * state (s->map_surface_id, s->surfaces_count,
 * s->surfaces_bytes), per the locking-model invariant
 * (drawfs.c:218-235). Release the lock around
 * vm_object_deallocate, per the same invariant.
 *
 * In practice, by the time priv_dtor calls this function the
 * session has already been removed from the global registry
 * (drawfs.c:904-906) and no concurrent access is possible:
 * any other thread looking up this session's surfaces would
 * have failed at the global-registry lookup. The lock here
 * is therefore defense-in-depth, ensuring the function obeys
 * the documented invariants regardless of how it might be
 * called in the future.
 */
void
drawfs_surfaces_free_all(struct drawfs_session *s)
{
    struct drawfs_surface *sf;
    vm_object_t vmobj;
    uint64_t bytes_to_remove;

    for (;;) {
        mtx_lock(&s->lock);

        sf = TAILQ_FIRST(&s->surfaces);
        if (sf == NULL) {
            /*
             * List empty. Defensive accounting reset: if any
             * stat drift accumulated despite per-surface
             * decrements above, snap to zero now while the
             * lock is held.
             */
            s->surfaces_count = 0;
            s->surfaces_bytes = 0;
            mtx_unlock(&s->lock);
            return;
        }

        TAILQ_REMOVE(&s->surfaces, sf, link);

        if (s->map_surface_id == sf->id)
            s->map_surface_id = 0;

        vmobj = sf->vmobj;
        sf->vmobj = NULL;

        if (s->surfaces_count > 0)
            s->surfaces_count--;

        bytes_to_remove = sf->bytes_total;
        if (s->surfaces_bytes >= bytes_to_remove)
            s->surfaces_bytes -= bytes_to_remove;
        else
            s->surfaces_bytes = 0;

        mtx_unlock(&s->lock);

        /* vm_object_deallocate must run unlocked. */
        if (vmobj != NULL) {
            atomic_add_int(&drawfs_vmobj_deallocs, 1);
            vm_object_deallocate(vmobj);
        }

        free(sf, M_DRAWFS);
    }
}
