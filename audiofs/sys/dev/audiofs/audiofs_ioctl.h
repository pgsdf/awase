/*
 * audiofs_ioctl.h - F.3.e format-negotiation ioctl ABI.
 *
 * Shared between the audiofs kernel module and userland
 * clients (semasound, test tools). Per ADR 0019, v1
 * negotiates sample rate only; bits and channels are fixed
 * at 16 / 2 and carried in the struct for forward
 * compatibility. Native-format-only per ADR 0007: a rate the
 * DAC does not advertise is rejected, not converted.
 */
#ifndef _AUDIOFS_IOCTL_H_
#define _AUDIOFS_IOCTL_H_

#ifdef _KERNEL
#include <sys/types.h>
#include <sys/ioccom.h>
#else
#include <stdint.h>
#include <sys/ioccom.h>
#endif

/* supported_rates bitmask values (GET_FORMAT). */
#define	AUDIOFS_RATE_32000	0x1
#define	AUDIOFS_RATE_44100	0x2
#define	AUDIOFS_RATE_48000	0x4

struct audiofs_format {
	uint32_t	rate_hz;		/* 32000 | 44100 | 48000        */
	uint16_t	format_word;		/* HDA SDnFMT word (GET only)    */
	uint8_t		bits;			/* 16 in v1                      */
	uint8_t		channels;		/* 2 in v1                       */
	uint32_t	supported_rates;	/* AUDIOFS_RATE_* mask (GET only)*/
};

#define	AUDIOFS_IOC_GET_FORMAT	_IOR('A', 1, struct audiofs_format)
#define	AUDIOFS_IOC_SET_FORMAT	_IOW('A', 2, struct audiofs_format)

#endif /* _AUDIOFS_IOCTL_H_ */
