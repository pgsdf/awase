/*-
 * SPDX-License-Identifier: MIT
 *
 * audiofs: Awase kernel audio substrate (Option A, PCI driver)
 *
 * Copyright (c) 2026 Pacific Geoscience Systems Development Foundation
 *
 * EXPERIMENTAL, NOT CANONICAL.
 *
 * Commits 1-6g of N for the controller bring-up:
 *
 *   - [commit 1] Match HDA controllers by PCI class, allocate
 *     and map BAR0, read GCAP, reset the controller per
 *     HDA 1.0a section 4.3.
 *   - [commit 2] Allocate DMA-backed CORB and RIRB rings,
 *     initialize and start them, send codec commands via
 *     CORB and read responses by polling RIRB. Enumerate
 *     populated codec slots from STATESTS and read each
 *     codec's vendor/device/revision/stepping ids.
 *   - [commit 3] Walk codec topology: query function-group
 *     sub-nodes, classify each FG (audio vs modem), read
 *     its subsystem id, walk widgets, log type and
 *     audio-widget-cap. For pin complexes log the
 *     configuration-default register. Enumerate-and-log
 *     only.
 *   - [commit 4a] Store widget topology in per-codec arrays
 *     indexed by nid offset. For widgets that advertise a
 *     connection list, read it via HDA_CMD_GET_CONN_LIST_ENTRY
 *     and expand spec-encoded ranges into a flat conns[]
 *     array. Per-FG state recorded on codec record. Per-
 *     connection eventlog entries make the full graph
 *     readable from sysctl.
 *   - [commit 4b] For each connected output pin, reverse-
 *     walk the connection graph from pin to DAC, following
 *     conns[0] at each widget. Log paths discovered.
 *   - [commit 5] For each connected output pin: read PIN_CAP
 *     and store it on the widget. Then write the pin widget
 *     control register, setting only bits the pin advertises
 *     it can honor (OUT_ENABLE if OUTPUT_CAP, HPHN_ENABLE
 *     if HEADPHONE_CAP and pin is HP-classed). Read back
 *     and verify. First commit that writes codec state.
 *     Pin amp unmute belongs in commit 6 alongside stream
 *     setup; this commit alone does not produce audible
 *     output.
 *   - [commit 6a] Output amplifier unmute. For each widget on
 *     each discovered output path that advertises an output
 *     amp, query its effective amp cap (widget override or
 *     FG default), set gain to OFFSET (0 dB position) with
 *     mute=0 for both stereo channels, read back, verify.
 *     The codec analog stage is now open; what remains
 *     before audible output is stream descriptor setup and
 *     a DAC bound to a running stream.
 *   - [commit 6b] DAC converter format binding. For each DAC
 *     on a discovered output path, query its supported PCM
 *     size/rate caps and stream-format caps (with FORMAT_OVR
 *     override matching the AMP_OVR pattern). Verify it
 *     supports 48 kHz / 16-bit / PCM. Write the format word
 *     via HDA_CMD_SET_CONV_FMT, read back via
 *     HDA_CMD_GET_CONV_FMT, verify. DAC now knows what
 *     format the stream descriptor will deliver.
 *   - [commit 6c] Output stream descriptor and BDL setup.
 *     Pick output stream slot 0 of the controller's OSS
 *     bank. Allocate a DMA-backed BDL (2 entries, 32 bytes)
 *     and a DMA-backed audio buffer (8 KB, zero-filled).
 *     Reset the stream descriptor, populate BDL entries,
 *     write SDnCBL/SDnLVI/SDnFMT/SDnBDPL/SDnBDPU registers,
 *     set SDnCTL2 STRM field to the assigned stream tag.
 *     RUN bit is deliberately NOT set; stream is configured
 *     but stopped. Stream tag and DAC selection are recorded
 *     on the softc so commit 6d can bind the DAC via
 *     SET_CONV_STREAM_CHAN and set RUN.
 *   - [commit 6d] Output stream RUN and position tracking.
 *     Bind the selected DAC to the stream tag via
 *     HDA_CMD_SET_CONV_STREAM_CHAN with payload
 *     (stream_id << 4) | channel. Set RUN in SDCTL. Sample
 *     SDnLPIB at 10 ms intervals to confirm position
 *     advances (proving the controller is consuming
 *     samples). Clear RUN at the end of the test. The
 *     audio buffer holds zeros so no audible output; this
 *     commit proves the DMA path is live, not that audio
 *     is heard. Commit 6e replaces zeros with a sine wave.
 *   - [commit 6e] Audible test signal. Replace the
 *     zero-filled buffer with a 750 Hz sine wave (64
 *     samples per period at 48 kHz, 32 full periods per
 *     8 KB buffer for seamless looping). Extend the run
 *     to 290 ms total so the tone is audibly long. With
 *     the CS4206's internal speaker enabled this commit
 *     produces the first audiofs-generated sound a human
 *     can hear.
 *   - [commit 6f] Platform-policy diagnostic infrastructure.
 *     Query each codec's GPIO inventory (HDA spec param
 *     0x11) and each pin's EAPD_CAP at attach time. If a
 *     codec advertises GPIO lines, adopt it as the
 *     "platform codec" for runtime control: configure all
 *     advertised lines as enabled outputs with data=0
 *     (safe default). Add one writeable sysctl:
 *       dev.audiofs.N.gpio_data       -> write to drive
 *                                        SET_GPIO_DATA
 *     so the empirical question "which GPIO bit controls
 *     a downstream amplifier on this board" can be
 *     answered without unloading the module. Pure HDA
 *     standard verbs throughout; no vendor-specific verbs.
 *
 *     Empirical finding documented for the pgsd-bare-metal
 *     Apple iMac (CS4206 codec, PCI subsystem 0x106b8200):
 *     gpio_data bit 3 high enables the internal speaker
 *     amplifier; clearing it powers the amp down; bits
 *     0-2 have no observable effect on amp state.
 *     Acting on that finding by setting gpio_data
 *     automatically at attach is intentionally deferred
 *     to commit 6g (the platform-policy table) so this
 *     commit lands the inspection mechanism in isolation.
 *   - [commit 6g] Platform-policy table. A small data
 *     table mapping (PCI subvendor, PCI subdevice) to an
 *     initial gpio_data value driven at attach. Single
 *     entry for the Apple iMac (subsys 0x106b 0x8200,
 *     gpio_data=0x08) as discovered empirically in
 *     commit 6f. On no match, gpio_data stays 0 (safe).
 *     The table is data, not vendor-specific code; the
 *     verb mechanism remains the standard SET_GPIO_DATA.
 *     With this commit the iMac's internal speaker
 *     produces sound automatically at module load.
 *
 * Out of scope for this commit:
 *   - Continuous streaming (the stream still runs for the
 *     test duration then stops; production would refill
 *     the buffer and keep running).
 *   - User-controlled playback beyond the test tone
 *     (no ioctl, no /dev node).
 *   - HDMI presence detection (still needed before
 *     HDMI streams can be expected to advance LPIB).
 *   - Interrupt-driven position tracking.
 *   - Underrun detection.
 *   - Format negotiation beyond fixed 48k/16/stereo.
 *   - CLOCK region writing, AUDIO_STATE, AUDIO_EVENTS.
 *
 * This file does not include or depend on snd(4); the
 * generic sound framework (device sound) is retained in
 * the PGSD kernel but unused here. Per ADR 0006 we are
 * the controller and codec driver.
 */

#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/conf.h>
#include <sys/malloc.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/sx.h>		/* sx lock for F.1 state publish (VFS sleeps) */
#include <sys/sbuf.h>
#include <sys/sysctl.h>
#include <sys/rman.h>
#include <sys/proc.h>		/* curthread, struct thread (F.1 state publish) */
#include <sys/namei.h>		/* nameidata, NDINIT (F.1 state publish) */
#include <sys/vnode.h>		/* vnode ops, vn_rdwr, vn_close (F.1) */
#include <sys/fcntl.h>		/* FWRITE, O_CREAT, O_TRUNC (F.1) */
#include <sys/syscallsubr.h>	/* kern_mkdirat (F.1 state publish) */
#include <sys/selinfo.h>	/* selrecord/selwakeup, knote (F.2 notify) */
#include <sys/poll.h>		/* POLLIN, POLLRDNORM (F.2 notify poll) */
#include <sys/event.h>		/* EVFILT_READ, filterops, KNOTE (F.2 notify) */
#include <sys/uio.h>		/* struct uio, uiomove (F.3.b cdev write) */
#include <sys/taskqueue.h>	/* taskqueue_fast for F.3.d xrun deferral */
#include <sys/endian.h>		/* le32enc, htole64 (F.4 clock writer) */

#include <machine/bus.h>
#include <machine/resource.h>

/* F.4 clock writer: shared kernel mapping of /var/run/sema/clock (ADR 0018). */
#include <vm/vm.h>
#include <vm/vm_param.h>
#include <vm/pmap.h>		/* pmap_t, struct pmap (needed by vm_map.h) */
#include <vm/vm_extern.h>
#include <vm/vm_map.h>
#include <vm/vm_object.h>
#include <vm/vm_kern.h>		/* kernel_map */

#include "audiofs_state.h"	/* F.1 state-region layout */
#include "audiofs_events.h"	/* F.2 events-ring layout */
#include "audiofs_ioctl.h"	/* F.3.e format ioctl ABI */

#include <dev/pci/pcivar.h>
#include <dev/pci/pcireg.h>

/*
 * Use the FreeBSD HDA register/macro headers. These are
 * pure header files, no driver dependency.
 */
#include <dev/sound/pci/hda/hdac_reg.h>
#include <dev/sound/pci/hda/hda_reg.h>

/*
 * Spec-derived constants we do not want to pull from
 * hdac.h / hdac_private.h, since those are hdac(4) driver
 * internals. Values match hdac.h verbatim.
 */
#ifndef HDA_DMA_ALIGNMENT
#define	HDA_DMA_ALIGNMENT	128
#endif
#ifndef HDA_INVALID
#define	HDA_INVALID		0xffffffff
#endif
#ifndef HDAC_RIRB_RESPONSE_EX_SDATA_IN_MASK
#define	HDAC_RIRB_RESPONSE_EX_SDATA_IN_MASK	0x0000000f
#define	HDAC_RIRB_RESPONSE_EX_SDATA_IN_OFFSET	0
#define	HDAC_RIRB_RESPONSE_EX_UNSOLICITED	0x00000010
#define	HDAC_RIRB_RESPONSE_EX_SDATA_IN(resp_ex)			\
    (((resp_ex) & HDAC_RIRB_RESPONSE_EX_SDATA_IN_MASK) >>	\
    HDAC_RIRB_RESPONSE_EX_SDATA_IN_OFFSET)
#endif

#define AUDIOFS_EVENTLOG_SLOTS	256
#define AUDIOFS_CODEC_MAX	16	/* per HDA spec, 15 SDIs (0-14) */
#define AUDIOFS_CMD_TIMEOUT	10000	/* 10000 * 10us = 100ms */

/*
 * Per-codec topology storage. The CS4206 has 20 widgets;
 * common consumer codecs are <40. 128 is a generous ceiling
 * that keeps softc footprint bounded (per-codec storage is
 * 128 * sizeof(struct audiofs_widget) bytes).
 *
 * Connection list per widget: 16 is enough for CS4206's
 * widest selector (a few inputs) and most codecs. hdaa.c
 * uses 32; we use 16 here and warn on overflow rather than
 * silently truncating.
 */
#define AUDIOFS_WIDGET_MAX	128	/* per FG */
#define AUDIOFS_CONN_MAX	16	/* per widget */
#define AUDIOFS_PATH_MAX_DEPTH	8	/* DAC->pin walk recursion bound */

/* The output stream format word audiofs writes; constant for now. */
#define AUDIOFS_FMT_48KHZ_16BIT_STEREO	0x0011

/*
 * CORB entries are 4-byte verbs; RIRB entries are 8-byte
 * response-and-extension pairs (struct hda_rirb).
 */
struct audiofs_rirb {
	uint32_t	response;
	uint32_t	response_ex;
} __packed;

#define	AUDIOFS_READ_1(sc, off)	bus_space_read_1((sc)->mem_tag, (sc)->mem_handle, (off))
#define	AUDIOFS_READ_2(sc, off)	bus_space_read_2((sc)->mem_tag, (sc)->mem_handle, (off))
#define	AUDIOFS_READ_4(sc, off)	bus_space_read_4((sc)->mem_tag, (sc)->mem_handle, (off))
#define	AUDIOFS_WRITE_1(sc, off, v) bus_space_write_1((sc)->mem_tag, (sc)->mem_handle, (off), (v))
#define	AUDIOFS_WRITE_2(sc, off, v) bus_space_write_2((sc)->mem_tag, (sc)->mem_handle, (off), (v))
#define	AUDIOFS_WRITE_4(sc, off, v) bus_space_write_4((sc)->mem_tag, (sc)->mem_handle, (off), (v))

struct audiofs_event {
	uint64_t	seq;
	uint64_t	ts_ns;
	const char	*kind;
	uintmax_t	arg;
};

struct audiofs_dma {
	bus_dma_tag_t	dma_tag;
	bus_dmamap_t	dma_map;
	bus_addr_t	dma_paddr;
	bus_size_t	dma_size;
	caddr_t		dma_vaddr;
};

/*
 * One widget node in a codec's audio function group. nid
 * uniquely identifies it; type is decoded from wcap; conns
 * is the list of nids that feed this widget's input
 * (relevant for non-pin widgets; the input source for a pin
 * widget is determined by its connection list when configured
 * as output, or it has no inputs when configured for input).
 *
 * pin_cfg is only meaningful when type==PIN_COMPLEX.
 */
struct audiofs_widget {
	int		valid;
	uint16_t	nid;
	uint32_t	wcap;
	uint32_t	type;		/* decoded HDA_PARAM_AUDIO_WIDGET_CAP_TYPE */
	uint32_t	pin_cfg;	/* pin complexes only */
	uint32_t	pin_cap;	/* pin complexes only - HDA_PARAM_PIN_CAP */
	uint8_t		nconns;
	uint16_t	conns[AUDIOFS_CONN_MAX];
	uint8_t		conn_overflow;	/* set if hardware reported >AUDIOFS_CONN_MAX */
};

struct audiofs_codec {
	int		populated;	/* set if STATESTS bit observed */
	int		pending;	/* outstanding commands count */
	uint32_t	response;	/* most recent response */
	uint16_t	vendor_id;
	uint16_t	device_id;
	uint8_t		revision_id;
	uint8_t		stepping_id;

	/*
	 * Audio function group state. Recorded during
	 * topology walk. fg_nid==0 if this codec has no
	 * audio FG.
	 */
	uint16_t	fg_nid;
	uint32_t	fg_subsystem;
	uint32_t	fg_output_amp_cap;	/* HDA_PARAM_OUTPUT_AMP_CAP at fg_nid */
	uint32_t	fg_supp_pcm_size_rate;	/* HDA_PARAM_SUPP_PCM_SIZE_RATE at fg_nid */
	uint32_t	fg_supp_stream_formats;	/* HDA_PARAM_SUPP_STREAM_FORMATS at fg_nid */
	uint16_t	widget_start;	/* first widget nid */
	uint16_t	widget_total;	/* widget count */
	struct audiofs_widget widgets[AUDIOFS_WIDGET_MAX];
};

struct audiofs_softc {
	device_t	dev;

	/* BAR mapping. */
	struct resource	*mem_res;
	int		mem_rid;
	bus_space_tag_t	mem_tag;
	bus_space_handle_t mem_handle;

	struct mtx	hw_lock;	/* serialize register access */

	/* Capabilities read from GCAP at attach. */
	uint16_t	gcap;
	int		num_iss;	/* input stream descriptors */
	int		num_oss;	/* output stream descriptors */
	int		num_bss;	/* bidirectional stream descriptors */
	int		num_sdo;	/* SDO line count */
	int		support_64bit;
	uint8_t		vmaj;
	uint8_t		vmin;

	/* CORB/RIRB rings, sized at runtime from CORBSIZE/RIRBSIZE caps. */
	struct audiofs_dma corb_dma;
	struct audiofs_dma rirb_dma;
	int		corb_size;	/* entries (2, 16, or 256) */
	int		rirb_size;	/* entries (2, 16, or 256) */
	uint16_t	corb_wp;	/* next slot to write */
	uint16_t	rirb_rp;	/* next slot to read */

	/* Per-codec state, indexed by codec address. */
	struct audiofs_codec codecs[AUDIOFS_CODEC_MAX];

	/*
	 * Output stream state. One stream descriptor reserved
	 * per controller; populated in commit 6c, exercised in
	 * commit 6d. output_stream_configured guards detach
	 * cleanup so we only free DMA we actually allocated.
	 */
	int			output_stream_configured;
	int			output_stream_idx;	/* 0..num_oss-1 */
	int			output_stream_id;	/* 1..15 */
	int			output_dac_cad;
	uint16_t		output_dac_nid;
	/*
	 * F.3.e (ADR 0019): the active output stream's negotiated
	 * format. Set by audiofs_stream_begin after validation;
	 * configure_output_stream and the DAC converter program
	 * from these. Default 48 kHz / 16-bit stereo.
	 */
	uint16_t		output_stream_format_word;
	uint32_t		output_stream_rate_hz;
	struct audiofs_dma	bdl_dma;
	struct audiofs_dma	buf_dma;

	/*
	 * F.3.c interrupt-driven lifecycle state (ADR 0016).
	 *
	 * The F.3.a polling kthread has been retired. The refill
	 * loop now runs as an ithread driven by the HDA stream
	 * interrupt. audiofs_intr_filter (filter context, MTX_SPIN
	 * intr_lock) acknowledges interrupts at the hardware level
	 * and schedules the ithread; audiofs_intr_thread runs the
	 * actual refill under hw_lock + user_ring_mtx as the
	 * kthread used to.
	 *
	 * output_stream_active replaces F.3.a's three-flag
	 * (running / stop_requested / stopped) interlock. It is set
	 * by stream_begin AFTER interrupts are enabled and cleared
	 * by stream_end BEFORE interrupts are disabled. The ithread
	 * checks it under intr_lock at entry; if clear, it returns
	 * without touching state. This closes the
	 * "SIE-cleared-but-ithread-already-scheduled" race that
	 * remains after clearing the stream's INTCTL bit.
	 *
	 * output_stream_last_sdsts holds the SDnSTS bits the filter
	 * has seen since the last ithread invocation. The filter
	 * ORs into this field (under intr_lock) so multiple
	 * interrupts before an ithread runs do not lose bits. The
	 * ithread reads and clears it under intr_lock.
	 *
	 * Refill cursor: output_stream_next_refill_fragment is the
	 * index (0..AUDIOFS_BDL_ENTRIES-1) of the fragment that
	 * will be refilled next. The ithread refills while
	 * next_refill_fragment != (curr_lpib / FRAG_BYTES),
	 * advancing the cursor modulo AUDIOFS_BDL_ENTRIES.
	 *
	 * frames_played accumulates LPIB delta across buffer wraps
	 * so stream_end reports the cumulative frame count, not
	 * just the final LPIB.
	 *
	 * output_stream_endpoint_slot is the index into the F.1
	 * state region's endpoint inventory that the stream
	 * targets; it identifies the endpoint in the F.2
	 * stream_begin/end events.
	 */
	int			output_stream_active;
	uint8_t			output_stream_last_sdsts;
	uint32_t		output_stream_prev_lpib;
	int			output_stream_next_refill_fragment;
	uint64_t		output_stream_frames_played;
	/*
	 * F.4 (ADR 0018): monotonic frame counter published as the clock
	 * region's samples_written. Distinct from output_stream_frames_played
	 * because the latter is reset to 0 at every stream_begin; this one is
	 * zeroed only at attach (softc is zero-allocated) and advanced by the
	 * same per-interrupt delta, so the published clock never regresses
	 * across a stop/start cycle. Single writer (the ithread); read by the
	 * publish path with atomic_load_64.
	 */
	uint64_t		clock_samples_total;
	uint16_t		output_stream_endpoint_slot;

	/*
	 * F.3.c PCI interrupt resources. Allocated in attach,
	 * released in detach. msi_count records which IRQ path
	 * was taken at attach (1 = MSI, 0 = INTx) so detach can
	 * call pci_release_msi only when appropriate.
	 * interrupts_attached is the "we successfully called
	 * bus_setup_intr" flag, controlling the teardown path in
	 * detach and the attach fail labels.
	 */
	struct resource	*irq_res;
	int		irq_rid;
	void		*irq_cookie;
	int		msi_count;
	int		interrupts_attached;
	struct mtx	intr_lock;	/* MTX_SPIN, innermost */

	/*
	 * F.3.b user-controlled playback state (ADR 0015).
	 *
	 * output_stream_source selects the data the refill loop
	 * draws from:
	 *   AUDIOFS_SRC_SINE -- the F.3.a internal sine table
	 *     (used when the test-tone tunable is set and no
	 *     cdev consumer is open).
	 *   AUDIOFS_SRC_USER -- the user-ring (used while a
	 *     cdev consumer is open).
	 * The 3-state source machine in ADR 0015 decision 3 has
	 * "stopped" represented by output_stream_active == 0;
	 * the two running states by output_stream_source.
	 *
	 * output_stream_user_ring is a 32 KB byte buffer
	 * (AUDIOFS_USER_RING_BYTES). _head advances on write(2)
	 * (producer), _tail advances on ithread refill (consumer
	 * since F.3.c; was the kthread under F.3.a/b). Both are
	 * size_t free-running counters; the actual ring index is
	 * (cursor & AUDIOFS_USER_RING_MASK). The ring is empty
	 * when _head == _tail and full when (_head - _tail) ==
	 * AUDIOFS_USER_RING_BYTES.
	 *
	 * output_stream_user_ring_mtx (MTX_DEF) covers _head,
	 * _tail, output_stream_source, output_stream_cdev_open,
	 * and is the address msleep'd on for back-pressure.
	 *
	 * output_stream_cdev_open is a boolean flag (0 or 1)
	 * enforcing exclusive open on the cdev.
	 *
	 * output_stream_underflow_count accumulates the number
	 * of BDL fragments where the user ring did not have a
	 * full fragment of data and was zero-filled, plus FIFOE
	 * occurrences reported by the controller in F.3.c's
	 * interrupt path. F.3.d will surface these as xrun
	 * events on the F.2 ring; F.3.c exposes the counter via
	 * the dev.audiofs.<N>.underflow_count sysctl for bench
	 * observability.
	 *
	 * output_stream_cdev is the registered /dev/audiofs<N>
	 * cdev; created at attach, destroyed at detach.
	 */
	int			output_stream_source;
	uint8_t			*output_stream_user_ring;
	size_t			output_stream_user_ring_head;
	size_t			output_stream_user_ring_tail;
	struct mtx		output_stream_user_ring_mtx;
	int			output_stream_cdev_open;
	uint64_t		output_stream_underflow_count;

	/*
	 * ADR 0022 instrumentation: per-BCIS refill accounting to
	 * confirm the stale-fragment-replay hypothesis.
	 * refill_miss_count counts interrupts that refilled zero
	 * fragments (curr_fragment read equal to the cursor);
	 * refill_multi_count counts those that refilled two or more
	 * (catch-up after a miss or ithread latency). Steady correct
	 * operation is exactly one refill per BCIS, so both stay at
	 * zero. Reset at stream_begin.
	 */
	uint64_t		output_stream_refill_miss_count;
	uint64_t		output_stream_refill_multi_count;

	struct cdev		*output_stream_cdev;

	/*
	 * F.3.d xrun deferral state (ADR 0017). The ithread
	 * detects FIFOE but cannot call audiofs_events_publish
	 * (which holds audiofs_state_sx and may sleep in VFS
	 * I/O); it updates the pending fields under intr_lock
	 * and enqueues output_stream_xrun_task on taskqueue_fast,
	 * which runs in a sleepable kernel thread and publishes.
	 *
	 * output_stream_pending_xrun_frames is an upper-bound
	 * estimate of the gap size accumulated since the last
	 * published xrun event. Each FIFOE adds one fragment's
	 * worth of frames (AUDIOFS_BUF_FRAG_BYTES / 4 = 1024
	 * frames at stereo 16-bit). Zero means "no pending xrun".
	 *
	 * output_stream_xrun_gap_pos is the frames_played value
	 * snapped at the FIRST FIFOE of a coalesced window.
	 * Becomes the published event's gap_sample_pos.
	 *
	 * output_stream_xrun_coalesced_count is how many FIFOE
	 * interrupts have been folded into the pending event.
	 * The task body sets AUDIOFS_EVFLAG_COALESCED on publish
	 * iff this is greater than 1.
	 *
	 * All three are protected by intr_lock (MTX_SPIN). The
	 * task itself uses taskqueue_fast's internal pending-bit
	 * to coalesce repeated enqueues at no cost.
	 */
	uint32_t		output_stream_pending_xrun_frames;
	uint64_t		output_stream_xrun_gap_pos;
	uint32_t		output_stream_xrun_coalesced_count;
	struct task		output_stream_xrun_task;

	/*
	 * Platform-policy GPIO state. The "platform codec" is the
	 * codec whose GPIOs we expose for runtime control via
	 * sysctl. There is typically at most one such codec per
	 * controller (the analog codec, not HDMI). gpio_num_lines
	 * is the number of bidirectional GPIO lines the codec
	 * advertises; gpio_data is the last value we wrote, and
	 * is what sysctl reads/writes. fg_nid_for_gpio caches the
	 * function-group nid on the platform codec.
	 */
	int			gpio_cad;		/* -1 if no platform codec */
	uint16_t		gpio_fg_nid;
	int			gpio_num_lines;		/* 0..7 */
	uint8_t			gpio_data;		/* current driven value */

	/* PCI identity. */
	uint16_t	pci_vendor;
	uint16_t	pci_device;
	uint16_t	pci_subvendor;
	uint16_t	pci_subdevice;

	/* Lifecycle event ring. */
	struct mtx	evlock;
	struct audiofs_event evlog[AUDIOFS_EVENTLOG_SLOTS];
	uint64_t	evseq;
};

MALLOC_DEFINE(M_AUDIOFS, "audiofs", "Awase audiofs PCI driver");

/* ---------------------------------------------------------
 * F.1 state-file publication (module-global)
 *
 * Each HDA controller attaches as a separate device_t with
 * its own softc, but the state file at
 * /var/run/sema/audio/state is system-global: it aggregates
 * every attached controller and every endpoint across all of
 * them. So the publication state lives at module scope, not
 * per-softc.
 *
 * audiofs_state_softcs[] is a small fixed registry of the
 * attached controller softcs, in attach order. The index into
 * this array is the controller_idx published in endpoint
 * slots. audiofs_state_mtx serializes registry mutation and
 * file republish; it is a sleepable sx because the publish
 * path performs VFS I/O (vn_rdwr) which may sleep.
 *
 * The on-disk file is rebuilt in full on every inventory
 * change (controller attach/detach). This is simple and
 * correct; inventory changes are rare (attach time, hot-plug)
 * so the full rebuild cost is irrelevant.
 * --------------------------------------------------------- */

static struct sx			audiofs_state_sx;
static struct audiofs_softc	*audiofs_state_softcs[AUDIOFS_STATE_CONTROLLER_SLOTS];
static int			 audiofs_state_softc_count;
static struct vnode		*audiofs_state_vp;
static uint32_t			 audiofs_state_inventory_seq;
static uint32_t			 audiofs_state_next_endpoint_id = 1;
static int			 audiofs_state_sync_logged_failure;
static int			 audiofs_state_initialized;

/* ---------------------------------------------------------
 * F.3.a bench-safety controls: module-global test-tone gate
 *
 * audiofs_test_tone (int sysctl + loader.conf tunable
 * hw.audiofs.test_tone, default 0):
 *
 *   0 = silent on attach; bench operator opts in to the
 *       continuous sine test tone explicitly.
 *   non-zero = test tone runs (starts on attach for new
 *       controllers; runtime write of >0 starts stream on
 *       all already-attached controllers; runtime write of
 *       0 stops it on all controllers).
 *
 * Default 0 because the bench-verified F.3.a load on
 * pgsd-bare-metal 2026-05-29 produced loud audio that the
 * operator could not silence through the normal off switch
 * (kldunload over SSH) - they had to pull power. Defaulting
 * the test tone to OFF protects unattended boots; the
 * tunable preserves the audible closure-proof on demand.
 *
 * Pair with the quieter sine table (~-40 dBFS, ~0.5%
 * amplitude) so even when the tone IS enabled, it is at
 * room-comfortable level.
 *
 * Implementation note: this control lives at the module
 * scope, not per-instance, because operators usually want a
 * single setting for the whole machine ("play tone on all
 * audiofs controllers" or "play tone on none"). A future
 * per-instance control could be added once the user API
 * (F.3.b) is on the table.
 * --------------------------------------------------------- */

static int audiofs_test_tone;
static int audiofs_sysctl_test_tone(SYSCTL_HANDLER_ARGS);

SYSCTL_NODE(_hw, OID_AUTO, audiofs, CTLFLAG_RW, 0,
    "Awase audiofs module-global controls");
SYSCTL_PROC(_hw_audiofs, OID_AUTO, test_tone,
    CTLTYPE_INT | CTLFLAG_RWTUN | CTLFLAG_MPSAFE,
    NULL, 0, audiofs_sysctl_test_tone, "I",
    "Bench test tone: 0=silent (default, safe), non-zero=play continuous "
    "750 Hz sine on all attached audiofs controllers. Write 0 to stop. "
    "Also a loader.conf tunable: hw.audiofs.test_tone");

/* state-file mode/owner, mirroring inputfs conventions. */
#define	AUDIOFS_STATE_MODE	0644
#define	AUDIOFS_STATE_UID	0
#define	AUDIOFS_STATE_GID	0

static void audiofs_state_register(struct audiofs_softc *sc);
static void audiofs_state_unregister(struct audiofs_softc *sc);
static void audiofs_state_republish(void);

/* ---------------------------------------------------------
 * F.2 events-ring publication (module-global)
 *
 * Lock-free single-producer (audiofs) / multi-consumer ring at
 * /var/run/sema/audio/events, mirroring inputfs's events ring.
 * The in-kernel buffer is the authoritative ring; it is synced
 * to the mmap-backed file after each publish. Writer-side
 * serialization reuses audiofs_state_sx (publishes happen in
 * the same attach/detach context as state updates).
 *
 * A pollable notification cdev /dev/audiofs_notify wakes
 * consumers on publish (poll + kqueue), mirroring inputfs
 * ADR 0021's /dev/inputfs_notify (AD-41.3 pattern).
 * --------------------------------------------------------- */

static struct audiofs_events_region	*audiofs_events_buf;
static struct vnode			*audiofs_events_vp;
static uint64_t				 audiofs_events_writer_seq;
static uint64_t				 audiofs_events_earliest_seq = 1;
static int				 audiofs_events_sync_logged_failure;

static struct cdev			*audiofs_notify_dev;
static struct selinfo			 audiofs_notify_selinfo;

static void audiofs_events_publish(uint8_t source_role, uint8_t event_type,
    uint16_t endpoint_slot, uint32_t flags, const void *payload,
    size_t payload_len);
static void audiofs_events_open_file(struct thread *td);
static void audiofs_events_close_file(struct thread *td);
static void audiofs_events_set_valid(struct thread *td);
static void audiofs_events_emit_endpoint_attaches(uint8_t controller_idx);

/* ---------------------------------------------------------
 * F.4 clock publication (module-global, ADR 0018)
 *
 * audiofs is the kernel writer of /var/run/sema/clock. Unlike
 * the F.1 state and F.2 events files (published with vn_rdwr
 * plus a seqlock), the clock wire format (ADR 0003,
 * shared/CLOCK.md) has no seqlock: samples_written is
 * published by a single store that a concurrent mmap reader
 * must observe whole. vn_rdwr (uiomove copy) can tear that
 * read, so the clock is published through a shared kernel
 * mapping of the file page instead. The page is wired so the
 * per-interrupt store from the ithread cannot fault.
 *
 * The mapping is module-global (one clock file, like the
 * state file). The monotonic count it publishes lives
 * per-softc in clock_samples_total; v1 has a single active
 * output stream, so one softc owns the clock at a time.
 *
 * amd64 scope: the samples_written field is at offset 12, a
 * 4-byte boundary. Its store is single-copy-atomic only by
 * the within-cache-line guarantee on amd64 (the page is
 * mapped page-aligned, so bytes 12-19 stay in one line). See
 * ADR 0018 Decision 3 for the non-TSO caveat.
 * --------------------------------------------------------- */

#define	AUDIOFS_CLOCK_PATH		"/var/run/sema/clock"
#define	AUDIOFS_CLOCK_SIZE		20
#define	AUDIOFS_CLOCK_MAGIC		0x534D434Bu	/* "SMCK" LE */
#define	AUDIOFS_CLOCK_VERSION		1u
#define	AUDIOFS_CLOCK_SOURCE_AUDIO	1u

/* Byte offsets within the 20-byte region (shared/CLOCK.md). */
#define	AUDIOFS_CLOCK_OFF_MAGIC		0
#define	AUDIOFS_CLOCK_OFF_VERSION	4
#define	AUDIOFS_CLOCK_OFF_VALID		5
#define	AUDIOFS_CLOCK_OFF_SOURCE		6
#define	AUDIOFS_CLOCK_OFF_PAD		7
#define	AUDIOFS_CLOCK_OFF_RATE		8
#define	AUDIOFS_CLOCK_OFF_SAMPLES	12

