/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * audiofs F.2 events-ring layout.
 *
 * Byte-level schema mirror of shared/AUDIO_EVENTS.md. The
 * structs below are the on-disk / in-region representation
 * published to /var/run/sema/audio/events. Every field offset
 * and the total region size are enforced against the spec by
 * _Static_assert at the bottom of this header.
 *
 * Design ADR: audiofs/docs/adr/0013-f2-events-ring.md
 * Schema:     shared/AUDIO_EVENTS.md
 *
 * Lock-free single-producer (audiofs) / multi-consumer ring,
 * mirroring shared/INPUT_EVENTS.md. Physics-only per ADR 0007.
 *
 * Copyright (c) 2026 PGSDF
 */

#ifndef _AUDIOFS_EVENTS_H_
#define _AUDIOFS_EVENTS_H_

#include <sys/types.h>

/* Magic: "AUEV" big-endian mnemonic; on disk little-endian. */
#define	AUDIOFS_EVENTS_MAGIC		0x41554556u
#define	AUDIOFS_EVENTS_VERSION		1u

#define	AUDIOFS_EVENTS_PATH		"/var/run/sema/audio/events"

/* v1 ring geometry. slot_count must be a power of two. */
#define	AUDIOFS_EVENTS_SLOT_COUNT	256
#define	AUDIOFS_EVENTS_SLOT_SIZE	64
#define	AUDIOFS_EVENTS_SLOT_MASK	(AUDIOFS_EVENTS_SLOT_COUNT - 1)

/* source_role values. */
#define	AUDIOFS_EVROLE_STREAM		1
#define	AUDIOFS_EVROLE_ENDPOINT		2

/* event_type values under role STREAM. */
#define	AUDIOFS_EVSTREAM_BEGIN		1
#define	AUDIOFS_EVSTREAM_END		2
#define	AUDIOFS_EVSTREAM_XRUN		3
#define	AUDIOFS_EVSTREAM_FORMAT_CHANGE	4

/* event_type values under role ENDPOINT. */
#define	AUDIOFS_EVENDPOINT_ATTACH	1
#define	AUDIOFS_EVENDPOINT_DETACH	2
#define	AUDIOFS_EVENDPOINT_INVENTORY_FULL	3

/* flags bits. */
#define	AUDIOFS_EVFLAG_SYNTHESISED	0x00000001u
#define	AUDIOFS_EVFLAG_COALESCED		0x00000002u

/* endpoint_slot sentinel: event not tied to a specific endpoint. */
#define	AUDIOFS_EVENTS_NO_ENDPOINT	0xffff

/* xrun_kind values. */
#define	AUDIOFS_XRUN_UNDERRUN		0
#define	AUDIOFS_XRUN_OVERRUN		1

/*
 * Ring header. 64 bytes. Field order and offsets per
 * shared/AUDIO_EVENTS.md "Header (64 bytes, offset 0)".
 */
struct audiofs_events_header {
	uint32_t	magic;		/* 0  */
	uint8_t		version;	/* 4  */
	uint8_t		ring_valid;	/* 5  */
	uint16_t	event_size;	/* 6  */
	uint32_t	slot_count;	/* 8  */
	uint32_t	_pad0;		/* 12 */
	uint64_t	writer_seq;	/* 16 */
	uint64_t	earliest_seq;	/* 24 */
	uint8_t		_pad1[32];	/* 32 */
} __packed;

/*
 * Event slot. 64 bytes. Per shared/AUDIO_EVENTS.md
 * "Event slot (64 bytes each, starts at offset 64)".
 * The payload is a raw 32-byte buffer; per-event-type layouts
 * are overlaid by the publisher and parsed by the reader using
 * the payload-struct definitions below.
 */
struct audiofs_event_slot {
	uint64_t	seq;		/* 0  */
	uint64_t	ts_ordering;	/* 8  */
	uint64_t	ts_sync;	/* 16 */
	uint16_t	endpoint_slot;	/* 24 */
	uint8_t		source_role;	/* 26 */
	uint8_t		event_type;	/* 27 */
	uint32_t	flags;		/* 28 */
	uint8_t		payload[32];	/* 32 */
} __packed;

/*
 * Full region. Header + power-of-two slot array.
 * Total: 64 + 256*64 = 16448 bytes.
 */
struct audiofs_events_region {
	struct audiofs_events_header	header;
	struct audiofs_event_slot	slots[AUDIOFS_EVENTS_SLOT_COUNT];
} __packed;

#define	AUDIOFS_EVENTS_SIZE	(sizeof(struct audiofs_events_region))

/*
 * Per-event-type payload overlays (occupy the 32-byte payload).
 * Each is <= 32 bytes; the publisher zero-fills payload then
 * writes the relevant overlay fields.
 */

/* role STREAM, type BEGIN. */
struct audiofs_evp_stream_begin {
	uint32_t	stream_id;	/* 0  */
	uint16_t	format;		/* 4  */
	uint8_t		channels;	/* 6  */
	uint8_t		_pad;		/* 7  */
	uint32_t	rate_hz;	/* 8  */
} __packed;

