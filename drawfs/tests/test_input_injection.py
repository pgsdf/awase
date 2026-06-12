#!/usr/bin/env python3
"""
test_input_injection.py — DF-2 integration test for drawfs input event delivery.

Tests that:
  - DRAWFSGIOC_INJECT_INPUT delivers EVT_KEY, EVT_POINTER, EVT_SCROLL,
    EVT_TOUCH events to the session owning the target surface.
  - Injection into a non-existent surface returns ENOENT.
  - Queue backpressure under rapid injection matches existing surface event
    backpressure behaviour (ENOSPC when queue is full).
  - Event delivery does not block the rendering (present) path.

Requirements:
  - drawfs.ko loaded with DF-2 kernel changes: ./build.sh load
  - /dev/draw accessible (run as root)

Run:
  cd drawfs/tests
  sudo python3 test_input_injection.py

Exit codes:
  0  all tests passed
  1  one or more tests failed
  2  kernel module not available (skip)
"""

import os
import sys
import struct
import fcntl
import traceback
import threading
import time
from drawfs_test import (
    DrawSession, DEV, FMT_XRGB8888,
    REQ_SURFACE_PRESENT, RPL_SURFACE_PRESENT, EVT_SURFACE_PRESENTED,
    make_frame, make_msg, read_msg, parse_first_msg,
    FH_SIZE, MH_SIZE,
)

# ============================================================================
# ioctl constants
# ============================================================================

def _ioc(dir_, type_, nr, size):
    return (dir_ << 30) | (size << 16) | (ord(type_) << 8) | nr

IOC_READ  = 2
IOC_WRITE = 1
IOC_RW    = IOC_READ | IOC_WRITE

def _iowr(type_, nr, size):
    return _ioc(IOC_RW, type_, nr, size)

# struct drawfs_inject_input: uint32 surface_id, uint16 event_type, uint16 pad, uint8[32] payload
INJECT_STRUCT_FMT  = "=IHH32s"
INJECT_STRUCT_SIZE = struct.calcsize(INJECT_STRUCT_FMT)
DRAWFSGIOC_INJECT_INPUT = _iowr('D', 0x03, INJECT_STRUCT_SIZE)

# Event types
EVT_KEY      = 0x9010
EVT_POINTER  = 0x9011
EVT_SCROLL   = 0x9012
EVT_TOUCH    = 0x9013

# ============================================================================
# Payload builders (must fit in 32 bytes)
# ============================================================================

def key_payload(surface_id: int, code: int, state: int,
                mods: int = 0, ts: int = 0) -> bytes:
    """struct drawfs_evt_key: uint32 surface_id, code, state, mods; int64 ts_wall_ns"""
    raw = struct.pack("=IIIIq", surface_id, code, state, mods, ts)
    return raw.ljust(32, b'\x00')[:32]


def pointer_payload(surface_id: int, x: int, y: int,
                    dx: int = 0, dy: int = 0,
                    buttons: int = 0, ts: int = 0) -> bytes:
    """struct drawfs_evt_pointer: uint32 surface_id; int32 x,y,dx,dy; uint32 buttons; int64 ts"""
    raw = struct.pack("=IiiiiIq", surface_id, x, y, dx, dy, buttons, ts)
    return raw.ljust(32, b'\x00')[:32]


def scroll_payload(surface_id: int, dx: int, dy: int, ts: int = 0) -> bytes:
    """struct drawfs_evt_scroll: uint32 surface_id; int32 dx,dy; int64 ts"""
    raw = struct.pack("=Iiiq", surface_id, dx, dy, ts)
    return raw.ljust(32, b'\x00')[:32]


def touch_payload(surface_id: int, contact: int, phase: int,
                  x: int, y: int, ts: int = 0) -> bytes:
    """struct drawfs_evt_touch: uint32 surface_id, contact, phase; int32 x,y; int64 ts"""
    raw = struct.pack("=IIIiiq", surface_id, contact, phase, x, y, ts)
    return raw.ljust(32, b'\x00')[:32]


# ============================================================================
# Injection helper
# ============================================================================

ENOENT = 2
EINVAL = 22
ENOSPC = 28

def inject(fd: int, surface_id: int, event_type: int,
           payload: bytes) -> int:
    """
    Call DRAWFSGIOC_INJECT_INPUT. Returns 0 on success, errno on failure.
    """
    assert len(payload) == 32, f"payload must be 32 bytes, got {len(payload)}"
    buf = struct.pack(INJECT_STRUCT_FMT, surface_id, event_type, 0, payload)
    try:
        fcntl.ioctl(fd, DRAWFSGIOC_INJECT_INPUT, buf, True)
        return 0
    except OSError as e:
        return e.errno