static struct vnode	*audiofs_clock_vp;	/* held across module life */
static vm_offset_t	 audiofs_clock_kva;	/* kernel mapping of the page */
static int		 audiofs_clock_mapped;	/* 1 once kva is live + wired */

static void audiofs_clock_open(struct thread *td);
static void audiofs_clock_close(struct thread *td);
static void audiofs_clock_stream_begin(struct audiofs_softc *sc,
    uint32_t sample_rate);
static void audiofs_clock_update(struct audiofs_softc *sc);

/*
 * Defined later (near path discovery); forward-declared here
 * because the F.1 endpoint enumeration calls them.
 */
static uint16_t audiofs_path_from_pin(struct audiofs_softc *sc, int cad,
    uint16_t pin_nid, uint16_t path[AUDIOFS_PATH_MAX_DEPTH], int *depth_out);
static const char *audiofs_pin_device_name(uint32_t devkind);

/* ---------------------------------------------------------
 * Lifecycle event logging
 * --------------------------------------------------------- */

static void
audiofs_log(struct audiofs_softc *sc, const char *kind, uintmax_t arg)
{
	struct audiofs_event *ev;
	struct timespec ts;
	uint64_t slot;

	nanouptime(&ts);

	mtx_lock(&sc->evlock);
	slot = sc->evseq % AUDIOFS_EVENTLOG_SLOTS;
	ev = &sc->evlog[slot];
	ev->seq = sc->evseq++;
	ev->ts_ns = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
	ev->kind = kind;
	ev->arg = arg;
	mtx_unlock(&sc->evlock);

	device_printf(sc->dev, "[%ju] %s arg=0x%jx ts=%jd.%09ld\n",
	    (uintmax_t)ev->seq, kind, arg,
	    (intmax_t)ts.tv_sec, ts.tv_nsec);
}

/* Forward declarations: defined later, near the platform-policy code. */
static int audiofs_sysctl_gpio_data(SYSCTL_HANDLER_ARGS);
static int audiofs_sysctl_interrupts_setup(SYSCTL_HANDLER_ARGS);

static int
audiofs_sysctl_eventlog(SYSCTL_HANDLER_ARGS)
{
	struct audiofs_softc *sc = arg1;
	struct sbuf sb;
	int error, i;
	uint64_t start, end;

	/*
	 * Each entry prints as roughly 50-60 chars ("seq ts kind 0xhex\n").
	 * 16384 holds 256 entries comfortably with headroom for long
	 * "kind" labels.
	 */
	sbuf_new_for_sysctl(&sb, NULL, 16384, req);

	mtx_lock(&sc->evlock);
	end = sc->evseq;
	start = (end > AUDIOFS_EVENTLOG_SLOTS) ?
	    end - AUDIOFS_EVENTLOG_SLOTS : 0;
	for (i = (int)start; (uint64_t)i < end; i++) {
		struct audiofs_event *ev =
		    &sc->evlog[i % AUDIOFS_EVENTLOG_SLOTS];
		sbuf_printf(&sb, "%ju %ju %s 0x%jx\n",
		    (uintmax_t)ev->seq,
		    (uintmax_t)ev->ts_ns,
		    ev->kind ? ev->kind : "?",
		    ev->arg);
	}
	mtx_unlock(&sc->evlock);

	error = sbuf_finish(&sb);
	sbuf_delete(&sb);
	return (error);
}

static void
audiofs_sysctl_setup(struct audiofs_softc *sc)
{
	struct sysctl_ctx_list *ctx;
	struct sysctl_oid *tree;

	/*
	 * Use the device's own sysctl context and tree, which the
	 * kernel created when the device was added. This anchors
	 * our nodes under dev.audiofs.N alongside the auto-created
	 * %parent / %pnpinfo / %driver / %desc nodes.
	 */
	ctx = device_get_sysctl_ctx(sc->dev);
	tree = device_get_sysctl_tree(sc->dev);

	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "eventlog",
	    CTLTYPE_STRING | CTLFLAG_RD,
	    sc, 0, audiofs_sysctl_eventlog, "A",
	    "Recent lifecycle events");

	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "num_iss", CTLFLAG_RD,
	    &sc->num_iss, 0, "Input stream descriptors");

	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "num_oss", CTLFLAG_RD,
	    &sc->num_oss, 0, "Output stream descriptors");

	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "num_bss", CTLFLAG_RD,
	    &sc->num_bss, 0, "Bidirectional stream descriptors");

	SYSCTL_ADD_INT(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "support_64bit", CTLFLAG_RD,
	    &sc->support_64bit, 0, "64-bit DMA address support");

	SYSCTL_ADD_U16(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "pci_vendor", CTLFLAG_RD,
	    &sc->pci_vendor, 0, "PCI vendor id");

	SYSCTL_ADD_U16(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "pci_device", CTLFLAG_RD,
	    &sc->pci_device, 0, "PCI device id");

	/*
	 * Platform-policy runtime control. gpio_data drives the
	 * platform codec's GPIO data bits via SET_GPIO_DATA. The
	 * empirical sweep for "which GPIO bit enables the speaker
	 * amp" can be performed without unloading the module.
	 */
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "gpio_data",
	    CTLTYPE_INT | CTLFLAG_RW,
	    sc, 0, audiofs_sysctl_gpio_data, "I",
	    "Platform codec GPIO data bits (write to drive, read to inspect)");

	/*
	 * F.3.c (ADR 0016 Decision 9): expose which IRQ path was
	 * taken at attach and the running count of buffer underflows
	 * reported by the controller. F.3.d will surface underflows
	 * as F.2 xrun events; the sysctl is the F.3.c observability
	 * surface in the interim.
	 */
	SYSCTL_ADD_PROC(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "interrupts_setup",
	    CTLTYPE_STRING | CTLFLAG_RD,
	    sc, 0, audiofs_sysctl_interrupts_setup, "A",
	    "Interrupt path at attach: msi, intx, or none");

	SYSCTL_ADD_QUAD(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "underflow_count", CTLFLAG_RD,
	    &sc->output_stream_underflow_count,
	    "FIFO underflow events reported by the controller (F.3.c)");

	SYSCTL_ADD_QUAD(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "refill_miss_count", CTLFLAG_RD,
	    &sc->output_stream_refill_miss_count,
	    "BCIS interrupts that refilled zero fragments (ADR 0022)");

	SYSCTL_ADD_QUAD(ctx, SYSCTL_CHILDREN(tree),
	    OID_AUTO, "refill_multi_count", CTLFLAG_RD,
	    &sc->output_stream_refill_multi_count,
	    "BCIS interrupts that refilled two or more fragments (ADR 0022)");
}

/* ---------------------------------------------------------
 * F.1 state-file publication
 *
 * Design: audiofs/docs/adr/0012-f1-state-file.md
 * Schema: shared/AUDIO_STATE.md
 * Layout: audiofs_state.h
 *
 * Physics-only per ADR 0007. The region carries controller
 * inventory, endpoint inventory (pin->DAC output paths and
 * ADC->pin input paths discovered during topology walk), and
 * per-endpoint runtime state. No policy.
 *
 * VFS publication mirrors the inputfs pattern (vn_open with
 * O_CREAT|O_TRUNC, vn_rdwr to write, vn_close). All entry
 * points hold audiofs_state_sx, which is sleepable because
 * VFS I/O may sleep. Never call these from a non-sleepable
 * context.
 * --------------------------------------------------------- */

/*
 * Map an HDA pin configuration-default "device" field to the
 * audiofs endpoint-kind enum. devkind values are the standard
 * HDA pin-config default device codes (see
 * audiofs_pin_device_name). Output kinds for output pins,
 * input kinds for input pins. Digital pins are classified by
 * the caller using pin capabilities; this routine handles the
 * analog mapping plus the digital-out fallback.
 */
static uint8_t
audiofs_state_kind_from_devkind(uint32_t devkind, int is_digital)
{

	if (is_digital) {
		/*
		 * Digital output. SPDIF_Out (pin-config device kind
		 * 0x4) is distinct from HDMI/DisplayPort and gets its
		 * own endpoint kind. Digital_Other_Out (0x5) is the
		 * HDMI/DP family; distinguishing HDMI from DisplayPort
		 * within that family requires reading the pin's
		 * digital-converter capabilities or ELD, which belongs
		 * to F.3.f (HDMI bring-up). For F.1 the 0x5 family is
		 * classified as HDMI and DisplayPort discrimination is
		 * left to F.3.f.
		 */
		if (devkind == 0x4)
			return (AUDIOFS_EP_KIND_SPDIF);
		return (AUDIOFS_EP_KIND_HDMI);
	}

	switch (devkind) {
	case 0x0:	/* Line_Out */
		return (AUDIOFS_EP_KIND_LINE_OUT);
	case 0x1:	/* Speaker */
		return (AUDIOFS_EP_KIND_SPEAKER);
	case 0x2:	/* HP_Out */
		return (AUDIOFS_EP_KIND_HEADPHONE);
	case 0x8:	/* Line_In */
		return (AUDIOFS_EP_KIND_LINE_IN);
	case 0xa:	/* Mic_In */
		return (AUDIOFS_EP_KIND_MIC);
	default:
		return (AUDIOFS_EP_KIND_UNUSED);
	}
}

/*
 * Fill one endpoint slot from a discovered output path on a
 * codec. Returns 1 if a slot was filled, 0 if the widget is
 * not a publishable endpoint (no path to a DAC, or an
 * unclassifiable pin). next_id is the endpoint id to assign.
 *
 * Reads codec->widgets[] which is populated under hw_lock
 * during topology walk; by the time this runs (post-attach
 * republish) the walk is complete and the data is stable.
 */
static int
audiofs_state_fill_output_endpoint(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *pin, uint8_t controller_idx, uint32_t ep_id,
    struct audiofs_state_endpoint *slot)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
	int depth = 0;
	uint16_t dac;
	uint32_t devkind, psr;
	int is_digital;

	/* Only pin complexes are endpoints. */
	if (pin->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
		return (0);

	/* Must be configured as an output (have a path to a DAC). */
	dac = audiofs_path_from_pin(sc, cad, pin->nid, path, &depth);
	if (dac == 0)
		return (0);

	/*
	 * Device kind from pin config default (bits 23:20 of the
	 * configuration-default register).
	 */
	devkind = (pin->pin_cfg >> 20) & 0xf;

	/*
	 * Digital pins: HDA pin cap bit for digital is
	 * HDA_PARAM_PIN_CAP_DP / _HDMI. We approximate "digital"
	 * by the device kind being one of the digital-out codes
	 * (0x4 SPDIF_Out, 0x5 Digital_Other_Out) for the analog
	 * codec, and rely on F.3.f for true HDMI/DP separation on
	 * the HDMI controller's codec.
	 */
	is_digital = (devkind == 0x4 || devkind == 0x5);

	slot->endpoint_id = ep_id;
	slot->controller_idx = controller_idx;
	slot->codec_addr = (uint8_t)cad;
	slot->kind = audiofs_state_kind_from_devkind(devkind, is_digital);
	slot->direction = AUDIOFS_EP_DIR_OUTPUT;
	slot->pin_nid = pin->nid;
	slot->converter_nid = dac;

	/*
	 * electrically_ready: for F.1 we report the pin as ready
	 * if it was pin-controlled and the path resolved. The
	 * commit-5/6a code performs the pin control + amp unmute
	 * at attach for discovered output paths, so a resolved
	 * output path is electrically prepared. A finer
	 * per-endpoint readiness flag can be added when F.3
	 * tracks per-endpoint stream state explicitly.
	 */
	slot->electrically_ready = 1;

	/*
	 * runtime_active / current_format: the commit-6 test-tone
	 * path binds exactly one DAC (output_dac_cad/nid) for the
	 * duration of the test. Report this endpoint active only
	 * if it is that DAC and a stream is configured.
	 */
	if (sc->output_stream_configured &&
	    sc->output_dac_cad == cad &&
	    sc->output_dac_nid == dac) {
		slot->runtime_active = 1;
		slot->current_format = sc->output_stream_format_word;
	} else {
		slot->runtime_active = 0;
		slot->current_format = 0;
	}

	/*
	 * Format-capability bitmasks. psr is the raw
	 * SUPP_PCM_SIZE_RATE param: rate bits in 15:0, bit-depth
	 * bits in 20:16 (HDA 1.0a Table 87). We publish them
	 * split per shared/AUDIO_STATE.md.
	 */
	psr = codec->fg_supp_pcm_size_rate;
	slot->rate_mask = psr & 0xffff;
	slot->bit_depth_mask = (psr >> 16) & 0xff;

	/* Most analog endpoints are stereo; bit 1 = 2 channels. */
	slot->channel_mask = 0x02;

	/* Display name from the pin device kind. */
	strlcpy(slot->name, audiofs_pin_device_name(devkind),
	    sizeof(slot->name));

	return (1);
}

/*
 * Build the full state region into buf from the current
 * controller registry. Caller holds audiofs_state_sx.
 */
static void
audiofs_state_build_region(struct audiofs_state_region *r)
{
	int i, cad, w;
	uint8_t ep_count = 0;
	uint8_t ctrl_count = 0;

	memset(r, 0, sizeof(*r));

	r->header.magic = AUDIOFS_STATE_MAGIC;
	r->header.version = AUDIOFS_STATE_VERSION;
	r->header.controller_slot_count = AUDIOFS_STATE_CONTROLLER_SLOTS;
	r->header.endpoint_slot_count = AUDIOFS_STATE_ENDPOINT_SLOTS;
	r->header.controller_slot_size =
	    (uint8_t)sizeof(struct audiofs_state_controller);
	r->header.endpoint_slot_size =
	    (uint8_t)sizeof(struct audiofs_state_endpoint);
	r->header.inventory_seq = audiofs_state_inventory_seq;
	r->header.last_event_seq = audiofs_events_writer_seq;	/* F.2 correlation */

	for (i = 0; i < audiofs_state_softc_count &&
	    i < AUDIOFS_STATE_CONTROLLER_SLOTS; i++) {
		struct audiofs_softc *sc = audiofs_state_softcs[i];
		struct audiofs_state_controller *cs = &r->controllers[i];

		if (sc == NULL)
			continue;

		cs->controller_id = (uint32_t)(i + 1);
		cs->subtype = AUDIOFS_CTRL_SUBTYPE_PCI_HDA;
		cs->pci_vendor = sc->pci_vendor;
		cs->pci_device = sc->pci_device;
		cs->pci_subvendor = sc->pci_subvendor;
		cs->pci_subdevice = sc->pci_subdevice;
		cs->num_iss = (uint8_t)sc->num_iss;
		cs->num_oss = (uint8_t)sc->num_oss;
		cs->num_bss = (uint8_t)sc->num_bss;
		cs->support_64bit = (uint8_t)sc->support_64bit;
		snprintf(cs->name, sizeof(cs->name),
		    "HDA %04x:%04x", sc->pci_vendor, sc->pci_device);
		ctrl_count++;

		/* Enumerate endpoints on each codec of this controller. */
		for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
			struct audiofs_codec *codec = &sc->codecs[cad];

			if (!codec->populated || codec->fg_nid == 0)
				continue;

			for (w = 0; w < codec->widget_total; w++) {
				struct audiofs_widget *wp = &codec->widgets[w];
				struct audiofs_state_endpoint *eslot;

				if (!wp->valid)
					continue;
				if (ep_count >= AUDIOFS_STATE_ENDPOINT_SLOTS)
					break;

				eslot = &r->endpoints[ep_count];
				if (audiofs_state_fill_output_endpoint(sc, cad,
				    wp, (uint8_t)i,
				    audiofs_state_next_endpoint_id, eslot)) {
					audiofs_state_next_endpoint_id++;
					ep_count++;
				}
			}
		}
	}

	r->header.controller_count = ctrl_count;
	r->header.endpoint_count = ep_count;
}

/*
 * Open (create/truncate) the state file. Sets
 * audiofs_state_vp on success; leaves it NULL on failure
 * (publication then silently no-ops). Caller holds
 * audiofs_state_sx.
 */
static void
audiofs_state_open_file(struct thread *td)
{
	struct nameidata nd;
	struct vattr vattr;
	int flags, error;

	(void)kern_mkdirat(td, AT_FDCWD,
	    __DECONST(char *, AUDIOFS_STATE_PARENT), UIO_SYSSPACE, 0755);
	(void)kern_mkdirat(td, AT_FDCWD,
	    __DECONST(char *, AUDIOFS_STATE_DIR), UIO_SYSSPACE, 0755);

	flags = FWRITE | O_CREAT | O_TRUNC;
	NDINIT(&nd, LOOKUP, FOLLOW, UIO_SYSSPACE,
	    __DECONST(char *, AUDIOFS_STATE_PATH));
	error = vn_open(&nd, &flags, AUDIOFS_STATE_MODE, NULL);
	if (error != 0) {
		printf("audiofs: vn_open(%s) failed: %d "
		    "(continuing without state file)\n",
		    AUDIOFS_STATE_PATH, error);
		audiofs_state_vp = NULL;
		return;
	}
	NDFREE_PNBUF(&nd);
	audiofs_state_vp = nd.ni_vp;

	VATTR_NULL(&vattr);
	vattr.va_uid = (uid_t)AUDIOFS_STATE_UID;
	vattr.va_gid = (gid_t)AUDIOFS_STATE_GID;
	vattr.va_mode = (mode_t)(AUDIOFS_STATE_MODE & 07777);
	error = VOP_SETATTR(audiofs_state_vp, &vattr, td->td_ucred);
	if (error != 0)
		printf("audiofs: VOP_SETATTR(%s) failed: %d\n",
		    AUDIOFS_STATE_PATH, error);

	VOP_UNLOCK(audiofs_state_vp);
	printf("audiofs: opened state file %s (size=%lu bytes)\n",
	    AUDIOFS_STATE_PATH, (unsigned long)AUDIOFS_STATE_SIZE);
}

static void
audiofs_state_close_file(struct thread *td)
{

	if (audiofs_state_vp == NULL)
		return;
	(void)vn_close(audiofs_state_vp, FWRITE, NOCRED, td);
	audiofs_state_vp = NULL;
}

/*
 * F.4 clock publication helpers (ADR 0018). Module-global,
 * mirroring the state-file open/close pattern but mapping the
 * file page into kernel_map (and wiring it) instead of writing
 * with vn_rdwr, because the clock format has no seqlock and
 * relies on a single atomic store visible to a concurrent mmap
 * reader (see the F.4 section comment above the constants).
 */

/*
 * Open /var/run/sema/clock, size it to one page, map that page
 * into kernel virtual address space, wire it, and write the
 * static header. Caller holds audiofs_state_sx. On any failure
 * the clock is left unmapped (audiofs_clock_mapped = 0) and
 * playback proceeds without a published clock.
 */
static void
audiofs_clock_open(struct thread *td)
{
	struct nameidata nd;
	struct vattr vattr;
	vm_object_t obj;
	vm_offset_t kva;
	uint8_t *p;
	int flags, error;

	(void)kern_mkdirat(td, AT_FDCWD,
	    __DECONST(char *, AUDIOFS_STATE_PARENT), UIO_SYSSPACE, 0755);

	flags = FWRITE | O_CREAT | O_TRUNC;
	NDINIT(&nd, LOOKUP, FOLLOW, UIO_SYSSPACE,
	    __DECONST(char *, AUDIOFS_CLOCK_PATH));
	error = vn_open(&nd, &flags, AUDIOFS_STATE_MODE, NULL);
	if (error != 0) {
		printf("audiofs: vn_open(%s) failed: %d "
		    "(continuing without clock writer)\n",
		    AUDIOFS_CLOCK_PATH, error);
		audiofs_clock_vp = NULL;
		return;
	}
	NDFREE_PNBUF(&nd);
	audiofs_clock_vp = nd.ni_vp;

	/*
	 * Size to a full page. The region is 20 bytes, but the
	 * mapping is page-granular; the file's first page backs it.
	 */
	VATTR_NULL(&vattr);
	vattr.va_uid = (uid_t)AUDIOFS_STATE_UID;
	vattr.va_gid = (gid_t)AUDIOFS_STATE_GID;
	vattr.va_mode = (mode_t)(AUDIOFS_STATE_MODE & 07777);
	vattr.va_size = PAGE_SIZE;
	error = VOP_SETATTR(audiofs_clock_vp, &vattr, td->td_ucred);
	if (error != 0)
		printf("audiofs: VOP_SETATTR(%s) failed: %d\n",
		    AUDIOFS_CLOCK_PATH, error);

	/*
	 * Materialise the vnode's VM object and take a reference for
	 * the kernel mapping. vnode_create_vobject needs the vnode
	 * locked, which it still is from vn_open.
	 */
	error = vnode_create_vobject(audiofs_clock_vp, PAGE_SIZE, td);
	if (error != 0 || audiofs_clock_vp->v_object == NULL) {
		printf("audiofs: clock vnode_create_vobject failed: %d "
		    "(continuing without clock writer)\n", error);
		VOP_UNLOCK(audiofs_clock_vp);
		return;
	}
	obj = audiofs_clock_vp->v_object;
	vm_object_reference(obj);	/* donated to the map entry below */
	VOP_UNLOCK(audiofs_clock_vp);

	/*
	 * Map the object's first page into kernel_map and wire it.
	 * vm_map_find consumes the reference taken above on success;
	 * on failure we drop it here. Wiring guarantees the
	 * per-interrupt store from the ithread never faults.
	 *
	 * BENCH-CRITICAL: the vm_map_find / vm_map_wire / vm_map_remove
	 * reference discipline is the highest-risk part of F.4 and
	 * cannot be exercised off-target. Verify object ref counts via
	 * vmstat -z across kldload/kldunload cycles (closure crit. 9).
	 */
	kva = 0;
	error = vm_map_find(kernel_map, obj, 0, &kva, PAGE_SIZE, 0,
	    VMFS_ANY_SPACE, VM_PROT_READ | VM_PROT_WRITE,
	    VM_PROT_READ | VM_PROT_WRITE, 0);
	if (error != KERN_SUCCESS) {
		printf("audiofs: clock vm_map_find failed: %d "
		    "(continuing without clock writer)\n", error);
		vm_object_deallocate(obj);
		return;
	}
	error = vm_map_wire(kernel_map, kva, kva + PAGE_SIZE,
	    VM_MAP_WIRE_SYSTEM | VM_MAP_WIRE_NOHOLES);
	if (error != KERN_SUCCESS) {
		printf("audiofs: clock vm_map_wire failed: %d "
		    "(continuing without clock writer)\n", error);
		(void)vm_map_remove(kernel_map, kva, kva + PAGE_SIZE);
		return;
	}

	audiofs_clock_kva = kva;
	audiofs_clock_mapped = 1;

	/* Static header: valid=0 until the first stream_begin. */
	p = (uint8_t *)kva;
	memset(p, 0, AUDIOFS_CLOCK_SIZE);
	le32enc(p + AUDIOFS_CLOCK_OFF_MAGIC, AUDIOFS_CLOCK_MAGIC);
	p[AUDIOFS_CLOCK_OFF_VERSION] = (uint8_t)AUDIOFS_CLOCK_VERSION;
	p[AUDIOFS_CLOCK_OFF_VALID] = 0;
	p[AUDIOFS_CLOCK_OFF_SOURCE] = AUDIOFS_CLOCK_SOURCE_AUDIO;
	p[AUDIOFS_CLOCK_OFF_PAD] = 0;
	le32enc(p + AUDIOFS_CLOCK_OFF_RATE, 0);
	*(volatile uint64_t *)(p + AUDIOFS_CLOCK_OFF_SAMPLES) = htole64(0);

	printf("audiofs: opened clock file %s (mapped, wired)\n",
	    AUDIOFS_CLOCK_PATH);
}

/*
 * Tear down the clock mapping and close the file. Caller holds
 * audiofs_state_sx. vm_map_remove unwires and removes the
 * mapping and releases the map entry's object reference; the
 * file persists on disk with its last values (clock_valid stays
 * 1, last samples_written) per ADR 0003 section 4. This is a
 * deliberate divergence from the state file, which is rewritten
 * with state_valid=0 on teardown.
 */
static void
audiofs_clock_close(struct thread *td)
{

	if (audiofs_clock_mapped) {
		(void)vm_map_remove(kernel_map, audiofs_clock_kva,
		    audiofs_clock_kva + PAGE_SIZE);
		audiofs_clock_kva = 0;
		audiofs_clock_mapped = 0;
	}
	if (audiofs_clock_vp != NULL) {
		(void)vn_close(audiofs_clock_vp, FWRITE, NOCRED, td);
		audiofs_clock_vp = NULL;
	}
}

/*
 * Mark the clock live at stream_begin: publish sample_rate and
 * clock_source, then release-store clock_valid=1 (written last
 * so a reader seeing valid=1 also sees the rate). Idempotent
 * after the first stream. Does NOT touch clock_samples_total;
 * the published count is monotonic across stop/start.
 */
static void
audiofs_clock_stream_begin(struct audiofs_softc *sc, uint32_t sample_rate)
{
	uint8_t *p;

	(void)sc;
	if (!audiofs_clock_mapped)
		return;
	p = (uint8_t *)audiofs_clock_kva;
	le32enc(p + AUDIOFS_CLOCK_OFF_RATE, sample_rate);
	p[AUDIOFS_CLOCK_OFF_SOURCE] = AUDIOFS_CLOCK_SOURCE_AUDIO;
	atomic_store_rel_8(p + AUDIOFS_CLOCK_OFF_VALID, 1);
}

/*
 * Publish the current monotonic count. Hot path: called inline
 * from the ithread after the per-interrupt accumulation, and
 * once at stream_end. The store at offset 12 is a single 64-bit
 * write to the wired, page-aligned mapping; on amd64 that is
 * single-copy-atomic for a concurrent mmap reader (within one
 * cache line). amd64-scoped per ADR 0018 Decision 3.
 */
static void
audiofs_clock_update(struct audiofs_softc *sc)
{
	uint8_t *p;
	uint64_t samples;

	if (!audiofs_clock_mapped)
		return;
	samples = atomic_load_acq_64((volatile uint64_t *)&sc->clock_samples_total);
	p = (uint8_t *)audiofs_clock_kva;
	*(volatile uint64_t *)(p + AUDIOFS_CLOCK_OFF_SAMPLES) =
	    htole64(samples);
}

/*
 * Write the region buffer to the state file. Caller holds
 * audiofs_state_sx. The seqlock discipline (odd while
 * writing) is encoded in the buffer header before/after the
 * vn_rdwr so a concurrent reader observes a consistent
 * snapshot or retries.
 */
static void
audiofs_state_write_region(struct thread *td,
    struct audiofs_state_region *r)
{
	int error;

	if (audiofs_state_vp == NULL)
		return;

	/* seqlock: odd value published first (write in progress). */
	r->header.seqlock = (audiofs_state_inventory_seq << 1) | 1u;

	error = vn_rdwr(UIO_WRITE, audiofs_state_vp, (void *)r,
	    (int)AUDIOFS_STATE_SIZE, (off_t)0, UIO_SYSSPACE,
	    IO_UNIT | IO_SYNC, NOCRED, NULL, NULL, td);
	if (error != 0) {
		if (!audiofs_state_sync_logged_failure) {
			printf("audiofs: state vn_rdwr failed: %d "
			    "(further failures suppressed until success)\n",
			    error);
			audiofs_state_sync_logged_failure = 1;
		}
		return;
	}
	audiofs_state_sync_logged_failure = 0;

	/* seqlock: even value published last (write complete). */
	r->header.seqlock = (audiofs_state_inventory_seq << 1);
	r->header.state_valid = 1;
	(void)vn_rdwr(UIO_WRITE, audiofs_state_vp, (void *)r,
	    (int)AUDIOFS_STATE_SIZE, (off_t)0, UIO_SYSSPACE,
	    IO_UNIT | IO_SYNC, NOCRED, NULL, NULL, td);
}

/*
 * Rebuild and rewrite the whole state file from the current
 * registry. Caller holds audiofs_state_sx.
 */
static void
audiofs_state_republish(void)
{
	struct audiofs_state_region *r;
	struct thread *td = curthread;

	if (!audiofs_state_initialized || audiofs_state_vp == NULL)
		return;

	r = malloc(sizeof(*r), M_AUDIOFS, M_WAITOK | M_ZERO);
	audiofs_state_build_region(r);
	audiofs_state_write_region(td, r);
	free(r, M_AUDIOFS);
}

/*
 * Register a controller softc in the global registry and
 * republish. Called from attach after topology walk completes.
 */
static void
audiofs_state_register(struct audiofs_softc *sc)
{
	uint8_t new_controller_idx;

	sx_xlock(&audiofs_state_sx);

	if (!audiofs_state_initialized) {
		audiofs_state_open_file(curthread);
		audiofs_events_open_file(curthread);
		audiofs_clock_open(curthread);
		audiofs_state_initialized = 1;
	}

	if (audiofs_state_softc_count < AUDIOFS_STATE_CONTROLLER_SLOTS) {
		audiofs_state_softcs[audiofs_state_softc_count++] = sc;
		audiofs_state_inventory_seq++;
		new_controller_idx = (uint8_t)(audiofs_state_softc_count - 1);
	} else {
		printf("audiofs: controller registry full (>%d); "
		    "state file will omit this controller\n",
		    AUDIOFS_STATE_CONTROLLER_SLOTS);
		new_controller_idx = 0xff;	/* not registered */
	}

	audiofs_state_republish();

	/*
	 * F.2: emit endpoint_attach events for this controller's
	 * newly enumerated endpoints, then mark the ring live. The
	 * emit walks the freshly rebuilt state region so
	 * endpoint_slot indices match the state inventory, filtered
	 * to the just-registered controller so a later controller's
	 * register does not re-emit earlier endpoints. Each publish
	 * also republishes state (updating last_event_seq), keeping
	 * the two surfaces correlated.
	 */
	if (new_controller_idx != 0xff)
		audiofs_events_emit_endpoint_attaches(new_controller_idx);
	audiofs_events_set_valid(curthread);

	sx_xunlock(&audiofs_state_sx);
}

/*
 * Remove a controller softc from the registry and republish.
 * Called from detach. Slots after the removed one shift down
 * so the registry stays contiguous; controller_idx values in
 * the next republish are recomputed from the new order.
 */
static void
audiofs_state_unregister(struct audiofs_softc *sc)
{
	int i, j;

	sx_xlock(&audiofs_state_sx);

	for (i = 0; i < audiofs_state_softc_count; i++) {
		if (audiofs_state_softcs[i] != sc)
			continue;
		for (j = i; j < audiofs_state_softc_count - 1; j++)
			audiofs_state_softcs[j] =
			    audiofs_state_softcs[j + 1];
		audiofs_state_softcs[--audiofs_state_softc_count] = NULL;
		audiofs_state_inventory_seq++;
		break;
	}

	audiofs_state_republish();

	sx_xunlock(&audiofs_state_sx);
}

/* ---------------------------------------------------------
 * F.2 events-ring publication
 *
 * Design: audiofs/docs/adr/0013-f2-events-ring.md
 * Schema: shared/AUDIO_EVENTS.md
 * Layout: audiofs_events.h
 *
 * The in-kernel audiofs_events_buf is the authoritative ring.
 * audiofs_events_publish writes one slot (seq-last protocol),
 * advances writer_seq, syncs the buffer to the file, updates
 * the state region's last_event_seq (via republish, which
 * reads audiofs_events_writer_seq), and wakes the notify cdev.
 *
 * All publish calls hold audiofs_state_sx (sleepable; VFS I/O
 * in the sync path may sleep).
 * --------------------------------------------------------- */

/* notify cdev forward decls. */
static d_open_t		audiofs_notify_open;
static d_close_t	audiofs_notify_close;
static d_poll_t		audiofs_notify_poll;
static d_kqfilter_t	audiofs_notify_kqfilter;
static int		audiofs_notify_open_count;

static struct cdevsw audiofs_notify_cdevsw = {
	.d_version	= D_VERSION,
	.d_name		= "audiofs_notify",
	.d_open		= audiofs_notify_open,
	.d_close	= audiofs_notify_close,
	.d_poll		= audiofs_notify_poll,
	.d_kqfilter	= audiofs_notify_kqfilter,
	/*
	 * No d_read/d_write/d_ioctl/d_mmap: this cdev is a wake
	 * source only, mirroring inputfs ADR 0021. The data plane
	 * is the mmap-backed /var/run/sema/audio/events file.
	 */
};

static int
audiofs_notify_open(struct cdev *dev __unused, int oflags __unused,
    int devtype __unused, struct thread *td __unused)
{
	atomic_add_int(&audiofs_notify_open_count, 1);
	return (0);
}

static int
audiofs_notify_close(struct cdev *dev __unused, int fflag __unused,
    int devtype __unused, struct thread *td __unused)
{
	atomic_subtract_int(&audiofs_notify_open_count, 1);
	return (0);
}

/*
 * Edge-triggered poll, mirroring inputfs_notify_poll: always
 * selrecord and return 0; the selwakeup in audiofs_events_publish
 * delivers the edge. The cdev has no read syscall, so a level
 * check would make it appear permanently ready after the first
 * event. Consumers set their reader's last_consumed to
 * writer_seq at attach time to handle "events before first poll".
 */
