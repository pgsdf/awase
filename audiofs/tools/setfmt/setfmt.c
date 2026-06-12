/*-
 * SPDX-License-Identifier: MIT
 *
 * setfmt: F.3.e (ADR 0019) format-ioctl exerciser.
 *
 * Issues AUDIOFS_IOC_GET_FORMAT / AUDIOFS_IOC_SET_FORMAT on
 * /dev/audiofs<N> without writing audio. It covers the closure
 * criteria that exercise only the ioctl path and that playtone
 * cannot reach because playtone validates its --setrate value
 * client-side:
 *
 *   - criterion 1: current-format query and supported-rate mask
 *   - criterion 5: no-op SET (rate already current)
 *   - criterion 6: EINVAL on an unadvertised rate, a non-16-bit
 *     request, or a non-stereo request, with the stream left
 *     unchanged
 *
 * Opening the device starts a stream at the 48 kHz default
 * (F.3.b); this tool issues the ioctl(s) and exits, so any audio
 * is bounded to the run, the same bench-safety property playtone
 * relies on.
 *
 * Usage:
 *   setfmt [device]                       GET only
 *   setfmt [device] <rate>                SET rate (16-bit stereo), then GET
 *   setfmt [device] <rate> <bits> <ch>    SET raw values, then GET
 *                                         (use to drive the EINVAL paths)
 *   setfmt --seq [device] <r1> <r2> ...   open once, SET each rate (16-bit
 *                                         stereo) in turn with a GET and a
 *                                         1 s dwell between, so a single open
 *                                         cycles e.g. 44100 48000 32000. This
 *                                         is the only way to reconfigure back
 *                                         to 48000 from another rate, since a
 *                                         fresh open starts at the 48k default
 *                                         (ADR 0019 Decision 5).
 *
 * device defaults to /dev/audiofs0. Any argument beginning with
 * '/' is taken as the device; numeric arguments are rate, then
 * bits, then channels (single-shot mode), or the rate sequence
 * (after --seq).
 *
 * Copyright (c) 2026 Pacific Geoscience Systems Development Foundation
 */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "audiofs_ioctl.h"

static void
print_format(const char *tag, const struct audiofs_format *f)
{
	printf("%s: rate=%u word=0x%04x bits=%u ch=%u supported=0x%x",
	    tag, f->rate_hz, f->format_word, f->bits, f->channels,
	    f->supported_rates);
	if (f->supported_rates) {
		printf(" (");
		if (f->supported_rates & AUDIOFS_RATE_32000)
			printf("32000 ");
		if (f->supported_rates & AUDIOFS_RATE_44100)
			printf("44100 ");
		if (f->supported_rates & AUDIOFS_RATE_48000)
			printf("48000 ");
		printf(")");
	}
	printf("\n");
}

static void
do_get(int fd)
{
	struct audiofs_format f;

	memset(&f, 0, sizeof(f));
	if (ioctl(fd, AUDIOFS_IOC_GET_FORMAT, &f) < 0)
		warn("AUDIOFS_IOC_GET_FORMAT");
	else
		print_format("GET_FORMAT", &f);
}

static void
do_set(int fd, uint32_t rate, uint8_t bits, uint8_t ch)
{
	struct audiofs_format f;

	memset(&f, 0, sizeof(f));
	f.rate_hz = rate;
	f.bits = bits;
	f.channels = ch;
	printf("SET_FORMAT: rate=%u bits=%u ch=%u ... ", rate, bits, ch);
	if (ioctl(fd, AUDIOFS_IOC_SET_FORMAT, &f) < 0)
		printf("errno=%d (%s)\n", errno, strerror(errno));
	else
		printf("ok\n");
}

int
main(int argc, char **argv)
{
	const char *path = "/dev/audiofs0";
	long nums[3];
	int nnum = 0;
	int seq = 0;
	int fd, ai;

	for (ai = 1; ai < argc; ai++) {
		if (strcmp(argv[ai], "--seq") == 0) {
			seq = 1;
		} else if (argv[ai][0] == '/') {
			path = argv[ai];
		} else if (seq) {
			/* In --seq mode every remaining number is a rate;
			 * collect them lazily below by re-scanning argv. */
			continue;
		} else if (nnum < 3) {
			char *end;
			nums[nnum++] = strtol(argv[ai], &end, 10);
			if (*end != '\0')
				errx(2, "bad numeric argument: %s", argv[ai]);
		} else {
			errx(2, "too many arguments");
		}
	}

	fd = open(path, O_WRONLY);
	if (fd < 0)
		err(1, "open %s", path);

	if (seq) {
		int first = 1;

		for (ai = 1; ai < argc; ai++) {
			char *end;
			long r;

			if (strcmp(argv[ai], "--seq") == 0 ||
			    argv[ai][0] == '/')
				continue;
			r = strtol(argv[ai], &end, 10);
			if (*end != '\0')
				errx(2, "bad rate: %s", argv[ai]);
			if (!first)
				(void)sleep(1);
			first = 0;
			do_set(fd, (uint32_t)r, 16, 2);
			do_get(fd);
		}
		if (first)
			do_get(fd);	/* --seq with no rates: just GET */
	} else {
		if (nnum >= 1)
			do_set(fd, (uint32_t)nums[0],
			    (uint8_t)(nnum >= 2 ? nums[1] : 16),
			    (uint8_t)(nnum >= 3 ? nums[2] : 2));
		do_get(fd);
	}

	(void)close(fd);
	return (0);
}
