#!/usr/bin/env python3
"""
gen_constants.py — Protocol constants code generator for the Unified Temporal Fabric.

Reads shared/protocol_constants.json and emits generated constant blocks for:
  - drawfs/sys/dev/drawfs/drawfs_proto.h  (C enums: drawfs_msg_type, drawfs_err_code)
  - semadraw/src/ipc/protocol.zig         (Zig enum: MsgType, ErrorCode)
  - semadraw/src/sdcs.zig                 (Zig struct: Op pub consts)

Usage:
  # Generate and write to disk:
  python3 gen_constants.py

  # Validate only (exit non-zero if generated output differs from existing files):
  python3 gen_constants.py --validate

  # Print generated output without writing:
  python3 gen_constants.py --dry-run

The generator rewrites only the generated sections within each target file,
identified by sentinel comment markers:
  /* BEGIN GENERATED CONSTANTS */  ...  /* END GENERATED CONSTANTS */
  // BEGIN GENERATED CONSTANTS     ...  // END GENERATED CONSTANTS

If sentinels are absent the generator exits with an error rather than
overwriting arbitrary file content.
"""

import argparse
import json
import os
import sys
import textwrap

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPEC_PATH = os.path.join(REPO_ROOT, "shared", "protocol_constants.json")

# Target files and their sentinel style.
TARGET_DRAWFS_H = os.path.join(
    REPO_ROOT, "drawfs", "sys", "dev", "drawfs", "drawfs_proto.h"
)
TARGET_PROTOCOL_ZIG = os.path.join(
    REPO_ROOT, "semadraw", "src", "ipc", "protocol.zig"
)
TARGET_SDCS_ZIG = os.path.join(REPO_ROOT, "semadraw", "src", "sdcs.zig")

C_BEGIN = "/* BEGIN GENERATED CONSTANTS */"
C_END = "/* END GENERATED CONSTANTS */"
ZIG_BEGIN = "// BEGIN GENERATED CONSTANTS"
ZIG_END = "// END GENERATED CONSTANTS"

GENERATOR_NOTE_C = (
    "/* Do not edit. Generated from shared/protocol_constants.json\n"
    " * by shared/tools/gen_constants.py */\n"
)
GENERATOR_NOTE_ZIG = (
    "// Do not edit. Generated from shared/protocol_constants.json\n"
    "// by shared/tools/gen_constants.py\n"
)


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def gen_drawfs_h_main(spec: dict) -> str:
    """Generate drawfs_msg_type and drawfs_err_code enum blocks."""
    dp = spec["drawfs_protocol"]
    mt = dp["message_types"]
    ec = dp["error_codes"]
    lines = [GENERATOR_NOTE_C]

    # drawfs_msg_type: RPL first, then REQ.
    lines.append("enum drawfs_msg_type {")
    lines.append("    /* Replies (0x8xxx) */")
    for name, entry in mt["replies"].items():
        val = entry["value"]
        desc = entry["description"]
        lines.append(f"    DRAWFS_{name:<30} = {val},  /* {desc} */")
    lines.append("")
    lines.append("    /* Requests (0x0xxx) */")
    for name, entry in mt["requests"].items():
        val = entry["value"]
        desc = entry["description"]
        lines.append(f"    DRAWFS_{name:<30} = {val},  /* {desc} */")
    lines.append("};")
    lines.append("")

    # drawfs_err_code
    lines.append("enum drawfs_err_code {")
    for name, entry in ec.items():
        val = entry["value"]
        desc = entry["description"]
        lines.append(f"    DRAWFS_{name:<30} = {val},  /* {desc} */")
    lines.append("};")

    return "\n".join(lines)


def gen_drawfs_h_events(spec: dict) -> str:
    """Generate drawfs_event_type enum block."""
    dp = spec["drawfs_protocol"]
    mt = dp["message_types"]
    lines = [GENERATOR_NOTE_C]

    lines.append("enum drawfs_event_type {")
    lines.append("    /* Events (0x9xxx) */")
    for name, entry in mt["events"].items():
        val = entry["value"]
        desc = entry["description"]
        lines.append(f"    DRAWFS_{name:<30} = {val},  /* {desc} */")
    lines.append("};")

    return "\n".join(lines)