static int
audiofs_notify_poll(struct cdev *dev __unused, int events,
    struct thread *td)
{
	if ((events & (POLLIN | POLLRDNORM)) == 0)
		return (0);
	selrecord(td, &audiofs_notify_selinfo);
	return (0);
}

static void	audiofs_notify_filt_detach(struct knote *kn);
static int	audiofs_notify_filt_event(struct knote *kn, long hint);

static struct filterops audiofs_notify_filtops = {
	.f_isfd		= 1,
	.f_attach	= NULL,
	.f_detach	= audiofs_notify_filt_detach,
	.f_event	= audiofs_notify_filt_event,
};

static int
audiofs_notify_kqfilter(struct cdev *dev __unused, struct knote *kn)
{

	if (kn->kn_filter != EVFILT_READ)
		return (EOPNOTSUPP);

	kn->kn_fop = &audiofs_notify_filtops;
	/* Snapshot writer_seq at attach; filt_event reports ready
	 * when writer_seq has advanced past this mark. */
	kn->kn_data = (int64_t)audiofs_events_writer_seq;
	knlist_add(&audiofs_notify_selinfo.si_note, kn, 0);
	return (0);
}

static void
audiofs_notify_filt_detach(struct knote *kn)
{
	knlist_remove(&audiofs_notify_selinfo.si_note, kn, 0);
}

static int
audiofs_notify_filt_event(struct knote *kn, long hint __unused)
{
	return (audiofs_events_writer_seq > (uint64_t)kn->kn_data);
}

/*
 * Sync the in-kernel ring buffer to the events file. Caller
 * holds audiofs_state_sx. Writes the whole region; the ring is
 * small (16 KB) and publishes are rare, so a full write per
 * publish is fine and keeps the file byte-identical to the
 * in-kernel buffer.
 */
static void
audiofs_events_sync(struct thread *td)
{
	int error;

	if (audiofs_events_vp == NULL || audiofs_events_buf == NULL)
		return;

	error = vn_rdwr(UIO_WRITE, audiofs_events_vp,
	    (void *)audiofs_events_buf, (int)AUDIOFS_EVENTS_SIZE, (off_t)0,
	    UIO_SYSSPACE, IO_UNIT | IO_SYNC, NOCRED, NULL, NULL, td);
	if (error != 0) {
		if (!audiofs_events_sync_logged_failure) {
			printf("audiofs: events vn_rdwr failed: %d "
			    "(further failures suppressed until success)\n",
			    error);
			audiofs_events_sync_logged_failure = 1;
		}
		return;
	}
	audiofs_events_sync_logged_failure = 0;
}

/*
 * Publish one event to the ring. Caller holds audiofs_state_sx.
 * Implements the writer protocol from shared/AUDIO_EVENTS.md.
 */
static void
audiofs_events_publish(uint8_t source_role, uint8_t event_type,
    uint16_t endpoint_slot, uint32_t flags, const void *payload,
    size_t payload_len)
{
	struct audiofs_event_slot *slot;
	uint64_t new_seq;
	uint32_t idx;
	struct timespec ts;

	if (audiofs_events_buf == NULL)
		return;

	new_seq = audiofs_events_writer_seq + 1;
	idx = (uint32_t)(new_seq & AUDIOFS_EVENTS_SLOT_MASK);
	slot = &audiofs_events_buf->slots[idx];

	/*
	 * Step 1+2: invalidate the slot for any concurrent reader
	 * by storing seq=0 first.
	 */
	atomic_store_rel_64((volatile uint64_t *)&slot->seq, 0);

	/* Step 3: write all body fields except seq. */
	nanouptime(&ts);
	slot->ts_ordering =
	    (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
	/*
	 * ts_sync: audio sample-clock position. audiofs is not yet
	 * the clock writer (that is F.4), so 0 until then. The
	 * field is reserved per ADR 0013.
	 */
	slot->ts_sync = 0;
	slot->endpoint_slot = endpoint_slot;
	slot->source_role = source_role;
	slot->event_type = event_type;
	slot->flags = flags;
	memset(slot->payload, 0, sizeof(slot->payload));
	if (payload != NULL && payload_len > 0) {
		size_t copy = payload_len > sizeof(slot->payload) ?
		    sizeof(slot->payload) : payload_len;
		memcpy(slot->payload, payload, copy);
	}

	/* Step 4: publish by storing the new seq. */
	atomic_store_rel_64((volatile uint64_t *)&slot->seq, new_seq);

	/* Step 5: advance writer_seq. */
	audiofs_events_writer_seq = new_seq;
	audiofs_events_buf->header.writer_seq = new_seq;

	/*
	 * Step 5b: if the ring wrapped (writer_seq has advanced a
	 * full slot_count past earliest), advance earliest_seq.
	 */
	if (new_seq >= AUDIOFS_EVENTS_SLOT_COUNT) {
		audiofs_events_earliest_seq =
		    new_seq - AUDIOFS_EVENTS_SLOT_COUNT + 1;
		audiofs_events_buf->header.earliest_seq =
		    audiofs_events_earliest_seq;
	}

	/* Sync buffer to file. */
	audiofs_events_sync(curthread);

	/*
	 * Step 6: update the state region's last_event_seq by
	 * republishing it (build_region reads
	 * audiofs_events_writer_seq). This keeps the snapshot and
	 * the delta stream correlated.
	 */
	audiofs_state_republish();

	/* Step 7: wake the notify cdev (poll + kqueue). */
	selwakeup(&audiofs_notify_selinfo);
	KNOTE_UNLOCKED(&audiofs_notify_selinfo.si_note, 0);
}

/*
 * Open (create/truncate) the events file and initialise the
 * in-kernel ring buffer. Caller holds audiofs_state_sx.
 */
static void
audiofs_events_open_file(struct thread *td)
{
	struct nameidata nd;
	struct vattr vattr;
	int flags, error;

	/* Parent dirs already created by the state-file open path,
	 * but create defensively in case events opens first. */
	(void)kern_mkdirat(td, AT_FDCWD,
	    __DECONST(char *, AUDIOFS_STATE_PARENT), UIO_SYSSPACE, 0755);
	(void)kern_mkdirat(td, AT_FDCWD,
	    __DECONST(char *, AUDIOFS_STATE_DIR), UIO_SYSSPACE, 0755);

	flags = FWRITE | O_CREAT | O_TRUNC;
	NDINIT(&nd, LOOKUP, FOLLOW, UIO_SYSSPACE,
	    __DECONST(char *, AUDIOFS_EVENTS_PATH));
	error = vn_open(&nd, &flags, AUDIOFS_STATE_MODE, NULL);
	if (error != 0) {
		printf("audiofs: vn_open(%s) failed: %d "
		    "(continuing without events ring)\n",
		    AUDIOFS_EVENTS_PATH, error);
		audiofs_events_vp = NULL;
		return;
	}
	NDFREE_PNBUF(&nd);
	audiofs_events_vp = nd.ni_vp;

	VATTR_NULL(&vattr);
	vattr.va_uid = (uid_t)AUDIOFS_STATE_UID;
	vattr.va_gid = (gid_t)AUDIOFS_STATE_GID;
	vattr.va_mode = (mode_t)(AUDIOFS_STATE_MODE & 07777);
	error = VOP_SETATTR(audiofs_events_vp, &vattr, td->td_ucred);
	if (error != 0)
		printf("audiofs: VOP_SETATTR(%s) failed: %d\n",
		    AUDIOFS_EVENTS_PATH, error);
	VOP_UNLOCK(audiofs_events_vp);

	/* Allocate and initialise the in-kernel ring buffer. */
	audiofs_events_buf = malloc(AUDIOFS_EVENTS_SIZE, M_AUDIOFS,
	    M_WAITOK | M_ZERO);
	audiofs_events_buf->header.magic = AUDIOFS_EVENTS_MAGIC;
	audiofs_events_buf->header.version = AUDIOFS_EVENTS_VERSION;
	audiofs_events_buf->header.ring_valid = 0;
	audiofs_events_buf->header.event_size = AUDIOFS_EVENTS_SLOT_SIZE;
	audiofs_events_buf->header.slot_count = AUDIOFS_EVENTS_SLOT_COUNT;
	audiofs_events_buf->header.writer_seq = 0;
	audiofs_events_buf->header.earliest_seq = 1;
	audiofs_events_writer_seq = 0;
	audiofs_events_earliest_seq = 1;

	audiofs_events_sync(td);
	printf("audiofs: opened events ring %s (size=%lu bytes)\n",
	    AUDIOFS_EVENTS_PATH, (unsigned long)AUDIOFS_EVENTS_SIZE);
}

static void
audiofs_events_close_file(struct thread *td)
{

	if (audiofs_events_buf != NULL) {
		/* Mark the ring invalid so a mmap'd reader sees it
		 * gone, sync, then free. */
		audiofs_events_buf->header.ring_valid = 0;
		audiofs_events_sync(td);
	}
	if (audiofs_events_vp != NULL) {
		(void)vn_close(audiofs_events_vp, FWRITE, NOCRED, td);
		audiofs_events_vp = NULL;
	}
	if (audiofs_events_buf != NULL) {
		free(audiofs_events_buf, M_AUDIOFS);
		audiofs_events_buf = NULL;
	}
}

/* Mark the ring live (ring_valid=1) once enumeration completes. */
static void
audiofs_events_set_valid(struct thread *td)
{
	if (audiofs_events_buf == NULL)
		return;
	audiofs_events_buf->header.ring_valid = 1;
	audiofs_events_sync(td);
}

/*
 * Emit endpoint_attach events for the endpoints belonging to a
 * single controller (identified by its index in the state
 * region's endpoint inventory). Called from the attach path
 * after the state region is populated, so endpoint_slot indices
 * match the state region's endpoint inventory. Passing
 * controller_idx limits emission to the just-registered
 * controller, so a second controller's register does not
 * re-emit the first controller's endpoints. Caller holds
 * audiofs_state_sx.
 *
 * F.2 emits these immediately (endpoints exist at attach). The
 * stream events (begin/end/xrun/format_change) are emitted by
 * the data path in F.3.a/d/e; their schema is reserved now.
 */
static void
audiofs_events_emit_endpoint_attaches(uint8_t controller_idx)
{
	struct audiofs_state_region *r;
	uint8_t i;

	if (audiofs_events_buf == NULL)
		return;

	/*
	 * Rebuild the current state region to learn the endpoint
	 * inventory and slot indices, then emit one attach per
	 * populated endpoint on the named controller. build_region
	 * is cheap and already the source of truth for endpoint
	 * enumeration.
	 */
	r = malloc(sizeof(*r), M_AUDIOFS, M_WAITOK | M_ZERO);
	audiofs_state_build_region(r);

	for (i = 0; i < r->header.endpoint_count &&
	    i < AUDIOFS_STATE_ENDPOINT_SLOTS; i++) {
		struct audiofs_state_endpoint *ep = &r->endpoints[i];
		struct audiofs_evp_endpoint_attach pl;

		if (ep->controller_idx != controller_idx)
			continue;

		memset(&pl, 0, sizeof(pl));
		pl.endpoint_id = ep->endpoint_id;
		pl.kind = ep->kind;
		pl.direction = ep->direction;
		pl.controller_idx = ep->controller_idx;

		audiofs_events_publish(AUDIOFS_EVROLE_ENDPOINT,
		    AUDIOFS_EVENDPOINT_ATTACH, i, 0, &pl, sizeof(pl));
	}

	free(r, M_AUDIOFS);
}

/* ---------------------------------------------------------
 * Controller reset
 *
 * Sequence mirrors hdac.c hdac_reset() with wakeup=true:
 *   1. Stop stream DMA engines (we don't have streams set
 *      up yet, but writing 0 is safe).
 *   2. Stop control DMA engines (CORB/RIRB).
 *   3. Zero DMA position buffer base.
 *   4. Assert CRST=0, wait for hardware to acknowledge.
 *   5. Wait at least 100us, deassert CRST (CRST=1).
 *   6. Wait for hardware to acknowledge.
 *   7. Wait at least 521us for codecs to finish their
 *      reset (HDA 1.0a section 4.3).
 *
 * Per hdac.c, the per-stream DMA stop loop reads num_iss/
 * num_oss/num_bss from GCAP. We read GCAP first so the
 * loop can run, then do the actual reset.
 * --------------------------------------------------------- */

static int
audiofs_reset(struct audiofs_softc *sc)
{
	uint32_t gctl;
	int count, i;

	/* Stop stream DMA engines. */
	for (i = 0; i < sc->num_iss; i++)
		AUDIOFS_WRITE_4(sc, _HDAC_ISDCTL(i, sc->num_iss, sc->num_oss), 0);
	for (i = 0; i < sc->num_oss; i++)
		AUDIOFS_WRITE_4(sc, _HDAC_OSDCTL(i, sc->num_iss, sc->num_oss), 0);
	for (i = 0; i < sc->num_bss; i++)
		AUDIOFS_WRITE_4(sc, _HDAC_BSDCTL(i, sc->num_iss, sc->num_oss), 0);

	/* Stop control DMA engines. */
	AUDIOFS_WRITE_1(sc, HDAC_CORBCTL, 0);
	AUDIOFS_WRITE_1(sc, HDAC_RIRBCTL, 0);

	/* Zero DMA position buffer. */
	AUDIOFS_WRITE_4(sc, HDAC_DPIBLBASE, 0);
	AUDIOFS_WRITE_4(sc, HDAC_DPIBUBASE, 0);

	/* Assert reset (CRST=0). */
	gctl = AUDIOFS_READ_4(sc, HDAC_GCTL);
	AUDIOFS_WRITE_4(sc, HDAC_GCTL, gctl & ~HDAC_GCTL_CRST);
	count = 10000;
	do {
		gctl = AUDIOFS_READ_4(sc, HDAC_GCTL);
		if (!(gctl & HDAC_GCTL_CRST))
			break;
		DELAY(10);
	} while (--count);
	if (gctl & HDAC_GCTL_CRST) {
		device_printf(sc->dev, "unable to enter reset\n");
		audiofs_log(sc, "reset_enter_failed", 0);
		return (ENXIO);
	}

	/* Hold reset for at least 100us per spec. */
	DELAY(100);

	/* Release reset (CRST=1). */
	gctl = AUDIOFS_READ_4(sc, HDAC_GCTL);
	AUDIOFS_WRITE_4(sc, HDAC_GCTL, gctl | HDAC_GCTL_CRST);
	count = 10000;
	do {
		gctl = AUDIOFS_READ_4(sc, HDAC_GCTL);
		if (gctl & HDAC_GCTL_CRST)
			break;
		DELAY(10);
	} while (--count);
	if (!(gctl & HDAC_GCTL_CRST)) {
		device_printf(sc->dev, "stuck in reset\n");
		audiofs_log(sc, "reset_exit_failed", 0);
		return (ENXIO);
	}

	/*
	 * Wait at least 521us for codecs to finish their reset
	 * (HDA 1.0a section 4.3 Codec Discovery). hdac.c uses
	 * 1000us; we follow.
	 */
	DELAY(1000);

	audiofs_log(sc, "reset_complete", 0);
	return (0);
}

/* ---------------------------------------------------------
 * DMA helpers (mirrors hdac_dma_alloc/free/cb)
 * --------------------------------------------------------- */

static void
audiofs_dma_cb(void *arg, bus_dma_segment_t *segs, int nseg __unused,
    int error)
{
	struct audiofs_dma *dma = arg;

	if (error == 0)
		dma->dma_paddr = segs[0].ds_addr;
}

static int
audiofs_dma_alloc(struct audiofs_softc *sc, struct audiofs_dma *dma,
    bus_size_t size)
{
	bus_size_t roundsz;
	int error;

	roundsz = roundup2(size, HDA_DMA_ALIGNMENT);
	bzero(dma, sizeof(*dma));

	error = bus_dma_tag_create(
	    bus_get_dma_tag(sc->dev),
	    HDA_DMA_ALIGNMENT,
	    0,
	    sc->support_64bit ? BUS_SPACE_MAXADDR : BUS_SPACE_MAXADDR_32BIT,
	    BUS_SPACE_MAXADDR,
	    NULL, NULL,
	    roundsz,
	    1,
	    roundsz,
	    0,
	    NULL, NULL,
	    &dma->dma_tag);
	if (error != 0) {
		device_printf(sc->dev, "bus_dma_tag_create failed (%d)\n",
		    error);
		return (error);
	}

	error = bus_dmamem_alloc(dma->dma_tag, (void **)&dma->dma_vaddr,
	    BUS_DMA_NOWAIT | BUS_DMA_ZERO | BUS_DMA_COHERENT,
	    &dma->dma_map);
	if (error != 0) {
		device_printf(sc->dev, "bus_dmamem_alloc failed (%d)\n",
		    error);
		bus_dma_tag_destroy(dma->dma_tag);
		dma->dma_tag = NULL;
		return (error);
	}

	dma->dma_size = roundsz;

	error = bus_dmamap_load(dma->dma_tag, dma->dma_map,
	    dma->dma_vaddr, roundsz, audiofs_dma_cb, dma, 0);
	if (error != 0 || dma->dma_paddr == 0) {
		if (error == 0)
			error = ENOMEM;
		device_printf(sc->dev, "bus_dmamap_load failed (%d)\n", error);
		bus_dmamem_free(dma->dma_tag, dma->dma_vaddr, dma->dma_map);
		bus_dma_tag_destroy(dma->dma_tag);
		dma->dma_vaddr = NULL;
		dma->dma_tag = NULL;
		return (error);
	}

	return (0);
}

static void
audiofs_dma_free(struct audiofs_dma *dma)
{

	if (dma->dma_paddr != 0) {
		bus_dmamap_sync(dma->dma_tag, dma->dma_map,
		    BUS_DMASYNC_POSTREAD | BUS_DMASYNC_POSTWRITE);
		bus_dmamap_unload(dma->dma_tag, dma->dma_map);
		dma->dma_paddr = 0;
	}
	if (dma->dma_vaddr != NULL) {
		bus_dmamem_free(dma->dma_tag, dma->dma_vaddr, dma->dma_map);
		dma->dma_vaddr = NULL;
	}
	if (dma->dma_tag != NULL) {
		bus_dma_tag_destroy(dma->dma_tag);
		dma->dma_tag = NULL;
	}
	dma->dma_size = 0;
}

/* ---------------------------------------------------------
 * Pick CORB/RIRB sizes from the hardware's capability bits.
 * Prefer 256 entries (smallest overhead per round-trip);
 * fall back to 16 or 2.
 * --------------------------------------------------------- */

static int
audiofs_pick_corb_rirb_sizes(struct audiofs_softc *sc)
{
	uint8_t corbsize, rirbsize;

	corbsize = AUDIOFS_READ_1(sc, HDAC_CORBSIZE);
	if ((corbsize & HDAC_CORBSIZE_CORBSZCAP_256) ==
	    HDAC_CORBSIZE_CORBSZCAP_256)
		sc->corb_size = 256;
	else if ((corbsize & HDAC_CORBSIZE_CORBSZCAP_16) ==
	    HDAC_CORBSIZE_CORBSZCAP_16)
		sc->corb_size = 16;
	else if ((corbsize & HDAC_CORBSIZE_CORBSZCAP_2) ==
	    HDAC_CORBSIZE_CORBSZCAP_2)
		sc->corb_size = 2;
	else {
		device_printf(sc->dev, "invalid CORBSIZE caps 0x%02x\n",
		    corbsize);
		return (ENXIO);
	}

	rirbsize = AUDIOFS_READ_1(sc, HDAC_RIRBSIZE);
	if ((rirbsize & HDAC_RIRBSIZE_RIRBSZCAP_256) ==
	    HDAC_RIRBSIZE_RIRBSZCAP_256)
		sc->rirb_size = 256;
	else if ((rirbsize & HDAC_RIRBSIZE_RIRBSZCAP_16) ==
	    HDAC_RIRBSIZE_RIRBSZCAP_16)
		sc->rirb_size = 16;
	else if ((rirbsize & HDAC_RIRBSIZE_RIRBSZCAP_2) ==
	    HDAC_RIRBSIZE_RIRBSZCAP_2)
		sc->rirb_size = 2;
	else {
		device_printf(sc->dev, "invalid RIRBSIZE caps 0x%02x\n",
		    rirbsize);
		return (ENXIO);
	}

	return (0);
}

/* ---------------------------------------------------------
 * CORB/RIRB init and start. Sequence mirrors hdac.c's
 * hdac_corb_init/start and hdac_rirb_init/start.
 *
 * Must be called with hw_lock held, after the controller
 * has been reset (DMA engines stopped).
 * --------------------------------------------------------- */

static void
audiofs_corb_init(struct audiofs_softc *sc)
{
	uint8_t corbsize_reg;
	uint64_t paddr;

	switch (sc->corb_size) {
	case 256: corbsize_reg = HDAC_CORBSIZE_CORBSIZE_256; break;
	case 16:  corbsize_reg = HDAC_CORBSIZE_CORBSIZE_16;  break;
	case 2:   corbsize_reg = HDAC_CORBSIZE_CORBSIZE_2;   break;
	default:
		/* Already validated in audiofs_pick_corb_rirb_sizes. */
		return;
	}
	AUDIOFS_WRITE_1(sc, HDAC_CORBSIZE, corbsize_reg);

	paddr = (uint64_t)sc->corb_dma.dma_paddr;
	AUDIOFS_WRITE_4(sc, HDAC_CORBLBASE, (uint32_t)paddr);
	AUDIOFS_WRITE_4(sc, HDAC_CORBUBASE, (uint32_t)(paddr >> 32));

	/* Reset CORB read pointer. */
	sc->corb_wp = 0;
	AUDIOFS_WRITE_2(sc, HDAC_CORBWP, 0);
	AUDIOFS_WRITE_2(sc, HDAC_CORBRP, HDAC_CORBRP_CORBRPRST);
	/*
	 * Per hdac.c: some 82801G chipsets do not auto-clear
	 * CORBRPRST. Write zero explicitly.
	 */
	AUDIOFS_WRITE_2(sc, HDAC_CORBRP, 0);
}

static void
audiofs_rirb_init(struct audiofs_softc *sc)
{
	uint8_t rirbsize_reg;
	uint64_t paddr;

	switch (sc->rirb_size) {
	case 256: rirbsize_reg = HDAC_RIRBSIZE_RIRBSIZE_256; break;
	case 16:  rirbsize_reg = HDAC_RIRBSIZE_RIRBSIZE_16;  break;
	case 2:   rirbsize_reg = HDAC_RIRBSIZE_RIRBSIZE_2;   break;
	default:
		return;
	}
	AUDIOFS_WRITE_1(sc, HDAC_RIRBSIZE, rirbsize_reg);

	paddr = (uint64_t)sc->rirb_dma.dma_paddr;
	AUDIOFS_WRITE_4(sc, HDAC_RIRBLBASE, (uint32_t)paddr);
	AUDIOFS_WRITE_4(sc, HDAC_RIRBUBASE, (uint32_t)(paddr >> 32));

	sc->rirb_rp = 0;
	AUDIOFS_WRITE_2(sc, HDAC_RIRBWP, HDAC_RIRBWP_RIRBWPRST);

	/* Interrupt threshold; unused in polled mode but harmless. */
	AUDIOFS_WRITE_2(sc, HDAC_RINTCNT, sc->rirb_size / 2);
	/* We are polled; do not enable RINTCTL. Leave RIRBCTL bits off. */
	AUDIOFS_WRITE_1(sc, HDAC_RIRBCTL, 0);

	/* Pre-read sync once; the RIRB is device-write/host-read only. */
	bus_dmamap_sync(sc->rirb_dma.dma_tag, sc->rirb_dma.dma_map,
	    BUS_DMASYNC_PREREAD);
}

static void
audiofs_corb_start(struct audiofs_softc *sc)
{
	uint8_t corbctl;

	corbctl = AUDIOFS_READ_1(sc, HDAC_CORBCTL);
	corbctl |= HDAC_CORBCTL_CORBRUN;
	AUDIOFS_WRITE_1(sc, HDAC_CORBCTL, corbctl);
}

static void
audiofs_rirb_start(struct audiofs_softc *sc)
{
	uint8_t rirbctl;

	rirbctl = AUDIOFS_READ_1(sc, HDAC_RIRBCTL);
	rirbctl |= HDAC_RIRBCTL_RIRBDMAEN;
	AUDIOFS_WRITE_1(sc, HDAC_RIRBCTL, rirbctl);
}

/* ---------------------------------------------------------
 * RIRB flush: read all newly-arrived responses, deposit them
 * in the per-codec slot, and advance our read pointer.
 *
 * Returns the number of responses consumed. Caller holds
 * hw_lock.
 * --------------------------------------------------------- */

static int
audiofs_rirb_flush(struct audiofs_softc *sc)
{
	struct audiofs_rirb *base, *slot;
	uint16_t hw_wp;
	uint32_t resp, resp_ex;
	int cad;
	int consumed = 0;

	base = (struct audiofs_rirb *)sc->rirb_dma.dma_vaddr;
	hw_wp = AUDIOFS_READ_2(sc, HDAC_RIRBWP) & HDAC_RIRBWP_RIRBWP_MASK;

	bus_dmamap_sync(sc->rirb_dma.dma_tag, sc->rirb_dma.dma_map,
	    BUS_DMASYNC_POSTREAD);

	while (sc->rirb_rp != hw_wp) {
		sc->rirb_rp++;
		sc->rirb_rp %= sc->rirb_size;
		slot = &base[sc->rirb_rp];
		resp = le32toh(slot->response);
		resp_ex = le32toh(slot->response_ex);
		cad = HDAC_RIRB_RESPONSE_EX_SDATA_IN(resp_ex);

		if (resp_ex & HDAC_RIRB_RESPONSE_EX_UNSOLICITED) {
			/* Unsolicited - discard with a note. */
			audiofs_log(sc, "unsol_discarded", resp);
		} else if (cad < AUDIOFS_CODEC_MAX &&
		    sc->codecs[cad].pending > 0) {
			sc->codecs[cad].response = resp;
			sc->codecs[cad].pending--;
		} else {
			audiofs_log(sc, "stray_response", resp);
		}
		consumed++;
	}

	bus_dmamap_sync(sc->rirb_dma.dma_tag, sc->rirb_dma.dma_map,
	    BUS_DMASYNC_PREREAD);

	return (consumed);
}

/* ---------------------------------------------------------
 * Send a single verb to a codec and wait for its response.
 * Caller holds hw_lock.
 *
 * Returns the response, or HDA_INVALID on timeout.
 * --------------------------------------------------------- */

static uint32_t
audiofs_send_command(struct audiofs_softc *sc, int cad, uint32_t verb)
{
	uint32_t *corb;
	int timeout;

	if (cad < 0 || cad >= AUDIOFS_CODEC_MAX)
		return (HDA_INVALID);

	/* Embed cad into the verb's top bits. */
	verb &= ~HDA_CMD_CAD_MASK;
	verb |= ((uint32_t)cad) << HDA_CMD_CAD_SHIFT;

	sc->codecs[cad].response = HDA_INVALID;
	sc->codecs[cad].pending++;

	sc->corb_wp++;
	sc->corb_wp %= sc->corb_size;
	corb = (uint32_t *)sc->corb_dma.dma_vaddr;

	bus_dmamap_sync(sc->corb_dma.dma_tag, sc->corb_dma.dma_map,
	    BUS_DMASYNC_PREWRITE);
	corb[sc->corb_wp] = htole32(verb);
	bus_dmamap_sync(sc->corb_dma.dma_tag, sc->corb_dma.dma_map,
	    BUS_DMASYNC_POSTWRITE);

	AUDIOFS_WRITE_2(sc, HDAC_CORBWP, sc->corb_wp);

	timeout = AUDIOFS_CMD_TIMEOUT;
	do {
		if (audiofs_rirb_flush(sc) == 0)
			DELAY(10);
	} while (sc->codecs[cad].pending != 0 && --timeout);

	if (sc->codecs[cad].pending != 0) {
		audiofs_log(sc, "cmd_timeout", verb);
		sc->codecs[cad].pending = 0;
		return (HDA_INVALID);
	}

	return (sc->codecs[cad].response);
}

/* ---------------------------------------------------------
 * Codec enumeration. Reads STATESTS to find populated codec
 * addresses, then for each one queries vendor/device ids
 * and revision/stepping.
 * --------------------------------------------------------- */

static void
audiofs_enumerate_codecs(struct audiofs_softc *sc)
{
	uint16_t statests;
	uint32_t vendorid, revisionid;
	int cad, found = 0;

	statests = AUDIOFS_READ_2(sc, HDAC_STATESTS);
	/* Acknowledge by writing the bits back. */
	AUDIOFS_WRITE_2(sc, HDAC_STATESTS, statests);
	audiofs_log(sc, "statests", statests);

	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (!HDAC_STATESTS_SDIWAKE(statests, cad))
			continue;

		sc->codecs[cad].populated = 1;
		audiofs_log(sc, "codec_present_cad", cad);

		vendorid = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, 0x0, HDA_PARAM_VENDOR_ID));
		revisionid = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, 0x0, HDA_PARAM_REVISION_ID));

		if (vendorid == HDA_INVALID && revisionid == HDA_INVALID) {
			device_printf(sc->dev,
			    "codec at cad=%d did not respond\n", cad);
			audiofs_log(sc, "codec_no_response_cad", cad);
			sc->codecs[cad].populated = 0;
			continue;
		}

		sc->codecs[cad].vendor_id =
		    HDA_PARAM_VENDOR_ID_VENDOR_ID(vendorid);
		sc->codecs[cad].device_id =
		    HDA_PARAM_VENDOR_ID_DEVICE_ID(vendorid);
		sc->codecs[cad].revision_id =
		    HDA_PARAM_REVISION_ID_REVISION_ID(revisionid);
		sc->codecs[cad].stepping_id =
		    HDA_PARAM_REVISION_ID_STEPPING_ID(revisionid);

		audiofs_log(sc, "codec_vendor_id",
		    sc->codecs[cad].vendor_id);
		audiofs_log(sc, "codec_device_id",
		    sc->codecs[cad].device_id);

		device_printf(sc->dev,
		    "codec cad=%d vendor=0x%04x device=0x%04x "
		    "rev=0x%02x.%02x\n",
		    cad,
		    sc->codecs[cad].vendor_id,
		    sc->codecs[cad].device_id,
		    sc->codecs[cad].revision_id,
		    sc->codecs[cad].stepping_id);
		found++;
	}

	audiofs_log(sc, "codecs_found", found);
}

/* ---------------------------------------------------------
 * Widget-type name table. Indexed by HDA widget type 0x0-0xf;
 * unknown types fall through to "?". Used only for log
 * readability.
 * --------------------------------------------------------- */

static const char *audiofs_widget_type_name(uint32_t t)
{
	switch (t) {
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_AUDIO_OUTPUT:
		return ("audio_out");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_AUDIO_INPUT:
		return ("audio_in");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_AUDIO_MIXER:
		return ("mixer");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_AUDIO_SELECTOR:
		return ("selector");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX:
		return ("pin");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_POWER_WIDGET:
		return ("power");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_VOLUME_WIDGET:
		return ("volume_knob");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_BEEP_WIDGET:
		return ("beep");
	case HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_VENDOR_WIDGET:
		return ("vendor");
	default:
		return ("?");
	}
}

/* ---------------------------------------------------------
 * Read a widget's connection list and populate w->conns.
 *
 * Mirrors hdaa_widget_connection_parse() with the same
 * spec-derived range-expansion logic. Connection-list
 * entries can encode either single nids or ranges; the
 * RANGE bit in the response says "this entry is the end of
 * a range starting at prevcnid+1". A given hardware entry
 * thus expands to one or more conns[] slots.
 *
 * Short form: 4 entries per response, 7-bit nids each.
 * Long form: 2 entries per response, 15-bit nids each.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static void
audiofs_widget_read_conns(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	uint32_t res;
	int ents, entnum, i, j;
	uint16_t cnid, addcnid, prevcnid;
	int range_bit;

	w->nconns = 0;
	w->conn_overflow = 0;

	/*
	 * Widgets without a connection list (e.g. pin complexes
	 * not configured for output, or audio_out converters,
	 * or beep) skip this entirely.
	 */
	if (!(w->wcap & HDA_PARAM_AUDIO_WIDGET_CAP_CONN_LIST_MASK))
		return;

	res = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, w->nid, HDA_PARAM_CONN_LIST_LENGTH));
	if (res == HDA_INVALID)
		return;

	ents = HDA_PARAM_CONN_LIST_LENGTH_LIST_LENGTH(res);
	if (ents < 1)
		return;

	entnum = HDA_PARAM_CONN_LIST_LENGTH_LONG_FORM(res) ? 2 : 4;
	prevcnid = 0;

	/*
	 * Each verb fetches (entnum) connection entries packed
	 * into one 32-bit response. The range-bit is the high bit
	 * of each entry's slot.
	 */
	for (i = 0; i < ents; i += entnum) {
		res = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_CONN_LIST_ENTRY(0, w->nid, i));
		if (res == HDA_INVALID)
			return;
		for (j = 0; j < entnum; j++) {
			int shift = (32 / entnum) * j;
			int width = (32 / entnum);
			uint32_t mask = (1U << (width - 1)) - 1;
			cnid = (res >> shift) & mask;
			range_bit = (res >> (shift + width - 1)) & 1;

			if (cnid == 0) {
				/*
				 * Trailing zeros in the last response
				 * are padding; bail out cleanly. Stray
				 * zeros mid-list are technically a
				 * hardware bug; we log and stop.
				 */
				if (w->nconns < ents)
					audiofs_log(sc, "conn_zero_mid",
					    ((uintmax_t)w->nid << 32) |
					    ((uintmax_t)i << 16) | j);
				goto out;
			}

			if (range_bit == 0) {
				/* Single connection. */
				addcnid = cnid;
			} else if (prevcnid == 0 || prevcnid >= cnid) {
				/*
				 * Invalid range; hdaa.c notes this as a
				 * hardware bug warning but accepts the
				 * cnid as a single connection.
				 */
				audiofs_log(sc, "conn_bad_range",
				    ((uintmax_t)w->nid << 32) | cnid);
				addcnid = cnid;
			} else {
				/* Range from prevcnid+1 to cnid inclusive. */
				addcnid = prevcnid + 1;
			}

			while (addcnid <= cnid) {
				if (w->nconns >= AUDIOFS_CONN_MAX) {
					w->conn_overflow = 1;
					audiofs_log(sc, "conn_overflow",
					    ((uintmax_t)w->nid << 32) |
					    AUDIOFS_CONN_MAX);
					goto out;
				}
				/*
				 * Log each accepted connection so the full
				 * graph is queryable from sysctl eventlog
				 * alone. Encoding: nid in bits 32-47, index
				 * in bits 16-31, cnid in bits 0-15.
				 */
				audiofs_log(sc, "widget_conn",
				    ((uintmax_t)w->nid << 32) |
				    ((uintmax_t)w->nconns << 16) |
				    addcnid);
				w->conns[w->nconns++] = addcnid++;
			}
			prevcnid = cnid;
		}
	}
