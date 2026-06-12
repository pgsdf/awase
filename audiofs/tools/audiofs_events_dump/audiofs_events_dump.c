/*-
 * audiofs F.2 events-ring dump tool.
 *
 * Reads /var/run/sema/audio/events and prints decoded events in
 * human-readable form. Built for F.3.d bench verification (ADR
 * 0017): show that xrun events are actually emitted, with the
 * right fields and the right flags.
 *
 * The ring layout is the byte-for-byte schema in
 * audiofs/sys/dev/audiofs/audiofs_events.h, matching
 * shared/AUDIO_EVENTS.md. Header at offset 0 (64 bytes), then
 * 256 slots of 64 bytes each, total 16448 bytes.
 *
 * Build (on FreeBSD):
 *   make                                # uses Makefile (preferred)
 *   cc -O2 -Wall -o audiofs_events_dump audiofs_events_dump.c
 *
 * Usage:
 *   ./audiofs_events_dump                       # all events, latest 32
 *   ./audiofs_events_dump --type xrun           # xrun only
 *   ./audiofs_events_dump --since N             # events with seq > N
 *   ./audiofs_events_dump --raw                 # hex-dump payloads too
 *
 * The tool is purely a reader: it never writes to the ring or
 * modifies kernel state. Safe to run while audio is playing.
 *
 * F.3.d closure protocol:
 *
 *   1. Snapshot writer_seq before the test.
 *      ./audiofs_events_dump --header-only
 *   2. Run the underrun-inducing playtone command.
 *      sudo ./playtone --stall 500 /dev/audiofs0 2
 *   3. Dump xrun events since the snapshot.
 *      ./audiofs_events_dump --type xrun --since <prev_writer_seq>
 *   4. Confirm the dump shows an xrun event with xrun_kind=0,
 *      non-zero gap_sample_pos, non-zero gap_frames.
 *
 * For the sustained-stall test, the dumped xrun events should
 * have AUDIOFS_EVFLAG_COALESCED set on at least one of them,
 * and the total event count should be small (under ~20), not
 * proportional to the FIFOE interrupt rate.
 */

#include <sys/types.h>
#include <err.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Mirror of audiofs_events.h. We can't include the kernel header
 * from a userland tool, so the constants and structs are
 * duplicated here. The _Static_assert lines in the kernel header
 * keep the kernel side honest; matching it here is a manual
 * discipline. */

#define	EVENTS_PATH		"/var/run/sema/audio/events"

#define	AUDIOFS_EVENTS_MAGIC		0x41554556u
#define	AUDIOFS_EVENTS_VERSION		1u
#define	AUDIOFS_EVENTS_SLOT_COUNT	256
#define	AUDIOFS_EVENTS_SLOT_SIZE	64
#define	AUDIOFS_EVENTS_SLOT_MASK	(AUDIOFS_EVENTS_SLOT_COUNT - 1)

#define	AUDIOFS_EVROLE_STREAM		1
#define	AUDIOFS_EVROLE_ENDPOINT		2

#define	AUDIOFS_EVSTREAM_BEGIN		1
#define	AUDIOFS_EVSTREAM_END		2
#define	AUDIOFS_EVSTREAM_XRUN		3
#define	AUDIOFS_EVSTREAM_FORMAT_CHANGE	4

#define	AUDIOFS_EVENDPOINT_ATTACH	1
#define	AUDIOFS_EVENDPOINT_DETACH	2
#define	AUDIOFS_EVENDPOINT_INVENTORY_FULL	3

#define	AUDIOFS_EVFLAG_SYNTHESISED	0x00000001u
#define	AUDIOFS_EVFLAG_COALESCED	0x00000002u

#define	AUDIOFS_XRUN_UNDERRUN		0
#define	AUDIOFS_XRUN_OVERRUN		1

struct audiofs_events_header {
	uint32_t	magic;
	uint8_t		version;
	uint8_t		ring_valid;
	uint16_t	event_size;
	uint32_t	slot_count;
	uint32_t	_pad0;
	uint64_t	writer_seq;
	uint64_t	earliest_seq;
	uint8_t		_pad1[32];
} __attribute__((packed));

struct audiofs_event_slot {
	uint64_t	seq;
	uint64_t	ts_ordering;
	uint64_t	ts_sync;
	uint16_t	endpoint_slot;
	uint8_t		source_role;
	uint8_t		event_type;
	uint32_t	flags;
	uint8_t		payload[32];
} __attribute__((packed));

struct audiofs_evp_xrun {
	uint32_t	stream_id;
	uint8_t		xrun_kind;
	uint8_t		_pad[3];
	uint64_t	gap_sample_pos;
	uint32_t	gap_frames;
} __attribute__((packed));