def _to_snake(name: str) -> str:
    """Convert SCREAMING_SNAKE to snake_case."""
    return name.lower()


def gen_sdcs_zig(spec: dict) -> str:
    """Generate the Op pub const block for sdcs.zig."""
    sdcs = spec["sdcs"]
    opcodes = sdcs["opcodes"]
    lines = [GENERATOR_NOTE_ZIG]

    lines.append("pub const Op = struct {")

    for group_name, group in opcodes.items():
        if group_name.startswith("_"):
            continue
        lines.append(f"    // {group_name.capitalize()} opcodes")
        for name, entry in group.items():
            if name.startswith("_"):
                continue
            val = entry["value"]
            desc = entry["description"]
            payload = entry.get("payload")
            payload_note = f" payload={payload}b" if payload is not None and payload >= 0 else (
                " payload=variable" if payload == -1 else ""
            )
            lines.append(f"    pub const {name}: u16 = {val}; // {desc}{payload_note}")
        lines.append("")

    # Remove trailing blank line before closing brace.
    if lines[-1] == "":
        lines.pop()
    lines.append("};")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# File patching
# ---------------------------------------------------------------------------

def patch_file(path: str, generated: str, begin_sentinel: str, end_sentinel: str) -> str:
    """
    Replace the content between begin_sentinel and end_sentinel in the file
    at `path` with `generated`. Returns the new full file content.
    Raises if sentinels are not found or appear out of order.
    """
    with open(path, "r", encoding="utf-8") as f:
        original = f.read()

    begin_idx = original.find(begin_sentinel)
    end_idx = original.find(end_sentinel)

    if begin_idx == -1:
        raise ValueError(
            f"{path}: missing begin sentinel '{begin_sentinel}'\n"
            f"Add '{begin_sentinel}' and '{end_sentinel}' markers around the "
            f"generated section in this file."
        )
    if end_idx == -1:
        raise ValueError(
            f"{path}: missing end sentinel '{end_sentinel}'"
        )
    if end_idx <= begin_idx:
        raise ValueError(
            f"{path}: end sentinel appears before begin sentinel"
        )

    # Include sentinels in the preserved prefix/suffix.
    prefix = original[: begin_idx + len(begin_sentinel)]
    suffix = original[end_idx:]

    return f"{prefix}\n{generated}\n{suffix}"