out:
	return;
}

/* ---------------------------------------------------------
 * Walk one widget: read AUDIO_WIDGET_CAP, store into the
 * codec's widget array (indexed by nid - widget_start),
 * read CONFIGURATION_DEFAULT for pins and CONNECTION_LIST
 * for widgets that advertise one, then log everything.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static void
audiofs_walk_widget(struct audiofs_softc *sc, int cad, uint16_t nid)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	struct audiofs_widget *w;
	uint32_t wcap, type;
	uint32_t pincfg;
	uint32_t pincap;
	int idx;

	idx = nid - codec->widget_start;
	if (idx < 0 || idx >= AUDIOFS_WIDGET_MAX) {
		device_printf(sc->dev,
		    "cad=%d nid=%u out of widget array range\n", cad, nid);
		audiofs_log(sc, "widget_oor",
		    ((uint32_t)cad << 16) | nid);
		return;
	}
	w = &codec->widgets[idx];

	wcap = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, nid, HDA_PARAM_AUDIO_WIDGET_CAP));
	if (wcap == HDA_INVALID) {
		device_printf(sc->dev,
		    "cad=%d nid=%u widget_cap query timeout\n", cad, nid);
		audiofs_log(sc, "widget_cap_timeout",
		    ((uint32_t)cad << 16) | nid);
		return;
	}

	type = HDA_PARAM_AUDIO_WIDGET_CAP_TYPE(wcap);

	w->valid = 1;
	w->nid = nid;
	w->wcap = wcap;
	w->type = type;
	w->pin_cfg = 0;
	w->pin_cap = 0;
	w->nconns = 0;
	w->conn_overflow = 0;

	device_printf(sc->dev,
	    "  cad=%d nid=%u type=%s(0x%x) wcap=0x%08x\n",
	    cad, nid, audiofs_widget_type_name(type), type, wcap);

	/*
	 * Encode arg as nid in low 16, type in middle, cad in
	 * high; gives us a single uintmax_t the eventlog can
	 * carry that names the widget.
	 */
	audiofs_log(sc, "widget",
	    ((uintmax_t)cad << 32) |
	    ((uintmax_t)type << 16) |
	    nid);

	if (type == HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX) {
		pincfg = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_CONFIGURATION_DEFAULT(0, nid));
		if (pincfg == HDA_INVALID) {
			device_printf(sc->dev,
			    "  cad=%d nid=%u pin_cfg query timeout\n",
			    cad, nid);
			audiofs_log(sc, "pincfg_timeout",
			    ((uint32_t)cad << 16) | nid);
		} else {
			w->pin_cfg = pincfg;
			device_printf(sc->dev,
			    "    pin_cfg=0x%08x\n", pincfg);
			audiofs_log(sc, "pincfg",
			    ((uintmax_t)nid << 32) | pincfg);
		}

		/*
		 * Read pin capabilities (HDA_PARAM_PIN_CAP). This
		 * tells us which control bits the pin actually
		 * honors: OUTPUT_CAP, INPUT_CAP, HEADPHONE_CAP,
		 * EAPD_CAP, PRESENCE_DETECT_CAP, VREF_CTRL bits.
		 * Storing this lets later code set only those bits
		 * the hardware supports, avoiding write-and-read-
		 * back mismatches.
		 */
		pincap = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, nid, HDA_PARAM_PIN_CAP));
		if (pincap == HDA_INVALID) {
			device_printf(sc->dev,
			    "  cad=%d nid=%u pin_cap query timeout\n",
			    cad, nid);
			audiofs_log(sc, "pincap_timeout",
			    ((uint32_t)cad << 16) | nid);
		} else {
			w->pin_cap = pincap;
			device_printf(sc->dev,
			    "    pin_cap=0x%08x%s%s%s%s%s\n",
			    pincap,
			    (pincap & HDA_PARAM_PIN_CAP_OUTPUT_CAP_MASK)
			        ? " OUT" : "",
			    (pincap & HDA_PARAM_PIN_CAP_INPUT_CAP_MASK)
			        ? " IN" : "",
			    (pincap & HDA_PARAM_PIN_CAP_HEADPHONE_CAP_MASK)
			        ? " HP" : "",
			    (pincap & HDA_PARAM_PIN_CAP_EAPD_CAP_MASK)
			        ? " EAPD" : "",
			    (pincap & HDA_PARAM_PIN_CAP_PRESENCE_DETECT_CAP_MASK)
			        ? " PRES" : "");
			audiofs_log(sc, "pincap",
			    ((uintmax_t)nid << 32) | pincap);
		}
	}

	/* Read connection list, if this widget advertises one. */
	audiofs_widget_read_conns(sc, cad, w);

	if (w->nconns > 0) {
		char buf[160];
		int k, n;

		buf[0] = '\0';
		n = 0;
		for (k = 0; k < w->nconns; k++) {
			int rem = (int)sizeof(buf) - n;
			if (rem <= 1)
				break;
			n += snprintf(buf + n, rem, "%s%u",
			    k == 0 ? "" : ",", w->conns[k]);
		}
		device_printf(sc->dev,
		    "    conns(%u%s): %s\n",
		    w->nconns,
		    w->conn_overflow ? "+overflow" : "",
		    buf);

		audiofs_log(sc, "widget_nconns",
		    ((uintmax_t)nid << 16) | w->nconns);
	}
}

/* ---------------------------------------------------------
 * Walk one function group: log its type and subsystem id,
 * then query its sub-node count and walk every widget.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static void
audiofs_walk_function_group(struct audiofs_softc *sc, int cad,
    uint16_t fg_nid)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint32_t fgtype, subid, snc;
	uint32_t fg_kind;
	uint16_t start_nid, total, w;

	fgtype = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, fg_nid, HDA_PARAM_FCT_GRP_TYPE));
	if (fgtype == HDA_INVALID) {
		audiofs_log(sc, "fg_type_timeout",
		    ((uint32_t)cad << 16) | fg_nid);
		return;
	}
	fg_kind = HDA_PARAM_FCT_GRP_TYPE_NODE_TYPE(fgtype);

	subid = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_SUBSYSTEM_ID(0, fg_nid));
	if (subid == HDA_INVALID)
		subid = 0;

	device_printf(sc->dev,
	    "function_group cad=%d nid=%u kind=%s(0x%x) subsys=0x%08x\n",
	    cad, fg_nid,
	    fg_kind == HDA_PARAM_FCT_GRP_TYPE_NODE_TYPE_AUDIO ? "audio" :
	    fg_kind == HDA_PARAM_FCT_GRP_TYPE_NODE_TYPE_MODEM ? "modem" :
	    "?",
	    fg_kind, subid);

	audiofs_log(sc, "fg_kind",
	    ((uintmax_t)cad << 32) | ((uintmax_t)fg_kind << 16) | fg_nid);
	audiofs_log(sc, "fg_subsys", subid);

	/* Only audio function groups have widgets we care about. */
	if (fg_kind != HDA_PARAM_FCT_GRP_TYPE_NODE_TYPE_AUDIO)
		return;

	snc = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, fg_nid, HDA_PARAM_SUB_NODE_COUNT));
	if (snc == HDA_INVALID) {
		audiofs_log(sc, "fg_snc_timeout",
		    ((uint32_t)cad << 16) | fg_nid);
		return;
	}
	start_nid = HDA_PARAM_SUB_NODE_COUNT_START(snc);
	total = HDA_PARAM_SUB_NODE_COUNT_TOTAL(snc);

	device_printf(sc->dev,
	    "  widgets: start_nid=%u total=%u\n", start_nid, total);
	audiofs_log(sc, "fg_widgets",
	    ((uintmax_t)start_nid << 32) | total);

	if (total > AUDIOFS_WIDGET_MAX) {
		device_printf(sc->dev,
		    "  WARNING: widget count %u exceeds storage %u; "
		    "walking first %u only\n",
		    total, AUDIOFS_WIDGET_MAX, AUDIOFS_WIDGET_MAX);
		total = AUDIOFS_WIDGET_MAX;
	}

	/*
	 * Record codec FG state. The first audio FG wins if a
	 * codec has more than one; that case is exotic on
	 * consumer codecs and would be addressed separately.
	 */
	if (codec->fg_nid == 0) {
		uint32_t fg_amp_cap;
		uint32_t fg_psr;
		uint32_t fg_sfm;

		codec->fg_nid = fg_nid;
		codec->fg_subsystem = subid;
		codec->widget_start = start_nid;
		codec->widget_total = total;

		/*
		 * Read the FG-level default output amp cap. Widgets
		 * that lack AMP_OVR in their wcap inherit this value
		 * rather than overriding with their own cap. Storing
		 * the FG default once avoids re-querying it on every
		 * non-override widget.
		 */
		fg_amp_cap = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, fg_nid,
		        HDA_PARAM_OUTPUT_AMP_CAP));
		if (fg_amp_cap == HDA_INVALID)
			fg_amp_cap = 0;
		codec->fg_output_amp_cap = fg_amp_cap;
		audiofs_log(sc, "fg_output_amp_cap", fg_amp_cap);

		/*
		 * Read the FG-level default supported PCM size/rate
		 * cap and stream-formats cap. Same FORMAT_OVR override
		 * pattern as amp_cap.
		 */
		fg_psr = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, fg_nid,
		        HDA_PARAM_SUPP_PCM_SIZE_RATE));
		if (fg_psr == HDA_INVALID)
			fg_psr = 0;
		codec->fg_supp_pcm_size_rate = fg_psr;
		audiofs_log(sc, "fg_supp_pcm_size_rate", fg_psr);

		fg_sfm = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, fg_nid,
		        HDA_PARAM_SUPP_STREAM_FORMATS));
		if (fg_sfm == HDA_INVALID)
			fg_sfm = 0;
		codec->fg_supp_stream_formats = fg_sfm;
		audiofs_log(sc, "fg_supp_stream_formats", fg_sfm);
	}

	for (w = 0; w < total; w++)
		audiofs_walk_widget(sc, cad, start_nid + w);
}

/* ---------------------------------------------------------
 * Walk one codec: query its root sub-node count, then walk
 * each function group.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static void
audiofs_walk_codec(struct audiofs_softc *sc, int cad)
{
	uint32_t snc;
	uint16_t start_nid, total, fg;

	snc = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, 0, HDA_PARAM_SUB_NODE_COUNT));
	if (snc == HDA_INVALID) {
		audiofs_log(sc, "codec_snc_timeout", cad);
		return;
	}
	start_nid = HDA_PARAM_SUB_NODE_COUNT_START(snc);
	total = HDA_PARAM_SUB_NODE_COUNT_TOTAL(snc);

	device_printf(sc->dev,
	    "codec cad=%d function_groups: start_nid=%u total=%u\n",
	    cad, start_nid, total);
	audiofs_log(sc, "codec_fgs",
	    ((uintmax_t)cad << 32) |
	    ((uintmax_t)start_nid << 16) | total);

	for (fg = 0; fg < total; fg++)
		audiofs_walk_function_group(sc, cad, start_nid + fg);
}

/* ---------------------------------------------------------
 * Topology walk entry point: for each populated codec, walk
 * its function groups and their widgets, then find a path
 * from each connected output pin back to a DAC. Called from
 * attach after audiofs_enumerate_codecs. Caller holds hw_lock.
 *
 * Commit 3 enumerated and logged. Commit 4a stored state
 * and read connection lists. Commit 4b adds the path
 * discovery: for each connected output pin, reverse-walk
 * the connection graph following the first input at each
 * widget until a DAC is reached, and log the path.
 *
 * Heuristic note (documented per audit principle):
 *   At a mixer or selector with multiple inputs, we pick
 *   conns[0]. This corresponds to "hardware default input
 *   selection". For codecs that need a non-default selector
 *   position to route audibly (some Realtek/IDT designs),
 *   a quirks-style override mechanism will be needed in
 *   a later commit. The CS4206 has no mixers or selectors
 *   in its output paths so the rule is degenerate here.
 * --------------------------------------------------------- */

static const char *
audiofs_pin_device_name(uint32_t devkind)
{
	switch (devkind) {
	case 0x0: return "Line_Out";
	case 0x1: return "Speaker";
	case 0x2: return "HP_Out";
	case 0x3: return "CD";
	case 0x4: return "SPDIF_Out";
	case 0x5: return "Digital_Other_Out";
	case 0x6: return "Modem_Line";
	case 0x7: return "Modem_Handset";
	case 0x8: return "Line_In";
	case 0x9: return "AUX";
	case 0xa: return "Mic_In";
	case 0xb: return "Telephony";
	case 0xc: return "SPDIF_In";
	case 0xd: return "Digital_Other_In";
	case 0xe: return "Reserved";
	case 0xf: return "Other";
	default:  return "?";
	}
}

/*
 * Walk one output path. Starts at the given pin nid. Returns
 * the DAC nid found (and fills path[]/depth) on success, 0 on
 * failure (dead end, cycle, or depth exceeded).
 *
 * Caller holds hw_lock indirectly via attach; this routine
 * does not send verbs and so does not need the lock for HW
 * access, but it reads codec->widgets[] which is populated
 * under hw_lock.
 */
static uint16_t
audiofs_path_from_pin(struct audiofs_softc *sc, int cad, uint16_t pin_nid,
    uint16_t path[AUDIOFS_PATH_MAX_DEPTH], int *depth_out)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint16_t cur_nid = pin_nid;
	int depth = 0;

	while (depth < AUDIOFS_PATH_MAX_DEPTH) {
		int idx = cur_nid - codec->widget_start;
		struct audiofs_widget *w;

		if (idx < 0 || idx >= codec->widget_total) {
			audiofs_log(sc, "path_oob_nid",
			    ((uintmax_t)pin_nid << 32) | cur_nid);
			break;
		}
		w = &codec->widgets[idx];
		if (!w->valid) {
			audiofs_log(sc, "path_invalid_widget",
			    ((uintmax_t)pin_nid << 32) | cur_nid);
			break;
		}

		path[depth++] = cur_nid;

		if (w->type == HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_AUDIO_OUTPUT) {
			/* Reached a DAC. Path complete. */
			*depth_out = depth;
			return cur_nid;
		}

		if (w->nconns == 0) {
			audiofs_log(sc, "path_dead_end",
			    ((uintmax_t)pin_nid << 32) | cur_nid);
			break;
		}

		/* Heuristic: follow first input. */
		cur_nid = w->conns[0];
	}

	if (depth >= AUDIOFS_PATH_MAX_DEPTH) {
		audiofs_log(sc, "path_too_deep",
		    ((uintmax_t)pin_nid << 32) | AUDIOFS_PATH_MAX_DEPTH);
	}
	*depth_out = depth;
	return 0;
}

/*
 * Find and log a path for every connected output pin on
 * one codec. "Connected" means pin_cfg connectivity is
 * something other than NONE.
 */
static void
audiofs_find_paths_for_codec(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	int i;

	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		uint32_t devkind, connectivity;
		uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
		int depth;
		uint16_t dac;
		char buf[160];
		int k, n;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		devkind = HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
		connectivity = HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);

		/* Skip pins with no physical connection. */
		if (connectivity == 1)	/* NONE */
			continue;

		/* Skip input devices (0x8 and above except SPDIF_Out). */
		if (devkind > 0x5)
			continue;

		dac = audiofs_path_from_pin(sc, cad, w->nid, path, &depth);

		if (dac == 0) {
			device_printf(sc->dev,
			    "  path FAILED for pin nid=%u (%s)\n",
			    w->nid, audiofs_pin_device_name(devkind));
			audiofs_log(sc, "path_failed", w->nid);
			continue;
		}

		buf[0] = '\0';
		n = 0;
		/*
		 * Path is recorded pin-first; we print it DAC-first
		 * so it reads in signal-flow direction.
		 */
		for (k = depth - 1; k >= 0; k--) {
			int rem = (int)sizeof(buf) - n;
			if (rem <= 1) break;
			n += snprintf(buf + n, rem, "%s%u",
			    k == depth - 1 ? "" : " -> ", path[k]);
		}

		device_printf(sc->dev,
		    "  path: %s   [%s pin nid=%u]\n",
		    buf, audiofs_pin_device_name(devkind), w->nid);

		/*
		 * Eventlog encoding: arg = (pin_nid << 48) |
		 * (devkind << 40) | (dac_nid << 24) | (depth << 16).
		 * pin_nid identifies the path; dac_nid says which
		 * DAC drives it; depth gives the chain length.
		 */
		audiofs_log(sc, "path_found",
		    ((uintmax_t)w->nid << 48) |
		    ((uintmax_t)devkind << 40) |
		    ((uintmax_t)dac << 24) |
		    ((uintmax_t)depth << 16));
	}
}

/* ---------------------------------------------------------
 * Pin output enable.
 *
 * For each connected output pin discovered by
 * audiofs_find_paths_for_codec, set the pin widget control
 * register bits that the pin actually supports per its
 * PIN_CAP register, then read back and verify.
 *
 * Bits are gated by pin_cap:
 *   - OUT_ENABLE is set only if PIN_CAP.OUTPUT_CAP is set.
 *   - HPHN_ENABLE is set only if the pin is HP-classed AND
 *     PIN_CAP.HEADPHONE_CAP is set.
 *
 * This avoids the "write a bit the pin cannot honor, read it
 * back as zero, log a mismatch" pattern that masquerades as
 * a real warning. PIN_CAP is the hardware-described
 * authoritative source of what controls apply to a given
 * pin; pin_cfg is firmware-described intent and can name a
 * pin as HP_Out without an HP amp being present on the pin.
 *
 * What this enables (and does not):
 *   - Sets the pin's output gating bit so the codec routes
 *     internal audio toward the pin's external pad.
 *   - Does NOT unmute the pin's output amplifier. Most
 *     consumer codecs come out of reset with output amps
 *     muted at -infinity dB; the pin OUT_ENABLE bit alone
 *     does not bring up audible signal. Amp control belongs
 *     in commit 6 alongside stream setup.
 *   - Does NOT decide which pin is "the active output".
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

/* ---------------------------------------------------------
 * Power-state management.
 *
 * HDA spec section 7.3.3.10: widgets that advertise
 * POWER_CTRL in their wcap come out of reset in D3 (sleep)
 * state. In D3 the widget does not process signals - DAC
 * widgets ignore stream data, pin widgets do not emit
 * analog signal. Sending SET_POWER_STATE(D0) is necessary
 * before audio can flow.
 *
 * Power up the function group first, then each widget on
 * the discovered output paths. Skip widgets without
 * POWER_CTRL (they have no power state to set; they are
 * always active).
 *
 * The reference snd_hda driver does this routinely; the
 * lack of power-up in audiofs's earlier commits is why
 * commit 6e's sine wave reached the DAC but no analog
 * signal emerged from the speaker pin.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

#define AUDIOFS_POWER_STATE_D0	0x00
#define AUDIOFS_POWER_STATE_D3	0x03

static void
audiofs_power_up_widget(struct audiofs_softc *sc, int cad, uint16_t nid,
    uint32_t wcap)
{
	uint32_t got;
	int act, set;
	int count;

	if (!(wcap & HDA_PARAM_AUDIO_WIDGET_CAP_POWER_CTRL_MASK))
		return;

	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_POWER_STATE(0, nid, AUDIOFS_POWER_STATE_D0));

	/*
	 * Poll for the transition to complete. The SET field in
	 * the response reflects what was requested; the ACT field
	 * reflects the current actual state. The codec accepts
	 * the SET command immediately but takes time to transition,
	 * particularly from D3 to D0 where the analog stage powers
	 * up. Spec does not bound the time; we give it up to
	 * 1000 * 100us = 100 ms.
	 */
	count = 1000;
	got = 0;
	do {
		got = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_POWER_STATE(0, nid));
		if (got == HDA_INVALID) {
			audiofs_log(sc, "power_readback_timeout", nid);
			return;
		}
		act = HDA_CMD_GET_POWER_STATE_ACT(got);
		set = HDA_CMD_GET_POWER_STATE_SET(got);
		if (act == AUDIOFS_POWER_STATE_D0 &&
		    set == AUDIOFS_POWER_STATE_D0)
			break;
		DELAY(100);
	} while (--count);

	audiofs_log(sc, "power_set",
	    ((uintmax_t)nid << 32) | (got & 0xff));

	if (act != AUDIOFS_POWER_STATE_D0) {
		device_printf(sc->dev,
		    "  power nid=%u: D0 not reached "
		    "(act=%d set=%d after %d us)\n",
		    nid, act, set,
		    (1000 - count) * 100);
		audiofs_log(sc, "power_transition_timeout",
		    ((uintmax_t)nid << 32) | (got & 0xff));
	}
}

static void
audiofs_power_up_codec_paths(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	int i;

	if (codec->fg_nid == 0)
		return;

	/*
	 * Power up the function group itself, unconditionally.
	 * The AUDIO_WIDGET_CAP parameter is defined for widgets,
	 * not for function-group nodes, so its POWER_CTRL bit
	 * cannot be used to decide whether the FG supports power
	 * states; per HDA 1.0a section 7.3.4.4 every function
	 * group supports D0/D3. (Previously the FG was gated on
	 * that undefined parameter and could be silently skipped,
	 * leaving the FG in its reset power state while path
	 * widgets individually reported D0.) Pass a wcap with
	 * POWER_CTRL set so audiofs_power_up_widget proceeds.
	 */
	audiofs_power_up_widget(sc, cad, codec->fg_nid,
	    HDA_PARAM_AUDIO_WIDGET_CAP_POWER_CTRL_MASK);

	/*
	 * Power up every widget on every discovered output path.
	 * We do not yet know which path will be active when the
	 * stream runs, so power them all up; the per-path policy
	 * for selective power-down can be added later.
	 */
	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		uint32_t devkind, connectivity;
		uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
		int depth;
		uint16_t dac;
		int k;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		devkind = HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
		connectivity =
		    HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);
		if (connectivity == 1)	/* NONE */
			continue;
		if (devkind > 0x5)
			continue;

		dac = audiofs_path_from_pin(sc, cad, w->nid, path, &depth);
		if (dac == 0)
			continue;

		for (k = 0; k < depth; k++) {
			int wi = path[k] - codec->widget_start;
			struct audiofs_widget *pw;
			if (wi < 0 || wi >= codec->widget_total)
				continue;
			pw = &codec->widgets[wi];
			audiofs_power_up_widget(sc, cad, pw->nid, pw->wcap);
		}
	}
}

/* ---------------------------------------------------------
 * Platform-policy diagnostic.
 *
 * Surfaces the codec capabilities that platform-specific
 * output policy (e.g. Apple iMac downstream amplifier
 * enable) might use, without making any policy decisions
 * or writes. Pure inspection. Output goes to dmesg and
 * eventlog.
 *
 * Two capability surfaces are reported:
 *
 *   1. GPIO inventory at the audio function group, via
 *      HDA_PARAM_GPIO_COUNT (parameter id 0x11) which
 *      returns NumGPIOs / NumGPOs / NumGPIs and the
 *      Wake / Unsolicited capability flags. These GPIO
 *      lines are controlled by standard HDA verbs
 *      (0x715 Data, 0x716 Enable, 0x717 Direction,
 *      reads via 0xF15/F16/F17) per HDA 1.0a section
 *      7.3.3.22-27. The standard verbs are codec-agnostic;
 *      what each GPIO line is wired to on a given board
 *      is platform-specific and not discoverable from
 *      the codec.
 *
 *   2. Per-pin EAPD capability bit, taken from the
 *      already-stored pin_cap. EAPD_CAP indicates the
 *      pin has an EAPD-controlled output signal that
 *      can be enabled or disabled via the EAPD/BTL
 *      Enable verb (0x70C/0xF0C) per HDA 1.0a section
 *      7.3.3.16. EAPD is "strongly recommended" to
 *      default to 1 per the spec; on hardware where the
 *      downstream amplifier listens to EAPD, the
 *      amplifier stays powered down until we write 1.
 *
 * Neither GPIO nor EAPD writes are issued by this pass.
 * If the codec advertises any controllable surfaces here,
 * the next commit can attempt to drive them - still
 * through standard HDA verbs - with the platform-policy
 * question (which GPIO bit on this board? does EAPD on
 * which pin gate the amp?) made explicit and testable.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

/*
 * Platform-policy table: maps (codec function-group subsystem
 * ID, high 16 bits as subvendor, low 16 bits as subdevice) to
 * an initial gpio_data value that will be driven at attach
 * time.
 *
 * Why the codec FG subsystem ID, not the controller's PCI
 * subsystem ID: the controller chip (often Intel HDA) is
 * generic across many boards and its PCI subsystem ID
 * typically identifies the controller vendor, not the
 * audio board layout. The codec's audio-function-group
 * subsystem ID is set by the board integrator (read via verb
 * GET_SUBSYSTEM_ID 0xF20 on the FG nid); on integrator-
 * controlled hardware like Apple Macs it identifies the
 * specific board layout, which is exactly the granularity at
 * which the GPIO-to-amp wiring varies.
 *
 * Each entry exists because empirical evidence on real
 * hardware (documented in the commit that introduced the
 * entry) showed that the given gpio_data value is required
 * for the platform's downstream audio path to function.
 * The mechanism (SET_GPIO_DATA verb on the audio function
 * group) is the same on every codec; what varies between
 * boards is which GPIO bit is wired to what downstream
 * component, and that knowledge is empirical, not
 * discoverable.
 *
 * Lookup is exact-match on (subvendor, subdevice) parsed from
 * the codec FG subsystem ID. On no match, gpio_data stays at
 * 0 (safe default) and the table has no effect. Operators can
 * still drive the GPIO at runtime via dev.audiofs.N.gpio_data
 * to perform their own empirical investigation on unknown
 * hardware.
 *
 * Keep entries alphabetized by subvendor for readability.
 */
struct audiofs_platform_policy {
	uint16_t	subvendor;
	uint16_t	subdevice;
	uint8_t		initial_gpio_data;
	const char	*comment;
};

static const struct audiofs_platform_policy audiofs_platform_policies[] = {
	/*
	 * Apple iMac (CS4206 codec). Commit 6f documented the
	 * empirical sweep: gpio_data bit 3 high enables the
	 * downstream Class-D speaker amplifier (active-high
	 * gate, not a latch); other bits have no observable
	 * effect on amp state. Setting bit 3 at attach makes
	 * the internal speaker work without operator action.
	 */
	{ 0x106b, 0x8200, 0x08, "Apple iMac CS4206 internal speaker amp enable" },
};

#define AUDIOFS_PLATFORM_POLICIES_N	\
    (sizeof(audiofs_platform_policies) / sizeof(audiofs_platform_policies[0]))

static const struct audiofs_platform_policy *
audiofs_platform_policy_lookup(uint16_t subvendor, uint16_t subdevice)
{
	size_t i;
	for (i = 0; i < AUDIOFS_PLATFORM_POLICIES_N; i++) {
		const struct audiofs_platform_policy *p =
		    &audiofs_platform_policies[i];
		if (p->subvendor == subvendor && p->subdevice == subdevice)
			return (p);
	}
	return (NULL);
}

static void
audiofs_inspect_platform_caps(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint32_t gpio_cap;
	int num_gpio, num_gpo, num_gpi;
	int gpi_wake, gpi_unsol;
	int i;

	if (codec->fg_nid == 0)
		return;

	gpio_cap = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PARAMETER(0, codec->fg_nid,
	        HDA_PARAM_GPIO_COUNT));
	if (gpio_cap == HDA_INVALID) {
		audiofs_log(sc, "gpio_cap_timeout", codec->fg_nid);
		return;
	}

	num_gpio = HDA_PARAM_GPIO_COUNT_NUM_GPIO(gpio_cap);
	num_gpo  = HDA_PARAM_GPIO_COUNT_NUM_GPO(gpio_cap);
	num_gpi  = HDA_PARAM_GPIO_COUNT_NUM_GPI(gpio_cap);
	gpi_wake  = (gpio_cap & HDA_PARAM_GPIO_COUNT_GPI_WAKE_MASK)  ? 1 : 0;
	gpi_unsol = (gpio_cap & HDA_PARAM_GPIO_COUNT_GPI_UNSOL_MASK) ? 1 : 0;

	device_printf(sc->dev,
	    "  cad=%d FG nid=%u GPIO inventory: "
	    "GPIO=%d GPO=%d GPI=%d Wake=%d Unsol=%d (raw=0x%08x)\n",
	    cad, codec->fg_nid,
	    num_gpio, num_gpo, num_gpi,
	    gpi_wake, gpi_unsol,
	    gpio_cap);

	/*
	 * Eventlog encoding for the GPIO cap: store the raw
	 * 32-bit value with the FG nid in the high half so
	 * the entry self-identifies which codec it came from.
	 */
	audiofs_log(sc, "gpio_cap",
	    ((uintmax_t)codec->fg_nid << 32) | gpio_cap);

	/*
	 * If this codec advertises any GPIO lines and we have not
	 * yet claimed a "platform codec" for runtime GPIO control,
	 * adopt this one.
	 */
	if (num_gpio > 0 && sc->gpio_cad < 0) {
		sc->gpio_cad = cad;
		sc->gpio_fg_nid = codec->fg_nid;
		sc->gpio_num_lines = num_gpio;
		sc->gpio_data = 0;

		/*
		 * Adoption only: record where the GPIO surface
		 * lives. Configuration (enable mask, direction,
		 * data, platform-policy value) is deliberately
		 * NOT done here. This pass runs before the
		 * power-up pass, and GPIO state written while
		 * the function group is still in D3 is not
		 * trustworthy across the D3->D0 transition. The
		 * writes happen in audiofs_apply_gpio_policy,
		 * called after power-up. This also restores the
		 * property this pass's header promises: pure
		 * inspection, no writes.
		 */
		device_printf(sc->dev,
		    "  cad=%d adopted as platform codec for "
		    "GPIO control: %d lines (configuration "
		    "deferred until after power-up)\n",
		    cad, num_gpio);
	}

	/*
	 * Walk pin widgets and report which ones advertise
	 * EAPD_CAP. pin_cap was already read and stored in
	 * audiofs_walk_widget during commit 5.
	 */
	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		int has_eapd;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		has_eapd = (w->pin_cap &
		    HDA_PARAM_PIN_CAP_EAPD_CAP_MASK) ? 1 : 0;
		if (!has_eapd)
			continue;

		device_printf(sc->dev,
		    "  cad=%d pin nid=%u advertises EAPD "
		    "(pin_cap=0x%08x)\n",
		    cad, w->nid, w->pin_cap);
		audiofs_log(sc, "pin_eapd_cap",
		    ((uintmax_t)w->nid << 32) | w->pin_cap);
	}
}

