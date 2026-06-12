/*
 * drawfs_efifb.c — EFI framebuffer backend for drawfs
 *
 * Maps the UEFI GOP framebuffer passed by the bootloader and blits
 * rendered surface buffers directly to it on SURFACE_PRESENT.
 *
 * This allows drawfs to take over the display from vt_efifb without
 * requiring DRM/KMS or any GPU driver.
 *
 * Physical framebuffer address and geometry are read from the
 * MODINFOMD_EFI_FB metadata block that the EFI loader populates —
 * the same source used by sys/dev/vt/hw/efifb/efifb.c.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/linker.h>
#include <sys/module.h>
#include <vm/vm.h>
#include <vm/pmap.h>
#include <machine/metadata.h>

#include "drawfs.h"
#include "drawfs_efifb.h"

/* -------------------------------------------------------------------------
 * State
 * -------------------------------------------------------------------------
 */

static struct drawfs_efifb_state {
    /* Physical base address from EFI GOP */
    uint64_t    fb_paddr;
    /* Mapped virtual address (write-combining) */
    vm_offset_t fb_vaddr;
    /* Geometry */
    uint32_t    fb_width;
    uint32_t    fb_height;
    uint32_t    fb_stride;   /* bytes per scanline */
    uint32_t    fb_bpp;      /* bits per pixel */
    uint64_t    fb_size;     /* total mapped bytes */
    /* Pixel format masks from EFI GOP */
    uint32_t    mask_red;
    uint32_t    mask_green;
    uint32_t    mask_blue;
    /* Initialised flag */
    int         initialized;
} drawfs_efifb;

/* -------------------------------------------------------------------------
 * Initialisation
 * -------------------------------------------------------------------------
 * Called from drawfs_modevent(MOD_LOAD). Reads the efi_fb metadata
 * block and maps the framebuffer write-combining.
 */
int
drawfs_efifb_init(void)
{
    struct efi_fb   *efifb;
    caddr_t          kmdp;
    uint32_t         depth;

    bzero(&drawfs_efifb, sizeof(drawfs_efifb));

    /* Locate kernel preload metadata */
    kmdp = preload_search_by_type("elf kernel");
    if (kmdp == NULL)
        kmdp = preload_search_by_type("elf64 kernel");
    if (kmdp == NULL) {
        printf("drawfs_efifb: no kernel preload metadata\n");
        return (ENODEV);
    }

    efifb = (struct efi_fb *)preload_search_info(kmdp,
        MODINFO_METADATA | MODINFOMD_EFI_FB);
    if (efifb == NULL) {
        printf("drawfs_efifb: no EFI framebuffer metadata\n");
        return (ENODEV);
    }

    /* Extract geometry */
    drawfs_efifb.fb_paddr  = efifb->fb_addr;
    drawfs_efifb.fb_width  = efifb->fb_width;
    drawfs_efifb.fb_height = efifb->fb_height;

    /* Depth from mask union */
    depth = fls(efifb->fb_mask_red   | efifb->fb_mask_green |
                efifb->fb_mask_blue  | efifb->fb_mask_reserved);
    /* Round up to byte boundary */
    depth = roundup(depth, 8);
    if (depth == 0)
        depth = 32; /* default to 32bpp */

    drawfs_efifb.fb_bpp    = depth;
    drawfs_efifb.fb_stride = efifb->fb_stride * (depth / 8);
    drawfs_efifb.fb_size   = (uint64_t)drawfs_efifb.fb_height *
                              drawfs_efifb.fb_stride;

    drawfs_efifb.mask_red   = efifb->fb_mask_red;
    drawfs_efifb.mask_green = efifb->fb_mask_green;
    drawfs_efifb.mask_blue  = efifb->fb_mask_blue;

    /* Map framebuffer write-combining for performance */
    drawfs_efifb.fb_vaddr = (vm_offset_t)pmap_mapdev_attr(
        (vm_paddr_t)drawfs_efifb.fb_paddr,
        drawfs_efifb.fb_size,
        VM_MEMATTR_WRITE_COMBINING);

    if (drawfs_efifb.fb_vaddr == 0) {
        printf("drawfs_efifb: pmap_mapdev_attr failed\n");
        return (ENOMEM);
    }

    drawfs_efifb.initialized = 1;

    printf("drawfs_efifb: %ux%u stride=%u bpp=%u paddr=0x%llx vaddr=0x%lx\n",
        drawfs_efifb.fb_width,
        drawfs_efifb.fb_height,
        drawfs_efifb.fb_stride,
        drawfs_efifb.fb_bpp,
        (unsigned long long)drawfs_efifb.fb_paddr,
        (unsigned long)drawfs_efifb.fb_vaddr);

    return (0);
}

