/*
 * drawfs_efifb.h — EFI framebuffer backend interface
 */

#ifndef _DEV_DRAWFS_DRAWFS_EFIFB_H_
#define _DEV_DRAWFS_DRAWFS_EFIFB_H_

#include <sys/types.h>

/* Initialise: map EFI framebuffer from preload metadata. Returns 0 or errno. */
int      drawfs_efifb_init(void);

/* Release framebuffer mapping. */
void     drawfs_efifb_fini(void);

/* Blit a rectangle from a surface buffer to the framebuffer. */
void     drawfs_efifb_blit(const uint8_t *src, uint32_t src_stride,
             uint32_t x, uint32_t y, uint32_t w, uint32_t h);

/* Blit a full surface buffer to the framebuffer origin. */
void     drawfs_efifb_blit_full(const uint8_t *src, uint32_t src_stride);

/* Get pointer to a destination row in the EFI framebuffer (for kernel blit). */
uint8_t *drawfs_efifb_dst_row(uint32_t row);

/* Query */
int      drawfs_efifb_available(void);
uint32_t drawfs_efifb_width(void);
uint32_t drawfs_efifb_height(void);
uint32_t drawfs_efifb_stride(void);
uint32_t drawfs_efifb_bpp(void);

#endif /* _DEV_DRAWFS_DRAWFS_EFIFB_H_ */