/* ---------------------------------------------------------
 * GPIO platform-policy application.
 *
 * Configures the adopted platform codec's GPIO lines
 * (enable mask, direction=output, data) and applies the
 * platform-policy table's initial gpio_data value, then
 * reads the data register back so the eventlog records
 * effect, not just intent.
 *
 * MUST run after the power-up pass. The HDA spec does not
 * guarantee that GPIO state written while the function
 * group is in D3 survives the D3->D0 transition, and the
 * commit-6f empirical sweep that discovered the Apple
 * iMac's gpio_data=0x08 was performed at runtime via
 * sysctl - i.e. with the codec already in D0. Writing the
 * same value pre-power-up was not the experiment that was
 * validated.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static void
audiofs_apply_gpio_policy(struct audiofs_softc *sc)
{
	struct audiofs_codec *codec;
	uint8_t mask;
	uint32_t got;
	int cad;

	if (sc->gpio_cad < 0)
		return;

	cad = sc->gpio_cad;
	codec = &sc->codecs[cad];
	mask = (sc->gpio_num_lines >= 8) ?
	    0xff : (uint8_t)((1U << sc->gpio_num_lines) - 1);

	/* Enable all advertised GPIO lines. */
	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_GPIO_ENABLE_MASK(0, sc->gpio_fg_nid, mask));
	audiofs_log(sc, "gpio_enable_mask_set", mask);

	/* Direction = output for all enabled lines. */
	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_GPIO_DIRECTION(0, sc->gpio_fg_nid, mask));
	audiofs_log(sc, "gpio_direction_set", mask);

	/* Data = 0 to start (safe default). */
	sc->gpio_data = 0;
	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_GPIO_DATA(0, sc->gpio_fg_nid, 0));
	audiofs_log(sc, "gpio_data_init", 0);

	/*
	 * Apply platform-policy table override, if any. Keyed
	 * on the codec FG subsystem ID; see the table comment
	 * for why not the controller PCI subsystem ID. (Earlier
	 * code keyed the lookup on the controller PCI subsystem,
	 * which silently never matched the Apple iMac entry; the
	 * platform policy never fired, the speaker amp gate
	 * stayed off, and playback was audibly silent despite
	 * LPIB advancing normally. F.3.a bench surfaced this.)
	 */
	{
		uint16_t fg_subv = (uint16_t)
		    ((codec->fg_subsystem >> 16) & 0xffff);
		uint16_t fg_subd = (uint16_t)
		    (codec->fg_subsystem & 0xffff);
		const struct audiofs_platform_policy *p =
		    audiofs_platform_policy_lookup(fg_subv, fg_subd);

		if (p != NULL && p->initial_gpio_data != 0) {
			sc->gpio_data = p->initial_gpio_data;
			(void)audiofs_send_command(sc, cad,
			    HDA_CMD_SET_GPIO_DATA(0,
			        sc->gpio_fg_nid, sc->gpio_data));
			audiofs_log(sc, "gpio_data_policy",
			    ((uintmax_t)fg_subv << 48) |
			    ((uintmax_t)fg_subd << 32) |
			    sc->gpio_data);
			device_printf(sc->dev,
			    "  cad=%d platform policy matched "
			    "(codec FG subsys=0x%04x%04x): %s, "
			    "gpio_data=0x%02x\n",
			    cad, fg_subv, fg_subd,
			    p->comment, sc->gpio_data);
		}
	}

	/*
	 * Read the data register back: the eventlog should
	 * record what the codec now reports, not what we
	 * intended. A silent no-op here is exactly the class
	 * of failure this pass exists to catch. Encode
	 * HDA_INVALID readback as 0x1ff so it is
	 * distinguishable from a legitimate 0xff.
	 */
	got = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_GPIO_DATA(0, sc->gpio_fg_nid));
	audiofs_log(sc, "gpio_data_readback",
	    ((uintmax_t)sc->gpio_data << 32) |
	    ((got == HDA_INVALID) ? 0x1ff : (got & 0xff)));
	if (got == HDA_INVALID || (got & 0xff) != sc->gpio_data) {
		device_printf(sc->dev,
		    "  gpio_data write=0x%02x readback=0x%02x "
		    "(did not stick)\n",
		    sc->gpio_data,
		    (got == HDA_INVALID) ?
		        0xffU : (uint32_t)(got & 0xff));
	}
}

/* ---------------------------------------------------------
 * Platform-policy sysctl handlers.
 *
 * gpio_data:
 *   Read returns the last-written value, optimistically.
 *   Write drives the platform codec's GPIO data bits via
 *   SET_GPIO_DATA (verb 0x715). Writes are bounded to the
 *   8 GPIO bits the spec defines (NumGPIOs <= 7 in the
 *   spec, so 0xff is the absolute ceiling); the codec
 *   will silently ignore bits beyond NumGPIOs but we
 *   mask anyway to keep the readback predictable.
 *
 *   If no platform codec was adopted (gpio_cad < 0),
 *   writes return ENXIO. Reads return 0.
 *
 * The handler is advisory in failure: it logs to
 * dmesg and the eventlog so the empirical record is
 * preserved even when a write does not have the effect
 * the user expected.
 * --------------------------------------------------------- */

static int
audiofs_sysctl_gpio_data(SYSCTL_HANDLER_ARGS)
{
	struct audiofs_softc *sc = arg1;
	int value;
	int error;
	uint32_t got;

	mtx_lock(&sc->hw_lock);
	value = sc->gpio_data;
	mtx_unlock(&sc->hw_lock);

	error = sysctl_handle_int(oidp, &value, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);

	mtx_lock(&sc->hw_lock);
	if (sc->gpio_cad < 0) {
		mtx_unlock(&sc->hw_lock);
		return (ENXIO);
	}

	sc->gpio_data = (uint8_t)(value & 0xff);

	(void)audiofs_send_command(sc, sc->gpio_cad,
	    HDA_CMD_SET_GPIO_DATA(0, sc->gpio_fg_nid, sc->gpio_data));

	got = audiofs_send_command(sc, sc->gpio_cad,
	    HDA_CMD_GET_GPIO_DATA(0, sc->gpio_fg_nid));

	audiofs_log(sc, "gpio_data_set",
	    ((uintmax_t)sc->gpio_data << 32) | (got & 0xff));

	if (got != HDA_INVALID && (got & 0xff) != sc->gpio_data) {
		device_printf(sc->dev,
		    "  gpio_data write=0x%02x readback=0x%02x "
		    "(some bits did not stick)\n",
		    sc->gpio_data, (uint32_t)(got & 0xff));
	}

	mtx_unlock(&sc->hw_lock);
	return (0);
}

/*
 * F.3.c (ADR 0016 Decision 9): report which IRQ path was
 * taken at attach. Read-only string sysctl. The value is
 * set in attach (once, never modified) so no locking is
 * needed to read it.
 *
 *   "msi"  -- pci_alloc_msi succeeded; controller uses MSI.
 *   "intx" -- MSI not available; controller uses legacy
 *             shared INTx (RF_SHAREABLE).
 *   "none" -- interrupts not attached (attach failed before
 *             bus_setup_intr; controller is non-functional
 *             from audiofs's perspective).
 */
static int
audiofs_sysctl_interrupts_setup(SYSCTL_HANDLER_ARGS)
{
	struct audiofs_softc *sc = arg1;
	const char *s;

	if (!sc->interrupts_attached)
		s = "none";
	else if (sc->msi_count == 1)
		s = "msi";
	else
		s = "intx";

	return (sysctl_handle_string(oidp, __DECONST(char *, s),
	    0, req));
}

static void
audiofs_enable_pin_output(struct audiofs_softc *sc, int cad, uint16_t nid,
    uint32_t devkind)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	struct audiofs_widget *w;
	uint32_t want, got;
	int idx;

	idx = nid - codec->widget_start;
	if (idx < 0 || idx >= codec->widget_total)
		return;
	w = &codec->widgets[idx];
	if (!w->valid)
		return;

	/*
	 * Only set capability bits the pin advertises. The pin's
	 * PIN_CAP register, queried during widget walk and stored
	 * on w->pin_cap, is authoritative about what the pin can
	 * honor.
	 *
	 * If a pin's pin_cfg says it is an output device (Speaker,
	 * HP_Out, etc.) but its pin_cap.OUTPUT_CAP is 0, we still
	 * skip OUT_ENABLE: pin_cfg is firmware-described intent,
	 * pin_cap is hardware-described capability, and capability
	 * wins.
	 *
	 * Headphone amplifier enable: only set HPHN_ENABLE if the
	 * pin advertises HEADPHONE_CAP. Pins on consumer codecs
	 * (CS4206 included) frequently report output device type
	 * HP_Out via pin_cfg without having a separate HP amplifier
	 * on the pin itself; setting HPHN_ENABLE on such a pin is
	 * harmless but causes the bit to read back as zero (a
	 * "false mismatch"). Consulting pin_cap suppresses the
	 * false alarm.
	 */
	want = 0;
	if (w->pin_cap & HDA_PARAM_PIN_CAP_OUTPUT_CAP_MASK)
		want |= HDA_CMD_GET_PIN_WIDGET_CTRL_OUT_ENABLE_MASK;
	if (devkind == 0x2 &&	/* HP_Out */
	    (w->pin_cap & HDA_PARAM_PIN_CAP_HEADPHONE_CAP_MASK))
		want |= HDA_CMD_GET_PIN_WIDGET_CTRL_HPHN_ENABLE_MASK;

	if (want == 0) {
		device_printf(sc->dev,
		    "  pin nid=%u: SKIPPED (no applicable bits; "
		    "pin_cap=0x%08x devkind=0x%x)\n",
		    nid, w->pin_cap, devkind);
		audiofs_log(sc, "pin_ctrl_skipped",
		    ((uintmax_t)nid << 32) | w->pin_cap);
		return;
	}

	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_PIN_WIDGET_CTRL(0, nid, want));

	got = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_PIN_WIDGET_CTRL(0, nid));
	if (got == HDA_INVALID) {
		device_printf(sc->dev,
		    "  pin nid=%u: ctrl readback TIMEOUT (wrote 0x%02x)\n",
		    nid, want);
		audiofs_log(sc, "pin_ctrl_readback_timeout",
		    ((uintmax_t)nid << 32) | want);
		return;
	}

	got &= 0xff;

	device_printf(sc->dev,
	    "  pin nid=%u: ctrl wrote=0x%02x read=0x%02x %s\n",
	    nid, want, got,
	    got == want ? "OK" : "MISMATCH");

	/*
	 * Eventlog encoding: arg = (nid << 32) | (want << 16) | got.
	 * Decoder reads nid, intended value, observed value.
	 */
	audiofs_log(sc, "pin_ctrl_set",
	    ((uintmax_t)nid << 32) |
	    ((uintmax_t)want << 16) |
	    got);

	if (got != want) {
		audiofs_log(sc, "pin_ctrl_mismatch",
		    ((uintmax_t)nid << 32) |
		    ((uintmax_t)want << 16) |
		    got);
	}
}

static void
audiofs_enable_outputs_for_codec(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	int i;

	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		uint32_t devkind, connectivity;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		devkind = HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
		connectivity = HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);

		/* Mirror the output-pin filter from path discovery. */
		if (connectivity == 1)	/* NONE */
			continue;
		if (devkind > 0x5)	/* not an output device kind */
			continue;

		audiofs_enable_pin_output(sc, cad, w->nid, devkind);
	}
}

/* ---------------------------------------------------------
 * Output amplifier unmute.
 *
 * For each widget that lies on a discovered output path and
 * has an output amplifier, set the amp to gain=OFFSET (the
 * "0 dB" position from the amp's capability register) with
 * mute=0, for both stereo channels. Read back each channel
 * to verify.
 *
 * Note on the amp cap source: a widget's audio-widget-cap
 * AMP_OVR bit determines whether the widget has its own
 * amp cap or inherits the function-group default. We query
 * the FG default once at FG walk time and store it on the
 * codec record; per-widget overrides are queried here when
 * needed.
 *
 * Note on register decoding: HDA spec 7.3.3.7 says the
 * GET_AMP_GAIN_MUTE response packs mute at bit 7 and gain
 * in bits 6-0. The reference header hda_reg.h has these
 * masks at bit 3 / bits 0-2, which appears to be a
 * pre-spec or transcription error. We decode by spec, not
 * by header.
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

#define AUDIOFS_AMP_OUTPUT		0x8000	/* HDA_CMD_SET_AMP_GAIN_MUTE_OUTPUT */
#define AUDIOFS_AMP_LEFT		0x2000	/* SET_AMP LEFT */
#define AUDIOFS_AMP_RIGHT		0x1000	/* SET_AMP RIGHT */
#define AUDIOFS_AMP_MUTE_BIT		0x0080	/* SET payload bit 7 */
#define AUDIOFS_AMP_GAIN_MASK		0x007f	/* SET payload bits 6-0 */

#define AUDIOFS_GET_AMP_RSP_MUTE_MASK	0x00000080	/* spec 7.3.3.7 */
#define AUDIOFS_GET_AMP_RSP_GAIN_MASK	0x0000007f	/* spec 7.3.3.7 */

#define AUDIOFS_GET_AMP_OUTPUT		0x8000	/* query output amp */
#define AUDIOFS_GET_AMP_LEFT		0x2000	/* query left channel */

/* Get the effective output amp cap for a widget. */
static uint32_t
audiofs_widget_output_amp_cap(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint32_t cap;

	if (HDA_PARAM_AUDIO_WIDGET_CAP_AMP_OVR(w->wcap)) {
		cap = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, w->nid,
		        HDA_PARAM_OUTPUT_AMP_CAP));
		if (cap == HDA_INVALID)
			cap = 0;
		return (cap);
	}
	return (codec->fg_output_amp_cap);
}

static void
audiofs_unmute_output_amp(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	uint32_t amp_cap;
	uint8_t offset;
	uint8_t mute_cap;
	uint16_t payload;
	uint32_t got_l, got_r;
	uint8_t mute_l, gain_l, mute_r, gain_r;

	/* Quick reject for widgets with no output amp. */
	if (!HDA_PARAM_AUDIO_WIDGET_CAP_OUT_AMP(w->wcap))
		return;

	amp_cap = audiofs_widget_output_amp_cap(sc, cad, w);
	if (amp_cap == 0) {
		device_printf(sc->dev,
		    "  amp nid=%u: zero amp_cap (FG default also 0)\n",
		    w->nid);
		audiofs_log(sc, "amp_cap_missing", w->nid);
		return;
	}

	offset = HDA_PARAM_OUTPUT_AMP_CAP_OFFSET(amp_cap);
	mute_cap = HDA_PARAM_OUTPUT_AMP_CAP_MUTE_CAP(amp_cap);

	/*
	 * Build the SET_AMP_GAIN_MUTE payload: target output amp,
	 * both stereo channels, no mute, gain=offset (0 dB).
	 * Index field is 0 (only meaningful for input amps).
	 */
	payload = AUDIOFS_AMP_OUTPUT | AUDIOFS_AMP_LEFT | AUDIOFS_AMP_RIGHT |
	    (offset & AUDIOFS_AMP_GAIN_MASK);
	/* mute bit deliberately not set */

	audiofs_log(sc, "amp_set",
	    ((uintmax_t)w->nid << 32) | payload);

	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_AMP_GAIN_MUTE(0, w->nid, payload));

	/*
	 * Read back both channels. The GET payload is different
	 * from SET: it picks input/output and a single channel.
	 * Index in low 4 bits is 0 for output.
	 */
	got_l = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_AMP_GAIN_MUTE(0, w->nid,
	        AUDIOFS_GET_AMP_OUTPUT | AUDIOFS_GET_AMP_LEFT));
	got_r = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_AMP_GAIN_MUTE(0, w->nid,
	        AUDIOFS_GET_AMP_OUTPUT));

	if (got_l == HDA_INVALID || got_r == HDA_INVALID) {
		device_printf(sc->dev,
		    "  amp nid=%u: readback TIMEOUT\n", w->nid);
		audiofs_log(sc, "amp_readback_timeout", w->nid);
		return;
	}

	mute_l = (got_l & AUDIOFS_GET_AMP_RSP_MUTE_MASK) ? 1 : 0;
	gain_l = got_l & AUDIOFS_GET_AMP_RSP_GAIN_MASK;
	mute_r = (got_r & AUDIOFS_GET_AMP_RSP_MUTE_MASK) ? 1 : 0;
	gain_r = got_r & AUDIOFS_GET_AMP_RSP_GAIN_MASK;

	device_printf(sc->dev,
	    "  amp nid=%u: wrote mute=0 gain=%u; "
	    "L mute=%u gain=%u; R mute=%u gain=%u%s%s\n",
	    w->nid, offset,
	    mute_l, gain_l, mute_r, gain_r,
	    (mute_cap ? "" : " (no-mute-cap)"),
	    (mute_l == 0 && mute_r == 0 &&
	     gain_l == offset && gain_r == offset) ? " OK" : " MISMATCH");

	audiofs_log(sc, "amp_readback",
	    ((uintmax_t)w->nid << 48) |
	    ((uintmax_t)mute_l << 47) |
	    ((uintmax_t)gain_l << 40) |
	    ((uintmax_t)mute_r << 39) |
	    ((uintmax_t)gain_r << 32) |
	    ((uintmax_t)offset << 16));

	if (mute_l != 0 || mute_r != 0 ||
	    gain_l != offset || gain_r != offset) {
		audiofs_log(sc, "amp_mismatch",
		    ((uintmax_t)w->nid << 32) | payload);
	}
}

/*
 * Walk the discovered output paths and unmute the output
 * amp at each widget that has one. The path was recorded
 * by audiofs_path_from_pin pin-first (path[0] = pin,
 * path[depth-1] = DAC); for unmuting it does not matter
 * which order we walk, since each widget's amp is
 * independent of the others.
 */
static void
audiofs_unmute_output_paths_for_codec(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	int i;

	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		uint32_t devkind, connectivity;
		uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
		int depth;
		uint16_t dac;
		int k;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		devkind = HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
		connectivity = HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);
		if (connectivity == 1)	/* NONE */
			continue;
		if (devkind > 0x5)
			continue;

		dac = audiofs_path_from_pin(sc, cad, w->nid, path, &depth);
		if (dac == 0)
			continue;

		for (k = 0; k < depth; k++) {
			int wi = path[k] - codec->widget_start;
			if (wi < 0 || wi >= codec->widget_total)
				continue;
			audiofs_unmute_output_amp(sc, cad,
			    &codec->widgets[wi]);
		}
	}
}

/* ---------------------------------------------------------
 * DAC converter format binding.
 *
 * For each DAC widget on a discovered output path, query its
 * supported sample rates and bit depths (the SUPP_PCM_SIZE_RATE
 * and SUPP_STREAM_FORMATS caps, with FORMAT_OVR override
 * behavior matching the AMP_OVR pattern), verify the codec
 * supports 48 kHz / 16 bit / stereo PCM, then write the
 * format word via HDA_CMD_SET_CONV_FMT, read it back via
 * HDA_CMD_GET_CONV_FMT, and verify.
 *
 * Format selection rationale: 48 kHz / 16 bit / stereo PCM
 * is the most broadly supported HD-Audio format and matches
 * what the controller stream descriptor will be configured
 * for in commit 6c. A later commit can negotiate other
 * formats per consumer; this commit picks one known format
 * to land DAC-side bring-up.
 *
 * Format word encoding (HDA 1.0a section 3.7.1):
 *   bit 15:    TYPE     0=PCM, 1=non-PCM
 *   bit 14:    BASE     0=48 kHz family, 1=44.1 kHz family
 *   bits 13-11 MULT     sample rate multiplier
 *   bits 10-8  DIV      sample rate divisor
 *   bit 7:     reserved
 *   bits 6-4   BITS     001=16-bit
 *   bits 3-0   CHAN     channels minus 1
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

static uint32_t
audiofs_widget_supp_pcm_size_rate(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint32_t cap;

	if (HDA_PARAM_AUDIO_WIDGET_CAP_FORMAT_OVR(w->wcap)) {
		cap = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, w->nid,
		        HDA_PARAM_SUPP_PCM_SIZE_RATE));
		if (cap == HDA_INVALID)
			cap = 0;
		return (cap);
	}
	return (codec->fg_supp_pcm_size_rate);
}

static uint32_t
audiofs_widget_supp_stream_formats(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	uint32_t cap;

	if (HDA_PARAM_AUDIO_WIDGET_CAP_FORMAT_OVR(w->wcap)) {
		cap = audiofs_send_command(sc, cad,
		    HDA_CMD_GET_PARAMETER(0, w->nid,
		        HDA_PARAM_SUPP_STREAM_FORMATS));
		if (cap == HDA_INVALID)
			cap = 0;
		return (cap);
	}
	return (codec->fg_supp_stream_formats);
}

/*
 * F.3.e (ADR 0019): rate negotiation helpers. v1 is 16-bit
 * stereo only, so the format word is a function of the rate.
 */
static int
audiofs_rate_to_format_word(uint32_t rate_hz, uint16_t *word)
{
	switch (rate_hz) {
	case 48000:	*word = 0x0011; return (0);	/* 48k base x1 /1 */
	case 44100:	*word = 0x4011; return (0);	/* 44.1k base x1 /1 */
	case 32000:	*word = 0x0A11; return (0);	/* 48k base x2 /3 */
	default:	return (EINVAL);
	}
}

static bool
audiofs_psr_has_rate(uint32_t psr, uint32_t rate_hz)
{
	switch (rate_hz) {
	case 48000:	return ((psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_48KHZ_MASK) != 0);
	case 44100:	return ((psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_44KHZ_MASK) != 0);
	case 32000:	return ((psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_32KHZ_MASK) != 0);
	default:	return (false);
	}
}

static uint32_t
audiofs_psr_rate_mask(uint32_t psr)
{
	uint32_t m = 0;

	if (psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_32KHZ_MASK)
		m |= AUDIOFS_RATE_32000;
	if (psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_44KHZ_MASK)
		m |= AUDIOFS_RATE_44100;
	if (psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_48KHZ_MASK)
		m |= AUDIOFS_RATE_48000;
	return (m);
}

/*
 * PSR for the bound output DAC. Uses the codec's function-group
 * SUPP_PCM_SIZE_RATE (the same value audiofs_set_dac_format
 * validated at attach for the non-FORMAT_OVR case, which covers
 * the confirmed target). Returns 0 if no output DAC is bound.
 */
static uint32_t
audiofs_output_dac_psr(struct audiofs_softc *sc)
{
	if (sc->output_dac_cad < 0)
		return (0);
	return (sc->codecs[sc->output_dac_cad].fg_supp_pcm_size_rate);
}

static void
audiofs_set_dac_format(struct audiofs_softc *sc, int cad,
    struct audiofs_widget *w)
{
	uint32_t psr, sfm;
	uint32_t got;
	uint16_t want = AUDIOFS_FMT_48KHZ_16BIT_STEREO;

	psr = audiofs_widget_supp_pcm_size_rate(sc, cad, w);
	sfm = audiofs_widget_supp_stream_formats(sc, cad, w);

	audiofs_log(sc, "dac_psr", ((uintmax_t)w->nid << 32) | psr);
	audiofs_log(sc, "dac_sfm", ((uintmax_t)w->nid << 32) | sfm);

	/*
	 * Verify the codec supports the format we're about to
	 * write: PCM, 16-bit, 48 kHz. If any of these aren't
	 * advertised, log and skip - we don't yet have fallback
	 * format selection.
	 */
	if (!HDA_PARAM_SUPP_STREAM_FORMATS_PCM(sfm)) {
		device_printf(sc->dev,
		    "  dac nid=%u: PCM not supported (sfm=0x%08x)\n",
		    w->nid, sfm);
		audiofs_log(sc, "dac_no_pcm", w->nid);
		return;
	}
	if (!(psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_16BIT_MASK)) {
		device_printf(sc->dev,
		    "  dac nid=%u: 16-bit not supported (psr=0x%08x)\n",
		    w->nid, psr);
		audiofs_log(sc, "dac_no_16bit", w->nid);
		return;
	}
	if (!(psr & HDA_PARAM_SUPP_PCM_SIZE_RATE_48KHZ_MASK)) {
		device_printf(sc->dev,
		    "  dac nid=%u: 48kHz not supported (psr=0x%08x)\n",
		    w->nid, psr);
		audiofs_log(sc, "dac_no_48khz", w->nid);
		return;
	}

	audiofs_log(sc, "dac_fmt_set",
	    ((uintmax_t)w->nid << 32) | want);

	(void)audiofs_send_command(sc, cad,
	    HDA_CMD_SET_CONV_FMT(0, w->nid, want));

	got = audiofs_send_command(sc, cad,
	    HDA_CMD_GET_CONV_FMT(0, w->nid));
	if (got == HDA_INVALID) {
		device_printf(sc->dev,
		    "  dac nid=%u: fmt readback TIMEOUT (wrote 0x%04x)\n",
		    w->nid, want);
		audiofs_log(sc, "dac_fmt_readback_timeout",
		    ((uintmax_t)w->nid << 32) | want);
		return;
	}

	got &= 0xffff;

	device_printf(sc->dev,
	    "  dac nid=%u: fmt wrote=0x%04x read=0x%04x %s\n",
	    w->nid, want, got,
	    got == want ? "OK" : "MISMATCH");

	audiofs_log(sc, "dac_fmt_readback",
	    ((uintmax_t)w->nid << 32) |
	    ((uintmax_t)want << 16) |
	    got);

	if (got != want) {
		audiofs_log(sc, "dac_fmt_mismatch",
		    ((uintmax_t)w->nid << 32) |
		    ((uintmax_t)want << 16) |
		    got);
	}
}

/*
 * Walk discovered output paths, find each path's DAC widget
 * (the last entry in the path), and set its converter format.
 */
static void
audiofs_set_dac_formats_for_codec(struct audiofs_softc *sc, int cad)
{
	struct audiofs_codec *codec = &sc->codecs[cad];
	int i;

	for (i = 0; i < codec->widget_total; i++) {
		struct audiofs_widget *w = &codec->widgets[i];
		uint32_t devkind, connectivity;
		uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
		int depth;
		uint16_t dac;
		int dac_idx;

		if (!w->valid)
			continue;
		if (w->type != HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
			continue;

		devkind = HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
		connectivity = HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);
		if (connectivity == 1)	/* NONE */
			continue;
		if (devkind > 0x5)
			continue;

		dac = audiofs_path_from_pin(sc, cad, w->nid, path, &depth);
		if (dac == 0)
			continue;

		dac_idx = dac - codec->widget_start;
		if (dac_idx < 0 || dac_idx >= codec->widget_total)
			continue;

		audiofs_set_dac_format(sc, cad,
		    &codec->widgets[dac_idx]);
	}
}

/* ---------------------------------------------------------
 * Output stream descriptor and BDL setup.
 *
 * Reserves one output stream descriptor on the controller,
 * allocates a DMA-backed BDL (Buffer Descriptor List) and a
 * DMA-backed audio buffer (zeros for now - silence), and
 * configures the stream descriptor registers to point at
 * them. Format word and stream ID are recorded for the
 * stream-RUN commit (6d) to bind via SET_CONV_STREAM_CHAN.
 *
 * This commit does NOT:
 *   - Set the RUN bit. The stream stays stopped after this
 *     commit until commit 6d explicitly runs it.
 *   - Bind a DAC to the stream. SET_CONV_STREAM_CHAN is
 *     part of commit 6d.
 *   - Generate audible signal. The buffer holds zeros.
 *
 * Layout:
 *   - One stream descriptor (idx = 0 of the OSS bank).
 *   - One BDL with AUDIOFS_BDL_ENTRIES entries, each pointing
 *     at one AUDIOFS_BUF_FRAG_BYTES fragment of the audio
 *     buffer (HDA spec requires minimum 2 entries for ring
 *     behavior).
 *   - One audio buffer, AUDIOFS_BUF_BYTES bytes. Per ADR 0023
 *     experiment 1 the ring is currently 8 fragments of 4096
 *     bytes = 32768 bytes (~170 ms at 48 kHz/16-bit); each
 *     fragment covers 4096 bytes = 1024 frames = ~21 ms, and
 *     the fragment rate is unchanged at 46.875 Hz.
 *
 * Controller-relative stream descriptor offsets are
 * computed via the _HDAC_OSDxxx() macros in hdac_reg.h,
 * which encode the spec layout:
 *   SD offset = 0x80 + iss*0x20 + n*0x20
 *
 * Caller holds hw_lock.
 * --------------------------------------------------------- */

/*
 * Output DMA ring geometry. BDL_ENTRIES * BUF_FRAG_BYTES fragments
 * cycle as a hardware ring; the refill ithread (F.3.c) replaces the
 * just-consumed fragment behind the DAC's read position.
 *
 * Depth chosen per ADR 0023. The original bring-up geometry was 2
 * entries / 8 KB (~42 ms), which produced a boundary hum: on a ring
 * that shallow the refill ran right at the fragment the DAC was
 * crossing, and that per-fragment servicing perturbed the controller
 * read at the 46.875 Hz fragment rate. The corruption was below the
 * software path (the committed bytes were proven byte-exact) and was
 * audible only on tones not periodic in the 1024-frame fragment (440,
 * 660 hummed; 750, 468.75, 656.25 were clean). Deepening the ring
 * removed it. A depth sweep found 3 entries already clean, on the
 * idle bench and under CPU+bus load; 4 entries was chosen for a
 * two-fragment slack margin (one fragment of headroom over the
 * minimum) against load conditions the bench cannot reproduce, at a
 * ~21 ms latency cost over the minimum.
 *
 * The geometry is fragment-first: BUF_FRAG_BYTES is primary (4096
 * bytes = 1024 frames = ~21 ms at 48 kHz/16/stereo) and BUF_BYTES
 * derives as FRAG_BYTES * BDL_ENTRIES. The fragment rate (46.875 Hz)
 * is independent of ring depth. HDA requires a minimum of 2 entries.
 *
 *   2 entries =  8 KB = ~42 ms  (original; hums)
 *   3 entries = 12 KB = ~64 ms  (minimum clean depth)
 *   4 entries = 16 KB = ~85 ms  (chosen: clean + one-fragment margin)
 */
#define AUDIOFS_BDL_ENTRIES		4
#define AUDIOFS_BDL_BYTES		(AUDIOFS_BDL_ENTRIES * 16)
#define AUDIOFS_BUF_FRAG_BYTES		4096
#define AUDIOFS_BUF_BYTES		(AUDIOFS_BUF_FRAG_BYTES * AUDIOFS_BDL_ENTRIES)

#define AUDIOFS_OUTPUT_STREAM_IDX	0	/* OSS slot 0 */
#define AUDIOFS_OUTPUT_STREAM_ID	1	/* stream tag 1 (0=unused) */

/*
 * F.3.b user-ring sizing and source enum (ADR 0015).
 *
 * AUDIOFS_USER_RING_BYTES is the kernel-side ring that
 * write(2) fills and the ithread drains (was the kthread
 * under F.3.a/b). 32 KB at 48k/16/stereo is ~170 ms of
 * audio (4x the BDL buffer), chosen to be:
 *   - big enough that semasound's typical write granularity
 *     (a few ms) does not trigger back-pressure in steady
 *     state;
 *   - small enough that an overflowing write is observable
 *     as back-pressure rather than as a long stall;
 *   - a power of 2 so head/tail can use bitwise mask
 *     instead of modulo.
 */
#define AUDIOFS_USER_RING_BYTES		32768
#define AUDIOFS_USER_RING_MASK		(AUDIOFS_USER_RING_BYTES - 1)

#define AUDIOFS_SRC_SINE		0
#define AUDIOFS_SRC_USER		1


/*
 * Precomputed sine table for the audible test signal.
 *
 * At 48000 Hz sample rate with 64 samples per period, the
 * output frequency is exactly 750 Hz. The buffer is 2048
 * stereo frames, which is 32 complete periods, so the BDL
 * loop boundary is sample-aligned with the start of a
 * period and there is no discontinuity-click on wrap.
 *
 * Amplitude is 164 (~0.5% of int16 range, ~-40 dBFS),
 * deliberately quiet. The bench-verified F.3.a run on the
 * pgsd-bare-metal iMac at the prior amplitude of 16384
 * (-6 dBFS) through the CS4206 amp at gain=115 produced
 * unbearably loud output and could not be silenced through
 * normal channels (the operator had to pull power). This
 * amplitude is "quiet speech" level: clearly present and
 * verifiable on the bench, comfortable in a room. Operators
 * who need louder output for diagnostic reasons can raise
 * the codec amp gain via the existing path (commit 6).
 *
 * The table length being a power of two lets the lookup
 * use a bitwise mask instead of modulo, which is both
 * faster and clearer.
 */
#define AUDIOFS_SINE_TABLE_LEN		64
static const int16_t audiofs_sine_table[AUDIOFS_SINE_TABLE_LEN] = {
	     0,     16,     32,     48,     63,     77,     91,    104,
	   116,    127,    136,    145,    152,    157,    161,    163,
	   164,    163,    161,    157,    152,    145,    136,    127,
	   116,    104,     91,     77,     63,     48,     32,     16,
	     0,    -16,    -32,    -48,    -63,    -77,    -91,   -104,
	  -116,   -127,   -136,   -145,   -152,   -157,   -161,   -163,
	  -164,   -163,   -161,   -157,   -152,   -145,   -136,   -127,
	  -116,   -104,    -91,    -77,    -63,    -48,    -32,    -16,
};

/*
 * HDA BDL entry (HDA spec section 3.6.2): 16 bytes per
 * entry, packed.
 */
struct audiofs_bdle {
	uint64_t	addr;	/* physical buffer address */
	uint32_t	len;	/* length in bytes */
	uint32_t	ioc;	/* bit 0 = IOC, bits 31-1 reserved */
} __packed;

/*
 * Per the HDA spec, a stream descriptor's SDCTL low byte
 * SRST bit resets just that stream. We use it before
 * configuring registers, matching hdac.c's pattern.
 */
