#!/usr/bin/env python3
"""
test_sdcs_integration.py — Integration smoke test for the drawfs kernel module
and semadraw drawfs backend.

Tests the full surface lifecycle: connect, create surface, map it, write pixels,
present, and verify pixel persistence. This validates the kernel module's mmap
and present path that the semadraw drawfs backend relies on.

For SDCS rendering validation (which requires semadrawd running), see the
semadraw golden image tests in semadraw/tests/.

Requirements:
  - drawfs.ko loaded: cd drawfs && ./build.sh load
  - /dev/draw accessible (run as root or set hw.drawfs.dev_uid/gid/mode)

Run:
  cd drawfs/tests
  sudo python3 test_sdcs_integration.py

Exit codes:
  0  all tests passed
  1  one or more tests failed
  2  kernel module not available (skip)
"""

import os
import sys
import struct
import mmap
import traceback
from drawfs_test import (
    DrawSession, DEV,
    REQ_SURFACE_PRESENT, RPL_SURFACE_PRESENT, EVT_SURFACE_PRESENTED,
    FMT_XRGB8888,
    make_frame, make_msg, read_msg,
)


# ============================================================================
# Pixel helpers (XRGB8888: stored as B G R X in memory)
# ============================================================================

def write_pixel(buf: bytearray, x: int, y: int, stride: int,
                r: int, g: int, b: int) -> None:
    off = y * stride + x * 4
    buf[off]     = b
    buf[off + 1] = g
    buf[off + 2] = r
    buf[off + 3] = 0xFF


def read_pixel(buf: bytes, x: int, y: int, stride: int) -> tuple:
    """Returns (r, g, b)."""
    off = y * stride + x * 4
    return (buf[off + 2], buf[off + 1], buf[off])


def fill_rect(buf: bytearray, x0: int, y0: int, w: int, h: int,
              stride: int, r: int, g: int, b: int) -> None:
    for py in range(y0, y0 + h):
        for px in range(x0, x0 + w):
            write_pixel(buf, px, py, stride, r, g, b)


def assert_pixel(buf: bytes, x: int, y: int, stride: int,
                 expected: tuple, label: str, tol: int = 2) -> None:
    actual = read_pixel(buf, x, y, stride)
    for i, (a, e) in enumerate(zip(actual, expected)):
        if abs(a - e) > tol:
            raise AssertionError(
                f"{label}: pixel ({x},{y}) got rgb{actual}, "
                f"expected rgb{expected}"
            )


# ============================================================================
# Present helper using DrawSession primitives
# ============================================================================

def present(s: DrawSession, surface_id: int, cookie: int = 0) -> int:
    """Send SURFACE_PRESENT, drain reply and any EVT_SURFACE_PRESENTED, return status."""
    fid, mid = s._next_ids()
    payload = struct.pack("<IIQ", surface_id, 0, cookie)
    frame = make_frame(fid, [make_msg(REQ_SURFACE_PRESENT, mid, payload)])
    s.send(frame)

    # Read until we see the RPL_SURFACE_PRESENT, skipping any leading events.
    status = None
    for _ in range(20):
        mt, _, rpl = read_msg(s.fd)
        if mt == EVT_SURFACE_PRESENTED:
            continue
        if mt == RPL_SURFACE_PRESENT:
            status = struct.unpack_from("<i", rpl)[0]
            break
        raise AssertionError(f"unexpected reply 0x{mt:04x}")

    if status is None:
        raise AssertionError("no SURFACE_PRESENT reply received")

    # Drain any EVT_SURFACE_PRESENTED that arrives after the reply.
    try:
        while True:
            mt, _, _ = read_msg(s.fd, timeout_ms=200)
            if mt == EVT_SURFACE_PRESENTED:
                continue
            raise AssertionError(f"unexpected late message 0x{mt:04x}")
    except Exception:
        pass  # timeout — queue is empty, as expected

    return status


# ============================================================================
# Tests
# ============================================================================

WIDTH  = 128
HEIGHT = 128


def test_surface_create_and_map():
    """Surface creation and mmap return valid values."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        status, sid, stride, total = s.surface_create(WIDTH, HEIGHT)
        assert status == 0, f"SURFACE_CREATE status={status}"
        assert sid >= 1,    f"invalid surface_id={sid}"
        assert stride >= WIDTH * 4, f"stride too small: {stride}"
        assert total >= HEIGHT * stride, f"total too small: {total}"

        map_status, _, map_stride, map_total = s.map_surface(sid)
        assert map_status == 0, f"MAP_SURFACE status={map_status}"
        assert map_stride == stride
        assert map_total  == total

        s.surface_destroy(sid)
    print("  PASS: test_surface_create_and_map")


def test_pixel_write_and_read():
    """Pixels written to the mmap'd buffer are readable back."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        status, sid, stride, total = s.surface_create(WIDTH, HEIGHT)
        assert status == 0, f"SURFACE_CREATE status={status}"

        s.map_surface(sid)

        mm = mmap.mmap(s.fd, total, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE)
        try:
            # Write a known pixel pattern into the buffer
            buf = bytearray(total)
            fill_rect(buf, 0,  0,  WIDTH, HEIGHT, stride, 0, 0, 0)   # black bg
            fill_rect(buf, 10, 10, 20, 20, stride, 255, 0,   0)       # red rect
            fill_rect(buf, 50, 50, 20, 20, stride, 0,   255, 0)       # green rect
            fill_rect(buf, 90, 90, 20, 20, stride, 0,   0,   255)     # blue rect

            mm.seek(0)
            mm.write(bytes(buf))
            mm.flush()

            # Read back and verify
            mm.seek(0)
            readback = mm.read(total)

            assert_pixel(readback, 20, 20, stride, (255, 0,   0),   "red rect interior")
            assert_pixel(readback, 60, 60, stride, (0,   255, 0),   "green rect interior")
            assert_pixel(readback, 100, 100, stride, (0,  0,   255), "blue rect interior")
            assert_pixel(readback, 0,  0,  stride, (0,   0,   0),   "black background")
            assert_pixel(readback, 9,  9,  stride, (0,   0,   0),   "outside red rect")
        finally:
            mm.close()

        s.surface_destroy(sid)
    print("  PASS: test_pixel_write_and_read")


