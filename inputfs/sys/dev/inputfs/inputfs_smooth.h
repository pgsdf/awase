/*
 * inputfs_smooth.h: pointer smoothing surface declarations.
 *
 * Stage AD-2b step 2 (per
 * inputfs/docs/adr/0015-per-user-pointer-smoothing.md): fixed-point
 * pointer smoothing algorithms (NONE, EMA, ONE_EURO) implemented
 * in pure C, separated from inputfs.c so they are exercisable in
 * isolation and the algorithm code is small enough to read in
 * one sitting.
 *
 * Q16.16 fixed-point throughout. No FPU use; algorithms run in
 * inputfs's interrupt path. Multiplications widen to int64_t to
 * avoid intermediate overflow.
 *
 * The functions here are pure: they take their state by pointer
 * and never touch globals, sysctls, mutexes, or device-tree
 * handles. Callers (inputfs.c) own the state structures and
 * arrange seqlock / spin-lock protection around each call.
 *
 * Unit conventions:
 *   - Coordinates are int32_t pixels (compositor-space, after
 *     the D.3 transform clamp).
 *   - Q16.16 parameters are int32_t with the integer part in the
 *     upper 16 bits and the fractional part in the lower 16 bits.
 *   - Time is int64_t microseconds, monotonically increasing.
 *     Only differences matter; the epoch is opaque to the
 *     algorithm. Callers (stage 4) populate this from a
 *     monotonic kernel time source.
 *
 * One-Euro is normatively defined by inputfs_smooth_apply_one_euro
 * in inputfs_smooth.c. The implementation is inspired by the
 * Casiez/Roussel/Vogel paper but is specified by Awase in fixed
 * point; bit-for-bit equivalence with floating-point One-Euro
 * implementations is not a goal.
 */

#ifndef _INPUTFS_SMOOTH_H_
#define _INPUTFS_SMOOTH_H_

#ifdef _KERNEL
#include <sys/types.h>
#else
#include <stdint.h>
#endif

/*
 * Algorithm enum values. Match shared/INPUT_SMOOTHING.md and the
 * Zig SMOOTHING_NONE / EMA / ONE_EURO constants in
 * shared/src/input.zig.
 */
#define INPUTFS_SMOOTH_NONE      0u
#define INPUTFS_SMOOTH_EMA       1u
#define INPUTFS_SMOOTH_ONE_EURO  2u

/* Q16.16 representation of 1.0. */
#define INPUTFS_SMOOTH_Q16_ONE   0x10000

/*
 * EMA valid alpha range. The applier clamps to this range as
 * defence in depth; the writer (semadrawd) is expected to
 * range-check before publishing.
 */
#define INPUTFS_SMOOTH_EMA_ALPHA_MIN  0x00CC  /* ~0.005 */
#define INPUTFS_SMOOTH_EMA_ALPHA_MAX  0xFF34  /* ~0.997 */

/*
 * Per-axis EMA state.
 *
 * `prev` holds the previous smoothed output as integer pixels
 * (per the recurrence in shared/INPUT_SMOOTHING.md, which uses
 * a single >>16 reduction at the end and stores pixel-space
 * prev_out between samples). `initialised` is 0 until the first
 * sample arrives; the first sample seeds prev and is returned
 * unchanged.
 *
 * Two of these (one per axis) live as file-static globals in
 * inputfs.c per stage 4. Cleared by memset on module load and
 * on validity transitions of the smoothing region.
 */
struct inputfs_smooth_ema_state {
	int32_t  prev;          /* previous smoothed pixel value */
	int      initialised;
};

/*
 * Per-axis One-Euro state.
 *
 * `prev_x` holds the previous smoothed signal output, Q16.16.
 * `prev_dx` holds the previous smoothed derivative, Q16.16.
 * `prev_us` holds the timestamp of the previous sample in
 * microseconds; used to compute the sample interval.
 * `initialised` is 0 until the first sample arrives.
 *
 * Same lifecycle as inputfs_smooth_ema_state.
 */