static void
audiofs_output_stream_reset(struct audiofs_softc *sc, int idx)
{
	uint32_t ctl;
	int count;
	bus_size_t ctl_off = _HDAC_OSDCTL(idx, sc->num_iss, sc->num_oss);

	ctl = AUDIOFS_READ_4(sc, ctl_off);
	/* Stop first if running. */
	ctl &= ~HDAC_SDCTL_RUN;
	AUDIOFS_WRITE_4(sc, ctl_off, ctl);

	/* Assert SRST. */
	ctl |= HDAC_SDCTL_SRST;
	AUDIOFS_WRITE_4(sc, ctl_off, ctl);

	count = 1000;
	do {
		ctl = AUDIOFS_READ_4(sc, ctl_off);
		if (ctl & HDAC_SDCTL_SRST)
			break;
		DELAY(10);
	} while (--count);
	if (!(ctl & HDAC_SDCTL_SRST))
		audiofs_log(sc, "stream_srst_set_failed", idx);

	/* Deassert SRST. */
	ctl &= ~HDAC_SDCTL_SRST;
	AUDIOFS_WRITE_4(sc, ctl_off, ctl);
	count = 1000;
	do {
		ctl = AUDIOFS_READ_4(sc, ctl_off);
		if (!(ctl & HDAC_SDCTL_SRST))
			break;
		DELAY(10);
	} while (--count);
	if (ctl & HDAC_SDCTL_SRST)
		audiofs_log(sc, "stream_srst_clear_failed", idx);
}

static int
audiofs_configure_output_stream(struct audiofs_softc *sc)
{
	struct audiofs_bdle *bdl;
	bus_size_t off_ctl, off_sts, off_cbl, off_lvi, off_fmt;
	bus_size_t off_bdpl, off_bdpu;
	uint32_t ctl;
	uint8_t cad;
	int found, i;
	int idx = AUDIOFS_OUTPUT_STREAM_IDX;

	if (sc->num_oss < 1) {
		device_printf(sc->dev,
		    "output stream setup: no output streams (OSS=%d)\n",
		    sc->num_oss);
		audiofs_log(sc, "stream_no_oss", sc->num_oss);
		return (ENXIO);
	}

	/*
	 * Select a DAC on a discovered output path. For the
	 * unattended attach-time test signal, we prefer outputs
	 * a developer is most likely to hear at their desk: the
	 * internal speaker first, then headphones, then analog
	 * line-out, then various digital outputs. The priorities
	 * below are tied to this commit's purpose (an audible
	 * self-test); real output policy with jack-presence
	 * detection is a later commit.
	 *
	 * Priority by pin_cfg device kind:
	 *   0x1 Speaker            -> 10 (highest)
	 *   0x2 HP_Out             ->  5
	 *   0x0 Line_Out           ->  3
	 *   0x5 Digital_Other_Out  ->  2
	 *   0x4 SPDIF_Out          ->  1
	 *   0x3 CD                 ->  0
	 *   others                 ->  skip
	 */
	{
		static const int8_t devkind_priority[6] = {
			3,	/* 0x0 Line_Out */
			10,	/* 0x1 Speaker */
			5,	/* 0x2 HP_Out */
			0,	/* 0x3 CD */
			1,	/* 0x4 SPDIF_Out */
			2,	/* 0x5 Digital_Other_Out */
		};
		int best_priority = -1;

		found = 0;
		for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
			struct audiofs_codec *codec = &sc->codecs[cad];
			if (!codec->populated)
				continue;
			for (i = 0; i < codec->widget_total; i++) {
				struct audiofs_widget *w = &codec->widgets[i];
				uint32_t devkind, connectivity;
				uint16_t path[AUDIOFS_PATH_MAX_DEPTH];
				int depth;
				uint16_t dac;
				int priority;

				if (!w->valid)
					continue;
				if (w->type !=
				    HDA_PARAM_AUDIO_WIDGET_CAP_TYPE_PIN_COMPLEX)
					continue;
				devkind =
				    HDA_CONFIG_DEFAULTCONF_DEVICE(w->pin_cfg);
				connectivity =
				    HDA_CONFIG_DEFAULTCONF_CONNECTIVITY(w->pin_cfg);
				if (connectivity == 1)	/* NONE */
					continue;
				if (devkind > 0x5)
					continue;
				dac = audiofs_path_from_pin(sc, cad, w->nid,
				    path, &depth);
				if (dac == 0)
					continue;

				priority = devkind_priority[devkind];
				if (priority > best_priority) {
					sc->output_dac_cad = cad;
					sc->output_dac_nid = dac;
					best_priority = priority;
					found = 1;
				}
			}
		}
	}
	if (!found) {
		device_printf(sc->dev,
		    "output stream setup: no usable DAC on any "
		    "discovered output path\n");
		audiofs_log(sc, "stream_no_dac", 0);
		return (ENXIO);
	}

	device_printf(sc->dev,
	    "output stream: selected idx=%d stream_id=%d "
	    "cad=%d dac_nid=%u\n",
	    idx, AUDIOFS_OUTPUT_STREAM_ID,
	    sc->output_dac_cad, sc->output_dac_nid);
	audiofs_log(sc, "stream_select",
	    ((uintmax_t)sc->output_dac_cad << 32) |
	    ((uintmax_t)sc->output_dac_nid << 16) |
	    AUDIOFS_OUTPUT_STREAM_ID);

	/*
	 * Allocate the BDL. HDA spec section 3.6.2 requires
	 * 128-byte alignment for the BDL itself. audiofs_dma_alloc
	 * uses HDA_DMA_ALIGNMENT (128) which satisfies this.
	 */
	if (audiofs_dma_alloc(sc, &sc->bdl_dma, AUDIOFS_BDL_BYTES) != 0) {
		device_printf(sc->dev,
		    "output stream: BDL DMA alloc failed\n");
		audiofs_log(sc, "stream_bdl_alloc_failed", 0);
		return (ENOMEM);
	}
	audiofs_log(sc, "stream_bdl_allocated", sc->bdl_dma.dma_paddr);

	/*
	 * Allocate the audio buffer. Same alignment is fine; the
	 * spec only requires that each BDL entry's address be
	 * 128-byte aligned, which we get for the buffer start;
	 * the second BDL entry points midway through, which is
	 * also 128-byte-aligned since AUDIOFS_BUF_FRAG_BYTES is
	 * 4096.
	 */
	if (audiofs_dma_alloc(sc, &sc->buf_dma, AUDIOFS_BUF_BYTES) != 0) {
		device_printf(sc->dev,
		    "output stream: audio buffer DMA alloc failed\n");
		audiofs_log(sc, "stream_buf_alloc_failed", 0);
		audiofs_dma_free(&sc->bdl_dma);
		return (ENOMEM);
	}
	audiofs_log(sc, "stream_buf_allocated", sc->buf_dma.dma_paddr);

	/*
	 * Fill the buffer with a 750 Hz sine wave for audible
	 * test signal. Calculation:
	 *   sample_rate / freq = 48000 / 750 = 64 frames/period
	 *   buffer_frames = AUDIOFS_BUF_BYTES / 4
	 *   the table length (AUDIOFS_SINE_TABLE_LEN) divides the
	 *   frame count evenly, so the buffer holds an integer
	 *   number of periods regardless of ring depth; the loop
	 *   boundary is sample-aligned with the start of a period
	 *   and there is no discontinuity-click when the BDL wraps.
	 *   Both stereo channels carry the same sine. (This built-in
	 *   tone is for attach-time bring-up only; ADR 0023 geometry
	 *   experiments drive the user-ring path via playtone.)
	 *
	 * The sine table values are precomputed for
	 * amplitude = 164 (~0.5% of int16 range, ~-40 dBFS,
	 * deliberately quiet; see audiofs_sine_table commentary
	 * for why this is not louder). Lookup index advances 1
	 * per stereo frame, modulo AUDIOFS_SINE_TABLE_LEN.
	 */
	{
		int16_t *samples = (int16_t *)sc->buf_dma.dma_vaddr;
		int total_frames = AUDIOFS_BUF_BYTES / 4;
		int f;
		for (f = 0; f < total_frames; f++) {
			int16_t v =
			    audiofs_sine_table[f & (AUDIOFS_SINE_TABLE_LEN - 1)];
			samples[2 * f]     = v;	/* left  */
			samples[2 * f + 1] = v;	/* right */
		}
	}
	bus_dmamap_sync(sc->buf_dma.dma_tag, sc->buf_dma.dma_map,
	    BUS_DMASYNC_PREWRITE);
	audiofs_log(sc, "stream_buf_filled_sine", AUDIOFS_SINE_TABLE_LEN);

	/*
	 * Populate the BDL. AUDIOFS_BDL_ENTRIES entries, each
	 * covering one AUDIOFS_BUF_FRAG_BYTES fragment. IOC=1 on
	 * every entry per ADR 0016 Decision 6: each fragment
	 * boundary raises a stream interrupt, so the F.3.c ithread
	 * runs ~every 21 ms (4096 bytes / 192000 bytes/sec at
	 * 48k/16/stereo) to refill the just-consumed fragment. The
	 * fragment rate is independent of ring depth; ADR 0023
	 * experiment 1 deepened the ring without changing it.
	 */
	bdl = (struct audiofs_bdle *)sc->bdl_dma.dma_vaddr;
	for (i = 0; i < AUDIOFS_BDL_ENTRIES; i++) {
		bdl[i].addr = htole64(
		    (uint64_t)sc->buf_dma.dma_paddr +
		    (uint64_t)i * AUDIOFS_BUF_FRAG_BYTES);
		bdl[i].len = htole32(AUDIOFS_BUF_FRAG_BYTES);
		bdl[i].ioc = htole32(1);
	}
	bus_dmamap_sync(sc->bdl_dma.dma_tag, sc->bdl_dma.dma_map,
	    BUS_DMASYNC_PREWRITE);
	audiofs_log(sc, "stream_bdl_written", AUDIOFS_BDL_ENTRIES);

	/* Resolve register offsets once. */
	off_ctl  = _HDAC_OSDCTL(idx, sc->num_iss, sc->num_oss);
	off_sts  = _HDAC_OSDSTS(idx, sc->num_iss, sc->num_oss);
	off_cbl  = _HDAC_OSDCBL(idx, sc->num_iss, sc->num_oss);
	off_lvi  = _HDAC_OSDLVI(idx, sc->num_iss, sc->num_oss);
	off_fmt  = _HDAC_OSDFMT(idx, sc->num_iss, sc->num_oss);
	off_bdpl = _HDAC_OSDBDPL(idx, sc->num_iss, sc->num_oss);
	off_bdpu = _HDAC_OSDBDPU(idx, sc->num_iss, sc->num_oss);

	/* Reset the stream descriptor. */
	audiofs_output_stream_reset(sc, idx);

	/* Clear any latched status bits (RWC on the spec). */
	AUDIOFS_WRITE_1(sc, off_sts,
	    HDAC_SDSTS_BCIS | HDAC_SDSTS_FIFOE | HDAC_SDSTS_DESE);

	/* Cyclic Buffer Length and Last Valid Index. */
	AUDIOFS_WRITE_4(sc, off_cbl, AUDIOFS_BUF_BYTES);
	AUDIOFS_WRITE_2(sc, off_lvi, AUDIOFS_BDL_ENTRIES - 1);

	/* Format word (F.3.e: the negotiated word; the DAC
	 * converter is set to the same word in stream_begin). */
	AUDIOFS_WRITE_2(sc, off_fmt, sc->output_stream_format_word);

	/* BDL physical base. */
	AUDIOFS_WRITE_4(sc, off_bdpl,
	    (uint32_t)(sc->bdl_dma.dma_paddr & 0xffffffffUL));
	AUDIOFS_WRITE_4(sc, off_bdpu,
	    (uint32_t)((uint64_t)sc->bdl_dma.dma_paddr >> 32));

	/*
	 * Write SDCTL2 (the high byte of the 24-bit control
	 * region, at bits 23-16 in a 32-bit access): clear it
	 * fully and set the stream tag in bits 7-4 (STRM field).
	 * SDSTS lives at bits 31-24 of the same 32-bit window;
	 * we preserve those bits (they are RWC and a stale read
	 * value is harmless). DIR and STRIPE stay zero; we are
	 * an output stream, no stripe.
	 *
	 * Observed quirk on Intel Sunrise Point: SDCTL2 bit 2
	 * (TP, Traffic Priority) reads back set even after we
	 * write zero to it. Per HDA spec section 3.3.21, TP
	 * only has effect when STRIPE > 0; we keep STRIPE = 0,
	 * so a stuck TP=1 is functionally benign. ATI Oland
	 * HDMI accepts the clear normally. Documented here so a
	 * future reader does not mistake the sticky bit for a
	 * driver bug.
	 */
	ctl = AUDIOFS_READ_4(sc, off_ctl);
	ctl &= ~HDAC_SDCTL_RUN;	/* not running yet */
	ctl &= ~(0xffU << 16);	/* clear SDCTL2 (bits 23-16) */
	ctl |= ((uint32_t)AUDIOFS_OUTPUT_STREAM_ID <<
	    (HDAC_SDCTL2_STRM_SHIFT + 16));	/* STRM in high byte */
	AUDIOFS_WRITE_4(sc, off_ctl, ctl);

	device_printf(sc->dev,
	    "output stream configured: idx=%d stream_id=%d "
	    "bdl_paddr=0x%jx buf_paddr=0x%jx cbl=%u lvi=%u fmt=0x%04x\n",
	    idx, AUDIOFS_OUTPUT_STREAM_ID,
	    (uintmax_t)sc->bdl_dma.dma_paddr,
	    (uintmax_t)sc->buf_dma.dma_paddr,
	    AUDIOFS_BUF_BYTES,
	    AUDIOFS_BDL_ENTRIES - 1,
	    sc->output_stream_format_word);

	/* Read back the key registers as proof of configuration. */
	audiofs_log(sc, "stream_cbl_readback",
	    AUDIOFS_READ_4(sc, off_cbl));
	audiofs_log(sc, "stream_lvi_readback",
	    AUDIOFS_READ_2(sc, off_lvi));
	audiofs_log(sc, "stream_fmt_readback",
	    AUDIOFS_READ_2(sc, off_fmt));
	audiofs_log(sc, "stream_ctl_readback",
	    AUDIOFS_READ_4(sc, off_ctl));

	sc->output_stream_configured = 1;
	sc->output_stream_idx = idx;
	sc->output_stream_id = AUDIOFS_OUTPUT_STREAM_ID;

	return (0);
}

/* ---------------------------------------------------------
 * F.3.a/c continuous streaming: refill loop + lifecycle
 *
 * Design:
 *   F.3.a lifecycle: audiofs/docs/adr/0014-f3a-continuous-streaming.md
 *   F.3.c interrupt path: audiofs/docs/adr/0016-f3c-interrupt-driven-position.md
 *
 * audiofs_stream_begin / audiofs_stream_end are the in-kernel
 * callable lifecycle entry points. F.3.b wraps them in the
 * cdev API. F.3.c replaced the kthread-based refill with an
 * interrupt-driven model; the signatures of stream_begin/_end
 * did not change.
 *
 * The refill loop now runs as an ithread: BDL entries carry
 * IOC=1, the HDA controller raises a stream interrupt on each
 * fragment boundary, the filter handler acknowledges in
 * interrupt context, and the ithread refills the just-
 * completed fragment. Lock ordering (innermost-last):
 *   audiofs_state_sx (sleepable)
 *   -> output_stream_user_ring_mtx (MTX_DEF)
 *   -> hw_lock (MTX_DEF)
 *   -> intr_lock (MTX_SPIN, innermost)
 * The ithread takes hw_lock briefly for LPIB reads and
 * intr_lock briefly for the active/last_sdsts snapshot;
 * stream_begin/_end take audiofs_state_sx around F.2 event
 * emission (events_publish requires it).
 * --------------------------------------------------------- */

/*
 * F.3.c interrupt handlers (ADR 0016). Replaces the F.3.a
 * polling kthread. The filter runs in interrupt context
 * (MTX_SPIN intr_lock only); the ithread runs in a kernel
 * thread (MTX_DEF hw_lock + user_ring_mtx as before).
 */
static int audiofs_intr_filter(void *arg);
static void audiofs_intr_thread(void *arg);
static void audiofs_xrun_task(void *arg, int pending);

/*
 * Refill one BDL fragment with the next sine periods. With the
 * 32-period-per-buffer layout from audiofs_configure_output_stream,
 * each 4 KB fragment contains exactly 16 periods at 750 Hz; the
 * waveform is phase-continuous across fragment boundaries because
 * the period (64 frames) divides the fragment cleanly (1024 frames
 * = 16 periods). Refilling with the same samples preserves phase
 * continuity.
 *
 * Caller need not hold any lock; the BDL buffer is the kthread's
 * exclusive write target while a stream is running.
 */
static void
audiofs_refill_sine_fragment(struct audiofs_softc *sc, int fragment_idx)
{
	int16_t *samples;
	int frame_base;
	int f;

	if (fragment_idx < 0 || fragment_idx >= AUDIOFS_BDL_ENTRIES)
		return;

	samples = (int16_t *)sc->buf_dma.dma_vaddr;
	/* AUDIOFS_BUF_FRAG_BYTES = 4096, /4 = 1024 frames per fragment. */
	frame_base = fragment_idx * (AUDIOFS_BUF_FRAG_BYTES / 4);

	for (f = 0; f < AUDIOFS_BUF_FRAG_BYTES / 4; f++) {
		int idx = (frame_base + f) & (AUDIOFS_SINE_TABLE_LEN - 1);
		int16_t v = audiofs_sine_table[idx];
		samples[2 * (frame_base + f)]     = v;	/* left  */
		samples[2 * (frame_base + f) + 1] = v;	/* right */
	}

	/*
	 * Sync only the refilled range. The buf_dma map covers the
	 * whole buffer; bus_dmamap_sync syncs the entire mapping
	 * on amd64 (per-range sync is not portable), but the cost
	 * is small (8 KB) and predictable.
	 */
	bus_dmamap_sync(sc->buf_dma.dma_tag, sc->buf_dma.dma_map,
	    BUS_DMASYNC_PREWRITE);
}

/*
 * F.3.b: Refill one BDL fragment from the user ring. Drains
 * up to AUDIOFS_BUF_FRAG_BYTES from the ring (whatever is
 * available, less if the ring has less). Zero-fills the
 * remainder of the fragment if the ring runs short. Counts
 * an underflow event for any zero-fill. Wakes a blocked
 * writer if one is waiting on user_ring_mtx.
 *
 * Caller must NOT hold user_ring_mtx; this function takes it
 * briefly to advance the tail cursor and check for shortfall.
 * The bus_dmamap_sync runs without locks.
 */
static void
audiofs_refill_user_fragment(struct audiofs_softc *sc, int fragment_idx)
{
	uint8_t *dst;
	size_t available, copy_bytes, ring_idx;
	int shortfall;

	if (fragment_idx < 0 || fragment_idx >= AUDIOFS_BDL_ENTRIES)
		return;

	dst = (uint8_t *)sc->buf_dma.dma_vaddr +
	    fragment_idx * AUDIOFS_BUF_FRAG_BYTES;

	mtx_lock(&sc->output_stream_user_ring_mtx);
	available = sc->output_stream_user_ring_head -
	    sc->output_stream_user_ring_tail;
	if (available > AUDIOFS_BUF_FRAG_BYTES)
		copy_bytes = AUDIOFS_BUF_FRAG_BYTES;
	else
		copy_bytes = available;

	/*
	 * Copy from the ring into the BDL fragment. The ring is
	 * size AUDIOFS_USER_RING_BYTES (power of two). Tail
	 * advances in the ring is `(tail & MASK)` bytes; we may
	 * need two memcpy spans if the contiguous run crosses the
	 * ring end.
	 */
	if (copy_bytes > 0) {
		ring_idx = sc->output_stream_user_ring_tail &
		    AUDIOFS_USER_RING_MASK;
		if (ring_idx + copy_bytes <= AUDIOFS_USER_RING_BYTES) {
			memcpy(dst, sc->output_stream_user_ring + ring_idx,
			    copy_bytes);
		} else {
			size_t first = AUDIOFS_USER_RING_BYTES - ring_idx;
			memcpy(dst,
			    sc->output_stream_user_ring + ring_idx, first);
			memcpy(dst + first,
			    sc->output_stream_user_ring,
			    copy_bytes - first);
		}
		sc->output_stream_user_ring_tail += copy_bytes;
	}

	shortfall = (copy_bytes < AUDIOFS_BUF_FRAG_BYTES);
	mtx_unlock(&sc->output_stream_user_ring_mtx);

	/* Wake any writer blocked on a full ring. */
	wakeup(&sc->output_stream_user_ring_mtx);

	if (shortfall) {
		uint32_t gap_frames;

		memset(dst + copy_bytes, 0,
		    AUDIOFS_BUF_FRAG_BYTES - copy_bytes);
		sc->output_stream_underflow_count++;

		/*
		 * F.3.d (ADR 0017 amended 2026-05-30): user-ring
		 * shortfall is the underrun the consumer experiences
		 * on this stack. audiofs zero-padded the missing
		 * bytes; report the exact gap to the F.2 events ring
		 * via taskqueue_fast deferral.
		 *
		 * gap_frames is sample-accurate here (unlike the
		 * hardware FIFOE branch's one-fragment estimate)
		 * because we know exactly how many bytes we
		 * zero-padded: AUDIOFS_BUF_FRAG_BYTES - copy_bytes,
		 * divided by 4 (stereo 16-bit frame size).
		 *
		 * Coalescing: if multiple BCIS cycles produce
		 * back-to-back shortfalls (sustained stall), the
		 * taskqueue's internal pending-bit coalesces
		 * repeated enqueues for free.
		 */
		gap_frames = (uint32_t)(AUDIOFS_BUF_FRAG_BYTES -
		    copy_bytes) / 4;

		mtx_lock_spin(&sc->intr_lock);
		if (sc->output_stream_pending_xrun_frames == 0) {
			/* First shortfall in this coalesced window. */
			sc->output_stream_xrun_gap_pos =
			    sc->output_stream_frames_played;
		}
		sc->output_stream_pending_xrun_frames += gap_frames;
		sc->output_stream_xrun_coalesced_count++;
		mtx_unlock_spin(&sc->intr_lock);

		taskqueue_enqueue(taskqueue_fast,
		    &sc->output_stream_xrun_task);
	}

	bus_dmamap_sync(sc->buf_dma.dma_tag, sc->buf_dma.dma_map,
	    BUS_DMASYNC_PREWRITE);
}

/*
 * Dispatch refill based on the current source. The source
 * field is read under user_ring_mtx to interlock with the
 * cdev open/close path that swaps source atomically.
 */
static void
audiofs_refill_fragment(struct audiofs_softc *sc, int fragment_idx)
{
	int source;

	mtx_lock(&sc->output_stream_user_ring_mtx);
	source = sc->output_stream_source;
	mtx_unlock(&sc->output_stream_user_ring_mtx);

	if (source == AUDIOFS_SRC_USER)
		audiofs_refill_user_fragment(sc, fragment_idx);
	else
		audiofs_refill_sine_fragment(sc, fragment_idx);
}

/*
 * F.3.c filter handler (ADR 0016 Decision 2). Runs in
 * interrupt context, holds intr_lock (MTX_SPIN). Does the
 * minimum required to acknowledge the interrupt: reads
 * INTSTS, identifies our stream's bit, reads SDnSTS, ORs
 * into output_stream_last_sdsts, writes the bits back to
 * SDnSTS to clear (RWC semantics per HDA spec section
 * 3.3.36). Returns FILTER_SCHEDULE_THREAD if our bit was
 * set, FILTER_STRAY otherwise.
 *
 * Maximum work: 3 register I/Os (INTSTS read, SDnSTS read,
 * SDnSTS write). No memory operations beyond the softc
 * field OR. The OR (not overwrite) preserves bits from
 * multiple interrupts that fire before the ithread runs.
 *
 * intr_lock is innermost: never held outside this filter
 * or brief ithread accesses. Never taken while any other
 * audiofs lock is held.
 */
static int
audiofs_intr_filter(void *arg)
{
	struct audiofs_softc *sc = arg;
	bus_size_t off_sts;
	uint32_t intsts;
	uint32_t sis_mask;
	uint8_t sdsts;
	int idx;

	idx = sc->output_stream_idx;
	off_sts = _HDAC_OSDSTS(idx, sc->num_iss, sc->num_oss);
	/*
	 * INTSTS SIS bits are in the GLOBAL stream-descriptor
	 * enumeration; output stream idx N maps to bit
	 * (num_iss + N). See ADR 0016 (HDA 1.0a section
	 * 3.3.15). The F.3.c bench bug (2026-05-31) used
	 * (1 << idx) here without the offset.
	 */
	sis_mask = 1U << (sc->num_iss + idx);

	mtx_lock_spin(&sc->intr_lock);

	intsts = AUDIOFS_READ_4(sc, HDAC_INTSTS);
	if ((intsts & sis_mask) == 0) {
		mtx_unlock_spin(&sc->intr_lock);
		return (FILTER_STRAY);
	}

	/*
	 * Read and clear our stream's SDnSTS. The bits we care
	 * about are BCIS (buffer completion), FIFOE (FIFO error
	 * = underflow), and DESE (descriptor error). RWC: write
	 * 1 back to clear each set bit.
	 */
	sdsts = AUDIOFS_READ_1(sc, off_sts);
	AUDIOFS_WRITE_1(sc, off_sts,
	    sdsts & (HDAC_SDSTS_BCIS | HDAC_SDSTS_FIFOE |
	    HDAC_SDSTS_DESE));

	sc->output_stream_last_sdsts |=
	    sdsts & (HDAC_SDSTS_BCIS | HDAC_SDSTS_FIFOE |
	    HDAC_SDSTS_DESE);

	mtx_unlock_spin(&sc->intr_lock);
	return (FILTER_SCHEDULE_THREAD);
}

/*
 * F.3.c ithread handler (ADR 0016 Decision 3). Runs in a
 * kernel thread context. Can take MTX_DEF locks.
 *
 * Lock order (ADR 0016 Decision 7):
 *   audiofs_state_sx (not taken here; events_publish does)
 *   -> output_stream_user_ring_mtx
 *   -> hw_lock
 *   -> intr_lock (innermost)
 *
 * The intr_lock guards output_stream_active and
 * output_stream_last_sdsts. We snapshot last_sdsts under
 * the spin lock, then release before doing the refill work
 * that needs hw_lock and user_ring_mtx.
 *
 * Entry-time output_stream_active check: stream_end clears
 * this flag under intr_lock BEFORE clearing the SIE bit in
 * INTCTL, so any ithread invocation arriving after
 * stream_end sees active=0 and returns early without
 * touching being-torn-down state. This closes the
 * "SIE-cleared-but-ithread-already-scheduled" race.
 */
static void
audiofs_intr_thread(void *arg)
{
	struct audiofs_softc *sc = arg;
	bus_size_t off_lpib;
	uint32_t curr_lpib, prev_lpib;
	uint64_t delta;
	uint8_t sdsts;
	int idx, curr_fragment;

	/*
	 * Entry guard. If stream_end has run (active=0), the
	 * stream's hardware state is being torn down; we must
	 * not touch LPIB or refill. Returning here is safe even
	 * if there are unread SDnSTS bits because the filter has
	 * already cleared them at the hardware level; the
	 * snapshot in last_sdsts will be reset when active is
	 * next set.
	 */
	mtx_lock_spin(&sc->intr_lock);
	if (!sc->output_stream_active) {
		mtx_unlock_spin(&sc->intr_lock);
		return;
	}
	sdsts = sc->output_stream_last_sdsts;
	sc->output_stream_last_sdsts = 0;
	mtx_unlock_spin(&sc->intr_lock);

	idx = sc->output_stream_idx;
	off_lpib = _HDAC_OSDPICB(idx, sc->num_iss, sc->num_oss);

	/* Snap LPIB under hw_lock. */
	mtx_lock(&sc->hw_lock);
	curr_lpib = AUDIOFS_READ_4(sc, off_lpib);
	mtx_unlock(&sc->hw_lock);

	/*
	 * Accumulate frames played. LPIB is in bytes within
	 * the buffer (0..AUDIOFS_BUF_BYTES-1, wrapping). The
	 * delta from prev_lpib to curr_lpib is the byte
	 * advance since the last interrupt. At 48 kHz / 16 /
	 * stereo with ~21 ms per fragment, each interrupt's
	 * delta is one fragment (4096 bytes); a wrap occurs
	 * exactly once per buffer (~42 ms).
	 */
	prev_lpib = sc->output_stream_prev_lpib;
	if (curr_lpib >= prev_lpib)
		delta = (uint64_t)(curr_lpib - prev_lpib);
	else
		delta = (uint64_t)(AUDIOFS_BUF_BYTES - prev_lpib) +
		    (uint64_t)curr_lpib;
	/* 4 bytes per stereo 16-bit frame. */
	sc->output_stream_frames_played += delta / 4;
	/*
	 * F.4 (ADR 0018): advance the monotonic clock accumulator by the
	 * same delta and publish it. Unlike output_stream_frames_played,
	 * clock_samples_total is never reset at stream_begin, so the
	 * published clock does not regress across stop/start. The store is
	 * into the wired mapping; safe under the ithread's locks (no sleep,
	 * no fault).
	 */
	sc->clock_samples_total += delta / 4;
	audiofs_clock_update(sc);
	sc->output_stream_prev_lpib = curr_lpib;

	/*
	 * BCIS: refill the fragment(s) the hardware has just
	 * completed. The cursor next_refill_fragment names the
	 * fragment awaiting refill. Advance while it differs
	 * from the fragment LPIB is currently in. Normally only
	 * one fragment per BCIS, but the loop handles ithread
	 * latency that might let the hardware complete a second
	 * fragment before we run.
	 */
	if (sdsts & HDAC_SDSTS_BCIS) {
		int n_refilled = 0;	/* ADR 0022 instrumentation */

		curr_fragment = (int)(curr_lpib / AUDIOFS_BUF_FRAG_BYTES);
		while (sc->output_stream_next_refill_fragment != curr_fragment) {
			audiofs_refill_fragment(sc,
			    sc->output_stream_next_refill_fragment);
			sc->output_stream_next_refill_fragment =
			    (sc->output_stream_next_refill_fragment + 1) %
			    AUDIOFS_BDL_ENTRIES;
			n_refilled++;
		}
		if (n_refilled == 0)
			sc->output_stream_refill_miss_count++;
		else if (n_refilled >= 2)
			sc->output_stream_refill_multi_count++;
	}

	/*
	 * FIFOE: FIFO underrun. The controller wanted samples
	 * and the FIFO was empty.
	 *
	 * F.3.d (ADR 0017): defer publish to taskqueue_fast so
	 * we can call audiofs_events_publish from sleepable
	 * context. The pending fields under intr_lock are
	 * drained by audiofs_xrun_task. The underflow_count
	 * stays as a saturation counter for the
	 * dev.audiofs.<N>.underflow_count sysctl, independent
	 * of published events.
	 *
	 * gap_frames estimate: one fragment per FIFOE. The HDA
	 * spec does not expose a "FIFO has been empty for N
	 * samples" counter, so we report an upper bound per
	 * ADR 0007's physics-only constraint. Each FIFOE
	 * implies the FIFO ran empty sometime in the last
	 * interrupt interval (~21 ms at 48k stereo 16-bit), or
	 * at most one fragment's worth of frames.
	 */
	if (sdsts & HDAC_SDSTS_FIFOE) {
		sc->output_stream_underflow_count++;

		mtx_lock_spin(&sc->intr_lock);
		if (sc->output_stream_pending_xrun_frames == 0) {
			/* First FIFOE in this coalesced window. */
			sc->output_stream_xrun_gap_pos =
			    sc->output_stream_frames_played;
		}
		sc->output_stream_pending_xrun_frames +=
		    AUDIOFS_BUF_FRAG_BYTES / 4;
		sc->output_stream_xrun_coalesced_count++;
		mtx_unlock_spin(&sc->intr_lock);

		taskqueue_enqueue(taskqueue_fast,
		    &sc->output_stream_xrun_task);
	}

	/*
	 * DESE: descriptor error. The controller could not fetch
	 * a BDL entry. This is exceptional (suggests a serious
	 * DMA fault); log it but do not stop the stream.
	 */
	if (sdsts & HDAC_SDSTS_DESE) {
		device_printf(sc->dev,
		    "F.3.c: descriptor error (DESE) on stream %d\n",
		    sc->output_stream_id);
	}
}

/*
 * F.3.d xrun publish task (ADR 0017).
 *
 * Runs in taskqueue_fast's kernel thread context. Sleepable;
 * can acquire audiofs_state_sx via audiofs_events_publish.
 *
 * Drains the pending xrun fields under intr_lock. If the
 * cleared frames count is non-zero, builds the payload per
 * shared/AUDIO_EVENTS.md's schema and publishes one xrun
 * event. AUDIOFS_EVFLAG_COALESCED is set when more than one
 * FIFOE folded into this drain.
 *
 * If the stream is no longer active (stream_end has run),
 * returns without publishing. stream_end itself does the
 * inline drain-and-publish for any final pending xrun
 * before clearing active, and then taskqueue_drains us as a
 * safety net.
 *
 * The taskqueue's internal pending-bit guarantees this
 * function does not race against itself: multiple
 * taskqueue_enqueue calls while the task is pending
 * coalesce into one invocation.
 */