def read_event(s: DrawSession, timeout_ms: int = 500) -> tuple:
    """Read one message, skip SURFACE_PRESENTED events. Returns (msg_type, payload)."""
    for _ in range(20):
        try:
            mt, mid, payload = s.read_msg(timeout_ms=timeout_ms)
        except Exception:
            return (None, None)
        if mt == EVT_SURFACE_PRESENTED:
            continue
        return (mt, payload)
    return (None, None)


# ============================================================================
# Tests
# ============================================================================

WIDTH  = 64
HEIGHT = 64


def test_evt_key_delivery():
    """EVT_KEY injected on one fd is received on the owning session's fd."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, stride, total = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0, f"surface_create: {status}"

        # Inject a key-down event via the injector's fd
        payload = key_payload(sid, code=30, state=1, ts=0)
        err = inject(injector.fd, sid, EVT_KEY, payload)
        assert err == 0, f"inject EVT_KEY failed: errno={err}"

        # Receiver should get the key event
        mt, data = read_event(receiver)
        assert mt == EVT_KEY, f"expected EVT_KEY 0x{EVT_KEY:04x}, got 0x{mt:04x}"

        # Verify payload fields: surface_id, code, state
        surface_id, code, state, mods = struct.unpack_from("=IIII", data, 0)
        assert surface_id == sid,  f"surface_id mismatch: {surface_id} != {sid}"
        assert code == 30,         f"code mismatch: {code} != 30"
        assert state == 1,         f"state mismatch: {state} != 1"

        receiver.surface_destroy(sid)
    print("  PASS: test_evt_key_delivery")


def test_evt_pointer_delivery():
    """EVT_POINTER is delivered with correct coordinates."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, _, _ = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        payload = pointer_payload(sid, x=10, y=20, dx=1, dy=-1, buttons=1)
        err = inject(injector.fd, sid, EVT_POINTER, payload)
        assert err == 0, f"inject EVT_POINTER failed: {err}"

        mt, data = read_event(receiver)
        assert mt == EVT_POINTER, f"expected EVT_POINTER, got 0x{mt:04x}"

        surface_id, x, y, dx, dy, buttons = struct.unpack_from("=IiiiiI", data, 0)
        assert x == 10 and y == 20, f"coords: {x},{y}"
        assert buttons == 1,        f"buttons: {buttons}"

        receiver.surface_destroy(sid)
    print("  PASS: test_evt_pointer_delivery")


def test_evt_scroll_delivery():
    """EVT_SCROLL is delivered with correct deltas."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, _, _ = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        payload = scroll_payload(sid, dx=0, dy=-3)
        err = inject(injector.fd, sid, EVT_SCROLL, payload)
        assert err == 0, f"inject EVT_SCROLL failed: {err}"

        mt, data = read_event(receiver)
        assert mt == EVT_SCROLL, f"expected EVT_SCROLL, got 0x{mt:04x}"

        surface_id, dx, dy = struct.unpack_from("=Iii", data, 0)
        assert dy == -3, f"dy: {dy}"

        receiver.surface_destroy(sid)
    print("  PASS: test_evt_scroll_delivery")


def test_evt_touch_delivery():
    """EVT_TOUCH is delivered with correct contact and phase."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, _, _ = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        # Touch down
        payload = touch_payload(sid, contact=0, phase=0, x=32, y=32)
        err = inject(injector.fd, sid, EVT_TOUCH, payload)
        assert err == 0, f"inject EVT_TOUCH down failed: {err}"

        mt, data = read_event(receiver)
        assert mt == EVT_TOUCH, f"expected EVT_TOUCH, got 0x{mt:04x}"
        surface_id, contact, phase, x, y = struct.unpack_from("=IIIii", data, 0)
        assert phase == 0 and contact == 0, f"phase={phase} contact={contact}"
        assert x == 32 and y == 32, f"coords: {x},{y}"

        # Touch up
        payload = touch_payload(sid, contact=0, phase=2, x=32, y=32)
        inject(injector.fd, sid, EVT_TOUCH, payload)

        # The touch-up enqueued an EVT_TOUCH we never read. skip_events
        # drains async events before reading the destroy reply.
        receiver.surface_destroy(sid, skip_events=True)
    print("  PASS: test_evt_touch_delivery")


