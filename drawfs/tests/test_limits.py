#!/usr/bin/env python3
"""
test_limits.py - Limits, error handling, and backpressure tests

Tests:
  - Oversized surface rejection (EFBIG)
  - Maximum surface count (ENOSPC)
  - Event queue backpressure
  - Stats tracking for surfaces
"""

import errno
import os
import select
import struct
from drawfs_test import (
    DrawSession, DEV, make_frame, make_msg, parse_first_msg,
    REQ_HELLO, REQ_SURFACE_CREATE, REQ_SURFACE_PRESENT,
    RPL_SURFACE_CREATE, RPL_SURFACE_PRESENT, EVT_SURFACE_PRESENTED,
    FMT_XRGB8888
)


# Limits (from kernel)
MAX_SURFACE_SIZE = 64 * 1024 * 1024  # 64 MB
MAX_SURFACES = 64


def test_oversized_surface():
    """Oversized surface creation should fail with EFBIG."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        # Try to create a surface larger than 64 MB
        # 4096x4096 * 4 bytes = 64 MB (exactly at limit)
        # 4097x4096 * 4 bytes > 64 MB (over limit)
        w, h = 4097, 4096

        status, sid, stride, total = s.surface_create(w, h)
        assert status == errno.EFBIG, f"Expected EFBIG ({errno.EFBIG}), got {status}"
        print(f"  Oversized surface correctly rejected with EFBIG")


def test_max_surfaces():
    """Creating more than MAX_SURFACES should fail with ENOSPC."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        created = []
        for i in range(MAX_SURFACES + 5):
            status, sid, stride, total = s.surface_create(16, 16)

            if status == 0:
                created.append(sid)
            elif status == errno.ENOSPC:
                print(f"  Hit ENOSPC at surface {i+1} (created {len(created)})")
                break
            else:
                raise AssertionError(f"Unexpected status {status} at surface {i+1}")
        else:
            raise AssertionError(f"Should have hit limit, but created {len(created)} surfaces")

        assert len(created) <= MAX_SURFACES, f"Created {len(created)} > MAX_SURFACES"
        print(f"  Surface limit enforced: created {len(created)} before ENOSPC")


def test_event_queue_backpressure():
    """Event queue fills up, returns ENOSPC, then recovers after drain.

    Per docs/TEST_PLAN.md § Step 19 and docs/PROTOCOL.md, the kernel's
    contract is:

      - When the event queue can no longer accept an enqueue, the
        write(2) that provoked it fails with ENOSPC.
      - After the client drains the queue via read(2), writes succeed
        again.

    The test exercises exactly this. Each write carries a
    REQ_SURFACE_PRESENT; the kernel enqueues an RPL_SURFACE_PRESENT
    (and possibly an EVT_SURFACE_PRESENTED — the protocol permits
    these to coalesce, which is irrelevant here because replies do
    not coalesce). By never reading during the accumulation phase,
    bytes accumulate unconditionally until the kernel's write(2)
    path returns ENOSPC.

    The test does NOT try to read replies during accumulation. That
    would drain the very queue we are trying to fill. Reading happens
    only after ENOSPC, to verify recovery.
    """
    fd = os.open(DEV, os.O_RDWR)

    def read_one(fd):
        buf = os.read(fd, 4096)
        return parse_first_msg(buf)

    def hello(fd, frame_id, msg_id):
        payload = struct.pack("<HHII", 1, 0, 0, 65536)
        os.write(fd, make_frame(frame_id, [make_msg(REQ_HELLO, msg_id, payload)]))
        os.read(fd, 4096)

    def display_open(fd, frame_id, msg_id):
        payload = struct.pack("<I", 1)
        os.write(fd, make_frame(frame_id, [make_msg(0x0011, msg_id, payload)]))
        os.read(fd, 4096)

    def surface_create(fd, frame_id, msg_id, w, h):
        payload = struct.pack("<IIII", w, h, FMT_XRGB8888, 0)
        os.write(fd, make_frame(frame_id, [make_msg(REQ_SURFACE_CREATE, msg_id, payload)]))
        msg_type, _, payload = read_one(fd)
        assert msg_type == RPL_SURFACE_CREATE
        status, sid, stride, total = struct.unpack_from("<iIII", payload, 0)
        return status, sid

    try:
        hello(fd, 1, 1)
        display_open(fd, 2, 2)

        status, sid = surface_create(fd, 3, 3, 32, 32)
        assert status == 0

        # Accumulation phase: write presents without reading anything.
        # Each reply enqueued takes ~48 bytes; the default max_evq_bytes
        # is 8192, so the queue saturates at roughly 170 presents.
        # We cap the loop well above that to tolerate smaller queues
        # on tuned systems, and well below anything that would suggest
        # a runaway write that never backpressures.
        hit_enospc = False
        presents_written = 0
        MAX_ATTEMPTS = 2000

        for i in range(MAX_ATTEMPTS):
            payload = struct.pack("<IIQ", sid, 0, i)
            frame = make_frame(10 + i, [make_msg(REQ_SURFACE_PRESENT, 100 + i, payload)])
            try:
                os.write(fd, frame)
                presents_written += 1
            except OSError as e:
                if e.errno == errno.ENOSPC:
                    hit_enospc = True
                    break
                raise

        assert hit_enospc, (
            f"Expected write(2) to fail with ENOSPC after queue saturation, "
            f"but {MAX_ATTEMPTS} presents all succeeded. Kernel may not be "
            f"enforcing max_evq_bytes."
        )
        print(f"  Hit ENOSPC after {presents_written} presents "
              f"(write(2) returned errno {errno.ENOSPC})")

        # Drain the queue fully. Each read returns at least one message
        # (reply or event); we poll until no more are readable.
        p = select.poll()
        p.register(fd, select.POLLIN | select.POLLRDNORM)
        drained = 0
        while True:
            ev = p.poll(100)
            if not ev:
                break
            os.read(fd, 4096)
            drained += 1
        print(f"  Drained {drained} messages from the queue")

        # Recovery: a fresh present must now succeed at the write(2) level.
        # We do not assert anything about the reply payload here; the point
        # is just that the write no longer backpressures.
        payload = struct.pack("<IIQ", sid, 0, 0xDEADBEEF)
        frame = make_frame(99000, [make_msg(REQ_SURFACE_PRESENT, 99000, payload)])
        os.write(fd, frame)
        print(f"  Present after drain succeeded (write accepted)")

    finally:
        os.close(fd)


