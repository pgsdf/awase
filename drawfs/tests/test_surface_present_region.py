#!/usr/bin/env python3
"""
test_surface_present_region.py — end-to-end tests for the
DRAWFS_REQ_SURFACE_PRESENT_REGION opcode (B3.3 pass 3).

The design spec lives at drawfs/docs/DESIGN-surface-present-region.md;
this file checks behavior against it. Three test groups:

  Group A — Error table coverage.
    Every row of the design doc's error table gets one test.
    The validator is pure and should reject every malformed input
    with the documented error.

  Group B — Happy path, clamping, and within-request coalescing.
    Valid requests of various shapes. Checks that the event payload
    matches what the handler should have produced after clamping,
    dropping off-surface rects, and applying the area-sum threshold
    controlled by hw.drawfs.region_coalesce_threshold.

  Group C — N=1-full-surface equivalence invariant.
    A region present with exactly one rect covering the full surface
    must produce the same observable behavior as a regular
    SURFACE_PRESENT: reply status 0, event emitted, no pixel state
    disturbance beyond what the client wrote.

Errno values used below are FreeBSD values, not Linux. See
ARCHITECTURE_KMOD.md: "Clients must not hardcode Linux errno numbers."
"""

import errno
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from drawfs_test import (
    DrawSession,
    make_frame, make_msg,
    read_msg, drain_until, drain_all,
    REQ_SURFACE_PRESENT_REGION,
    RPL_SURFACE_PRESENT_REGION,
    EVT_SURFACE_PRESENTED_REGION,
    MAX_PRESENT_RECTS,
)


# FreeBSD errno values — numeric, because Python's `errno` module
# resolves to the host's values and tests run on the FreeBSD target.
FBSD_EINVAL     = 22
FBSD_ENOENT     = 2
FBSD_EOPNOTSUPP = 45
FBSD_EOVERFLOW  = 84

# Surface dimensions used across tests.
SURF_W = 200
SURF_H = 100
SURF_AREA = SURF_W * SURF_H  # 20000 pixels


# =============================================================================
# Protocol helpers local to this file
#
# The shared drawfs_test.py module doesn't yet have helpers for the new
# variable-length region request/reply/event. Pass 3 deliberately keeps
# these local rather than modifying shared infrastructure.
# =============================================================================

# Fixed request header: surface_id, flags, cookie, rect_count, _reserved.
# Layout must match struct drawfs_req_surface_present_region in drawfs_proto.h.
REQ_REGION_HDR_FMT = "<IIQII"
REQ_REGION_HDR_SIZE = struct.calcsize(REQ_REGION_HDR_FMT)  # 24

# Reply: status, surface_id, cookie.
RPL_REGION_FMT = "<iIQ"
RPL_REGION_SIZE = struct.calcsize(RPL_REGION_FMT)  # 16

# Event header: surface_id, rect_count, cookie. Followed by rect_count rects.
EVT_REGION_HDR_FMT = "<IIQ"
EVT_REGION_HDR_SIZE = struct.calcsize(EVT_REGION_HDR_FMT)  # 16

# Rect: x (signed), y (signed), width, height.
RECT_FMT = "<iiII"
RECT_SIZE = struct.calcsize(RECT_FMT)  # 16


def pack_rect(x, y, w, h):
    return struct.pack(RECT_FMT, x, y, w, h)


def pack_region_request(surface_id, cookie, rects,
                        flags=0, declared_rect_count=None, reserved=0):
    """Build a SURFACE_PRESENT_REGION request payload.

    declared_rect_count defaults to len(rects). Tests that want a
    count/payload mismatch can override it.
    """
    if declared_rect_count is None:
        declared_rect_count = len(rects)
    hdr = struct.pack(REQ_REGION_HDR_FMT,
                      surface_id, flags, cookie,
                      declared_rect_count, reserved)
    return hdr + b"".join(rects)


def parse_region_reply(payload):
    """Return (status, surface_id, cookie) from a RPL_SURFACE_PRESENT_REGION."""
    return struct.unpack_from(RPL_REGION_FMT, payload, 0)


