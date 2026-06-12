# setfmt: F.3.e (ADR 0019) format-ioctl exerciser. See setfmt.c.
# Drives the GET / no-op / EINVAL closure criteria that playtone
# cannot reach (playtone validates its rate client-side).

PROG=		setfmt
SRCS=		setfmt.c
CFLAGS+=	-O2 -Wall
# Pull in the audiofs ioctl ABI (struct audiofs_format, AUDIOFS_IOC_*).
CFLAGS+=	-I${.CURDIR}/../../sys/dev/audiofs

MAN=

.include <bsd.prog.mk>