/* -------------------------------------------------------------------------
 * Teardown
 * -------------------------------------------------------------------------
 */
void
drawfs_efifb_fini(void)
{
    if (drawfs_efifb.fb_vaddr != 0) {
        pmap_unmapdev((void *)drawfs_efifb.fb_vaddr, drawfs_efifb.fb_size);
        drawfs_efifb.fb_vaddr = 0;
    }
    drawfs_efifb.initialized = 0;
}

/* -------------------------------------------------------------------------
 * Blit
 * -------------------------------------------------------------------------
 * Copy a rectangular region from a drawfs surface buffer to the EFI
 * framebuffer. Called from drawfs_reply_surface_present().
 *
 * src        — pointer to the surface's mmap'd pixel buffer (XRGB8888)
 * src_stride — bytes per scanline in the source buffer
 * x, y       — destination offset in the framebuffer
 * w, h       — width and height in pixels to copy
 */
void
drawfs_efifb_blit(const uint8_t *src, uint32_t src_stride,
    uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    uint8_t  *dst;
    uint32_t  row;
    uint32_t  copy_bytes;

    if (!drawfs_efifb.initialized || drawfs_efifb.fb_vaddr == 0)
        return;

    /* Clip to framebuffer bounds */
    if (x >= drawfs_efifb.fb_width || y >= drawfs_efifb.fb_height)
        return;
    if (x + w > drawfs_efifb.fb_width)
        w = drawfs_efifb.fb_width - x;
    if (y + h > drawfs_efifb.fb_height)
        h = drawfs_efifb.fb_height - y;
    if (w == 0 || h == 0)
        return;

    copy_bytes = w * (drawfs_efifb.fb_bpp / 8);

    dst = (uint8_t *)drawfs_efifb.fb_vaddr
        + (uint64_t)y * drawfs_efifb.fb_stride
        + (uint64_t)x * (drawfs_efifb.fb_bpp / 8);

    for (row = 0; row < h; row++) {
        memcpy(dst, src, copy_bytes);
        dst += drawfs_efifb.fb_stride;
        src += src_stride;
    }
}

/* -------------------------------------------------------------------------
 * Full-screen blit
 * -------------------------------------------------------------------------
 * Convenience wrapper: blit an entire surface buffer to the framebuffer
 * origin. The source buffer must be at least fb_width * fb_height * 4 bytes.
 */
void
drawfs_efifb_blit_full(const uint8_t *src, uint32_t src_stride)
{
    drawfs_efifb_blit(src, src_stride,
        0, 0,
        drawfs_efifb.fb_width,
        drawfs_efifb.fb_height);
}

/* -------------------------------------------------------------------------
 * Accessors
 * -------------------------------------------------------------------------
 */
uint8_t *
drawfs_efifb_dst_row(uint32_t row)
{
    if (!drawfs_efifb.initialized || drawfs_efifb.fb_vaddr == 0)
        return (NULL);
    if (row >= drawfs_efifb.fb_height)
        return (NULL);
    return (uint8_t *)drawfs_efifb.fb_vaddr + (uint64_t)row * drawfs_efifb.fb_stride;
}

int      drawfs_efifb_available(void) { return drawfs_efifb.initialized; }
uint32_t drawfs_efifb_width(void)     { return drawfs_efifb.fb_width;    }
uint32_t drawfs_efifb_height(void)    { return drawfs_efifb.fb_height;   }
uint32_t drawfs_efifb_stride(void)    { return drawfs_efifb.fb_stride;   }
uint32_t drawfs_efifb_bpp(void)       { return drawfs_efifb.fb_bpp;      }
