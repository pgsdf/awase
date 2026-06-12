# Gesture layer

The recogniser logic described here lives in
`semainput/libsemainput/libsemainput.zig` (extracted from the
retired `semainputd` daemon during AD-2a Phase 2.3,
2026-04). The improvements below refer to versions from before
the daemon retirement (2026-05-08); the *behaviours* are
preserved in libsemainput and consumed by semadrawd via
build.zig addImport.

## v41 pinch scale factor

### Problem

The pinch `delta` field was computed as `(cur_dist² - prev_dist²) / 128`, an
approximation that did not correspond to any standard gesture API contract.
The `scale_hint` field (`"in"` or `"out"`) provided direction but no magnitude
usable by applications implementing pinch-to-zoom.

### Change

`delta` became the difference of Euclidean finger separations:
`sqrt(cur_dist²) - sqrt(prev_dist²)`. This is a calibrated pixel-distance
value rather than an arbitrary scaled squared-distance difference.

A `scale_factor` field was added to `pinch_begin` and `pinch` events. It is
the ratio of current to previous finger separation: `sqrt(cur_dist²) /
sqrt(prev_dist²)`. Values above 1.0 indicate spreading (zoom in); values
below 1.0 indicate pinching (zoom out). The initial value on `pinch_begin`
reflects the ratio at activation, not a fixed 1.0, so applications see the
correct magnitude from the first event.

`scale_factor` is rendered as a fixed-point decimal with 4 places
(`1.0500` = 5% larger) to avoid locale-dependent float formatting. It is
clamped to `[0.01, 99.99]` to guarantee finite, positive output even when
`prev_dist` is near zero.

The earlier `delta` and `scale_hint` fields are retained for backward
compatibility with consumers that integrated against them.

### Result

Applications can implement pinch-to-zoom by accumulating `scale_factor`
values:

```
zoom *= event.scale_factor
```

---

## v40 three-finger activation fix

### Problem

v39 could miss promotion when the cumulative anchor was initialised too
late in the update path.

### Change

The arbitration anchor is captured immediately when three-finger arbitration
begins. Activation still uses cumulative centroid displacement, but now
from the correct start point.

### Result

This improved:

- reliable three-finger activation on smooth hardware
- clean separation between activation and post-lock smoothing