/* role STREAM, type END. */
struct audiofs_evp_stream_end {
	uint32_t	stream_id;	/* 0  */
	uint32_t	_pad;		/* 4  */
	uint64_t	frames_total;	/* 8  */
} __packed;

/* role STREAM, type XRUN. */
struct audiofs_evp_xrun {
	uint32_t	stream_id;	/* 0  */
	uint8_t		xrun_kind;	/* 4  */
	uint8_t		_pad[3];	/* 5  */
	uint64_t	gap_sample_pos;	/* 8  */
	uint32_t	gap_frames;	/* 16 */
} __packed;

/* role STREAM, type FORMAT_CHANGE. */
struct audiofs_evp_format_change {
	uint32_t	stream_id;	/* 0  */
	uint16_t	old_format;	/* 4  */
	uint16_t	new_format;	/* 6  */
	uint32_t	new_rate_hz;	/* 8  */
} __packed;

/* role ENDPOINT, type ATTACH. */
struct audiofs_evp_endpoint_attach {
	uint32_t	endpoint_id;	/* 0  */
	uint8_t		kind;		/* 4  */
	uint8_t		direction;	/* 5  */
	uint8_t		controller_idx;	/* 6  */
} __packed;

/* role ENDPOINT, type DETACH. */
struct audiofs_evp_endpoint_detach {
	uint32_t	endpoint_id;	/* 0  */
} __packed;

/* role ENDPOINT, type INVENTORY_FULL. */
struct audiofs_evp_inventory_full {
	uint32_t	_pad;		/* 0  */
	uint8_t		attempted_kind;	/* 4  */
	uint8_t		which;		/* 5  */
} __packed;

/* --- Schema enforcement against shared/AUDIO_EVENTS.md --- */

_Static_assert(sizeof(struct audiofs_events_header) == 64,
    "audiofs_events_header must be 64 bytes");
_Static_assert(sizeof(struct audiofs_event_slot) == 64,
    "audiofs_event_slot must be 64 bytes");
_Static_assert(sizeof(struct audiofs_events_region) == 16448,
    "audiofs_events_region must be 16448 bytes");

/* Header field offsets. */
_Static_assert(__offsetof(struct audiofs_events_header, magic) == 0, "ev.magic@0");
_Static_assert(__offsetof(struct audiofs_events_header, version) == 4, "ev.version@4");
_Static_assert(__offsetof(struct audiofs_events_header, ring_valid) == 5, "ev.ring_valid@5");
_Static_assert(__offsetof(struct audiofs_events_header, event_size) == 6, "ev.event_size@6");
_Static_assert(__offsetof(struct audiofs_events_header, slot_count) == 8, "ev.slot_count@8");
_Static_assert(__offsetof(struct audiofs_events_header, writer_seq) == 16, "ev.writer_seq@16");
_Static_assert(__offsetof(struct audiofs_events_header, earliest_seq) == 24, "ev.earliest_seq@24");

/* Event slot field offsets. */
_Static_assert(__offsetof(struct audiofs_event_slot, seq) == 0, "slot.seq@0");
_Static_assert(__offsetof(struct audiofs_event_slot, ts_ordering) == 8, "slot.ts_ordering@8");
_Static_assert(__offsetof(struct audiofs_event_slot, ts_sync) == 16, "slot.ts_sync@16");
_Static_assert(__offsetof(struct audiofs_event_slot, endpoint_slot) == 24, "slot.endpoint_slot@24");
_Static_assert(__offsetof(struct audiofs_event_slot, source_role) == 26, "slot.source_role@26");
_Static_assert(__offsetof(struct audiofs_event_slot, event_type) == 27, "slot.event_type@27");
_Static_assert(__offsetof(struct audiofs_event_slot, flags) == 28, "slot.flags@28");
_Static_assert(__offsetof(struct audiofs_event_slot, payload) == 32, "slot.payload@32");

/* Payload overlay sanity (each must fit in 32 bytes). */
_Static_assert(sizeof(struct audiofs_evp_stream_begin) <= 32, "evp_stream_begin <= 32");
_Static_assert(sizeof(struct audiofs_evp_stream_end) <= 32, "evp_stream_end <= 32");
_Static_assert(sizeof(struct audiofs_evp_xrun) <= 32, "evp_xrun <= 32");
_Static_assert(sizeof(struct audiofs_evp_format_change) <= 32, "evp_format_change <= 32");
_Static_assert(sizeof(struct audiofs_evp_endpoint_attach) <= 32, "evp_endpoint_attach <= 32");
_Static_assert(sizeof(struct audiofs_evp_endpoint_detach) <= 32, "evp_endpoint_detach <= 32");
_Static_assert(sizeof(struct audiofs_evp_inventory_full) <= 32, "evp_inventory_full <= 32");

/* slot_count is a power of two. */
_Static_assert((AUDIOFS_EVENTS_SLOT_COUNT & (AUDIOFS_EVENTS_SLOT_COUNT - 1)) == 0,
    "AUDIOFS_EVENTS_SLOT_COUNT must be a power of two");

#endif /* _AUDIOFS_EVENTS_H_ */