def test_inject_unknown_surface_returns_enoent():
    """Injecting to a non-existent surface_id returns ENOENT."""
    with DrawSession() as s:
        s.hello()
        s.display_open()
        payload = key_payload(0xDEADBEEF, code=1, state=1)
        err = inject(s.fd, 0xDEADBEEF, EVT_KEY, payload)
        assert err == ENOENT, f"expected ENOENT({ENOENT}), got {err}"
    print("  PASS: test_inject_unknown_surface_returns_enoent")


def test_inject_invalid_event_type_returns_einval():
    """Injecting with an unrecognised event_type returns EINVAL."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, _, _ = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        payload = b'\x00' * 32
        err = inject(injector.fd, sid, 0x9999, payload)
        assert err == EINVAL, f"expected EINVAL({EINVAL}), got {err}"

        receiver.surface_destroy(sid)
    print("  PASS: test_inject_invalid_event_type_returns_einval")


def test_event_delivery_does_not_block_present():
    """Injecting events while presenting does not block the present path."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, stride, total = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        import mmap
        receiver.map_surface(sid)
        mm = mmap.mmap(receiver.fd, total, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE)

        # Inject 20 key events
        for i in range(20):
            payload = key_payload(sid, code=i + 1, state=1)
            inject(injector.fd, sid, EVT_KEY, payload)

        # Present must succeed immediately without waiting for event drain.
        # Use drain_until to skip the 20 pending EVT_KEY events and find
        # the RPL_SURFACE_PRESENT. (An earlier version of this test had a
        # hand-rolled skip loop with a subtle bug — it swallowed events
        # without reading past them on the "other event" branch — which is
        # why it intermittently failed with "present blocked: got 0x9010".)
        fid, mid = receiver._next_ids()
        frame = make_frame(fid, [make_msg(
            REQ_SURFACE_PRESENT, mid,
            struct.pack("<IIQ", sid, 0, 0)
        )])
        receiver.send(frame)
        # drain_until reads up to max_msgs messages, returning the first
        # one whose type matches. 40 is comfortably above the 20 queued
        # events plus the reply we expect.
        from drawfs_test import drain_until, RPL_SURFACE_PRESENT
        try:
            drain_until(receiver.fd, RPL_SURFACE_PRESENT, timeout_ms=2000, max_msgs=40)
        except RuntimeError as e:
            raise AssertionError(f"present blocked or never replied: {e}")

        mm.close()
        # Pending EVT_SURFACE_PRESENTED from the present above hasn't been
        # read. skip_events drains it so the destroy reply can land cleanly.
        receiver.surface_destroy(sid, skip_events=True)
    print("  PASS: test_event_delivery_does_not_block_present")


def test_backpressure_enospc():
    """Rapid injection eventually returns ENOSPC when queue is full."""
    with DrawSession() as receiver, DrawSession() as injector:
        receiver.hello()
        receiver.display_open()
        status, sid, _, _ = receiver.surface_create(WIDTH, HEIGHT)
        assert status == 0

        # Inject until queue full — max_evq_bytes default is 8192.
        # Each framed key event is ~48 bytes; 200 events = ~9600 bytes > 8192.
        enospc_seen = False
        for _ in range(250):
            payload = key_payload(sid, code=1, state=1)
            err = inject(injector.fd, sid, EVT_KEY, payload)
            if err == ENOSPC:
                enospc_seen = True
                break
            assert err == 0, f"unexpected inject error: {err}"

        assert enospc_seen, "expected ENOSPC after queue saturation"
        # The queue was deliberately filled to ENOSPC with ~200 EVT_KEY
        # events. drain_until's default max_msgs=20 is too small to skip
        # past them, so drain explicitly with the poll-based helper
        # before calling destroy.
        receiver.drain_all()
        receiver.surface_destroy(sid)
    print("  PASS: test_backpressure_enospc")


# ============================================================================
# Runner
# ============================================================================

TESTS = [
    test_evt_key_delivery,
    test_evt_pointer_delivery,
    test_evt_scroll_delivery,
    test_evt_touch_delivery,
    test_inject_unknown_surface_returns_enoent,
    test_inject_invalid_event_type_returns_einval,
    test_event_delivery_does_not_block_present,
    test_backpressure_enospc,
]


def main() -> int:
    if not os.path.exists(DEV):
        print(f"SKIP: {DEV} not found — load drawfs.ko (with DF-2) and retry",
              file=sys.stderr)
        return 2

    passed = 0
    failed = 0

    print(f"Running {len(TESTS)} input injection tests against {DEV}")
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