def validate_file(path: str, generated: str, begin_sentinel: str, end_sentinel: str) -> list[str]:
    """
    Return a list of diff lines if the generated content differs from what is
    currently in the file between the sentinels. Returns [] if identical.
    """
    import difflib

    with open(path, "r", encoding="utf-8") as f:
        original = f.read()

    begin_idx = original.find(begin_sentinel)
    end_idx = original.find(end_sentinel)

    if begin_idx == -1 or end_idx == -1 or end_idx <= begin_idx:
        return [f"  MISSING sentinels in {path}"]

    current = original[begin_idx + len(begin_sentinel) : end_idx].strip()
    expected = generated.strip()

    if current == expected:
        return []

    diff = list(
        difflib.unified_diff(
            current.splitlines(keepends=True),
            expected.splitlines(keepends=True),
            fromfile=f"{path} (current)",
            tofile=f"{path} (generated)",
            n=3,
        )
    )
    return diff


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def load_spec() -> dict:
    with open(SPEC_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def gen_protocol_zig_msg_type(spec: dict) -> str:
    """Generate only the MsgType enum block for protocol.zig."""
    si = spec["semadraw_ipc"]
    mt = si["message_types"]
    lines = [GENERATOR_NOTE_ZIG]

    lines.append("pub const MsgType = enum(u16) {")
    lines.append("    // Client -> Daemon requests (0x0xxx)")
    for name, entry in mt["requests"].items():
        snake = _to_snake(name)
        lines.append(f"    {snake} = {entry['value']}, // {entry['description']}")
    lines.append("")
    lines.append("    // Daemon -> Client responses (0x8xxx)")
    for name, entry in mt["replies"].items():
        snake = _to_snake(name)
        lines.append(f"    {snake} = {entry['value']}, // {entry['description']}")
    lines.append("")
    lines.append("    // Daemon -> Client events (0x9xxx)")
    for name, entry in mt["events"].items():
        snake = _to_snake(name)
        lines.append(f"    {snake} = {entry['value']}, // {entry['description']}")
    lines.append("};")
    return "\n".join(lines)


def gen_protocol_zig_error_code(spec: dict) -> str:
    """Generate only the ErrorCode enum block for protocol.zig."""
    si = spec["semadraw_ipc"]
    ec = si["error_codes"]
    lines = [GENERATOR_NOTE_ZIG]

    lines.append("pub const ErrorCode = enum(u32) {")
    for name, entry in ec.items():
        snake = _to_snake(name)
        lines.append(f"    {snake} = {entry['value']}, // {entry['description']}")
    lines.append("};")
    return "\n".join(lines)


def build_targets(spec: dict) -> list[tuple[str, str, str, str]]:
    """Return list of (path, generated_content, begin_sentinel, end_sentinel)."""
    return [
        (TARGET_DRAWFS_H,
         gen_drawfs_h_main(spec),
         "/* BEGIN GENERATED CONSTANTS */",
         "/* END GENERATED CONSTANTS */"),
        (TARGET_DRAWFS_H,
         gen_drawfs_h_events(spec),
         "/* BEGIN GENERATED CONSTANTS: events */",
         "/* END GENERATED CONSTANTS: events */"),
        (TARGET_PROTOCOL_ZIG,
         gen_protocol_zig_msg_type(spec),
         "// BEGIN GENERATED CONSTANTS: msg_type",
         "// END GENERATED CONSTANTS: msg_type"),
        (TARGET_PROTOCOL_ZIG,
         gen_protocol_zig_error_code(spec),
         "// BEGIN GENERATED CONSTANTS: error_code",
         "// END GENERATED CONSTANTS: error_code"),
        (TARGET_SDCS_ZIG,
         gen_sdcs_zig(spec),
         ZIG_BEGIN,
         ZIG_END),
    ]


def cmd_generate(targets: list, dry_run: bool) -> int:
    ok = True
    for path, generated, begin, end in targets:
        try:
            patched = patch_file(path, generated, begin, end)
        except ValueError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            ok = False
            continue

        if dry_run:
            rel = os.path.relpath(path, REPO_ROOT)
            print(f"--- {rel} (would write) ---")
            print(generated)
            print()
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(patched)
            rel = os.path.relpath(path, REPO_ROOT)
            print(f"  wrote  {rel}")

    return 0 if ok else 1


def cmd_validate(targets: list) -> int:
    all_clean = True
    for path, generated, begin, end in targets:
        rel = os.path.relpath(path, REPO_ROOT)
        try:
            diff = validate_file(path, generated, begin, end)
        except FileNotFoundError:
            print(f"  MISSING  {rel}")
            all_clean = False
            continue

        if diff:
            print(f"  DRIFT    {rel}")
            sys.stdout.writelines(diff)
            all_clean = False
        else:
            print(f"  OK       {rel}")

    if not all_clean:
        print(
            "\nValidation failed. Run 'python3 shared/tools/gen_constants.py' to sync.",
            file=sys.stderr,
        )
        return 1

    print("\nAll constants match the specification.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate or validate protocol constants from protocol_constants.json."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--validate",
        action="store_true",
        help="Check that existing files match the spec. Exit non-zero on drift.",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Print generated output without writing to disk.",
    )
    args = parser.parse_args()

    try:
        spec = load_spec()
    except FileNotFoundError:
        print(f"ERROR: spec not found at {SPEC_PATH}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON in spec: {e}", file=sys.stderr)
        return 1

    targets = build_targets(spec)

    if args.validate:
        return cmd_validate(targets)
    else:
        return cmd_generate(targets, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
