# ADR 0001 amendment: process-input ownership includes environment access

Status: Proposed (operator ratification pending green bench)
Date: 2026-06-15
Amends: ADR 0001 (compatibility boundary), Decision on process-input ownership

## Context

ADR 0001 established the compatibility boundary and assigned command-line
argument acquisition to an owned surface (compat.args), on the rationale that
Zig 0.16 reshaped how a process receives its startup inputs and that call sites
should not track that churn directly.

Zig 0.16 also removed std.posix.getenv. Environment variables are the second
process-input channel alongside argv. The semasound migration surfaced three
direct std.posix.getenv call sites (estimator, predictor, estimator_thread)
that the original removed-surface inventory did not anticipate, because env
access was not one of the migration's named classes.

Resolving each site with a file-local std.c.getenv wrapper would scatter raw
libc environment details across consumer files, which is precisely the
toolchain volatility the boundary exists to absorb. It would also leave the
next subproject to rediscover the same libc details.

## Decision

Process-input ownership under ADR 0001 covers both process-startup input
channels, not argv alone:

> compat.args owns command-line argument acquisition and environment-variable
> acquisition. Call sites must not reach directly into std.c.getenv or other
> process-environment APIs.

This is a narrow extension of an established boundary, not a new boundary, so it
is recorded as an amendment rather than a separate ADR. No new module is
introduced: environment acquisition lives in compat.args beside argument
acquisition, behind one owned surface for all process-startup inputs.

## Surface

    compat.args.getenv(name: []const u8) ?[]const u8

Returns the environment value for name, or null when unset. The returned slice
points into the process environment block and is read-only; callers do not free
it. FreeBSD always links libc, so the implementation reads the libc environment
directly.

## Consequences

- estimator.zig, predictor.zig, estimator_thread.zig route env reads through
  compat.args.getenv; no consumer references std.c.getenv.
- A later subproject needing environment variables has one owned adaptation
  point already in place.
- compat.args now depends on libc (std.c.getenv). On FreeBSD this is always
  linked, consistent with the rest of the boundary (compat.posix already uses
  libc via posix.system).
