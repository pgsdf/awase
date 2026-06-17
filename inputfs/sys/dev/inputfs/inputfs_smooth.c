/*
 * inputfs_smooth.c: pointer smoothing algorithms (Q16.16 fixed point).
 *
 * Stage AD-2b step 2 (per
 * inputfs/docs/adr/0015-per-user-pointer-smoothing.md): three
 * smoothing algorithms (NONE, EMA, ONE_EURO) implemented as pure
 * functions over int32_t state.
 *
 * No FPU: per ADR 0015 §2, smoothing runs in inputfs's interrupt
 * path and introducing fpu_kern_enter/leave to that path is a
 * property someone reading the code in three years would have to
 * understand for an imperceptible precision win. All math is
 * Q16.16 with multiplications widened to int64_t to avoid
 * intermediate overflow.
 *
 * No softc dependencies: this file does not include sysctls,
 * mutexes, or device-tree handles. Callers (inputfs.c at stage 4)
 * own the state structures and arrange any locking around them.
 *
 * One-Euro is normatively defined by inputfs_smooth_apply_one_euro
 * in this file. The algorithm is *inspired by* the
 * Casiez/Roussel/Vogel One-Euro paper (Casiez, Roussel, Vogel,
 * "1€ Filter: A Simple Speed-based Low-pass Filter for Noisy
 * Input in Interactive Systems", CHI 2012) but is specified by
 * Awase in fixed-point; bit-for-bit equivalence with floating-point
 * One-Euro implementations is not a goal. Recordings made under
 * Awase replay identically against Awase.
 */

#ifdef _KERNEL
#include <sys/param.h>
#include <sys/systm.h>
#else
#include <stdint.h>
#include <string.h>
#endif

#include "inputfs_smooth.h"

/*
 * Q16.16 representation of 2π. 2π = 6.28318530717958647...
 * Multiplied by 65536 and rounded to the nearest integer:
 *   round(6.28318530717958647 * 65536) = 411774.78... → 411775 = 0x6487F.
 * Stored as int32_t for type uniformity; well within i32 range.
 *
 * This is the only transcendental constant in the algorithm. Awase
 * One-Euro's normative behaviour is defined relative to this
 * specific Q16.16 approximation; any future change to TWO_PI_Q16
 * is a behaviour change and would invalidate captured replay
 * recordings.
 */
#define TWO_PI_Q16  ((int32_t)0x6487F)  /* 411775 ≈ 2π × 65536 */

/* ============================================================
 * Reset
 * ============================================================ */

void
inputfs_smooth_ema_reset(struct inputfs_smooth_ema_state *s)
{
	if (s == NULL)
		return;
	s->prev = 0;
	s->initialised = 0;
}

void
inputfs_smooth_one_euro_reset(struct inputfs_smooth_one_euro_state *s)
{
	if (s == NULL)
		return;
	s->prev_x = 0;
	s->prev_dx = 0;
	s->prev_us = 0;
	s->initialised = 0;
}

/* ============================================================
 * Helpers
 * ============================================================ */

/*
 * Clamp alpha to [INPUTFS_SMOOTH_EMA_ALPHA_MIN,
 * INPUTFS_SMOOTH_EMA_ALPHA_MAX]. Defence in depth: the spec
 * requires the writer (semadrawd) to range-check before
 * publishing, but the kernel must not blow up if it doesn't.
 */
static int32_t
clamp_alpha(int32_t alpha)
{
	if (alpha < INPUTFS_SMOOTH_EMA_ALPHA_MIN)
		return ((int32_t)INPUTFS_SMOOTH_EMA_ALPHA_MIN);
	if (alpha > INPUTFS_SMOOTH_EMA_ALPHA_MAX)
		return ((int32_t)INPUTFS_SMOOTH_EMA_ALPHA_MAX);
	return (alpha);
}

/*
 * Multiply two Q16.16 values, returning the Q16.16 product.
 *   (a_q16 * b_q16) / Q16_ONE = ((a * b) >> 16)
 * widened to int64_t to avoid intermediate overflow.
 */
static int32_t
q16_mul(int32_t a, int32_t b)
{
	int64_t prod;

	prod = (int64_t)a * (int64_t)b;
	return ((int32_t)(prod >> 16));
}

/*
 * EMA recurrence per shared/INPUT_SMOOTHING.md:
 *
 *   out = (alpha * in + (Q16_ONE - alpha) * prev_out) >> 16
 *   prev_out := out
 *
 * Here `in` and `prev_out` are integer pixel coordinates, and
 * `alpha` is Q16.16. The multiplications widen to int64_t. The
 * single `>> 16` at the end reduces the Q16.16-scaled sum back
 * to integer pixels. `prev_out` storage is integer pixels per
 * spec; sub-pixel state is not retained between samples.
 *
 * Inputs and output are integer pixels, not Q16.16. Caller does
 * the parameter clamping; this helper does the math.
 */