static void
audiofs_xrun_task(void *arg, int pending __unused)
{
	struct audiofs_softc *sc = arg;
	uint32_t frames, coalesced;
	uint64_t gap_pos;
	uint32_t flags;
	struct {
		uint32_t stream_id;
		uint8_t  xrun_kind;
		uint8_t  _pad[3];
		uint64_t gap_sample_pos;
		uint32_t gap_frames;
	} __packed payload;

	mtx_lock_spin(&sc->intr_lock);
	if (!sc->output_stream_active) {
		mtx_unlock_spin(&sc->intr_lock);
		return;
	}
	frames = sc->output_stream_pending_xrun_frames;
	coalesced = sc->output_stream_xrun_coalesced_count;
	gap_pos = sc->output_stream_xrun_gap_pos;
	sc->output_stream_pending_xrun_frames = 0;
	sc->output_stream_xrun_coalesced_count = 0;
	sc->output_stream_xrun_gap_pos = 0;
	mtx_unlock_spin(&sc->intr_lock);

	if (frames == 0)
		return;

	memset(&payload, 0, sizeof(payload));
	payload.stream_id = (uint32_t)sc->output_stream_id;
	payload.xrun_kind = AUDIOFS_XRUN_UNDERRUN;
	payload.gap_sample_pos = gap_pos;
	payload.gap_frames = frames;

	flags = (coalesced > 1) ? AUDIOFS_EVFLAG_COALESCED : 0;

	audiofs_events_publish(AUDIOFS_EVROLE_STREAM,
	    AUDIOFS_EVSTREAM_XRUN,
	    sc->output_stream_endpoint_slot, flags,
	    &payload, sizeof(payload));
}

/*
 * Begin a continuous output stream on the controller's reserved
 * stream descriptor. Allocates DMA, fills the buffer, binds the
 * DAC, emits the F.2 stream_begin event, starts the refill
 * kthread, sets RUN.
 *
 * v1 caveats (per ADR 0014):
 *   - One stream per controller.
 *   - format / channels / rate_hz arguments must be
 *     0x0011 / 2 / 48000; other values return EINVAL.
 *   - endpoint_id is informational, used to set
 *     output_stream_endpoint_slot for the F.2 events.
 *
 * Returns 0 on success with *out_stream_id set; an errno on
 * failure with no side effects (any partial setup is undone).
 *
 * Caller must NOT hold hw_lock (DMA alloc may sleep). Caller
 * must NOT hold audiofs_state_sx (taken internally).
 */
static int
audiofs_stream_begin(struct audiofs_softc *sc, uint32_t endpoint_id,
    uint16_t format, uint8_t channels, uint32_t rate_hz,
    uint32_t *out_stream_id)
{
	struct audiofs_evp_stream_begin pl;
	bus_size_t off_ctl;
	uint16_t payload;
	uint32_t ctl;
	int idx, error;

	/*
	 * F.3.e (ADR 0019): rate negotiation. v1 is 16-bit
	 * stereo, so the format word is a function of the rate.
	 * Validate channels, that the caller's word matches the
	 * rate, and that the bound DAC advertises the rate.
	 * Native-only (ADR 0007): an unadvertised rate is
	 * rejected here, not converted.
	 */
	{
		uint16_t expect_word;

		if (channels != 2 ||
		    audiofs_rate_to_format_word(rate_hz, &expect_word) != 0 ||
		    format != expect_word ||
		    !audiofs_psr_has_rate(audiofs_output_dac_psr(sc), rate_hz))
			return (EINVAL);
	}

	if (sc->output_stream_active)
		return (EBUSY);

	/* Record the negotiated format; configure + DAC program read it. */
	sc->output_stream_format_word = format;
	sc->output_stream_rate_hz = rate_hz;

	/*
	 * Configure descriptor + DMA + initial sine fill. This
	 * uses audiofs_dma_alloc (BUS_DMA_NOWAIT internally) and
	 * audiofs_send_command (CORB writes); both expect hw_lock.
	 */
	mtx_lock(&sc->hw_lock);
	error = audiofs_configure_output_stream(sc);
	if (error != 0) {
		mtx_unlock(&sc->hw_lock);
		audiofs_log(sc, "stream_begin_configure_failed",
		    (uintmax_t)error);
		return (error);
	}

	idx = sc->output_stream_idx;
	off_ctl = _HDAC_OSDCTL(idx, sc->num_iss, sc->num_oss);

	/*
	 * F.3.e (ADR 0019): program the DAC converter to the
	 * negotiated format so the converter and the stream
	 * descriptor agree on every begin, including a
	 * SET_FORMAT reconfigure. Attach set the converter to
	 * the 48 kHz default; this keeps it in sync per stream.
	 */
	(void)audiofs_send_command(sc, sc->output_dac_cad,
	    HDA_CMD_SET_CONV_FMT(0, sc->output_dac_nid,
	    sc->output_stream_format_word));

	/*
	 * Bind DAC to stream tag (HDA spec section 7.3.3.11).
	 * stream_id in bits 7-4, channel 0 in bits 3-0.
	 */
	payload =
	    HDA_CMD_SET_CONV_STREAM_CHAN_STREAM(sc->output_stream_id) |
	    HDA_CMD_SET_CONV_STREAM_CHAN_CHAN(0);
	(void)audiofs_send_command(sc, sc->output_dac_cad,
	    HDA_CMD_SET_CONV_STREAM_CHAN(0, sc->output_dac_nid, payload));
	mtx_unlock(&sc->hw_lock);
	audiofs_log(sc, "stream_begin_dac_bound",
	    ((uintmax_t)sc->output_dac_cad << 32) |
	    ((uintmax_t)sc->output_dac_nid << 16) | payload);

	/* Init refill bookkeeping (no locks needed; ithread not
	 * yet enabled for this stream). */
	sc->output_stream_prev_lpib = 0;
	sc->output_stream_next_refill_fragment = 0;
	sc->output_stream_frames_played = 0;
	sc->output_stream_last_sdsts = 0;
	sc->output_stream_endpoint_slot = AUDIOFS_EVENTS_NO_ENDPOINT;
	(void)endpoint_id;	/* v1: endpoint_id reserved for F.3.b */

	/*
	 * Emit F.2 stream_begin event. Requires state_sx (sx is
	 * sleepable, so this must run with no spin mtx held).
	 */
	memset(&pl, 0, sizeof(pl));
	pl.stream_id = (uint32_t)sc->output_stream_id;
	pl.format = format;
	pl.channels = channels;
	pl.rate_hz = rate_hz;
	sx_xlock(&audiofs_state_sx);
	audiofs_events_publish(AUDIOFS_EVROLE_STREAM,
	    AUDIOFS_EVSTREAM_BEGIN, sc->output_stream_endpoint_slot,
	    0, &pl, sizeof(pl));
	sx_xunlock(&audiofs_state_sx);

	/*
	 * F.4 (ADR 0018): publish sample_rate and mark the clock valid
	 * before the stream's RUN bit is set, so a reader sees valid=1 as
	 * frames begin to flow. Memory stores into the wired mapping only;
	 * no lock required. Does not reset the monotonic accumulator.
	 */
	audiofs_clock_stream_begin(sc, rate_hz);

	/*
	 * F.3.c (ADR 0016 Decision 5): set output_stream_active
	 * = 1, then enable our stream's interrupt source in
	 * INTCTL, then set RUN. The order matters:
	 *   - active must be set before SIE so the first
	 *     interrupt the controller raises does not arrive
	 *     at an ithread whose entry guard rejects it.
	 *   - SIE must be enabled before RUN so the first BCIS
	 *     interrupt the controller raises is delivered (not
	 *     dropped because SIE was 0 when the interrupt fired).
	 *   - RUN starts DMA; the controller will reach a BDL
	 *     entry boundary (IOC=1) within ~21 ms and raise the
	 *     first interrupt.
	 *
	 * GIE and CIE are set unconditionally (they may already
	 * be set from a prior stream or attach; idempotent).
	 */
	mtx_lock_spin(&sc->intr_lock);
	sc->output_stream_active = 1;
	mtx_unlock_spin(&sc->intr_lock);

	/*
	 * INTCTL SIE / INTSTS SIS bit positions are in the
	 * GLOBAL stream-descriptor enumeration: bits 0 to
	 * (num_iss-1) for input streams, bits num_iss to
	 * (num_iss + num_oss - 1) for output streams. So the
	 * SIE bit for output stream idx N is bit (num_iss + N),
	 * NOT bit N. The F.3.c bench bug (2026-05-31) was that
	 * the filter handler and these INTCTL updates used
	 * (1 << idx) directly, missing the num_iss offset; on
	 * the iMac's Intel HDA (num_iss=4) this meant we
	 * enabled the wrong SIE bit and the filter checked the
	 * wrong INTSTS bit, so interrupts fired in hardware but
	 * the filter returned FILTER_STRAY and the ithread
	 * never ran.
	 */
	mtx_lock(&sc->hw_lock);
	ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
	ctl |= HDAC_INTCTL_GIE | HDAC_INTCTL_CIE |
	    (1U << (sc->num_iss + sc->output_stream_idx));
	AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
	mtx_unlock(&sc->hw_lock);

	/*
	 * Buffer DMA sync (no locks needed) then set RUN under
	 * hw_lock. Per HDA spec section 3.3.35, the per-stream
	 * IOCE / FEIE / DEIE interrupt-enable bits in SDnCTL
	 * gate the stream-level interrupt sources. The BDL
	 * entries' IOC bits (set in configure_output_stream)
	 * are only honored when IOCE=1 in SDnCTL. The F.3.c
	 * BENCH BUG (2026-05-30) was that we set the BDL IOC
	 * bits and the INTCTL SIE bit but forgot SDnCTL IOCE;
	 * the controller therefore did not raise BCIS even
	 * though the BDL entries asked it to.
	 *
	 *   IOCE: enable BCIS interrupt on BDL IOC completion.
	 *   FEIE: enable FIFOE (underflow) reporting in SDnSTS.
	 *   DEIE: enable DESE (descriptor error) reporting.
	 *
	 * We OR these with RUN in one write so the stream goes
	 * from configured-and-quiet to running-with-interrupts
	 * atomically.
	 */
	bus_dmamap_sync(sc->buf_dma.dma_tag, sc->buf_dma.dma_map,
	    BUS_DMASYNC_PREREAD);
	mtx_lock(&sc->hw_lock);
	ctl = AUDIOFS_READ_4(sc, off_ctl);
	ctl |= HDAC_SDCTL_RUN | HDAC_SDCTL_IOCE |
	    HDAC_SDCTL_FEIE | HDAC_SDCTL_DEIE;
	AUDIOFS_WRITE_4(sc, off_ctl, ctl);
	mtx_unlock(&sc->hw_lock);
	audiofs_log(sc, "stream_begin_run_set", (uintmax_t)sc->output_stream_id);

	if (out_stream_id != NULL)
		*out_stream_id = (uint32_t)sc->output_stream_id;

	device_printf(sc->dev,
	    "stream_begin: stream_id=%d format=0x%04x ch=%u rate=%u Hz, "
	    "interrupts enabled, RUN set\n",
	    sc->output_stream_id, format, channels, rate_hz);
	return (0);
}

/*
 * End an active output stream (F.3.c, ADR 0016).
 *
 * Teardown sequence:
 *   1. Clear output_stream_active under intr_lock. Any
 *      ithread invocation already pending or in-flight
 *      hits the entry guard and returns without touching
 *      state.
 *   2. Disable our stream's SIE bit in INTCTL. No further
 *      interrupts will fire for this stream.
 *   3. Clear RUN in SDnCTL. DMA stops.
 *   4. Read final LPIB and add the delta to frames_played
 *      to capture samples consumed between the last
 *      interrupt and RUN clear.
 *   5. Unbind DAC, emit F.2 stream_end event.
 *
 * No msleep wait. The F.3.a polling-kthread acknowledgment
 * dance is retired (ADR 0016 Decision 4); the interrupt
 * path's teardown is synchronous because the active flag
 * gates ithread entry and bus_teardown_intr (in detach)
 * blocks until any in-flight ithread completes.
 *
 * Caller must NOT hold hw_lock (taken internally). Caller
 * must NOT hold audiofs_state_sx (taken internally).
 */
static int
audiofs_stream_end(struct audiofs_softc *sc, uint32_t stream_id)
{
	struct audiofs_evp_stream_end pl;
	bus_size_t off_ctl, off_lpib;
	uint32_t final_lpib, ctl;
	uint64_t frames_total;
	int idx;

	if (!sc->output_stream_active)
		return (ENXIO);
	if (stream_id != (uint32_t)sc->output_stream_id)
		return (EINVAL);

	idx = sc->output_stream_idx;
	off_ctl = _HDAC_OSDCTL(idx, sc->num_iss, sc->num_oss);
	off_lpib = _HDAC_OSDPICB(idx, sc->num_iss, sc->num_oss);

	/*
	 * Step 1: gate the ithread, and atomically drain any
	 * pending F.3.d xrun (ADR 0017) under the same lock
	 * acquire. Order is load-bearing: by clearing the
	 * pending fields and setting active=0 in one lock
	 * region, we guarantee no ithread can observe
	 * active=1 with stale pending state, and no task can
	 * observe active=1 after this point.
	 *
	 * If a snapshot of pending xrun frames is non-zero,
	 * publish it inline (we're in sleepable context) so
	 * the final underrun reaches the events ring BEFORE
	 * the stream_end event below. Then taskqueue_drain
	 * catches any task that was already enqueued and is
	 * still in-flight; that task will see active=0 and
	 * return harmlessly.
	 */
	{
		uint32_t pend_frames = 0, pend_coalesced = 0;
		uint64_t pend_gap_pos = 0;

		mtx_lock_spin(&sc->intr_lock);
		pend_frames = sc->output_stream_pending_xrun_frames;
		pend_coalesced = sc->output_stream_xrun_coalesced_count;
		pend_gap_pos = sc->output_stream_xrun_gap_pos;
		sc->output_stream_pending_xrun_frames = 0;
		sc->output_stream_xrun_coalesced_count = 0;
		sc->output_stream_xrun_gap_pos = 0;
		sc->output_stream_active = 0;
		mtx_unlock_spin(&sc->intr_lock);

		if (pend_frames > 0) {
			struct {
				uint32_t stream_id;
				uint8_t  xrun_kind;
				uint8_t  _pad[3];
				uint64_t gap_sample_pos;
				uint32_t gap_frames;
			} __packed payload;
			uint32_t flags;

			memset(&payload, 0, sizeof(payload));
			payload.stream_id = (uint32_t)sc->output_stream_id;
			payload.xrun_kind = AUDIOFS_XRUN_UNDERRUN;
			payload.gap_sample_pos = pend_gap_pos;
			payload.gap_frames = pend_frames;
			flags = (pend_coalesced > 1) ?
			    AUDIOFS_EVFLAG_COALESCED : 0;
			audiofs_events_publish(AUDIOFS_EVROLE_STREAM,
			    AUDIOFS_EVSTREAM_XRUN,
			    sc->output_stream_endpoint_slot, flags,
			    &payload, sizeof(payload));
		}
	}
	taskqueue_drain(taskqueue_fast,
	    &sc->output_stream_xrun_task);

	/*
	 * Step 2: disable our stream's interrupt source. We
	 * leave GIE and CIE alone (other streams may use them;
	 * detach clears them).
	 */
	mtx_lock(&sc->hw_lock);
	ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
	ctl &= ~(1U << (sc->num_iss + sc->output_stream_idx));
	AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
	mtx_unlock(&sc->hw_lock);

	/*
	 * Step 3: clear RUN and the per-stream interrupt-enable
	 * bits (IOCE/FEIE/DEIE) symmetrically with the begin-
	 * path's combined set. Belt-and-suspenders: SIE in
	 * INTCTL was already cleared above so no interrupt
	 * could fire even with these bits set, but matching the
	 * begin-path's atomic set with an atomic clear keeps
	 * the descriptor state predictable across stream_end /
	 * stream_begin cycles.
	 *
	 * Read final LPIB after the write. LPIB freezes at the
	 * last sample position once RUN is clear.
	 */
	mtx_lock(&sc->hw_lock);
	ctl = AUDIOFS_READ_4(sc, off_ctl);
	ctl &= ~(HDAC_SDCTL_RUN | HDAC_SDCTL_IOCE |
	    HDAC_SDCTL_FEIE | HDAC_SDCTL_DEIE);
	AUDIOFS_WRITE_4(sc, off_ctl, ctl);
	final_lpib = AUDIOFS_READ_4(sc, off_lpib);
	mtx_unlock(&sc->hw_lock);
	audiofs_log(sc, "stream_end_intr_disabled", 0);

	/*
	 * Step 4: capture final LPIB delta. Any in-flight
	 * ithread that ran between our active=0 store and our
	 * SIE disable already saw active=0 and returned
	 * without updating frames_played, so our final-delta
	 * accounting is correct.
	 */
	{
		uint32_t prev = sc->output_stream_prev_lpib;
		uint64_t delta;
		if (final_lpib >= prev)
			delta = (uint64_t)(final_lpib - prev);
		else
			delta = (uint64_t)(AUDIOFS_BUF_BYTES - prev) +
			    (uint64_t)final_lpib;
		sc->output_stream_frames_played += delta / 4;
		/* F.4: capture the final fragment in the monotonic clock too. */
		sc->clock_samples_total += delta / 4;
	}
	frames_total = sc->output_stream_frames_played;
	/* F.4 (ADR 0018): final publish so the clock reflects the last frame. */
	audiofs_clock_update(sc);

	/* Step 5a: unbind the DAC. send_command needs hw_lock. */
	mtx_lock(&sc->hw_lock);
	(void)audiofs_send_command(sc, sc->output_dac_cad,
	    HDA_CMD_SET_CONV_STREAM_CHAN(0, sc->output_dac_nid, 0));
	mtx_unlock(&sc->hw_lock);
	audiofs_log(sc, "stream_end_dac_unbound", sc->output_dac_nid);

	/* Step 5b: emit F.2 stream_end event. */
	memset(&pl, 0, sizeof(pl));
	pl.stream_id = (uint32_t)sc->output_stream_id;
	pl.frames_total = frames_total;
	sx_xlock(&audiofs_state_sx);
	audiofs_events_publish(AUDIOFS_EVROLE_STREAM,
	    AUDIOFS_EVSTREAM_END, sc->output_stream_endpoint_slot,
	    0, &pl, sizeof(pl));
	sx_xunlock(&audiofs_state_sx);

	device_printf(sc->dev,
	    "stream_end: stream_id=%u frames_total=%ju (clean stop)\n",
	    (unsigned)sc->output_stream_id, (uintmax_t)frames_total);
	return (0);
}

/* ---------------------------------------------------------
 * F.3.b user-controlled playback (/dev/audiofs<N>)
 *
 * Design: audiofs/docs/adr/0015-f3b-user-controlled-playback.md
 *
 * Surface: write(2) cdev with exclusive open. open() brings
 * up the stream (or swaps source from SINE to USER if a
 * running stream already exists); close() ends it (or swaps
 * back to SINE if the test-tone tunable is set).
 *
 * Data path: write(2) copyin's into the 32 KB user ring;
 * the kthread refill loop drains BDL-fragment-sized chunks
 * into the BDL buffer, zero-filling shortfalls and counting
 * underflows. write(2) blocks (or returns EAGAIN with
 * O_NONBLOCK) when the ring is full; the kthread wakes
 * waiters after draining a fragment.
 *
 * Lock ordering for this block (with the F.3.a locks):
 *   audiofs_state_sx (sleepable, outermost) ->
 *   user_ring_mtx (MTX_DEF, middle, msleep'd for back-pressure) ->
 *   hw_lock (MTX_DEF, innermost, brief).
 * --------------------------------------------------------- */

static d_open_t		audiofs_cdev_open;
static d_close_t	audiofs_cdev_close;
static d_write_t	audiofs_cdev_write;
static d_read_t		audiofs_cdev_read;
static d_ioctl_t	audiofs_cdev_ioctl;
static d_poll_t		audiofs_cdev_poll;

static struct cdevsw audiofs_cdev_cdevsw = {
	.d_version	= D_VERSION,
	.d_flags	= D_TRACKCLOSE,
	.d_open		= audiofs_cdev_open,
	.d_close	= audiofs_cdev_close,
	.d_read		= audiofs_cdev_read,
	.d_write	= audiofs_cdev_write,
	.d_ioctl	= audiofs_cdev_ioctl,
	.d_poll		= audiofs_cdev_poll,
	.d_name		= "audiofs",
};

/*
 * Source swap helper used by cdev open/close. Caller must
 * hold user_ring_mtx. Sets the source field to the requested
 * value; no hardware writes (the kthread picks up the new
 * source on its next refill iteration, at most 10 ms later).
 *
 * Resetting the ring head/tail on swap-to-USER ensures the
 * kthread starts reading from byte 0 of fresh data, not
 * stale bytes left over from a prior cdev open.
 */
static void
audiofs_source_set(struct audiofs_softc *sc, int new_source)
{
	if (new_source == AUDIOFS_SRC_USER) {
		sc->output_stream_user_ring_head = 0;
		sc->output_stream_user_ring_tail = 0;
		sc->output_stream_underflow_count = 0;
		sc->output_stream_refill_miss_count = 0;
		sc->output_stream_refill_multi_count = 0;
	}
	sc->output_stream_source = new_source;
}

/*
 * cdev open. Exclusive: if already open, EBUSY. The check
 * AND the flag set must be atomic, so they happen together
 * under user_ring_mtx. If the stream is stopped, start it
 * with USER source; if the stream is running (SINE source
 * from the tunable), swap source to USER without restarting
 * the stream.
 *
 * Known v1 behavior on the cold-open path (test_tone=0,
 * stream was stopped): audiofs_configure_output_stream
 * (called from stream_begin) fills the BDL with the F.3.a
 * sine pattern as part of bringup. The kthread's first
 * refill iteration (within ~10ms) detects source=USER and
 * starts refilling with user data (or zero-fill if the ring
 * is empty), but the initial 8 KB of BDL contents play out
 * to the hardware first. The audible result is up to ~85 ms
 * of pre-existing quiet sine immediately after open before
 * user data takes over. The warm-open path (test_tone=1,
 * stream already alive) does not have this leak; only source
 * swaps under the lock.
 *
 * This is acceptable v1 behavior per ADR 0015; F.3.c's
 * interrupt path may address it more precisely if needed.
 */
static int
audiofs_cdev_open(struct cdev *dev, int oflags __unused,
    int devtype __unused, struct thread *td __unused)
{
	struct audiofs_softc *sc = dev->si_drv1;
	int needs_stream_begin;
	int error = 0;

	mtx_lock(&sc->output_stream_user_ring_mtx);
	if (sc->output_stream_cdev_open) {
		mtx_unlock(&sc->output_stream_user_ring_mtx);
		return (EBUSY);
	}
	sc->output_stream_cdev_open = 1;
	needs_stream_begin = !sc->output_stream_active;
	audiofs_source_set(sc, AUDIOFS_SRC_USER);
	mtx_unlock(&sc->output_stream_user_ring_mtx);

	if (needs_stream_begin) {
		uint32_t sid = 0;
		error = audiofs_stream_begin(sc, 0,
		    AUDIOFS_FMT_48KHZ_16BIT_STEREO, 2, 48000, &sid);
		if (error != 0) {
			/* Undo the open flag; the source field is
			 * harmless to leave at USER since no stream
			 * is running to consult it. */
			mtx_lock(&sc->output_stream_user_ring_mtx);
			sc->output_stream_cdev_open = 0;
			audiofs_source_set(sc, AUDIOFS_SRC_SINE);
			mtx_unlock(&sc->output_stream_user_ring_mtx);
			return (error);
		}
	}

	audiofs_log(sc, "cdev_open",
	    (uintmax_t)needs_stream_begin);
	return (0);
}

/*
 * cdev close. Drop the open flag. Decide the next state:
 * if the test-tone tunable is set, swap source back to SINE
 * (stream stays running, audible sine resumes); otherwise
 * call stream_end (stream stops, hardware quiet).
 *
 * v1 does NOT drain queued user data before ending the
 * stream. Operator semantics: close means stop now. Up to
 * ~210 ms of queued audio may be lost. Documented in ADR
 * 0015 decision rationale.
 */
static int
audiofs_cdev_close(struct cdev *dev, int fflag __unused,
    int devtype __unused, struct thread *td __unused)
{
	struct audiofs_softc *sc = dev->si_drv1;
	int want_sine;

	mtx_lock(&sc->output_stream_user_ring_mtx);
	sc->output_stream_cdev_open = 0;
	want_sine = (audiofs_test_tone != 0);
	if (want_sine)
		audiofs_source_set(sc, AUDIOFS_SRC_SINE);
	mtx_unlock(&sc->output_stream_user_ring_mtx);

	if (!want_sine) {
		(void)audiofs_stream_end(sc,
		    (uint32_t)sc->output_stream_id);
	}

	audiofs_log(sc, "cdev_close", (uintmax_t)want_sine);
	return (0);
}

/*
 * cdev write. Copy from uio into the user ring. Block on
 * msleep when the ring is full (or return EAGAIN with
 * O_NONBLOCK). Partial writes are permitted; we return
 * whatever was successfully enqueued.
 *
 * Only complete stereo frames (4 bytes each at v1's
 * 48k/16/stereo) are enqueued. A trailing partial frame in
 * the user buffer is left in the uio for the next call to
 * pick up.
 */
static int
audiofs_cdev_write(struct cdev *dev, struct uio *uio, int ioflag)
{
	struct audiofs_softc *sc = dev->si_drv1;
	size_t want, space, copy_bytes, ring_idx;
	int error = 0;

	while (uio->uio_resid >= 4) {
		mtx_lock(&sc->output_stream_user_ring_mtx);
		for (;;) {
			space = AUDIOFS_USER_RING_BYTES -
			    (sc->output_stream_user_ring_head -
			     sc->output_stream_user_ring_tail);
			if (space >= 4)
				break;
			if (ioflag & IO_NDELAY) {
				mtx_unlock(
				    &sc->output_stream_user_ring_mtx);
				/*
				 * EAGAIN: write(2) returns the count
				 * of bytes already transferred (which
				 * the framework computes from initial
				 * vs current uio_resid) or -1+EAGAIN
				 * if zero bytes were transferred.
				 */
				return (EAGAIN);
			}
			error = msleep(&sc->output_stream_user_ring_mtx,
			    &sc->output_stream_user_ring_mtx,
			    PCATCH, "audwrite", 0);
			if (error != 0) {
				mtx_unlock(
				    &sc->output_stream_user_ring_mtx);
				/* On signal, return any bytes already
				 * enqueued; EINTR if zero. */
				return (error);
			}
		}

		want = (size_t)uio->uio_resid;
		if (want > space)
			want = space;
		/* Only whole frames (4 bytes). */
		want &= ~(size_t)3;
		if (want == 0) {
			mtx_unlock(&sc->output_stream_user_ring_mtx);
			break;
		}

		ring_idx = sc->output_stream_user_ring_head &
		    AUDIOFS_USER_RING_MASK;
		if (ring_idx + want <= AUDIOFS_USER_RING_BYTES) {
			copy_bytes = want;
			mtx_unlock(&sc->output_stream_user_ring_mtx);
			error = uiomove(
			    sc->output_stream_user_ring + ring_idx,
			    (int)copy_bytes, uio);
			mtx_lock(&sc->output_stream_user_ring_mtx);
		} else {
			size_t first = AUDIOFS_USER_RING_BYTES - ring_idx;
			mtx_unlock(&sc->output_stream_user_ring_mtx);
			error = uiomove(
			    sc->output_stream_user_ring + ring_idx,
			    (int)first, uio);
			if (error == 0) {
				error = uiomove(
				    sc->output_stream_user_ring,
				    (int)(want - first), uio);
			}
			copy_bytes = want;
			mtx_lock(&sc->output_stream_user_ring_mtx);
		}

		if (error != 0) {
			mtx_unlock(&sc->output_stream_user_ring_mtx);
			return (error);
		}
		sc->output_stream_user_ring_head += copy_bytes;
		mtx_unlock(&sc->output_stream_user_ring_mtx);
	}

	return (0);
}

/*
 * cdev read: output-only device. F.3.b does not support
 * capture; that is future work.
 */
static int
audiofs_cdev_read(struct cdev *dev __unused, struct uio *uio __unused,
    int ioflag __unused)
{
	return (ENXIO);
}

/*
 * cdev ioctl (F.3.e, ADR 0019): format query and format set.
 * GET_FORMAT returns the active format plus the bound DAC's
 * advertised rate set. SET_FORMAT negotiates a new rate
 * (16-bit stereo fixed) and reconfigures the running stream.
 */
static int
audiofs_cdev_ioctl(struct cdev *dev, u_long cmd, caddr_t data,
    int fflag __unused, struct thread *td __unused)
{
	struct audiofs_softc *sc = dev->si_drv1;
	struct audiofs_format *f = (struct audiofs_format *)data;

	switch (cmd) {
	case AUDIOFS_IOC_GET_FORMAT:
		f->rate_hz = sc->output_stream_rate_hz;
		f->format_word = sc->output_stream_format_word;
		f->bits = 16;
		f->channels = 2;
		f->supported_rates =
		    audiofs_psr_rate_mask(audiofs_output_dac_psr(sc));
		return (0);

	case AUDIOFS_IOC_SET_FORMAT: {
		struct audiofs_evp_format_change pl;
		uint16_t new_word, old_word;
		uint32_t old_rate, sid;
		int error;

		/* v1: 16-bit stereo only. */
		if (f->bits != 16 || f->channels != 2)
			return (EINVAL);
		if (audiofs_rate_to_format_word(f->rate_hz, &new_word) != 0)
			return (EINVAL);
		if (!audiofs_psr_has_rate(audiofs_output_dac_psr(sc),
		    f->rate_hz))
			return (EINVAL);

		/* No-op if the rate is unchanged: no restart, no event. */
		if (f->rate_hz == sc->output_stream_rate_hz)
			return (0);

		old_word = sc->output_stream_format_word;
		old_rate = sc->output_stream_rate_hz;

		/*
		 * Flush the user ring: buffered bytes are at the old
		 * rate and must not play at the new one. Discard them
		 * (head = tail) and wake any writer blocked on a full
		 * ring so it re-evaluates after the reconfigure.
		 */
		mtx_lock(&sc->output_stream_user_ring_mtx);
		sc->output_stream_user_ring_head =
		    sc->output_stream_user_ring_tail;
		mtx_unlock(&sc->output_stream_user_ring_mtx);
		wakeup(&sc->output_stream_user_ring_mtx);

		/*
		 * Reconfigure: stop, then start at the new rate.
		 * stream_begin records the format, reprograms the
		 * stream descriptor and the DAC converter, and
		 * republishes the F.4 clock rate.
		 */
		error = audiofs_stream_end(sc, sc->output_stream_id);
		if (error != 0)
			return (error);
		sid = 0;
		error = audiofs_stream_begin(sc, 0, new_word, 2,
		    f->rate_hz, &sid);
		if (error != 0) {
			/* Best-effort restore to the prior rate. */
			(void)audiofs_stream_begin(sc, 0, old_word, 2,
			    old_rate, &sid);
			return (error);
		}

		/* F.2 format_change event. */
		memset(&pl, 0, sizeof(pl));
		pl.stream_id = (uint32_t)sc->output_stream_id;
		pl.old_format = old_word;
		pl.new_format = new_word;
		pl.new_rate_hz = f->rate_hz;
		sx_xlock(&audiofs_state_sx);
		audiofs_events_publish(AUDIOFS_EVROLE_STREAM,
		    AUDIOFS_EVSTREAM_FORMAT_CHANGE,
		    AUDIOFS_EVENTS_NO_ENDPOINT, 0, &pl, sizeof(pl));
		sx_xunlock(&audiofs_state_sx);

		/* F.1: refresh state so current_format reflects the change. */
		audiofs_state_republish();
		return (0);
	}

	default:
		return (ENOTTY);
	}
}

/*
 * cdev poll: report writable when the ring has at least one
 * frame (4 bytes) of free space; report readable as a
 * "would-error" so selecting consumers see immediate
 * negative status. POLLIN is unusual on an output-only
 * device but reporting it suppresses indefinite blocking.
 */
static int
audiofs_cdev_poll(struct cdev *dev, int events, struct thread *td __unused)
{
	struct audiofs_softc *sc = dev->si_drv1;
	int revents = 0;

	if (events & (POLLOUT | POLLWRNORM)) {
		mtx_lock(&sc->output_stream_user_ring_mtx);
		if ((AUDIOFS_USER_RING_BYTES -
		     (sc->output_stream_user_ring_head -
		      sc->output_stream_user_ring_tail)) >= 4) {
			revents |= events & (POLLOUT | POLLWRNORM);
		}
		mtx_unlock(&sc->output_stream_user_ring_mtx);
	}
	/* Output-only: any read interest is satisfied
	 * immediately so the caller sees the device is not
	 * a read source. */
	if (events & (POLLIN | POLLRDNORM))
		revents |= events & (POLLIN | POLLRDNORM);

	return (revents);
}