def test_present_cycle():
    """SURFACE_PRESENT completes without error after writing pixels."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        status, sid, stride, total = s.surface_create(WIDTH, HEIGHT)
        assert status == 0, f"SURFACE_CREATE status={status}"

        s.map_surface(sid)

        mm = mmap.mmap(s.fd, total, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE)
        try:
            # Fill with a solid colour
            buf = bytearray(total)
            fill_rect(buf, 0, 0, WIDTH, HEIGHT, stride, 128, 64, 32)
            mm.seek(0)
            mm.write(bytes(buf))
            mm.flush()

            # Present — must return status 0
            pstatus = present(s, sid, cookie=0xDEADBEEF)
            assert pstatus == 0, f"SURFACE_PRESENT status={pstatus}"

            # Pixels must survive the present round-trip
            mm.seek(0)
            readback = mm.read(total)
            assert_pixel(readback, WIDTH // 2, HEIGHT // 2, stride,
                         (128, 64, 32), "pixel survives present")
        finally:
            mm.close()

        s.surface_destroy(sid)
    print("  PASS: test_present_cycle")


def test_multiple_presents():
    """Multiple sequential presents all succeed."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        status, sid, stride, total = s.surface_create(WIDTH, HEIGHT)
        assert status == 0

        s.map_surface(sid)
        mm = mmap.mmap(s.fd, total, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE)
        try:
            for frame_num in range(5):
                # Each frame: different solid colour
                r = (frame_num * 50) % 256
                buf = bytearray(total)
                fill_rect(buf, 0, 0, WIDTH, HEIGHT, stride, r, 0, 0)
                mm.seek(0)
                mm.write(bytes(buf))
                mm.flush()

                pstatus = present(s, sid, cookie=frame_num)
                assert pstatus == 0, f"frame {frame_num}: status={pstatus}"

                mm.seek(0)
                readback = mm.read(total)
                assert_pixel(readback, WIDTH // 2, HEIGHT // 2, stride,
                             (r, 0, 0), f"frame {frame_num} pixel")
        finally:
            mm.close()

        s.surface_destroy(sid)
    print("  PASS: test_multiple_presents")


def test_abrupt_disconnect_no_panic():
    """Abrupt disconnect after surface creation leaves kernel in clean state."""
    # First session: create surface and disconnect without destroying it
    with DrawSession() as s:
        s.hello()
        s.display_open()
        status, sid, stride, total = s.surface_create(WIDTH, HEIGHT)
        assert status == 0
        s.map_surface(sid)
        # Let context manager close the fd without explicit destroy

    # Second session: kernel must have reclaimed resources — new session works
    with DrawSession() as s:
        s.hello()
        s.display_open()
        status, sid2, stride2, total2 = s.surface_create(WIDTH, HEIGHT)
        assert status == 0, f"post-disconnect SURFACE_CREATE status={status}"
        assert sid2 >= 1
        s.surface_destroy(sid2)
    print("  PASS: test_abrupt_disconnect_no_panic")


def test_surface_id_uniqueness():
    """Each surface creation yields a unique non-zero surface ID."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        ids = []
        for _ in range(4):
            status, sid, _, _ = s.surface_create(32, 32)
            assert status == 0, f"SURFACE_CREATE status={status}"
            assert sid >= 1,    f"invalid surface_id={sid}"
            assert sid not in ids, f"duplicate surface_id={sid}"
            ids.append(sid)

        for sid in ids:
            s.surface_destroy(sid)
    print("  PASS: test_surface_id_uniqueness")


# ============================================================================
# Runner
# ============================================================================

TESTS = [
    test_surface_create_and_map,
    test_pixel_write_and_read,
    test_present_cycle,
    test_multiple_presents,
    test_abrupt_disconnect_no_panic,
    test_surface_id_uniqueness,
]


def main() -> int:
    if not os.path.exists(DEV):
        print(f"SKIP: {DEV} not found — load drawfs.ko and retry", file=sys.stderr)
        return 2

    passed = 0
    failed = 0

    print(f"Running {len(TESTS)} drawfs integration tests against {DEV}")
    print()

    for test_fn in TESTS:
        try:
            test_fn()
            passed += 1
        except AssertionError as e:
            print(f"  FAIL: {test_fn.__name__}: {e}")
            failed += 1
        except Exception:
            print(f"  ERROR: {test_fn.__name__}")
            traceback.print_exc()
            failed += 1

    print()
    print(f"Results: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