static int32_t
ema_q16(int32_t alpha, int32_t in_px, int32_t prev_px)
{
	int64_t a, in_a, one_minus_a, prev_b, sum;

	a = (int64_t)alpha;
	in_a = a * (int64_t)in_px;
	one_minus_a = (int64_t)INPUTFS_SMOOTH_Q16_ONE - a;
	prev_b = one_minus_a * (int64_t)prev_px;
	sum = in_a + prev_b;
	return ((int32_t)(sum >> 16));
}

/*
 * Compute the One-Euro alpha for a given cutoff (Hz, Q16.16) and
 * sample interval (microseconds). Returns Q16.16 alpha, clamped
 * to [INPUTFS_SMOOTH_EMA_ALPHA_MIN, INPUTFS_SMOOTH_EMA_ALPHA_MAX]
 * to avoid pathological behaviour at extreme dt or cutoff.
 *
 * Derivation (floating-point reference):
 *   tau = 1 / (2π × cutoff_hz)
 *   alpha = 1 / (1 + tau / dt_seconds)
 *         = (2π × cutoff_hz × dt_seconds) / (1 + 2π × cutoff_hz × dt_seconds)
 *
 * Let k = 2π × cutoff_hz × dt_seconds; then alpha = k / (k + 1).
 *
 * In Q16.16:
 *   k_q16 = TWO_PI_Q16 × cutoff_q16 × dt_us / (Q16_ONE × 1_000_000)
 *
 * Numerator widened to int64_t. With cutoff up to 1000 Hz
 * (cutoff_q16 ≈ 6.55e7) and dt up to ~10 seconds (dt_us = 1e7),
 * the intermediate before the divide reaches:
 *   TWO_PI_Q16 × cutoff_q16 × dt_us
 *     ≈ 4.1e5 × 6.55e7 × 1e7 = 2.7e20
 * which overflows int64_t (max ~9.2e18). To stay safe over the
 * full range, divide by 1_000_000 (the dt-to-seconds factor)
 * before multiplying by TWO_PI_Q16:
 *
 *   k_q16 = (cutoff_q16 × dt_us / 1_000_000) × TWO_PI_Q16 / Q16_ONE
 *
 * which reorders to keep intermediates below 2^62 across the
 * design range. See guard against dt_us = 0 in the caller.
 */
static int32_t
one_euro_alpha(int32_t cutoff_q16, int64_t dt_us)
{
	int64_t k_step1, k_q16, alpha_q16;

	if (cutoff_q16 < 1)
		cutoff_q16 = 1;          /* defence in depth */
	if (dt_us < 1)
		dt_us = 1;

	/*
	 * Step 1: cutoff_q16 × dt_us. cutoff_q16 fits in 32 bits;
	 * dt_us up to ~9.2e18. For sane pointer rates the product
	 * is a few-times-1e10 to 1e15, well under int64_t max.
	 */
	k_step1 = (int64_t)cutoff_q16 * dt_us;

	/*
	 * Step 2: divide by 1_000_000 (microseconds to seconds).
	 * k_step1 / 1_000_000 yields cutoff_hz × dt_seconds in
	 * Q16.16. Could be zero if cutoff is small and dt small
	 * (e.g. cutoff_q16 = 1, dt_us = 1: product = 1, divides
	 * to 0). Allow zero through; subsequent multiply just
	 * yields zero alpha which then clamps to the floor.
	 */
	k_step1 /= 1000000LL;

	/*
	 * Step 3: multiply by TWO_PI_Q16, then divide by Q16_ONE
	 * to remove one of the Q16.16 factors. Result is Q16.16
	 * representation of k = 2π × cutoff × dt_seconds.
	 */
	k_q16 = (k_step1 * (int64_t)TWO_PI_Q16) / (int64_t)INPUTFS_SMOOTH_Q16_ONE;

	if (k_q16 < 1)
		k_q16 = 1;               /* avoid alpha = 0 / 1 = 0 */

	/*
	 * Step 4: alpha_q16 = k_q16 × Q16_ONE / (k_q16 + Q16_ONE)
	 * = k / (k + 1) in Q16.16.
	 *
	 * The numerator k_q16 × Q16_ONE: at the upper end of
	 * sensible inputs k_q16 reaches ~1e10, so the numerator
	 * reaches ~6.5e14. Safely in int64_t.
	 */
	alpha_q16 = (k_q16 * (int64_t)INPUTFS_SMOOTH_Q16_ONE) /
	    (k_q16 + (int64_t)INPUTFS_SMOOTH_Q16_ONE);

	/* Clamp to the EMA-valid range so downstream code can
	 * assume any alpha here passes the same checks. */
	if (alpha_q16 < (int64_t)INPUTFS_SMOOTH_EMA_ALPHA_MIN)
		alpha_q16 = (int64_t)INPUTFS_SMOOTH_EMA_ALPHA_MIN;
	if (alpha_q16 > (int64_t)INPUTFS_SMOOTH_EMA_ALPHA_MAX)
		alpha_q16 = (int64_t)INPUTFS_SMOOTH_EMA_ALPHA_MAX;

	return ((int32_t)alpha_q16);
}

/* ============================================================
 * EMA
 * ============================================================ */

int32_t
inputfs_smooth_apply_ema(int32_t alpha, int32_t in_px,
    struct inputfs_smooth_ema_state *state)
{
	int32_t out_px, alpha_clamped;