/*
 * Sysctl handler for hw.audiofs.test_tone.
 *
 * Read: returns the current value of the audiofs_test_tone
 * global. Write: if the new value differs from the current
 * one, walk the registered softcs and start (new != 0,
 * previous == 0) or stop (new == 0, previous != 0) the test
 * stream on each. Same-value writes are no-ops.
 *
 * Lock discipline: snapshot the softc list under
 * audiofs_state_sx, drop the sx, then iterate. We must NOT
 * hold audiofs_state_sx across the stream_begin / stream_end
 * calls because those internally take audiofs_state_sx for
 * the F.2 event publish (and the default sx is non-recursive,
 * so a recursive xlock attempt would panic). Snapshotting
 * under sx then iterating without is the established pattern
 * used elsewhere in audiofs.
 *
 * The snapshot may go stale if a controller attaches or
 * detaches between snapshot and iteration; that is acceptable
 * for a bench-iteration knob. A controller that attaches
 * during the write will read the new value from
 * audiofs_test_tone in audiofs_attach (which reads it under
 * the same conventions) and act accordingly.
 */
static int
audiofs_sysctl_test_tone(SYSCTL_HANDLER_ARGS)
{
	struct audiofs_softc *snap[AUDIOFS_STATE_CONTROLLER_SLOTS];
	int snap_n;
	int newval = audiofs_test_tone;
	int prev;
	int error, i;

	error = sysctl_handle_int(oidp, &newval, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);

	prev = audiofs_test_tone;
	audiofs_test_tone = newval;
	if ((prev == 0) == (newval == 0))
		return (0);	/* no transition (0->0 or nonzero->nonzero) */

	/* Snapshot the softc list under the sx. */
	sx_xlock(&audiofs_state_sx);
	snap_n = audiofs_state_softc_count;
	for (i = 0; i < snap_n; i++)
		snap[i] = audiofs_state_softcs[i];
	sx_xunlock(&audiofs_state_sx);

	/*
	 * Iterate without sx held. Failures are non-fatal: one
	 * controller might lack output capability (HDMI without
	 * codecs etc.) and we want the other controllers to still
	 * follow the toggle.
	 *
	 * Per ADR 0015 (F.3.b) source-state machine: if a
	 * controller has a cdev consumer open, the cdev owns the
	 * stream; the tunable does not override. The tunable
	 * value is still recorded (audiofs_test_tone updated
	 * above) so that when the cdev closes, close() consults
	 * the current value to decide whether to fall back to
	 * sine or stop the stream.
	 */
	for (i = 0; i < snap_n; i++) {
		struct audiofs_softc *sc = snap[i];
		int cdev_open;
		if (sc == NULL)
			continue;

		mtx_lock(&sc->output_stream_user_ring_mtx);
		cdev_open = sc->output_stream_cdev_open;
		mtx_unlock(&sc->output_stream_user_ring_mtx);
		if (cdev_open) {
			audiofs_log(sc, "test_tone_toggle_cdev_owned",
			    (uintmax_t)newval);
			continue;
		}

		if (newval != 0 && !sc->output_stream_active) {
			uint32_t sid = 0;
			/* Source defaults to SINE in stream_begin's
			 * initialization (set at attach to SINE; never
			 * changed except by cdev open/close). */
			(void)audiofs_stream_begin(sc, 0,
			    AUDIOFS_FMT_48KHZ_16BIT_STEREO, 2, 48000,
			    &sid);
		} else if (newval == 0 && sc->output_stream_active) {
			(void)audiofs_stream_end(sc,
			    (uint32_t)sc->output_stream_id);
		}
	}
	return (0);
}

static void
audiofs_walk_topology(struct audiofs_softc *sc)
{
	int cad;

	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_walk_codec(sc, cad);
	}

	/*
	 * After enumeration completes for all codecs, walk paths
	 * from every connected output pin back to a DAC. Done as
	 * a separate pass so that all widget state is in place
	 * before any pathfinding runs.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_find_paths_for_codec(sc, cad);
	}

	/*
	 * Platform-policy diagnostic pass: query each codec's
	 * GPIO inventory and each pin's EAPD capability. Pure
	 * inspection - no writes - so we can see what spec-
	 * defined surfaces the codec exposes for downstream
	 * amplifier control before deciding policy.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_inspect_platform_caps(sc, cad);
	}

	/*
	 * Power-up pass: send SET_POWER_STATE(D0) to the function
	 * group and to every widget on every discovered output
	 * path. Widgets that advertise POWER_CTRL come out of
	 * reset in D3 (sleep) state; D0 is required for them to
	 * process audio. Without this, all subsequent pin enable,
	 * amp unmute, and stream RUN passes appear to succeed at
	 * the register level but no analog signal is produced.
	 *
	 * This pass logically belongs before everything that
	 * writes audio-path state. Numbered after path discovery
	 * for ordering reasons only.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_power_up_codec_paths(sc, cad);
	}

	/*
	 * GPIO platform-policy pass: configure the adopted
	 * platform codec's GPIO lines and drive the policy
	 * table's initial gpio_data, with readback. Runs after
	 * the power-up pass because GPIO state written while
	 * the function group is in D3 is not trustworthy
	 * across the D3->D0 transition (the commit-6f sweep
	 * that validated gpio_data=0x08 ran with the codec
	 * already in D0).
	 */
	audiofs_apply_gpio_policy(sc);

	/*
	 * Third pass: enable each connected output pin's output
	 * gating bit. This is the first commit that writes codec
	 * state through audiofs's own command path.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_enable_outputs_for_codec(sc, cad);
	}

	/*
	 * Fourth pass: unmute the output amplifier on each widget
	 * along each discovered output path. Without this the
	 * codec routes samples through a muted analog stage; with
	 * it, the amplifier is open and any stream of samples
	 * delivered to the DAC will reach the pin.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_unmute_output_paths_for_codec(sc, cad);
	}

	/*
	 * Fifth pass: bind each DAC on a discovered output path
	 * to a chosen converter format. Without this the DAC has
	 * an unspecified format and the controller stream
	 * descriptor (commit 6c) cannot agree with it on sample
	 * encoding.
	 */
	for (cad = 0; cad < AUDIOFS_CODEC_MAX; cad++) {
		if (sc->codecs[cad].populated)
			audiofs_set_dac_formats_for_codec(sc, cad);
	}

	/*
	 * F.3.a (per ADR 0014): the stream_begin call is made by
	 * audiofs_attach AFTER the hw_lock is released and AFTER
	 * audiofs_state_register has populated the F.1 endpoint
	 * inventory. stream_begin takes hw_lock internally for
	 * register writes; calling it from here (inside the
	 * walk_topology / hw_lock context) would recurse.
	 *
	 * walk_topology's role ends with the codec/widget walk.
	 * Stream lifecycle is attach's responsibility.
	 */
}

/* ---------------------------------------------------------
 * Device methods
 * --------------------------------------------------------- */

static int
audiofs_probe(device_t dev)
{
	uint16_t class, subclass;

	class = pci_get_class(dev);
	subclass = pci_get_subclass(dev);

	if (class != PCIC_MULTIMEDIA || subclass != PCIS_MULTIMEDIA_HDA)
		return (ENXIO);

	device_set_desc(dev, "Awase audiofs (HDA Controller)");
	return (BUS_PROBE_DEFAULT);
}

static int
audiofs_attach(device_t dev)
{
	struct audiofs_softc *sc = device_get_softc(dev);
	int error;

	sc->dev = dev;
	sc->pci_vendor = pci_get_vendor(dev);
	sc->pci_device = pci_get_device(dev);
	sc->pci_subvendor = pci_get_subvendor(dev);
	sc->pci_subdevice = pci_get_subdevice(dev);
	sc->gpio_cad = -1;	/* no platform codec until inspect picks one */

	mtx_init(&sc->evlock, "audiofs evlog", NULL, MTX_DEF);
	mtx_init(&sc->hw_lock, "audiofs hw", NULL, MTX_DEF);
	/*
	 * F.3.c (ADR 0016 Decision 7): intr_lock is MTX_SPIN,
	 * innermost in the lock order. Filter handler uses it
	 * for INTSTS/SDnSTS register I/O; ithread uses it for
	 * brief output_stream_active / _last_sdsts accesses.
	 * Never held while any other audiofs lock is held.
	 */
	mtx_init(&sc->intr_lock, "audiofs intr", NULL, MTX_SPIN);
	TASK_INIT(&sc->output_stream_xrun_task, 0,
	    audiofs_xrun_task, sc);

	/*
	 * F.3.b user-ring state. The 32 KB ring buffer is
	 * allocated at attach so its lifetime matches the
	 * softc; the mutex covers head/tail/source/cdev_open
	 * and is also the back-pressure msleep address.
	 * output_stream_source initializes to SINE so the
	 * F.3.a internal sine source remains the default in the
	 * absence of a cdev consumer; the F.3.c ithread will
	 * draw from it when test_tone is set.
	 */
	mtx_init(&sc->output_stream_user_ring_mtx,
	    "audiofs userring", NULL, MTX_DEF);
	sc->output_stream_user_ring = malloc(AUDIOFS_USER_RING_BYTES,
	    M_AUDIOFS, M_WAITOK | M_ZERO);
	sc->output_stream_source = AUDIOFS_SRC_SINE;

	audiofs_sysctl_setup(sc);

	audiofs_log(sc, "attach_begin", 0);
	device_printf(dev,
	    "PCI: vendor=0x%04x device=0x%04x subvendor=0x%04x subdevice=0x%04x\n",
	    sc->pci_vendor, sc->pci_device,
	    sc->pci_subvendor, sc->pci_subdevice);

	/* Enable PCI bus mastering (required for DMA later; harmless now). */
	pci_enable_busmaster(dev);

	/* Map BAR 0. */
	sc->mem_rid = PCIR_BAR(0);
	sc->mem_res = bus_alloc_resource_any(dev, SYS_RES_MEMORY,
	    &sc->mem_rid, RF_ACTIVE);
	if (sc->mem_res == NULL) {
		device_printf(dev, "unable to allocate BAR0\n");
		audiofs_log(sc, "bar_alloc_failed", 0);
		error = ENOMEM;
		goto fail_early;
	}
	sc->mem_tag = rman_get_bustag(sc->mem_res);
	sc->mem_handle = rman_get_bushandle(sc->mem_res);
	audiofs_log(sc, "bar_mapped", 0);

	/* Read version and GCAP. */
	sc->vmaj = AUDIOFS_READ_1(sc, HDAC_VMAJ);
	sc->vmin = AUDIOFS_READ_1(sc, HDAC_VMIN);
	sc->gcap = AUDIOFS_READ_2(sc, HDAC_GCAP);
	sc->num_iss = HDAC_GCAP_ISS(sc->gcap);
	sc->num_oss = HDAC_GCAP_OSS(sc->gcap);
	sc->num_bss = HDAC_GCAP_BSS(sc->gcap);
	sc->num_sdo = HDAC_GCAP_NSDO(sc->gcap);
	sc->support_64bit = (sc->gcap & HDAC_GCAP_64OK) ? 1 : 0;

	audiofs_log(sc, "hda_version_major", sc->vmaj);
	audiofs_log(sc, "hda_version_minor", sc->vmin);
	audiofs_log(sc, "gcap", sc->gcap);
	audiofs_log(sc, "num_iss", sc->num_iss);
	audiofs_log(sc, "num_oss", sc->num_oss);
	audiofs_log(sc, "num_bss", sc->num_bss);

	device_printf(dev,
	    "HDA v%u.%u: GCAP=0x%04x ISS=%d OSS=%d BSS=%d SDO=%d 64bit=%s\n",
	    sc->vmaj, sc->vmin, sc->gcap,
	    sc->num_iss, sc->num_oss, sc->num_bss, sc->num_sdo,
	    sc->support_64bit ? "yes" : "no");

	/* Reset the controller. */
	mtx_lock(&sc->hw_lock);
	error = audiofs_reset(sc);
	mtx_unlock(&sc->hw_lock);
	if (error != 0) {
		device_printf(dev, "controller reset failed (%d)\n", error);
		goto fail_mapped;
	}

	/*
	 * F.3.c (ADR 0016 Decision 1): allocate PCI interrupt
	 * resource and register filter+ithread handlers. Try MSI
	 * first (one vector); fall back to INTx if MSI is
	 * unavailable. Failure is a hard attach error: ADR 0016
	 * does not retain the F.3.a polling fallback.
	 *
	 * Note: the controller's INTCTL register is still all
	 * zeros at this point (no stream's SIE is set, GIE/CIE
	 * are cleared by the reset above). No interrupts will
	 * actually fire until stream_begin sets the relevant
	 * INTCTL bits. So it is safe to set up the handler now
	 * even though CORB/RIRB/codec init has not run yet.
	 */
	/*
	 * Try MSI first (single vector). pci_alloc_msi takes
	 * the requested count as input and the actual count
	 * granted as output; we only proceed with MSI if it
	 * succeeded AND we got exactly 1 vector.
	 *
	 *   pci_alloc_msi returns 0 with count == 1: use MSI.
	 *   pci_alloc_msi returns 0 with count != 1: release
	 *     the vectors we got (we cannot use them) and
	 *     fall back to INTx.
	 *   pci_alloc_msi returns nonzero: failure, no
	 *     vectors allocated, fall back to INTx.
	 */
	sc->msi_count = 1;
	error = pci_alloc_msi(dev, &sc->msi_count);
	if (error == 0 && sc->msi_count == 1) {
		/* MSI: vector 1 is the only one we allocated. */
		sc->irq_rid = 1;
	} else {
		if (error == 0)
			pci_release_msi(dev);
		sc->msi_count = 0;
		sc->irq_rid = 0;
	}
	/* error reset; INTx path is the success-by-default path. */
	error = 0;
	sc->irq_res = bus_alloc_resource_any(dev, SYS_RES_IRQ,
	    &sc->irq_rid,
	    (sc->msi_count == 1 ? RF_ACTIVE : RF_SHAREABLE | RF_ACTIVE));
	if (sc->irq_res == NULL) {
		device_printf(dev, "unable to allocate IRQ resource\n");
		audiofs_log(sc, "irq_alloc_failed", 0);
		if (sc->msi_count == 1) {
			pci_release_msi(dev);
			sc->msi_count = 0;
		}
		error = ENOMEM;
		goto fail_mapped;
	}

	error = bus_setup_intr(dev, sc->irq_res,
	    INTR_TYPE_AV | INTR_MPSAFE, audiofs_intr_filter,
	    audiofs_intr_thread, sc, &sc->irq_cookie);
	if (error != 0) {
		device_printf(dev,
		    "bus_setup_intr failed (%d)\n", error);
		audiofs_log(sc, "irq_setup_failed", (uintmax_t)error);
		bus_release_resource(dev, SYS_RES_IRQ, sc->irq_rid,
		    sc->irq_res);
		sc->irq_res = NULL;
		if (sc->msi_count == 1) {
			pci_release_msi(dev);
			sc->msi_count = 0;
		}
		goto fail_mapped;
	}
	sc->interrupts_attached = 1;
	audiofs_log(sc,
	    sc->msi_count == 1 ? "intr_setup_msi" : "intr_setup_intx", 0);
	device_printf(dev, "F.3.c: interrupts attached (%s)\n",
	    sc->msi_count == 1 ? "MSI" : "INTx");

	/* Pick CORB/RIRB sizes from controller capabilities. */
	error = audiofs_pick_corb_rirb_sizes(sc);
	if (error != 0)
		goto fail_mapped;
	audiofs_log(sc, "corb_size", sc->corb_size);
	audiofs_log(sc, "rirb_size", sc->rirb_size);

	/* Allocate DMA-backed CORB (4 bytes/entry) and RIRB (8 bytes/entry). */
	error = audiofs_dma_alloc(sc, &sc->corb_dma, sc->corb_size * 4);
	if (error != 0) {
		device_printf(dev, "CORB DMA alloc failed (%d)\n", error);
		goto fail_mapped;
	}
	audiofs_log(sc, "corb_dma_allocated", sc->corb_dma.dma_paddr);

	error = audiofs_dma_alloc(sc, &sc->rirb_dma,
	    sc->rirb_size * sizeof(struct audiofs_rirb));
	if (error != 0) {
		device_printf(dev, "RIRB DMA alloc failed (%d)\n", error);
		goto fail_corb;
	}
	audiofs_log(sc, "rirb_dma_allocated", sc->rirb_dma.dma_paddr);

	/* Init and start the rings. */
	mtx_lock(&sc->hw_lock);
	audiofs_corb_init(sc);
	audiofs_rirb_init(sc);
	audiofs_corb_start(sc);
	audiofs_rirb_start(sc);

	/* Enable unsolicited response delivery (required by some codecs). */
	AUDIOFS_WRITE_4(sc, HDAC_GCTL,
	    AUDIOFS_READ_4(sc, HDAC_GCTL) | HDAC_GCTL_UNSOL);

	/* Enumerate populated codec slots. */
	audiofs_enumerate_codecs(sc);

	/* Walk topology: function groups, widgets, pin configs. */
	audiofs_walk_topology(sc);
	mtx_unlock(&sc->hw_lock);

	audiofs_log(sc, "attach_end", 0);

	/*
	 * F.1: register this controller in the module-global state
	 * registry and (re)publish /var/run/sema/audio/state. By
	 * now the topology walk, path discovery, pin control, amp
	 * unmute, format binding, and stream configuration are all
	 * complete, so the endpoint enumeration in the publish path
	 * reads stable widget state. State publication failure is
	 * non-fatal: the controller stays attached and functional;
	 * only the state file is absent.
	 */
	audiofs_state_register(sc);

	/*
	 * F.3.b: create /dev/audiofs<N> for user-controlled
	 * playback (ADR 0015). Mode 0666 so non-root operators
	 * can test from a userland program; in production
	 * semasound runs as a privileged user and the open
	 * exclusion enforces single-consumer semantics. The
	 * cdev exists from attach to detach; stream_begin is
	 * called on open(), not on cdev creation.
	 *
	 * make_dev_s gives us a clean error path. On failure
	 * the cdev stays NULL and userland sees no device;
	 * the rest of audiofs continues to work for diagnostic
	 * purposes.
	 */
	{
		struct make_dev_args dargs;
		int err;

		make_dev_args_init(&dargs);
		dargs.mda_devsw = &audiofs_cdev_cdevsw;
		dargs.mda_uid = UID_ROOT;
		dargs.mda_gid = GID_WHEEL;
		dargs.mda_mode = 0666;
		dargs.mda_si_drv1 = sc;
		err = make_dev_s(&dargs, &sc->output_stream_cdev,
		    "audiofs%d", device_get_unit(dev));
		if (err != 0) {
			device_printf(dev,
			    "F.3.b make_dev_s failed: %d "
			    "(no /dev/audiofs%d; rest of attach continues)\n",
			    err, device_get_unit(dev));
			sc->output_stream_cdev = NULL;
		} else {
			audiofs_log(sc, "cdev_created",
			    (uintmax_t)device_get_unit(dev));
		}
	}

	/*
	 * F.3.a: optionally start a continuous output stream on
	 * the controller's reserved output stream descriptor.
	 * Per ADR 0014, the test tone is the audible closure
	 * proof; per the post-bench safety amendment (2026-05-29),
	 * autoplay is opt-in via hw.audiofs.test_tone (default 0
	 * = silent). Operators enable the tone via loader.conf
	 * tunable or `sysctl hw.audiofs.test_tone=1` at runtime;
	 * setting it back to 0 stops the stream cleanly without
	 * needing kldunload.
	 *
	 * Called HERE (not from walk_topology) for two reasons:
	 * (1) hw_lock is released, so stream_begin can take it
	 * cleanly for register writes without recursing; (2) the
	 * F.1 endpoint inventory is now populated by
	 * audiofs_state_register, so stream events emitted from
	 * stream_begin correlate to a published endpoint slot.
	 *
	 * v1 hardcodes 48 kHz / 16-bit / stereo (matching what
	 * commit 6 bound electrically). F.3.e will negotiate
	 * format. endpoint_id 0 is informational in v1 (F.3.b
	 * will map an explicit endpoint).
	 *
	 * Best-effort: failure to start the stream is logged but
	 * does not abort attach (F.1 / F.2 still publish, and the
	 * controller is still useful for inspection).
	 */
	if (audiofs_test_tone != 0) {
		uint32_t stream_id = 0;
		int err = audiofs_stream_begin(sc, 0,
		    AUDIOFS_FMT_48KHZ_16BIT_STEREO, 2, 48000, &stream_id);
		if (err != 0) {
			device_printf(dev,
			    "F.3.a stream_begin failed: %d "
			    "(continuing without continuous stream)\n",
			    err);
			audiofs_log(sc, "stream_begin_failed",
			    (uintmax_t)err);
		}
	} else {
		audiofs_log(sc, "stream_begin_skipped_tone_off", 0);
	}

	return (0);

fail_corb:
	audiofs_dma_free(&sc->corb_dma);
fail_mapped:
	/*
	 * F.3.c: tear down interrupt setup if it was attached.
	 * bus_teardown_intr blocks until any in-flight ithread
	 * completes. Then release the IRQ and free the MSI
	 * vector if one was allocated.
	 */
	if (sc->interrupts_attached) {
		bus_teardown_intr(dev, sc->irq_res, sc->irq_cookie);
		sc->irq_cookie = NULL;
		sc->interrupts_attached = 0;
		/*
		 * F.3.d (ADR 0017): drain any pending xrun task.
		 * bus_teardown_intr has ensured no ithread is in
		 * flight, so no new enqueues happen after this
		 * point. taskqueue_drain catches anything already
		 * scheduled.
		 */
		taskqueue_drain(taskqueue_fast,
		    &sc->output_stream_xrun_task);
	}
	if (sc->irq_res != NULL) {
		bus_release_resource(dev, SYS_RES_IRQ, sc->irq_rid,
		    sc->irq_res);
		sc->irq_res = NULL;
	}
	if (sc->msi_count == 1) {
		pci_release_msi(dev);
		sc->msi_count = 0;
	}
	bus_release_resource(dev, SYS_RES_MEMORY, sc->mem_rid, sc->mem_res);
	sc->mem_res = NULL;
fail_early:
	if (sc->output_stream_user_ring != NULL) {
		free(sc->output_stream_user_ring, M_AUDIOFS);
		sc->output_stream_user_ring = NULL;
	}
	mtx_destroy(&sc->output_stream_user_ring_mtx);
	mtx_destroy(&sc->intr_lock);
	mtx_destroy(&sc->hw_lock);
	mtx_destroy(&sc->evlock);
	return (error);
}

static int
audiofs_detach(device_t dev)
{
	struct audiofs_softc *sc = device_get_softc(dev);

	audiofs_log(sc, "detach_begin", 0);

	/*
	 * F.3.b: destroy the /dev/audiofs<N> cdev BEFORE
	 * touching anything else. destroy_dev blocks until all
	 * in-flight cdev operations (open/close/write/poll)
	 * complete and prevents new ones; only after it returns
	 * are output_stream_active, the ithread, and the user
	 * ring safe to tear down.
	 *
	 * If a writer was blocked in msleep on user_ring_mtx
	 * when destroy_dev fires, the close() that drains the
	 * fd table will tear down the cdev open state cleanly
	 * (D_TRACKCLOSE). Subsequent stream_end below disables
	 * the stream's interrupt source.
	 */
	if (sc->output_stream_cdev != NULL) {
		destroy_dev(sc->output_stream_cdev);
		sc->output_stream_cdev = NULL;
	}

	/*
	 * F.3.a: end any active output stream FIRST, before the
	 * IRQ teardown and hardware reset. stream_end clears
	 * output_stream_active under intr_lock, disables the
	 * stream's SIE bit in INTCTL, clears RUN, unbinds the
	 * DAC, and emits the F.2 stream_end event while the
	 * state region still has the endpoint inventory (so the
	 * event's endpoint_slot remains correlatable).
	 *
	 * If no stream is running, audiofs_stream_end returns
	 * ENXIO and we proceed. Failure beyond that is best-
	 * effort (we still tear down).
	 */
	if (sc->output_stream_active) {
		(void)audiofs_stream_end(sc,
		    (uint32_t)sc->output_stream_id);
	}

	/*
	 * F.3.c (ADR 0016 Decision 5): clear GIE and CIE in
	 * INTCTL. stream_end above already cleared the stream's
	 * SIE bit. Now disabling GIE+CIE ensures no further
	 * interrupts of any kind will fire.
	 */
	if (sc->mem_res != NULL) {
		uint32_t ctl;
		mtx_lock(&sc->hw_lock);
		ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
		ctl &= ~(HDAC_INTCTL_GIE | HDAC_INTCTL_CIE);
		AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
		mtx_unlock(&sc->hw_lock);
	}

	/*
	 * F.3.c: tear down the interrupt resource.
	 * bus_teardown_intr blocks until any in-flight ithread
	 * invocation completes; combined with the GIE+CIE clear
	 * above, no new ithread invocations will arrive after
	 * teardown returns. Safe to release IRQ and free MSI
	 * vectors after.
	 */
	if (sc->interrupts_attached) {
		bus_teardown_intr(dev, sc->irq_res, sc->irq_cookie);
		sc->irq_cookie = NULL;
		sc->interrupts_attached = 0;
		audiofs_log(sc, "intr_teardown", 0);
	}
	if (sc->irq_res != NULL) {
		bus_release_resource(dev, SYS_RES_IRQ, sc->irq_rid,
		    sc->irq_res);
		sc->irq_res = NULL;
	}
	if (sc->msi_count == 1) {
		pci_release_msi(dev);
		sc->msi_count = 0;
	}

	/*
	 * F.1: remove this controller from the module-global state
	 * registry and republish before tearing down hardware. Done
	 * first so the state file never references a controller
	 * whose DMA and registers are being freed.
	 */
	audiofs_state_unregister(sc);

	if (sc->mem_res != NULL) {
		mtx_lock(&sc->hw_lock);
		/*
		 * Stop CORB/RIRB DMA before reset; reset also stops
		 * them but doing it explicitly is cheap insurance.
		 *
		 * If an output stream was configured, audiofs_reset
		 * also stops it (writes 0 to every OSDCTL), so the
		 * stream cleanup just needs to free its DMA after
		 * reset returns.
		 */
		AUDIOFS_WRITE_1(sc, HDAC_CORBCTL, 0);
		AUDIOFS_WRITE_1(sc, HDAC_RIRBCTL, 0);
		(void)audiofs_reset(sc);
		mtx_unlock(&sc->hw_lock);

		if (sc->output_stream_configured) {
			audiofs_dma_free(&sc->buf_dma);
			audiofs_dma_free(&sc->bdl_dma);
			sc->output_stream_configured = 0;
		}
		audiofs_dma_free(&sc->rirb_dma);
		audiofs_dma_free(&sc->corb_dma);

		bus_release_resource(dev, SYS_RES_MEMORY,
		    sc->mem_rid, sc->mem_res);
		sc->mem_res = NULL;
	}

	pci_disable_busmaster(dev);

	/*
	 * F.3.b user-ring cleanup. By now stream_end has run
	 * (above), interrupts are disabled and torn down, and
	 * the cdev has been destroyed, so no one can touch the
	 * ring or its mutex; free and destroy unconditionally.
	 */
	if (sc->output_stream_user_ring != NULL) {
		free(sc->output_stream_user_ring, M_AUDIOFS);
		sc->output_stream_user_ring = NULL;
	}
	mtx_destroy(&sc->output_stream_user_ring_mtx);
	mtx_destroy(&sc->intr_lock);
	mtx_destroy(&sc->hw_lock);
	mtx_destroy(&sc->evlock);

	return (0);
}

static int
audiofs_suspend(device_t dev)
{
	struct audiofs_softc *sc = device_get_softc(dev);

	audiofs_log(sc, "suspend", 0);
	return (0);
}

static int
audiofs_resume(device_t dev)
{
	struct audiofs_softc *sc = device_get_softc(dev);

	audiofs_log(sc, "resume", 0);
	return (0);
}

static device_method_t audiofs_methods[] = {
	DEVMETHOD(device_probe,		audiofs_probe),
	DEVMETHOD(device_attach,	audiofs_attach),
	DEVMETHOD(device_detach,	audiofs_detach),
	DEVMETHOD(device_suspend,	audiofs_suspend),
	DEVMETHOD(device_resume,	audiofs_resume),
	DEVMETHOD_END
};

static driver_t audiofs_driver = {
	"audiofs",
	audiofs_methods,
	sizeof(struct audiofs_softc),
};

/*
 * Module event handler. Initializes and tears down the
 * module-global F.1 state-publication machinery.
 *
 * MOD_LOAD: initialize the state sx. The state file itself is
 * created lazily on the first controller attach
 * (audiofs_state_register), so a load with no matching
 * hardware leaves no file behind.
 *
 * MOD_UNLOAD: close the state file (if open) and mark the
 * region invalid by zeroing state_valid before close. By
 * unload time every controller has detached (the driver
 * framework detaches device instances before MOD_UNLOAD), so
 * the registry is already empty; this just releases the file
 * and destroys the sx.
 */
static int
audiofs_modevent(module_t mod __unused, int what, void *arg __unused)
{

	switch (what) {
	case MOD_LOAD:
		sx_init(&audiofs_state_sx, "audiofs state");
		/*
		 * F.2: initialise the notify cdev's selinfo knote
		 * list before any thread can selrecord or knlist_add
		 * against it, then create /dev/audiofs_notify. A NULL
		 * lock uses the shared global knlist mutex, correct
		 * for our low publish rate (mirrors inputfs AD-41.3).
		 * make_dev_p failure is non-fatal: events still
		 * publish to the mmap-backed file, only the wake
		 * source is absent.
		 */
		knlist_init(&audiofs_notify_selinfo.si_note, NULL, NULL,
		    NULL, NULL);
		if (make_dev_p(MAKEDEV_CHECKNAME | MAKEDEV_WAITOK,
		    &audiofs_notify_dev, &audiofs_notify_cdevsw, NULL,
		    (uid_t)AUDIOFS_STATE_UID, (gid_t)AUDIOFS_STATE_GID,
		    0644, "audiofs_notify") != 0) {
			printf("audiofs: make_dev_p(audiofs_notify) failed "
			    "(events ring still published; no wake fd)\n");
			audiofs_notify_dev = NULL;
		}
		return (0);
	case MOD_UNLOAD:
		sx_xlock(&audiofs_state_sx);
		if (audiofs_state_vp != NULL) {
			struct audiofs_state_region *r;
			struct thread *td = curthread;

			/*
			 * Publish an invalid (state_valid=0) region so a
			 * reader still mmap'd sees the subsystem as gone,
			 * then close the file. The file is left on disk
			 * (not unlinked), matching inputfs's state-file
			 * behavior: the established Awase substrate pattern
			 * is invalidate-and-close, not remove. ADR 0012
			 * closure criterion 4 permits either removal or
			 * invalidation; audiofs takes the invalidation
			 * path for consistency with inputfs. The lingering
			 * file lives in tmpfs-backed /var/run and is
			 * overwritten cleanly on the next load (or cleared
			 * at reboot); a reader that opens it while audiofs
			 * is unloaded sees state_valid=0 and treats the
			 * subsystem as absent.
			 */
			r = malloc(sizeof(*r), M_AUDIOFS, M_WAITOK | M_ZERO);
			r->header.magic = AUDIOFS_STATE_MAGIC;
			r->header.version = AUDIOFS_STATE_VERSION;
			r->header.state_valid = 0;
			r->header.controller_slot_count =
			    AUDIOFS_STATE_CONTROLLER_SLOTS;
			r->header.endpoint_slot_count =
			    AUDIOFS_STATE_ENDPOINT_SLOTS;
			r->header.controller_slot_size =
			    (uint8_t)sizeof(struct audiofs_state_controller);
			r->header.endpoint_slot_size =
			    (uint8_t)sizeof(struct audiofs_state_endpoint);
			(void)vn_rdwr(UIO_WRITE, audiofs_state_vp, (void *)r,
			    (int)AUDIOFS_STATE_SIZE, (off_t)0, UIO_SYSSPACE,
			    IO_UNIT | IO_SYNC, NOCRED, NULL, NULL, td);
			free(r, M_AUDIOFS);
			audiofs_state_close_file(td);
		}
		/*
		 * F.2: close the events ring (invalidate-and-close,
		 * matching the state file) while still holding the sx,
		 * since it does VFS I/O.
		 */
		audiofs_events_close_file(curthread);
		/*
		 * F.4 (ADR 0018): unmap and close the clock. The file
		 * persists with its last values (clock_valid stays 1),
		 * unlike the state file's state_valid=0, per ADR 0003.
		 */
		audiofs_clock_close(curthread);
		audiofs_state_initialized = 0;
		sx_xunlock(&audiofs_state_sx);

		/*
		 * F.2: tear down the notify cdev after releasing the
		 * sx. Order matters (mirrors inputfs AD-41.3):
		 * destroy_dev first so no new open/poll/kqfilter can
		 * race, then seldrain to flush poll waiters, then
		 * knlist_destroy to tear down the kqueue note list.
		 */
		if (audiofs_notify_dev != NULL) {
			destroy_dev(audiofs_notify_dev);
			audiofs_notify_dev = NULL;
		}
		seldrain(&audiofs_notify_selinfo);
		knlist_destroy(&audiofs_notify_selinfo.si_note);

		sx_destroy(&audiofs_state_sx);
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

DRIVER_MODULE(audiofs, pci, audiofs_driver, audiofs_modevent, NULL);
MODULE_VERSION(audiofs, 1);