struct audiofs_evp_stream_begin {
	uint32_t	stream_id;
	uint16_t	format;
	uint8_t		channels;
	uint8_t		_pad;
	uint32_t	rate_hz;
} __attribute__((packed));

struct audiofs_evp_stream_end {
	uint32_t	stream_id;
	uint32_t	_pad;
	uint64_t	frames_total;
} __attribute__((packed));

struct audiofs_evp_format_change {
	uint32_t	stream_id;
	uint16_t	old_format;
	uint16_t	new_format;
	uint32_t	new_rate_hz;
} __attribute__((packed));

#define	EVENTS_TOTAL_SIZE	(sizeof(struct audiofs_events_header) + \
    AUDIOFS_EVENTS_SLOT_COUNT * sizeof(struct audiofs_event_slot))

/* ------------------------------------------------------------ */

static const char *
role_name(uint8_t role)
{
	switch (role) {
	case AUDIOFS_EVROLE_STREAM:	return "stream";
	case AUDIOFS_EVROLE_ENDPOINT:	return "endpoint";
	default:			return "?";
	}
}

static const char *
type_name(uint8_t role, uint8_t type)
{
	if (role == AUDIOFS_EVROLE_STREAM) {
		switch (type) {
		case AUDIOFS_EVSTREAM_BEGIN:		return "begin";
		case AUDIOFS_EVSTREAM_END:		return "end";
		case AUDIOFS_EVSTREAM_XRUN:		return "xrun";
		case AUDIOFS_EVSTREAM_FORMAT_CHANGE:	return "format_change";
		}
	} else if (role == AUDIOFS_EVROLE_ENDPOINT) {
		switch (type) {
		case AUDIOFS_EVENDPOINT_ATTACH:		return "attach";
		case AUDIOFS_EVENDPOINT_DETACH:		return "detach";
		case AUDIOFS_EVENDPOINT_INVENTORY_FULL:	return "inventory_full";
		}
	}
	return "?";
}

static void
fmt_flags(uint32_t f, char *buf, size_t len)
{
	int n = 0;
	buf[0] = '\0';
	if (f & AUDIOFS_EVFLAG_SYNTHESISED)
		n += snprintf(buf + n, len - n, "%ssynthesised",
		    n ? "," : "");
	if (f & AUDIOFS_EVFLAG_COALESCED)
		n += snprintf(buf + n, len - n, "%scoalesced",
		    n ? "," : "");
	if (n == 0)
		snprintf(buf, len, "-");
}

static void
print_payload(const struct audiofs_event_slot *s, int raw)
{
	if (s->source_role == AUDIOFS_EVROLE_STREAM) {
		if (s->event_type == AUDIOFS_EVSTREAM_XRUN) {
			const struct audiofs_evp_xrun *p =
			    (const struct audiofs_evp_xrun *)s->payload;
			printf("  stream_id=%u kind=%s "
			    "gap_sample_pos=%" PRIu64 " gap_frames=%u\n",
			    p->stream_id,
			    p->xrun_kind == AUDIOFS_XRUN_UNDERRUN
			        ? "underrun" : "overrun",
			    p->gap_sample_pos, p->gap_frames);
		} else if (s->event_type == AUDIOFS_EVSTREAM_BEGIN) {
			const struct audiofs_evp_stream_begin *p =
			    (const struct audiofs_evp_stream_begin *)s->payload;
			printf("  stream_id=%u format=0x%04x channels=%u "
			    "rate=%u\n",
			    p->stream_id, p->format, p->channels, p->rate_hz);
		} else if (s->event_type == AUDIOFS_EVSTREAM_END) {
			const struct audiofs_evp_stream_end *p =
			    (const struct audiofs_evp_stream_end *)s->payload;
			printf("  stream_id=%u frames_total=%" PRIu64 "\n",
			    p->stream_id, p->frames_total);
		} else if (s->event_type == AUDIOFS_EVSTREAM_FORMAT_CHANGE) {
			const struct audiofs_evp_format_change *p =
			    (const struct audiofs_evp_format_change *)s->payload;
			printf("  stream_id=%u old_format=0x%04x "
			    "new_format=0x%04x new_rate=%u\n",
			    p->stream_id, p->old_format, p->new_format,
			    p->new_rate_hz);
		}
	}
	if (raw) {
		printf("  payload[32]:");
		for (int i = 0; i < 32; i++)
			printf(" %02x", s->payload[i]);
		printf("\n");
	}
}

static void
usage(const char *prog)
{
	fprintf(stderr,
	    "usage: %s [--type TYPE] [--since SEQ] [--raw] [--header-only]\n"
	    "  --type TYPE    one of: begin, end, xrun, format_change,\n"
	    "                 attach, detach, inventory_full\n"
	    "                 (filter to events of this type only)\n"
	    "  --since SEQ    only show events with seq > SEQ\n"
	    "  --raw          also print payload as hex dump\n"
	    "  --header-only  print ring header (incl. writer_seq) and exit\n",
	    prog);
}