def parse_region_event(payload):
    """Return (surface_id, cookie, list_of_rects) from a
    EVT_SURFACE_PRESENTED_REGION payload.
    """
    surface_id, rect_count, cookie = struct.unpack_from(
        EVT_REGION_HDR_FMT, payload, 0)
    rects = []
    off = EVT_REGION_HDR_SIZE
    for _ in range(rect_count):
        x, y, w, h = struct.unpack_from(RECT_FMT, payload, off)
        rects.append((x, y, w, h))
        off += RECT_SIZE
    return surface_id, cookie, rects


def send_region_request(session, surface_id, cookie, rects, **kwargs):
    """Send the request frame; return the frame_id and msg_id used."""
    fid, mid = session._next_ids()
    payload = pack_region_request(surface_id, cookie, rects, **kwargs)
    frame = make_frame(fid, [make_msg(REQ_SURFACE_PRESENT_REGION, mid, payload)])
    session.send(frame)
    return fid, mid


def read_region_reply(session, timeout_ms=2000):
    """Read messages until the reply is found; return (status, sid, cookie)."""
    _, reply_payload = drain_until(session.fd, RPL_SURFACE_PRESENT_REGION,
                                   timeout_ms=timeout_ms, max_msgs=40)
    return parse_region_reply(reply_payload)


def read_region_event(session, timeout_ms=2000):
    """Read messages until the region event is found; return parsed form."""
    _, evt_payload = drain_until(session.fd, EVT_SURFACE_PRESENTED_REGION,
                                 timeout_ms=timeout_ms, max_msgs=40)
    return parse_region_event(evt_payload)


def sysctl_get(name):
    """Read an int sysctl. Returns int."""
    r = subprocess.run(["sysctl", "-n", name],
                       capture_output=True, text=True, check=True)
    return int(r.stdout.strip())


def sysctl_set(name, value):
    """Write an int sysctl. Requires root."""
    subprocess.run(["sysctl", f"{name}={value}"],
                   capture_output=True, check=True)


# =============================================================================
# Group A — Error table coverage
# =============================================================================

def _setup_session_with_surface(w=SURF_W, h=SURF_H):
    """Return an entered DrawSession with a display open and one surface
    created. Caller is responsible for closing via __exit__."""
    s = DrawSession()
    s.__enter__()
    s.hello()
    s.display_open()
    status, sid, stride, total = s.surface_create(w, h)
    assert status == 0, f"surface_create failed: {status}"
    return s, sid


