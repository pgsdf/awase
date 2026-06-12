#ifndef _DEV_DRAWFS_DRAWFS_FRAME_H_
#define _DEV_DRAWFS_DRAWFS_FRAME_H_

#include "drawfs_proto.h"

/*
 * Frame encoding and validation for drawfs protocol.
 *
 * This module handles the low-level wire format:
 * - Validating incoming frame headers
 * - Validating incoming message payloads
 * - Building outgoing frames with proper alignment
 */

/*
 * Validate a frame header.
 * Returns DRAWFS_ERR_OK on success, error code otherwise.
 * On success, fills out_hdr with the parsed header.
 * On error, fills out_err_offset with the offset of the problematic field.
 */
int drawfs_frame_validate(const uint8_t *buf, size_t n,
    struct drawfs_frame_hdr *out_hdr, uint32_t *out_err_offset);

/*
 * Validate a SURFACE_PRESENT_REGION request payload.
 *
 * Pure validator: inspects on-wire bytes, produces a validated view
 * without consulting session state. The error table in
 * drawfs/docs/DESIGN-surface-present-region.md § "Error conditions"
 * is authoritative.
 *
 * Returns DRAWFS_ERR_OK on success, with:
 *   - out_req        — filled with the 24-byte fixed header
 *   - out_rects      — pointer into the payload buffer where the rect
 *                      array begins. Aliased, NOT owned. Valid only
 *                      for the lifetime of the `payload` argument.
 *   - out_rect_count — number of rects, always in [1, DRAWFS_MAX_PRESENT_RECTS]
 *
 * Returns one of DRAWFS_ERR_{INVALID_FRAME, INVALID_MSG,
 * UNSUPPORTED_CAP, INVALID_ARG, OVERFLOW} on failure. See the function
 * body for exact mapping.
 *
 * Semantic concerns the dispatch layer handles (not this validator):
 *   - Looking up the surface by surface_id
 *   - Clamping rects to the surface's actual bounds
 *   - Dropping rects entirely outside the surface
 *   - Queue-full / backpressure
 */
int drawfs_req_surface_present_region_validate(const uint8_t *payload,
    size_t payload_len,
    struct drawfs_req_surface_present_region *out_req,
    const struct drawfs_rect **out_rects,
    uint32_t *out_rect_count);

/*
 * Build a frame containing one message.
 * Allocates and returns the frame buffer, sets *out_len to total frame size.
 * Caller must free the returned buffer with free(buf, M_DRAWFS).
 *
 * Parameters:
 *   frame_id    - unique frame identifier
 *   msg_type    - message type (DRAWFS_RPL_*, DRAWFS_EVT_*)
 *   msg_id      - message ID (echoed from request, or 0 for events)
 *   payload     - message payload bytes (may be NULL if payload_len is 0)
 *   payload_len - payload size in bytes
 *   out_len     - receives total frame size
 *
 * Returns allocated buffer on success, NULL on allocation failure.
 */
uint8_t *drawfs_frame_build(uint32_t frame_id, uint16_t msg_type,
    uint32_t msg_id, const void *payload, size_t payload_len,
    size_t *out_len);

#endif /* _DEV_DRAWFS_DRAWFS_FRAME_H_ */
