/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * clock_dump: read and decode /var/run/sema/clock (the audio
 * clock region, ADR 0003 / shared/CLOCK.md). Bench-safety and
 * diagnostic tool for F.4 (ADR 0018), which moves the clock
 * writer from semaaud into audiofs.
 *
 * Usage:
 *   clock_dump [-p path] [count [interval_ms]]
 *
 * One-shot by default. With count > 1 it samples the region that
 * many times at interval_ms (default 200), which is how the F.4
 * bench plan checks monotonic advance during a playtone run and
 * across a stop/start cycle.
 *
 * Read-only: opens the file O_RDONLY and maps it MAP_SHARED so a
 * live sample reflects the kernel writer's current value. The
 * samples_written field is read with a single 64-bit load, the
 * same shape the production reader uses, so a live sample is not
 * torn by a concurrent writer.
 *
 * Copyright (c) 2026 PGSDF
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/endian.h>

#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define	CLOCK_PATH_DEFAULT	"/var/run/sema/clock"
#define	CLOCK_SIZE		20
#define	CLOCK_MAGIC		0x534D434Bu	/* "SMCK" */

#define	OFF_MAGIC	0
#define	OFF_VERSION	4
#define	OFF_VALID	5
#define	OFF_SOURCE	6
#define	OFF_PAD		7
#define	OFF_RATE	8
#define	OFF_SAMPLES	12

static const char *
source_name(uint8_t s)
{

	switch (s) {
	case 0:
		return ("invalid");
	case 1:
		return ("audio");
	case 2:
		return ("wall(reserved)");
	case 3:
		return ("tsc(reserved)");
	default:
		return ("unknown");
	}
}

static void
dump_once(const volatile uint8_t *m)
{
	char magstr[5];
	uint64_t samples;
	uint32_t magic, rate;
	uint8_t version, valid, source;

	magic = le32dec((const void *)(m + OFF_MAGIC));
	version = m[OFF_VERSION];
	valid = m[OFF_VALID];
	source = m[OFF_SOURCE];
	rate = le32dec((const void *)(m + OFF_RATE));
	/* Single 64-bit read of the hot field (amd64: atomic within line). */
	samples = le64toh(*(const volatile uint64_t *)(m + OFF_SAMPLES));

	/* Mnemonic is the u32 read high byte first: 0x534D434B -> "SMCK". */
	magstr[0] = (char)((magic >> 24) & 0xff);
	magstr[1] = (char)((magic >> 16) & 0xff);
	magstr[2] = (char)((magic >> 8) & 0xff);
	magstr[3] = (char)(magic & 0xff);
	magstr[4] = '\0';

	if (magic != CLOCK_MAGIC) {
		printf("magic=0x%08x (BAD, expected SMCK); region not a "
		    "valid clock\n", magic);
		return;
	}

	printf("magic=%s version=%u clock_valid=%u clock_source=%u(%s) "
	    "sample_rate=%u samples_written=%llu", magstr, version, valid,
	    source, source_name(source), rate,
	    (unsigned long long)samples);
	if (valid && rate != 0)
		printf(" t=%.6f s", (double)samples / (double)rate);
	printf("\n");
}

int
main(int argc, char **argv)
{
	struct stat sb;
	struct timespec ts;
	void *map;
	const char *path = CLOCK_PATH_DEFAULT;
	long count = 1, interval_ms = 200, i;
	int fd, ch;

	while ((ch = getopt(argc, argv, "p:")) != -1) {
		switch (ch) {
		case 'p':
			path = optarg;
			break;
		default:
			fprintf(stderr, "usage: clock_dump [-p path] "
			    "[count [interval_ms]]\n");
			return (2);
		}
	}
	argc -= optind;
	argv += optind;
	if (argc >= 1)
		count = strtol(argv[0], NULL, 10);
	if (argc >= 2)
		interval_ms = strtol(argv[1], NULL, 10);
	if (count < 1)
		count = 1;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		err(1, "open %s", path);
	if (fstat(fd, &sb) != 0)
		err(1, "fstat %s", path);
	if (sb.st_size < CLOCK_SIZE)
		errx(1, "%s is %jd bytes, expected at least %d "
		    "(writer not active?)", path, (intmax_t)sb.st_size,
		    CLOCK_SIZE);

	map = mmap(NULL, CLOCK_SIZE, PROT_READ, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED)
		err(1, "mmap %s", path);

	for (i = 0; i < count; i++) {
		dump_once((const volatile uint8_t *)map);
		if (i + 1 < count && interval_ms > 0) {
			ts.tv_sec = interval_ms / 1000;
			ts.tv_nsec = (interval_ms % 1000) * 1000000L;
			(void)nanosleep(&ts, NULL);
		}
	}

	(void)munmap(map, CLOCK_SIZE);
	(void)close(fd);
	return (0);
}
