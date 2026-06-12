/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * audiofs F.1 state-region layout.
 *
 * Byte-level schema mirror of shared/AUDIO_STATE.md. The
 * structs below are the on-disk / in-region representation
 * published to /var/run/sema/audio/state. Every field offset
 * and the total region size are enforced against the spec by
 * _Static_assert at the bottom of this header.
 *
 * Design ADR: audiofs/docs/adr/0012-f1-state-file.md
 * Schema:     shared/AUDIO_STATE.md
 *
 * Physics-only per ADR 0007: this region carries what the
 * hardware can do and is currently doing, not policy.
 *
 * Copyright (c) 2026 PGSDF
 */

#ifndef _AUDIOFS_STATE_H_
#define _AUDIOFS_STATE_H_

#include <sys/types.h>

/* Magic: "AUST" big-endian mnemonic; on disk little-endian. */
#define	AUDIOFS_STATE_MAGIC		0x54535541u
#define	AUDIOFS_STATE_VERSION		1u

#define	AUDIOFS_STATE_PATH		"/var/run/sema/audio/state"
#define	AUDIOFS_STATE_PARENT		"/var/run/sema"
#define	AUDIOFS_STATE_DIR		"/var/run/sema/audio"

/* v1 slot capacities. */
#define	AUDIOFS_STATE_CONTROLLER_SLOTS	8
#define	AUDIOFS_STATE_ENDPOINT_SLOTS	32

/* Controller subtype. */
#define	AUDIOFS_CTRL_SUBTYPE_UNUSED	0
#define	AUDIOFS_CTRL_SUBTYPE_PCI_HDA	1
#define	AUDIOFS_CTRL_SUBTYPE_USB_AUDIO	2	/* reserved, F.3 future */

/* Endpoint direction. */
#define	AUDIOFS_EP_DIR_UNUSED		0
#define	AUDIOFS_EP_DIR_OUTPUT		1
#define	AUDIOFS_EP_DIR_INPUT		2
#define	AUDIOFS_EP_DIR_LOOPBACK		3	/* reserved */

/* Endpoint-kind enum (shared/AUDIO_STATE.md). */
#define	AUDIOFS_EP_KIND_UNUSED		0
#define	AUDIOFS_EP_KIND_SPEAKER		1
#define	AUDIOFS_EP_KIND_HEADPHONE	2
#define	AUDIOFS_EP_KIND_LINE_OUT	3
#define	AUDIOFS_EP_KIND_MIC		4
#define	AUDIOFS_EP_KIND_LINE_IN		5
#define	AUDIOFS_EP_KIND_HDMI		6
#define	AUDIOFS_EP_KIND_DISPLAYPORT	7
#define	AUDIOFS_EP_KIND_SPDIF		8
/* 9..15 reserved */

/*
 * Header. 64 bytes. Field order and offsets per
 * shared/AUDIO_STATE.md "Header (64 bytes, offset 0)".
 */
struct audiofs_state_header {
	uint32_t	magic;			/* 0  */
	uint8_t		version;		/* 4  */
	uint8_t		state_valid;		/* 5  */
	uint8_t		controller_count;	/* 6  */
	uint8_t		endpoint_count;		/* 7  */
	uint32_t	seqlock;		/* 8  */
	uint32_t	inventory_seq;		/* 12 */
	uint64_t	last_event_seq;		/* 16 */
	uint8_t		controller_slot_count;	/* 24 */
	uint8_t		endpoint_slot_count;	/* 25 */
	uint8_t		controller_slot_size;	/* 26 */
	uint8_t		endpoint_slot_size;	/* 27 */
	uint8_t		_pad[36];		/* 28 */
} __packed;

/*
 * Controller slot. 64 bytes. Per shared/AUDIO_STATE.md
 * "Controller inventory".
 */
struct audiofs_state_controller {
	uint32_t	controller_id;		/* 0  */
	uint8_t		subtype;		/* 4  */
	uint8_t		_pad0[3];		/* 5  */
	uint16_t	pci_vendor;		/* 8  */
	uint16_t	pci_device;		/* 10 */
	uint16_t	pci_subvendor;		/* 12 */
	uint16_t	pci_subdevice;		/* 14 */
	uint8_t		num_iss;		/* 16 */
	uint8_t		num_oss;		/* 17 */
	uint8_t		num_bss;		/* 18 */
	uint8_t		support_64bit;		/* 19 */
	uint32_t	_pad1;			/* 20 */
	char		name[40];		/* 24 */
} __packed;

/*
 * Endpoint slot. 64 bytes. Per shared/AUDIO_STATE.md
 * "Endpoint inventory".
 */
struct audiofs_state_endpoint {
	uint32_t	endpoint_id;		/* 0  */
	uint8_t		controller_idx;		/* 4  */
	uint8_t		codec_addr;		/* 5  */
	uint8_t		kind;			/* 6  */
	uint8_t		direction;		/* 7  */
	uint16_t	pin_nid;		/* 8  */
	uint16_t	converter_nid;		/* 10 */
	uint8_t		electrically_ready;	/* 12 */
	uint8_t		runtime_active;		/* 13 */
	uint16_t	current_format;		/* 14 */
	uint32_t	rate_mask;		/* 16 */
	uint32_t	bit_depth_mask;		/* 20 */
	uint8_t		channel_mask;		/* 24 */
	uint8_t		_pad0[7];		/* 25 */
	char		name[32];		/* 32 */
} __packed;

/*
 * Full region. Header + controller array + endpoint array.
 * Total: 64 + 8*64 + 32*64 = 2624 bytes.
 */
