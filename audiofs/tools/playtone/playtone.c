/*-
 * F.3.b/F.3.d bench-safety test program.
 *
 * Opens /dev/audiofs<N> (default /dev/audiofs0), writes
 * a quiet 750 Hz sine, closes, exits. The deliberately
 * bounded lifetime is the bench-safety gate from ADR 0015
 * Section "Bench-safety review": if anything goes wrong,
 * the audio stops when this program exits.
 *
 * F.3.d (ADR 0017) adds a --stall option: pause writing for
 * a specified duration after the first half of playback.
 * This forces an underrun by emptying the buffering between
 * userland and the DAC. Buffer sizing:
 *
 *   user ring:    32768 bytes = ~170 ms at 48k stereo 16-bit
 *   DMA buffer:    8192 bytes = ~43 ms
 *   total:        40960 bytes = ~213 ms
 *
 * Stalls shorter than ~220 ms will be absorbed by the
 * buffers and produce no underrun. Stalls of 300-500 ms
 * produce a brief underrun. Stalls of 1000+ ms produce a
 * sustained underrun and exercise the coalesced-event path.
 *
 * Build (on FreeBSD):
 *   make                                # uses the Makefile, links -lm
 *   cc -O2 -Wall -o playtone playtone.c -lm   # equivalent direct invocation
 *
 * Usage:
 *   ./playtone                          # 1 sec, no stall
 *   ./playtone /dev/audiofs0 2          # 2 sec, no stall
 *   ./playtone --stall 500              # 1 sec, 500 ms stall mid-way
 *   ./playtone --stall 1000 /dev/audiofs0 2
 *
 * Argument order: --stall <ms> may appear anywhere; the
 * remaining positional arguments are [device [seconds]] as
 * before.
 *
 * The sine is generated at amplitude 164 (~ -40 dBFS), the
 * same quiet level as the audiofs internal sine table per
 * the ADR 0014 amendment. Raise SINE_AMPLITUDE here if you
 * deliberately want louder; do not raise it unless you are
 * sure your bench environment is safe to be loud in.
 */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <err.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "audiofs_ioctl.h"	/* F.3.e: struct audiofs_format, AUDIOFS_IOC_* */

#define SAMPLE_RATE	48000
#define FRAME_BYTES	4		/* stereo 16-bit */
#define SINE_FREQ_HZ	750
#define SINE_AMPLITUDE	164		/* ~ -40 dBFS, deliberately quiet */
#define WRITE_CHUNK	4096		/* bytes per write(2) */

static void
usage(const char *prog)
{
	fprintf(stderr,
	    "usage: %s [--stall <ms>] [--setrate <hz>] [device [seconds]]\n"
	    "  --stall <ms>   pause writes for <ms> milliseconds\n"
	    "                 mid-way through playback to induce\n"
	    "                 an underrun (F.3.d bench test).\n"
	    "  --setrate <hz> SET_FORMAT to <hz> (32000|44100|48000)\n"
	    "                 mid-way through playback to reconfigure\n"
	    "                 the running stream (F.3.e bench test).\n"
	    "  --freq <hz>    tone frequency in Hz (default 750)\n"
	    "  --chunk <n>    bytes per write(2) (default 4096); probe for a\n"
	    "                 write/DMA-boundary artifact by sweeping this.\n"
	    "  --refout <f>   dump generated PCM to file f for ADR 0022\n"
	    "                 capture comparison (do not mix with --setrate).\n"
	    "  device         /dev/audiofs0 (default)\n"
	    "  seconds        total playback duration (default 1.0)\n"
	    "Stalls shorter than ~220 ms are absorbed by buffering\n"
	    "and produce no underrun. Stalls of 300+ ms produce a\n"
	    "brief underrun; 1000+ ms produces a sustained one.\n",
	    prog);
}

