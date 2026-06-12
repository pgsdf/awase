/*
 * drawfs_frame.c - Frame encoding and validation for drawfs protocol
 *
 * This module handles the low-level wire format for the drawfs protocol,
 * including frame header validation and frame construction.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>

#include "drawfs.h"
#include "drawfs_proto.h"
#include "drawfs_internal.h"
#include "drawfs_frame.h"

/*
 * Validate a frame header.
 * Returns DRAWFS_ERR_OK on success, error code otherwise.
 */
int
drawfs_frame_validate(const uint8_t *buf, size_t n,
    struct drawfs_frame_hdr *out_hdr, uint32_t *out_err_offset)
{
    struct drawfs_frame_hdr fh;

    if (n < sizeof(fh)) {
        *out_err_offset = 0;
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    memcpy(&fh, buf, sizeof(fh));

    if (fh.magic != DRAWFS_MAGIC) {
        *out_err_offset = 0;
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    if (fh.version != DRAWFS_VERSION) {
        *out_err_offset = offsetof(struct drawfs_frame_hdr, version);
        return (DRAWFS_ERR_UNSUPPORTED_VERSION);
    }

    if (fh.header_bytes != sizeof(struct drawfs_frame_hdr)) {
        *out_err_offset = offsetof(struct drawfs_frame_hdr, header_bytes);
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    if (fh.frame_bytes < fh.header_bytes) {
        *out_err_offset = offsetof(struct drawfs_frame_hdr, frame_bytes);
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    if (fh.frame_bytes > n) {
        *out_err_offset = offsetof(struct drawfs_frame_hdr, frame_bytes);
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    if ((fh.frame_bytes & 3u) != 0) {
        *out_err_offset = offsetof(struct drawfs_frame_hdr, frame_bytes);
        return (DRAWFS_ERR_INVALID_FRAME);
    }

    *out_hdr = fh;
    *out_err_offset = 0;
    return (DRAWFS_ERR_OK);
}

/*
 * Validate a SURFACE_PRESENT_REGION request payload.
 *
 * This is a PURE validator: it inspects the on-wire bytes and reports
 * whether the request is well-formed per the specification at
 * drawfs/docs/DESIGN-surface-present-region.md § "Error conditions".
 * It does not consult session state, does not look up the surface,
 * does not clamp rects to surface bounds, and does not allocate.
 * Those are dispatch-layer concerns (B3.3 pass 2).
 *
 * On success (DRAWFS_ERR_OK), fills:
 *   - *out_req        — the fixed 24-byte header, copied out
 *   - *out_rects      — pointer into `payload` where the rect array starts.
 *                       Caller MUST NOT free this pointer; it aliases the
 *                       caller's buffer and is valid only as long as
 *                       `payload` is.
 *   - *out_rect_count — number of rects (1..DRAWFS_MAX_PRESENT_RECTS)
 *
 * On error, returns one of:
 *   DRAWFS_ERR_INVALID_FRAME    — payload shorter than the fixed header,
 *                                 or shorter than needed for the declared
 *                                 rect_count.
 *   DRAWFS_ERR_INVALID_MSG      — `_reserved` field is non-zero.
 *   DRAWFS_ERR_UNSUPPORTED_CAP  — `flags` field has any non-zero bit.
 *   DRAWFS_ERR_INVALID_ARG      — rect_count == 0, or any rect has
 *                                 width == 0 or height == 0.
 *   DRAWFS_ERR_OVERFLOW         — rect_count > DRAWFS_MAX_PRESENT_RECTS.
 *
 * The error ordering matches the spec's error table order. Multiple
 * violations return the first one encountered.
 *
 * Note on flags: if any flag bits are ever defined in the future, this
 * validator must be updated to permit them. Until then, strict
 * rejection of non-zero flags catches client bugs early.
 */
int
drawfs_req_surface_present_region_validate(const uint8_t *payload,
    size_t payload_len,
    struct drawfs_req_surface_present_region *out_req,
    const struct drawfs_rect **out_rects,
    uint32_t *out_rect_count)
{
    struct drawfs_req_surface_present_region req;
    size_t expected_bytes;
    uint32_t i;
    const struct drawfs_rect *rects;

    /*
     * Defensive clear. If we return an error partway through, callers
     * who ignore the return value and read the outputs anyway see
     * zeroed memory, not undefined state from the wire.
     */
    bzero(&req, sizeof(req));
    *out_rects = NULL;
    *out_rect_count = 0;

    /* Payload must at least contain the fixed 24-byte header. */
    if (payload_len < sizeof(req))
        return (DRAWFS_ERR_INVALID_FRAME);

    bcopy(payload, &req, sizeof(req));

    /*
     * Strict checks on the header fields. Order matches the spec's
     * error table. Every check has a single clear failure mode.
     */

    /* `_reserved` must be zero (forward-compat guard). */
    if (req._reserved != 0)
        return (DRAWFS_ERR_INVALID_MSG);

    /* No flag bits are defined yet; all must be zero. */
    if (req.flags != 0)
        return (DRAWFS_ERR_UNSUPPORTED_CAP);

    /* Zero rects is a protocol violation — use SURFACE_PRESENT for full. */
    if (req.rect_count == 0)
        return (DRAWFS_ERR_INVALID_ARG);

    /* Protocol-level cap. */
    if (req.rect_count > DRAWFS_MAX_PRESENT_RECTS)
        return (DRAWFS_ERR_OVERFLOW);

    /*
     * The declared rect_count must fit in the supplied payload.
     * This is a wire-format check, not a semantic one — if the client
     * claimed 5 rects but sent bytes for only 3, the frame is malformed.
     */
    expected_bytes = sizeof(req) +
        (size_t)req.rect_count * sizeof(struct drawfs_rect);
    if (payload_len < expected_bytes)
        return (DRAWFS_ERR_INVALID_FRAME);

    /*
     * The rect array starts immediately after the fixed header. Point
     * into the caller's buffer rather than copying — the caller already
     * owns the memory and the dispatch layer will consume it before the
     * buffer is released.
     */
    rects = (const struct drawfs_rect *)(payload + sizeof(req));

    /*
     * Per-rect semantic checks. Negative x/y are allowed (clamping
     * happens in dispatch; off-surface is not an error here). Zero
     * width or height is rejected — it would be a no-op after clamping
     * and indicates a bug upstream.
     */
    for (i = 0; i < req.rect_count; i++) {
        if (rects[i].width == 0 || rects[i].height == 0)
            return (DRAWFS_ERR_INVALID_ARG);
    }

    /* All checks passed. Hand the validated view to the caller. */
    *out_req = req;
    *out_rects = rects;
    *out_rect_count = req.rect_count;
    return (DRAWFS_ERR_OK);
}

/*
 * Build a frame containing one message.
 * Returns allocated buffer on success, NULL on failure.
 */
uint8_t *
drawfs_frame_build(uint32_t frame_id, uint16_t msg_type,
    uint32_t msg_id, const void *payload, size_t payload_len,
    size_t *out_len)
{
    struct drawfs_frame_hdr fh;
    struct drawfs_msg_hdr mh;
    uint32_t msg_bytes;
    uint32_t msg_bytes_aligned;
    uint32_t frame_bytes;
    uint8_t *out;

    msg_bytes = (uint32_t)(sizeof(struct drawfs_msg_hdr) + payload_len);
    msg_bytes_aligned = drawfs_align4(msg_bytes);
    frame_bytes = (uint32_t)sizeof(struct drawfs_frame_hdr) + msg_bytes_aligned;

    out = malloc(frame_bytes, M_DRAWFS, M_WAITOK | M_ZERO);
    if (out == NULL) {
        *out_len = 0;
        return (NULL);
    }

    fh.magic = DRAWFS_MAGIC;
    fh.version = DRAWFS_VERSION;
    fh.header_bytes = (uint16_t)sizeof(struct drawfs_frame_hdr);
    fh.frame_bytes = frame_bytes;
    fh.frame_id = frame_id;

    mh.msg_type = msg_type;
    mh.msg_flags = 0;
    mh.msg_bytes = msg_bytes;
    mh.msg_id = msg_id;
    mh.reserved = 0;

    memcpy(out, &fh, sizeof(fh));
    memcpy(out + sizeof(fh), &mh, sizeof(mh));
    if (payload != NULL && payload_len > 0)
        memcpy(out + sizeof(fh) + sizeof(mh), payload, payload_len);

    *out_len = frame_bytes;
    return (out);
}
