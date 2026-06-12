.PATH: ${.CURDIR}/../../dev/inputfs
KMOD=	inputfs
SRCS=	inputfs.c
SRCS+=	inputfs_parser.c
SRCS+=	inputfs_kbdmux.c
SRCS+=	inputfs_smooth.c
SRCS+=	opt_global.h opt_kbd.h
SRCS+=	bus_if.h device_if.h vnode_if.h

.include <bsd.kmod.mk>
