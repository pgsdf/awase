# Semantic invariants

This document defines invariants that are always enforced by the semantic layer.
Backends must not violate these rules.

## Numeric validity

1. All Scalar values in commands must be finite.
2. NaN and Infinity are rejected at decode time.
3. Negative zero is permitted but should be normalized by encoders.

## Geometry

1. Rect width and height must be greater than or equal to zero.
2. A rect with zero width or zero height is a no op.
3. Coordinates are in logical units.

## State

1. The command stream is a fully specified program.
2. No implicit global state is allowed.
3. Default state is explicit at stream start or via RESET.

## Ordering and determinism

1. Commands execute in stream order.
2. If two operations overlap, later commands win under the defined blend mode.
3. Backends must produce results consistent with the reference renderer within defined tolerances.

## Clipping

1. Clip state is part of stream state.
2. Clip rects are in logical units.
3. Clip behavior is intersection based.

## Images

1. Image resources have stable identifiers within a stream scope.
2. Sampling defaults are explicitly defined in SDCS for each operation.
3. Color space conversions are explicit, not implicit.

## Text

1. Text drawing consumes glyph runs, not strings.
2. Shaping is external or performed by an optional shaping component.
3. Glyph run interpretation is deterministic given the same font and run data.


## Fractional coordinates

Coordinates may be fractional. Backends must define rounding rules via the reference renderer behavior.


## Clip rect lists

SET_CLIP_RECTS replaces the active clip list. The active clip list is applied as a union of clip rectangles for drawing operations.


## Transform state

SET_TRANSFORM_2D sets the current affine transform. The reference renderer applies the transform to geometry before rasterization. Clip rectangles are interpreted in the same logical coordinate space and therefore naturally interact with transformed geometry.


## Blend mode

SET_BLEND selects the blending operator for subsequent drawing. The reference renderer supports SrcOver (default), Src, Clear, and Add.


## Stroke

STROKE_RECT width is interpreted in user space. Geometry is transformed, then stroked using the specified width. The reference renderer decomposes a stroke into four filled edge rectangles.


## Stroke line

STROKE_LINE is a semantic line stroke with a width in user space. v1 requires axis aligned endpoints in user space.


## Stroke joins

Stroke join is explicit state. In v1 it affects consecutive axis aligned STROKE_LINE segments that connect at an endpoint.


## Stroke caps

Stroke cap is explicit state. In v1 it affects the ends of axis aligned STROKE_LINE segments that are not connected to a consecutive segment.


## Round cap

Round caps are rendered as a filled disk (or ellipse under affine transform) centered on each open stroke endpoint with radius stroke_width/2.