int
main(int argc, char **argv)
{
	const char *path = "/dev/audiofs0";
	double seconds = 1.0;
	int stall_ms = 0;
	int setrate = 0;	/* F.3.e: SET_FORMAT to this rate mid-stream */
	double freq_hz = SINE_FREQ_HZ;	/* tone frequency; override with --freq */
	int write_chunk = WRITE_CHUNK;	/* bytes per write(2); override with --chunk */
	const char *refout = NULL;	/* ADR 0022: dump generated PCM here */
	int fd;
	size_t total_frames, total_bytes, frames_written;
	size_t stall_at_bytes = 0;
	size_t setrate_at_bytes = 0;
	int stalled = 0;
	int set_done = 0;
	int16_t *samples;
	uint8_t *p;
	double phase, dphi;
	size_t i;
	int ai;
	int positional = 0;

	/*
	 * Parse argv. --stall <ms> can appear anywhere; remaining
	 * positionals are [device [seconds]] as in the original.
	 */
	for (ai = 1; ai < argc; ai++) {
		if (strcmp(argv[ai], "--stall") == 0) {
			if (ai + 1 >= argc) {
				fprintf(stderr,
				    "--stall requires a value in milliseconds\n");
				usage(argv[0]);
				return (2);
			}
			ai++;
			stall_ms = atoi(argv[ai]);
			if (stall_ms < 0 || stall_ms > 10000) {
				errx(2,
				    "--stall value must be in [0, 10000] ms");
			}
		} else if (strcmp(argv[ai], "--setrate") == 0) {
			if (ai + 1 >= argc) {
				fprintf(stderr,
				    "--setrate requires a rate in Hz\n");
				usage(argv[0]);
				return (2);
			}
			ai++;
			setrate = atoi(argv[ai]);
			if (setrate != 32000 && setrate != 44100 &&
			    setrate != 48000)
				errx(2,
				    "--setrate must be 32000, 44100, or 48000");
		} else if (strcmp(argv[ai], "--freq") == 0) {
			if (ai + 1 >= argc) {
				fprintf(stderr,
				    "--freq requires a frequency in Hz\n");
				usage(argv[0]);
				return (2);
			}
			ai++;
			freq_hz = strtod(argv[ai], NULL);
			if (freq_hz <= 0.0 || freq_hz > 20000.0)
				errx(2, "--freq must be in (0, 20000] Hz");
		} else if (strcmp(argv[ai], "--chunk") == 0) {
			if (ai + 1 >= argc) {
				fprintf(stderr,
				    "--chunk requires a size in bytes\n");
				usage(argv[0]);
				return (2);
			}
			ai++;
			write_chunk = atoi(argv[ai]);
			if (write_chunk < FRAME_BYTES ||
			    write_chunk > 262144 ||
			    (write_chunk % FRAME_BYTES) != 0)
				errx(2,
				    "--chunk must be a multiple of %d in [%d, 262144]",
				    FRAME_BYTES, FRAME_BYTES);
		} else if (strcmp(argv[ai], "--refout") == 0) {
			if (ai + 1 >= argc) {
				fprintf(stderr,
				    "--refout requires a file path\n");
				usage(argv[0]);
				return (2);
			}
			ai++;
			refout = argv[ai];
		} else if (strcmp(argv[ai], "--help") == 0 ||
		    strcmp(argv[ai], "-h") == 0) {
			usage(argv[0]);
			return (0);
		} else if (positional == 0) {
			path = argv[ai];
			positional++;
		} else if (positional == 1) {
			seconds = strtod(argv[ai], NULL);
			if (seconds <= 0.0 || seconds > 60.0)
				errx(2, "seconds must be in (0, 60]");
			positional++;
		} else {
			fprintf(stderr, "unexpected argument: %s\n",
			    argv[ai]);
			usage(argv[0]);
			return (2);
		}
	}

	total_frames = (size_t)(seconds * SAMPLE_RATE);
	total_bytes = total_frames * FRAME_BYTES;

	/*
	 * If --stall was set, pause halfway through. "Halfway" is
	 * a byte offset, not a wall-clock midpoint, so the stall
	 * always happens after the same number of samples have
	 * been queued regardless of how long the buffer takes to
	 * drain.
	 */
	if (stall_ms > 0)
		stall_at_bytes = (total_bytes / 2) &
		    ~(size_t)(FRAME_BYTES - 1);

	/*
	 * F.3.e: if --setrate was given, issue SET_FORMAT at the
	 * byte midpoint. Samples are generated at 48k phase
	 * throughout, so after the switch the second half plays
	 * at the new rate: a correctly working stream shifts the
	 * tone's pitch (e.g. 750 Hz -> ~689 Hz at 44.1k, 500 Hz
	 * at 32k), which is the audible proof the DAC rate
	 * changed. clock_dump should show the new sample_rate.
	 */
	if (setrate > 0)
		setrate_at_bytes = (total_bytes / 2) &
		    ~(size_t)(FRAME_BYTES - 1);

	samples = malloc(total_bytes);
	if (samples == NULL)
		err(1, "malloc %zu bytes", total_bytes);

	phase = 0.0;
	dphi = 2.0 * M_PI * freq_hz / SAMPLE_RATE;
	for (i = 0; i < total_frames; i++) {
		int16_t v = (int16_t)lround(SINE_AMPLITUDE * sin(phase));
		samples[2 * i]     = v;	/* left  */
		samples[2 * i + 1] = v;	/* right */
		phase += dphi;
		if (phase >= 2.0 * M_PI)
			phase -= 2.0 * M_PI;
	}

	/*
	 * ADR 0022 capture fork: dump the generated PCM to a file so
	 * it can be compared byte-for-byte against the kernel's
	 * capture_buf sysctl (the bytes the refill committed to the
	 * DMA buffer). A match exonerates the software path from the
	 * user ring down; a diff is the defect and its exact offset.
	 * Written before playback; only --setrate would later diverge
	 * the second half, so do not combine --refout with --setrate.
	 */
	if (refout != NULL) {
		int rfd = open(refout, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (rfd < 0)
			err(1, "open %s", refout);
		if (write(rfd, samples, total_bytes) !=
		    (ssize_t)total_bytes)
			err(1, "write %s", refout);
		(void)close(rfd);
		printf("playtone: wrote reference PCM (%zu bytes) to %s\n",
		    total_bytes, refout);
	}

	fd = open(path, O_WRONLY);
	if (fd < 0)
		err(1, "open %s", path);

	frames_written = 0;
	p = (uint8_t *)samples;
	while (frames_written < total_bytes) {
		size_t want = total_bytes - frames_written;
		ssize_t n;

		/*
		 * If we've reached the stall point and haven't
		 * stalled yet, pause now. usleep takes microseconds.
		 */
		if (!stalled && stall_at_bytes > 0 &&
		    frames_written >= stall_at_bytes) {
			printf("playtone: stalling for %d ms at offset "
			    "%zu / %zu bytes\n",
			    stall_ms, frames_written, total_bytes);
			fflush(stdout);
			(void)usleep((useconds_t)stall_ms * 1000);
			stalled = 1;
		}

		/* F.3.e: reconfigure the running stream mid-write. */
		if (!set_done && setrate_at_bytes > 0 &&
		    frames_written >= setrate_at_bytes) {
			struct audiofs_format f;

			memset(&f, 0, sizeof(f));
			f.rate_hz = (uint32_t)setrate;
			f.bits = 16;
			f.channels = 2;
			if (ioctl(fd, AUDIOFS_IOC_SET_FORMAT, &f) < 0)
				warn("AUDIOFS_IOC_SET_FORMAT %d", setrate);
			else
				printf("playtone: SET_FORMAT %d Hz at offset "
				    "%zu / %zu bytes\n", setrate,
				    frames_written, total_bytes);
			fflush(stdout);
			set_done = 1;
		}

		if (want > (size_t)write_chunk)
			want = (size_t)write_chunk;
		n = write(fd, p + frames_written, want);
		if (n < 0) {
			warn("write at offset %zu", frames_written);
			break;
		}
		frames_written += (size_t)n;
	}

	if (setrate > 0) {
		struct audiofs_format f;

		memset(&f, 0, sizeof(f));
		if (ioctl(fd, AUDIOFS_IOC_GET_FORMAT, &f) == 0)
			printf("playtone: GET_FORMAT after set: rate=%u "
			    "word=0x%04x bits=%u ch=%u supported=0x%x\n",
			    f.rate_hz, f.format_word, f.bits, f.channels,
			    f.supported_rates);
		else
			warn("AUDIOFS_IOC_GET_FORMAT");
	}

	(void)close(fd);
	free(samples);

	printf("playtone: %s wrote %zu / %zu bytes "
	    "(%.3f sec at %d Hz / 16 / stereo)",
	    path, frames_written, total_bytes,
	    (double)frames_written / FRAME_BYTES / SAMPLE_RATE,
	    SAMPLE_RATE);
	if (stall_ms > 0)
		printf(" [--stall %d ms applied]", stall_ms);
	printf("\n");

	return ((frames_written == total_bytes) ? 0 : 1);
}