	if (state == NULL)
		return (in_px);

	if (!state->initialised) {
		/* First sample: seed prev with the input pixel and
		 * return the input unchanged. No smoothing on the
		 * first sample (no history to smooth against). */
		state->prev = in_px;
		state->initialised = 1;
		return (in_px);
	}

	alpha_clamped = clamp_alpha(alpha);
	out_px = ema_q16(alpha_clamped, in_px, state->prev);
	state->prev = out_px;
	return (out_px);
}

/* ============================================================
 * One-Euro
 * ============================================================ */

int32_t
inputfs_smooth_apply_one_euro(int32_t min_cutoff, int32_t beta,
    int32_t d_cutoff, int32_t in_px, int64_t t_us,
    struct inputfs_smooth_one_euro_state *state)
{
	int32_t in_q16, raw_dx_q16, smoothed_dx_q16, abs_dx_q16;
	int32_t cutoff_q16, alpha_q16, d_alpha_q16, out_q16;
	int64_t dt_us, raw_dx_wide;

	if (state == NULL)
		return (in_px);

	/* Defence in depth: clamp parameters to sensible ranges
	 * so downstream arithmetic doesn't trip on absurd values
	 * even if the writer publishes them. */
	if (min_cutoff < 1)
		min_cutoff = 1;
	if (beta < 0)
		beta = 0;
	if (d_cutoff < 1)
		d_cutoff = 1;

	in_q16 = in_px << 16;

	if (!state->initialised) {
		state->prev_x = in_q16;
		state->prev_dx = 0;
		state->prev_us = t_us;
		state->initialised = 1;
		return (in_px);
	}

	dt_us = t_us - state->prev_us;
	if (dt_us < 1)
		dt_us = 1;  /* defensive: equal or out-of-order timestamps */

	/*
	 * Raw derivative in Q16.16 px/s. Computed as
	 *   raw_dx_q16 = (in_q16 - prev_x) × 1_000_000 / dt_us
	 * widened to i64 for the multiply so the units carry
	 * through cleanly without losing precision when dt_us is
	 * large.
	 *
	 * The intermediate (in_q16 - prev_x) × 1_000_000:
	 *   in_q16 - prev_x is at most ~Q16.16 of 32K pixels
	 *   = 2.1e9 in magnitude. × 1e6 = 2.1e15. Fits in i64.
	 */
	raw_dx_wide = ((int64_t)(in_q16 - state->prev_x) * 1000000LL) /
	    dt_us;
	/* Clamp to int32_t range. Using literal hex bounds rather
	 * than INT32_MIN/INT32_MAX for kernel-header portability;
	 * sys/stdint.h does define these macros but inputfs's
	 * existing kernel code does not depend on them, so we
	 * keep this self-contained. */
	if (raw_dx_wide > 0x7FFFFFFFLL)
		raw_dx_wide = 0x7FFFFFFFLL;
	if (raw_dx_wide < -0x80000000LL)
		raw_dx_wide = -0x80000000LL;
	raw_dx_q16 = (int32_t)raw_dx_wide;

	/* Smooth the derivative with d_cutoff. */
	d_alpha_q16 = one_euro_alpha(d_cutoff, dt_us);
	smoothed_dx_q16 = ema_q16(d_alpha_q16, raw_dx_q16, state->prev_dx);

	/*
	 * Adaptive cutoff: cutoff_q16 = min_cutoff + beta × |dx_q16|
	 *
	 * |dx_q16| is in Q16.16 px/s. beta × |dx_q16|
	 * (Q16.16 multiply via q16_mul) is in Q16.16 (Hz × px/s
	 * with beta carrying the implicit "Hz per px/s" units).
	 *
	 * Use the absolute value in pixel-space rather than the
	 * signed Q16.16 derivative; sign is irrelevant to "how
	 * fast the cursor is moving."
	 *
	 * Negation of INT32_MIN would overflow; clamp first to
	 * stay within well-defined behaviour. raw_dx is already
	 * clamped to (-0x80000000, 0x7FFFFFFF] above by the i64
	 * widening, but ema_q16 of clamped inputs stays in i32
	 * range without an explicit guard, so a defensive clamp
	 * on the post-EMA dx costs nothing.
	 */
	if (smoothed_dx_q16 == (int32_t)(-0x80000000LL))
		smoothed_dx_q16 = -0x7FFFFFFF;
	abs_dx_q16 = (smoothed_dx_q16 < 0) ?
	    -smoothed_dx_q16 : smoothed_dx_q16;
	cutoff_q16 = min_cutoff + q16_mul(beta, abs_dx_q16);
	if (cutoff_q16 < 1)
		cutoff_q16 = 1;

	/* Final alpha and apply. */
	alpha_q16 = one_euro_alpha(cutoff_q16, dt_us);
	out_q16 = ema_q16(alpha_q16, in_q16, state->prev_x);

	/* Persist state for the next sample. */
	state->prev_x = out_q16;
	state->prev_dx = smoothed_dx_q16;
	state->prev_us = t_us;

	return ((int32_t)(out_q16 >> 16));
}
