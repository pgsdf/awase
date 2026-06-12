.PATH: ${.CURDIR}/../../dev/drawfs
KMOD=   drawfs
SRCS=   drawfs.c drawfs_surface.c drawfs_frame.c
SRCS+=  opt_global.h

#
# Optional DRM/KMS backend gating.
#
# By default (DRAWFS_DRM_ENABLED unset) drawfs.ko is built as a pure
# swap-backed /dev/draw device with zero DRM references and no drm-kmod
# build-time or load-time dependency. This is the project's unbreakable
# default path — every invariant below must hold for it:
#
#   - SRCS does not include drawfs_drm.c
#   - CFLAGS does not contain -DDRAWFS_DRM_ENABLED
#   - No drm_* kernel symbols are referenced
#
# To opt in, pass DRAWFS_DRM_ENABLED=1 to make(1). The project-level
# drawfs/build.sh does this when DRAWFS_DRM=true in .config.
#
# Example (manual):
#   pkg install drm-kmod
#   cd /usr/src/sys/modules/drawfs
#   make DRAWFS_DRM_ENABLED=1
#
.if defined(DRAWFS_DRM_ENABLED)
SRCS+=  drawfs_drm.c
CFLAGS+= -DDRAWFS_DRM_ENABLED
.endif

.include <bsd.kmod.mk>
