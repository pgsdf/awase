.PATH: ${.CURDIR}/../../dev/drawfs
KMOD=   drawfs
SRCS=   drawfs.c drawfs_surface.c drawfs_frame.c drawfs_efifb.c
SRCS+=  opt_global.h

# drawfs_drm.c implements the Phase 2 DRM/KMS backend.
# It requires drm-kmod headers and is excluded from the default build.
# To enable: install drm-kmod, add drawfs_drm.c to SRCS, and set
# CFLAGS+=-DDRAWFS_DRM_ENABLED

.include <bsd.kmod.mk>
