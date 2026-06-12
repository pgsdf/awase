# Bench-safety test program for F.3.b user-controlled
# playback. See playtone.c for what it does.

PROG=		playtone
SRCS=		playtone.c
LDFLAGS+=	-lm
CFLAGS+=	-O2 -Wall
# F.3.e: pull in the audiofs ioctl ABI (struct audiofs_format,
# AUDIOFS_IOC_*) for the --setrate option.
CFLAGS+=	-I${.CURDIR}/../../sys/dev/audiofs

# No man page. The "NO_MAN=1" form was deprecated in FreeBSD's
# bsd.prog.mk; "MAN=" (empty) is the portable way to say "this
# program has no man page".
MAN=

.include <bsd.prog.mk>