def test_err_unknown_surface_id():
    """Unknown surface_id -> reply status ENOENT."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(0, 0, 10, 10)]
        send_region_request(s, surface_id=0xDEADBEEF, cookie=1, rects=rects)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_ENOENT, (
            f"unknown surface_id should yield ENOENT ({FBSD_ENOENT}), got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_rect_count_zero():
    """rect_count == 0 -> reply status EINVAL (validator: INVALID_ARG)."""
    s, sid = _setup_session_with_surface()
    try:
        send_region_request(s, surface_id=sid, cookie=2, rects=[])
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EINVAL, (
            f"rect_count=0 should yield EINVAL, got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_rect_count_over_max():
    """rect_count > DRAWFS_MAX_PRESENT_RECTS -> reply status EOVERFLOW."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(0, 0, 1, 1) for _ in range(MAX_PRESENT_RECTS + 1)]
        send_region_request(s, surface_id=sid, cookie=3, rects=rects)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EOVERFLOW, (
            f"rect_count>MAX should yield EOVERFLOW ({FBSD_EOVERFLOW}), "
            f"got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_zero_width_rect():
    """A rect with width=0 -> reply status EINVAL."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(10, 10, 0, 50)]
        send_region_request(s, surface_id=sid, cookie=4, rects=rects)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EINVAL, (
            f"zero-width rect should yield EINVAL, got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_zero_height_rect():
    """A rect with height=0 -> reply status EINVAL."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(10, 10, 50, 0)]
        send_region_request(s, surface_id=sid, cookie=5, rects=rects)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EINVAL, (
            f"zero-height rect should yield EINVAL, got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_nonzero_flags():
    """flags != 0 -> reply status EOPNOTSUPP (validator: UNSUPPORTED_CAP)."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(0, 0, 10, 10)]
        send_region_request(s, surface_id=sid, cookie=6, rects=rects,
                            flags=0x0001)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EOPNOTSUPP, (
            f"non-zero flags should yield EOPNOTSUPP ({FBSD_EOPNOTSUPP}), "
            f"got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_nonzero_reserved():
    """_reserved != 0 -> reply status EINVAL (validator: INVALID_MSG)."""
    s, sid = _setup_session_with_surface()
    try:
        rects = [pack_rect(0, 0, 10, 10)]
        send_region_request(s, surface_id=sid, cookie=7, rects=rects,
                            reserved=0xCAFE)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EINVAL, (
            f"non-zero _reserved should yield EINVAL, got {status}")
    finally:
        s.__exit__(None, None, None)


def test_err_rect_count_mismatch_short():
    """Declared rect_count > actual rects in payload -> EINVAL (INVALID_FRAME)."""
    s, sid = _setup_session_with_surface()
    try:
        # Ship 1 rect's worth of bytes but claim 5.
        rects = [pack_rect(0, 0, 10, 10)]
        send_region_request(s, surface_id=sid, cookie=8,
                            rects=rects, declared_rect_count=5)
        status, _, _ = read_region_reply(s)
        assert status == FBSD_EINVAL, (
            f"count/payload mismatch should yield EINVAL, got {status}")
    finally:
        s.__exit__(None, None, None)


# =============================================================================
# Group B — Happy path, clamping, within-request coalescing
# =============================================================================

def test_happy_single_small_rect_emits_event():
    """A single small rect well under threshold is emitted unchanged."""
    s, sid = _setup_session_with_surface()
    try:
        rects_in = [(10, 10, 20, 20)]  # 400 / 20000 = 2%, no collapse
        send_region_request(s, surface_id=sid, cookie=0x1001,
                            rects=[pack_rect(*r) for r in rects_in])
        status, rsid, cookie = read_region_reply(s)
        assert status == 0, f"expected success, got {status}"
        assert rsid == sid
        assert cookie == 0x1001

        evt_sid, evt_cookie, evt_rects = read_region_event(s)
        assert evt_sid == sid
        assert evt_cookie == 0x1001
        assert evt_rects == rects_in, (
            f"expected event rects {rects_in}, got {evt_rects}")
    finally:
        s.__exit__(None, None, None)


def test_happy_multiple_small_rects_under_threshold():
    """Several small rects whose sum stays under threshold pass through."""
    s, sid = _setup_session_with_surface()
    try:
        # Three 20x20 rects = 1200 / 20000 = 6%, no collapse.
        rects_in = [(0, 0, 20, 20), (40, 40, 20, 20), (80, 20, 20, 20)]
        send_region_request(s, surface_id=sid, cookie=0x1002,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        assert evt_rects == rects_in, (
            f"expected {rects_in}, got {evt_rects}")
    finally:
        s.__exit__(None, None, None)


def test_happy_rects_over_threshold_collapse():
    """Rect sum at or above threshold collapses to one full-surface rect."""
    s, sid = _setup_session_with_surface()
    orig = sysctl_get("hw.drawfs.region_coalesce_threshold")
    try:
        # Ensure threshold is at its default 75.
        sysctl_set("hw.drawfs.region_coalesce_threshold", 75)

        # 200x80 = 16000 / 20000 = 80%, above 75% threshold.
        rects_in = [(0, 0, 200, 80)]
        send_region_request(s, surface_id=sid, cookie=0x1003,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        expected = [(0, 0, SURF_W, SURF_H)]
        assert evt_rects == expected, (
            f"expected collapse to {expected}, got {evt_rects}")
    finally:
        sysctl_set("hw.drawfs.region_coalesce_threshold", orig)
        s.__exit__(None, None, None)


def test_happy_clamping_partially_off_surface():
    """Rects spilling off edges are clamped to the surface bounds."""
    s, sid = _setup_session_with_surface()
    try:
        # Rect at (-20, -10, 50, 40) -> clamp to (0, 0, 30, 30)
        # Rect at (180, 90, 50, 50) -> clamp to (180, 90, 20, 10)
        rects_in = [(-20, -10, 50, 40), (180, 90, 50, 50)]
        send_region_request(s, surface_id=sid, cookie=0x1004,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        expected = [(0, 0, 30, 30), (180, 90, 20, 10)]
        assert evt_rects == expected, (
            f"expected clamped {expected}, got {evt_rects}")
    finally:
        s.__exit__(None, None, None)


def test_happy_rect_fully_outside_dropped():
    """A rect entirely outside the surface is dropped."""
    s, sid = _setup_session_with_surface()
    try:
        # First rect fully outside; second valid.
        rects_in = [(1000, 1000, 10, 10), (10, 10, 20, 20)]
        send_region_request(s, surface_id=sid, cookie=0x1005,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        expected = [(10, 10, 20, 20)]  # only the second rect survives
        assert evt_rects == expected, (
            f"expected dropped off-surface, got {evt_rects}")
    finally:
        s.__exit__(None, None, None)


def test_happy_all_rects_outside_triggers_collapse():
    """If every rect is outside, handler collapses to one full-surface rect.

    This is the defensive 'accepted_count == 0' branch in the handler
    — the request is well-formed so reply is success, but there's
    nothing to emit, so the handler substitutes a full-surface rect
    to keep the client informed that the present was processed.
    """
    s, sid = _setup_session_with_surface()
    try:
        rects_in = [(1000, 1000, 10, 10), (2000, 2000, 10, 10)]
        send_region_request(s, surface_id=sid, cookie=0x1006,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0, f"expected success, got {status}"

        _, _, evt_rects = read_region_event(s)
        expected = [(0, 0, SURF_W, SURF_H)]
        assert evt_rects == expected, (
            f"expected full-surface collapse, got {evt_rects}")
    finally:
        s.__exit__(None, None, None)


def test_happy_threshold_zero_always_collapses():
    """Setting threshold=0 should collapse every request."""
    s, sid = _setup_session_with_surface()
    orig = sysctl_get("hw.drawfs.region_coalesce_threshold")
    try:
        sysctl_set("hw.drawfs.region_coalesce_threshold", 0)

        # A tiny rect that would never trigger the 75% threshold.
        rects_in = [(5, 5, 2, 2)]
        send_region_request(s, surface_id=sid, cookie=0x1007,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        expected = [(0, 0, SURF_W, SURF_H)]
        assert evt_rects == expected, (
            f"threshold=0 should collapse, got {evt_rects}")
    finally:
        sysctl_set("hw.drawfs.region_coalesce_threshold", orig)
        s.__exit__(None, None, None)


def test_happy_threshold_hundred_preserves_rects():
    """threshold=100 preserves rect lists that don't sum to full surface."""
    s, sid = _setup_session_with_surface()
    orig = sysctl_get("hw.drawfs.region_coalesce_threshold")
    try:
        sysctl_set("hw.drawfs.region_coalesce_threshold", 100)

        # 99% coverage: one rect of 200x99 = 19800 / 20000 = 99%
        rects_in = [(0, 0, 200, 99)]
        send_region_request(s, surface_id=sid, cookie=0x1008,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        assert evt_rects == rects_in, (
            f"99%% at threshold 100 should NOT collapse, got {evt_rects}")
    finally:
        sysctl_set("hw.drawfs.region_coalesce_threshold", orig)
        s.__exit__(None, None, None)


def test_happy_max_rects_accepted():
    """Exactly DRAWFS_MAX_PRESENT_RECTS (16) rects are accepted."""
    s, sid = _setup_session_with_surface()
    try:
        # 16 tiny 1x1 rects, total area = 16 pixels of 20000 = 0.08%
        # Stays well under threshold; all should come through.
        rects_in = [(i, i, 1, 1) for i in range(MAX_PRESENT_RECTS)]
        send_region_request(s, surface_id=sid, cookie=0x1009,
                            rects=[pack_rect(*r) for r in rects_in])
        status, _, _ = read_region_reply(s)
        assert status == 0

        _, _, evt_rects = read_region_event(s)
        assert len(evt_rects) == MAX_PRESENT_RECTS, (
            f"expected {MAX_PRESENT_RECTS} rects, got {len(evt_rects)}")
        assert evt_rects == rects_in
    finally:
        s.__exit__(None, None, None)


# =============================================================================
# Group C — N=1-full-surface equivalence invariant
# =============================================================================

def test_equivalence_n1_full_surface():
    """A region present with one rect covering the full surface behaves
    equivalently to a regular SURFACE_PRESENT: reply status 0, event
    emitted. This is the design doc's headline invariant.

    The 'observable behavior' the design doc talks about includes the
    event *type*. Per spec: region requests always emit
    EVT_SURFACE_PRESENTED_REGION, never EVT_SURFACE_PRESENTED. The
    equivalence is about status and cookie roundtrip, not event type.
    """
    s, sid = _setup_session_with_surface()
    try:
        # Region present with one full-surface rect.
        rects_in = [(0, 0, SURF_W, SURF_H)]
        send_region_request(s, surface_id=sid, cookie=0xABCDEF01,
                            rects=[pack_rect(*r) for r in rects_in])
        status, rsid, cookie = read_region_reply(s)
        assert status == 0
        assert rsid == sid
        assert cookie == 0xABCDEF01

        evt_sid, evt_cookie, evt_rects = read_region_event(s)
        assert evt_sid == sid
        assert evt_cookie == 0xABCDEF01
        # This specific case: the sum == surface area, so the
        # threshold check fires (since 100% >= 75%), and the rect
        # list collapses to a single full-surface rect. That matches
        # what the client sent, so the test is equivalence-preserving.
        assert evt_rects == rects_in, (
            f"expected {rects_in}, got {evt_rects}")

        # Now do a regular SURFACE_PRESENT on the same surface and
        # verify it still works. Not a pixel comparison (we have no
        # mmap in this test), but the reply status and event arrival
        # are the observable behaviors the spec calls out.
        status2, sid2, cookie2 = s.surface_present(sid, cookie=0xABCDEF02)
        assert status2 == 0
        assert sid2 == sid
        assert cookie2 == 0xABCDEF02

        evt_sid2, _, evt_cookie2 = s.read_presented_event()
        assert evt_sid2 == sid
        assert evt_cookie2 == 0xABCDEF02
    finally:
        s.__exit__(None, None, None)


# =============================================================================
# Runner
# =============================================================================

TESTS = [
    # Group A — error table
    ("error: unknown surface_id",       test_err_unknown_surface_id),
    ("error: rect_count == 0",          test_err_rect_count_zero),
    ("error: rect_count > MAX",         test_err_rect_count_over_max),
    ("error: zero-width rect",          test_err_zero_width_rect),
    ("error: zero-height rect",         test_err_zero_height_rect),
    ("error: non-zero flags",           test_err_nonzero_flags),
    ("error: non-zero _reserved",       test_err_nonzero_reserved),
    ("error: declared count mismatch",  test_err_rect_count_mismatch_short),

    # Group B — happy path and coalescing
    ("happy: single small rect",        test_happy_single_small_rect_emits_event),
    ("happy: several rects below thr",  test_happy_multiple_small_rects_under_threshold),
    ("happy: rects over threshold",     test_happy_rects_over_threshold_collapse),
    ("happy: partial off-surface",      test_happy_clamping_partially_off_surface),
    ("happy: fully-outside dropped",    test_happy_rect_fully_outside_dropped),
    ("happy: all outside -> collapse",  test_happy_all_rects_outside_triggers_collapse),
    ("happy: threshold=0",              test_happy_threshold_zero_always_collapses),
    ("happy: threshold=100",            test_happy_threshold_hundred_preserves_rects),
    ("happy: max rects accepted",       test_happy_max_rects_accepted),

    # Group C — equivalence invariant
    ("equivalence: N=1 full surface",   test_equivalence_n1_full_surface),
]


def main():
    if os.geteuid() != 0:
        print("ERROR: this test must run as root "
              "(writes sysctl, opens /dev/draw)", file=sys.stderr)
        return 2

    passed = 0
    failed = 0

    for name, test_fn in TESTS:
        try:
            print(f"[TEST] {name}")
            test_fn()
            print(f"[PASS] {name}\n")
            passed += 1
        except Exception as e:
            print(f"[FAIL] {name}: {e}\n")
            failed += 1

    print(f"Results: {passed} passed, {failed} failed")
    if failed > 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