struct audiofs_state_region {
	struct audiofs_state_header	header;
	struct audiofs_state_controller	controllers[AUDIOFS_STATE_CONTROLLER_SLOTS];
	struct audiofs_state_endpoint	endpoints[AUDIOFS_STATE_ENDPOINT_SLOTS];
} __packed;

#define	AUDIOFS_STATE_SIZE	(sizeof(struct audiofs_state_region))

/* --- Schema enforcement against shared/AUDIO_STATE.md --- */

_Static_assert(sizeof(struct audiofs_state_header) == 64,
    "audiofs_state_header must be 64 bytes");
_Static_assert(sizeof(struct audiofs_state_controller) == 64,
    "audiofs_state_controller must be 64 bytes");
_Static_assert(sizeof(struct audiofs_state_endpoint) == 64,
    "audiofs_state_endpoint must be 64 bytes");
_Static_assert(sizeof(struct audiofs_state_region) == 2624,
    "audiofs_state_region must be 2624 bytes");

/* Header field offsets. */
_Static_assert(__offsetof(struct audiofs_state_header, magic) == 0, "magic@0");
_Static_assert(__offsetof(struct audiofs_state_header, version) == 4, "version@4");
_Static_assert(__offsetof(struct audiofs_state_header, state_valid) == 5, "state_valid@5");
_Static_assert(__offsetof(struct audiofs_state_header, controller_count) == 6, "controller_count@6");
_Static_assert(__offsetof(struct audiofs_state_header, endpoint_count) == 7, "endpoint_count@7");
_Static_assert(__offsetof(struct audiofs_state_header, seqlock) == 8, "seqlock@8");
_Static_assert(__offsetof(struct audiofs_state_header, inventory_seq) == 12, "inventory_seq@12");
_Static_assert(__offsetof(struct audiofs_state_header, last_event_seq) == 16, "last_event_seq@16");
_Static_assert(__offsetof(struct audiofs_state_header, controller_slot_count) == 24, "controller_slot_count@24");
_Static_assert(__offsetof(struct audiofs_state_header, endpoint_slot_count) == 25, "endpoint_slot_count@25");
_Static_assert(__offsetof(struct audiofs_state_header, controller_slot_size) == 26, "controller_slot_size@26");
_Static_assert(__offsetof(struct audiofs_state_header, endpoint_slot_size) == 27, "endpoint_slot_size@27");

/* Controller slot field offsets. */
_Static_assert(__offsetof(struct audiofs_state_controller, controller_id) == 0, "ctrl.controller_id@0");
_Static_assert(__offsetof(struct audiofs_state_controller, subtype) == 4, "ctrl.subtype@4");
_Static_assert(__offsetof(struct audiofs_state_controller, pci_vendor) == 8, "ctrl.pci_vendor@8");
_Static_assert(__offsetof(struct audiofs_state_controller, pci_device) == 10, "ctrl.pci_device@10");
_Static_assert(__offsetof(struct audiofs_state_controller, pci_subvendor) == 12, "ctrl.pci_subvendor@12");
_Static_assert(__offsetof(struct audiofs_state_controller, pci_subdevice) == 14, "ctrl.pci_subdevice@14");
_Static_assert(__offsetof(struct audiofs_state_controller, num_iss) == 16, "ctrl.num_iss@16");
_Static_assert(__offsetof(struct audiofs_state_controller, num_oss) == 17, "ctrl.num_oss@17");
_Static_assert(__offsetof(struct audiofs_state_controller, num_bss) == 18, "ctrl.num_bss@18");
_Static_assert(__offsetof(struct audiofs_state_controller, support_64bit) == 19, "ctrl.support_64bit@19");
_Static_assert(__offsetof(struct audiofs_state_controller, name) == 24, "ctrl.name@24");

/* Endpoint slot field offsets. */
_Static_assert(__offsetof(struct audiofs_state_endpoint, endpoint_id) == 0, "ep.endpoint_id@0");
_Static_assert(__offsetof(struct audiofs_state_endpoint, controller_idx) == 4, "ep.controller_idx@4");
_Static_assert(__offsetof(struct audiofs_state_endpoint, codec_addr) == 5, "ep.codec_addr@5");
_Static_assert(__offsetof(struct audiofs_state_endpoint, kind) == 6, "ep.kind@6");
_Static_assert(__offsetof(struct audiofs_state_endpoint, direction) == 7, "ep.direction@7");
_Static_assert(__offsetof(struct audiofs_state_endpoint, pin_nid) == 8, "ep.pin_nid@8");
_Static_assert(__offsetof(struct audiofs_state_endpoint, converter_nid) == 10, "ep.converter_nid@10");
_Static_assert(__offsetof(struct audiofs_state_endpoint, electrically_ready) == 12, "ep.electrically_ready@12");
_Static_assert(__offsetof(struct audiofs_state_endpoint, runtime_active) == 13, "ep.runtime_active@13");
_Static_assert(__offsetof(struct audiofs_state_endpoint, current_format) == 14, "ep.current_format@14");
_Static_assert(__offsetof(struct audiofs_state_endpoint, rate_mask) == 16, "ep.rate_mask@16");
_Static_assert(__offsetof(struct audiofs_state_endpoint, bit_depth_mask) == 20, "ep.bit_depth_mask@20");
_Static_assert(__offsetof(struct audiofs_state_endpoint, channel_mask) == 24, "ep.channel_mask@24");
_Static_assert(__offsetof(struct audiofs_state_endpoint, name) == 32, "ep.name@32");

#endif /* _AUDIOFS_STATE_H_ */