def test_stats_surface_tracking():
    """Stats correctly track surface count and bytes."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        stats0 = s.get_stats()
        assert stats0['surfaces_count'] == 0
        assert stats0['surfaces_bytes'] == 0

        # Create surface
        status, sid, stride, total = s.surface_create(64, 64)
        assert status == 0

        stats1 = s.get_stats()
        assert stats1['surfaces_count'] == 1, f"Expected 1 surface, got {stats1['surfaces_count']}"
        assert stats1['surfaces_bytes'] >= 64 * 64 * 4, f"surfaces_bytes too small"

        # Create another
        status, sid2, stride2, total2 = s.surface_create(128, 128)
        assert status == 0

        stats2 = s.get_stats()
        assert stats2['surfaces_count'] == 2
        assert stats2['surfaces_bytes'] > stats1['surfaces_bytes']

        # Destroy first
        s.surface_destroy(sid)

        stats3 = s.get_stats()
        assert stats3['surfaces_count'] == 1
        assert stats3['surfaces_bytes'] < stats2['surfaces_bytes']

        print(f"  Stats tracking verified: 0 -> 1 -> 2 -> 1 surfaces")


def test_stats_event_tracking():
    """Stats correctly track events enqueued."""
    with DrawSession() as s:
        s.hello()
        s.display_open()

        status, sid, stride, total = s.surface_create(32, 32)
        assert status == 0
        s.map_surface(sid)

        stats0 = s.get_stats()
        initial_events = stats0['events_enqueued']

        # Present 5 times
        for i in range(5):
            s.surface_present(sid, i)
            s.read_presented_event()

        stats1 = s.get_stats()
        new_events = stats1['events_enqueued'] - initial_events
        assert new_events >= 5, f"Expected at least 5 new events, got {new_events}"

        print(f"  Event tracking verified: {new_events} events enqueued")


def main():
    tests = [
        ("Oversized surface", test_oversized_surface),
        ("Max surfaces", test_max_surfaces),
        ("Event queue backpressure", test_event_queue_backpressure),
        ("Stats surface tracking", test_stats_surface_tracking),
        ("Stats event tracking", test_stats_event_tracking),
    ]

    passed = 0
    failed = 0

    for name, test_fn in tests:
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