struct inputfs_smooth_one_euro_state {
	int32_t  prev_x;        /* Q16.16 previous smoothed signal */
	int32_t  prev_dx;       /* Q16.16 previous smoothed derivative */
	int64_t  prev_us;       /* timestamp (microseconds) */
	int      initialised;
};

/*
 * Reset state structures. Equivalent to a memset to zero. The
 * state types are defined in this header so callers can include
 * them by value; reset functions are provided so future fields
 * (extra accumulators, lazy-init markers) can be added without
 * source changes elsewhere.
 */
void inputfs_smooth_ema_reset(struct inputfs_smooth_ema_state *s);
void inputfs_smooth_one_euro_reset(struct inputfs_smooth_one_euro_state *s);

/*
 * Apply EMA to a single axis sample.
 *
 *   alpha:  Q16.16 smoothing factor; clamped to
 *           [INPUTFS_SMOOTH_EMA_ALPHA_MIN, INPUTFS_SMOOTH_EMA_ALPHA_MAX].
 *   in_px:  raw input coordinate in pixels (int32_t).
 *   state:  per-axis state. On first call, state must be
 *           memset(0)-equivalent; the function seeds prev from
 *           in_px and returns in_px unchanged.
 *
 * Returns the smoothed coordinate in pixels (int32_t).
 *
 * Recurrence: out_q16 = (alpha * in_q16 + (Q16_ONE - alpha) * prev_q16) >> 16
 * Multiplications widen to int64_t to avoid overflow.
 */
int32_t inputfs_smooth_apply_ema(int32_t alpha, int32_t in_px,
    struct inputfs_smooth_ema_state *state);

/*
 * Apply One-Euro to a single axis sample.
 *
 *   min_cutoff: Q16.16 minimum cutoff frequency in Hz. Clamped to
 *               > 0 (treated as 1 LSB if zero or negative).
 *   beta:       Q16.16 speed coefficient. Clamped to >= 0 (negative
 *               makes the cutoff decrease with speed, which is the
 *               opposite of what One-Euro intends).
 *   d_cutoff:   Q16.16 derivative cutoff in Hz. Clamped to > 0.
 *   in_px:      raw input coordinate in pixels (int32_t).
 *   t_us:       sample timestamp in microseconds (monotonic).
 *   state:      per-axis state. On first call, state must be
 *               memset(0)-equivalent; the function seeds the state
 *               from in_px and t_us and returns in_px unchanged.
 *
 * Returns the smoothed coordinate in pixels (int32_t).
 *
 * Algorithm (Awase specification):
 *   1. dt = (t_us - prev_us) microseconds. If dt <= 0, treated
 *      as 1 microsecond (defensive against equal or out-of-order
 *      timestamps).
 *   2. raw_dx = (in_q16 - prev_x) / dt_seconds  (units: Q16.16 px/s)
 *   3. d_alpha = inputfs_smooth_alpha(d_cutoff, dt)
 *   4. smoothed_dx = ema(raw_dx, prev_dx, d_alpha)
 *   5. cutoff = min_cutoff + beta * abs(smoothed_dx)
 *   6. alpha = inputfs_smooth_alpha(cutoff, dt)
 *   7. out = ema(in_q16, prev_x, alpha)
 *
 * inputfs_smooth_alpha(cutoff_hz_q16, dt_us) = Q16_ONE /
 *   (Q16_ONE + ((Q16_ONE / (TWO_PI * cutoff_hz)) * (1e6 / dt_us)))
 * computed in Q16.16, with all intermediates widened to int64_t.
 * Detailed comments at the implementation site.
 */
int32_t inputfs_smooth_apply_one_euro(int32_t min_cutoff, int32_t beta,
    int32_t d_cutoff, int32_t in_px, int64_t t_us,
    struct inputfs_smooth_one_euro_state *state);

#endif /* _INPUTFS_SMOOTH_H_ */