static int
match_type(const char *want, uint8_t role, uint8_t type)
{
	if (want == NULL)
		return (1);
	const char *got = type_name(role, type);
	return (strcmp(want, got) == 0);
}

int
main(int argc, char **argv)
{
	int fd;
	uint8_t buf[EVENTS_TOTAL_SIZE];
	ssize_t n;
	const struct audiofs_events_header *hdr;
	const struct audiofs_event_slot *slots;
	const char *type_filter = NULL;
	uint64_t since_seq = 0;
	int raw = 0;
	int header_only = 0;
	int ai;

	for (ai = 1; ai < argc; ai++) {
		if (strcmp(argv[ai], "--type") == 0 && ai + 1 < argc) {
			type_filter = argv[++ai];
		} else if (strcmp(argv[ai], "--since") == 0 && ai + 1 < argc) {
			since_seq = strtoull(argv[++ai], NULL, 10);
		} else if (strcmp(argv[ai], "--raw") == 0) {
			raw = 1;
		} else if (strcmp(argv[ai], "--header-only") == 0) {
			header_only = 1;
		} else if (strcmp(argv[ai], "--help") == 0 ||
		    strcmp(argv[ai], "-h") == 0) {
			usage(argv[0]);
			return (0);
		} else {
			fprintf(stderr, "unexpected argument: %s\n",
			    argv[ai]);
			usage(argv[0]);
			return (2);
		}
	}

	fd = open(EVENTS_PATH, O_RDONLY);
	if (fd < 0)
		err(1, "open %s", EVENTS_PATH);

	n = read(fd, buf, sizeof(buf));
	if (n < 0)
		err(1, "read %s", EVENTS_PATH);
	if ((size_t)n < sizeof(buf)) {
		errx(1, "short read on %s: got %zd, expected %zu",
		    EVENTS_PATH, n, sizeof(buf));
	}
	(void)close(fd);

	hdr = (const struct audiofs_events_header *)buf;
	slots = (const struct audiofs_event_slot *)(buf +
	    sizeof(struct audiofs_events_header));

	if (hdr->magic != AUDIOFS_EVENTS_MAGIC) {
		errx(1, "bad magic 0x%08x (expected 0x%08x)",
		    hdr->magic, AUDIOFS_EVENTS_MAGIC);
	}

	printf("ring: magic=0x%08x version=%u ring_valid=%u "
	    "slot_count=%u\n",
	    hdr->magic, hdr->version, hdr->ring_valid, hdr->slot_count);
	printf("ring: writer_seq=%" PRIu64 " earliest_seq=%" PRIu64 "\n",
	    hdr->writer_seq, hdr->earliest_seq);

	if (header_only)
		return (0);

	if (!hdr->ring_valid) {
		errx(1, "ring_valid=0; ring contents are not trustworthy");
	}

	/*
	 * Walk the slots in seq order. We pick a starting point at
	 * max(earliest_seq, since_seq+1) and stop at writer_seq-1.
	 * Each slot's index is seq & SLOT_MASK; the seq field in the
	 * slot must match to confirm the slot wasn't overwritten
	 * mid-read.
	 */
	uint64_t start = hdr->earliest_seq;
	if (since_seq + 1 > start)
		start = since_seq + 1;

	int printed = 0;
	for (uint64_t seq = start; seq < hdr->writer_seq; seq++) {
		const struct audiofs_event_slot *s =
		    &slots[seq & AUDIOFS_EVENTS_SLOT_MASK];

		/* Concurrent-writer guard: if seq doesn't match, the
		 * slot has been overwritten. v1 reader behaviour: report
		 * the issue and continue; the bench tests don't generate
		 * enough events to lap the ring. */
		if (s->seq != seq) {
			fprintf(stderr,
			    "WARN: seq=%" PRIu64 " slot mismatch "
			    "(got %" PRIu64 "); ring may have lapped\n",
			    seq, s->seq);
			continue;
		}

		if (!match_type(type_filter, s->source_role, s->event_type))
			continue;

		char flagbuf[64];
		fmt_flags(s->flags, flagbuf, sizeof(flagbuf));

		printf("seq=%" PRIu64 " ts_order=%" PRIu64
		    " role=%s type=%s endpoint=%u flags=%s\n",
		    s->seq, s->ts_ordering,
		    role_name(s->source_role),
		    type_name(s->source_role, s->event_type),
		    s->endpoint_slot, flagbuf);
		print_payload(s, raw);
		printed++;
	}

	fprintf(stderr, "\n%d event(s) printed (seq range: %" PRIu64
	    " .. %" PRIu64 ")\n",
	    printed, start, hdr->writer_seq > 0 ? hdr->writer_seq - 1 : 0);

	return (0);
}
