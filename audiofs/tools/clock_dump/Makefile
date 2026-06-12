# clock_dump bench tool for F.4 (ADR 0018). Reads
# /var/run/sema/clock and prints the decoded clock region.
# Used to verify the audiofs kernel clock writer: valid flip,
# monotonic samples_written, sample_rate, and no regression
# across a stop/start cycle.

PROG=		clock_dump
SRCS=		clock_dump.c
CFLAGS+=	-O2 -Wall

# No man page in v1; same convention as playtone and
# audiofs_events_dump.
MAN=

.include <bsd.prog.mk>
