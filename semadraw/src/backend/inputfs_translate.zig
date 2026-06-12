//! HID Usage Page 0x07 (Keyboard) → evdev code translation.
//!
//! inputfs publishes keyboard events with `hid_usage` values from
//! HID Usage Tables 1.4 §10 (Keyboard/Keypad Page = 0x07). The drawfs
//! backend's KeyEvent.key_code field carries an evdev code by historical
//! contract (semainputd produced evdev codes; clients consume them as
//! such). This module provides the translation that semainputd used to
//! perform implicitly by virtue of reading evdev directly.
//!
//! The table covers HID usage IDs 0x04 (Keyboard A) through 0xE7
//! (Keyboard Right GUI). Usages outside this range translate to 0
//! (sentinel "unmapped"); callers should drop unmapped events rather
//! than forward 0 as if it were a key. Page 0x07 covers ordinary
//! keyboard keys; consumer-control keys (volume, media) live on Usage
//! Page 0x0C and are deferred — inputfs does not currently publish
//! them.
//!
//! References:
//! - USB HID Usage Tables 1.4, §10 Keyboard/Keypad Page (0x07)
//! - Linux input-event-codes.h (KEY_* values; same values used as
//!   the evdev wire contract on FreeBSD via the evdev compatibility
//!   layer, which UTF is in the process of removing — see AD-2a)
//!
//! Stage E note: this translation table is the userland half of the
//! evdev-removal motion. inputfs publishes HID usages because that's
//! what the hardware produces; clients still expect evdev codes
//! because that's what semainputd produced. Eventually the client
//! protocol may switch to HID usages directly (KeyPressMsg.key_code
//! becomes a HID usage), at which point this table goes away. That
//! is not Phase 1's scope; Phase 1 preserves the client-facing wire
//! contract.

const std = @import("std");

/// Translate a HID Usage Page 0x07 ID to an evdev key code.
/// Returns 0 for unmapped usages; caller should drop those events.
pub fn hidUsageToEvdev(hid_usage: u32) u32 {
    // hid_usage from inputfs is the Usage ID alone (Page 0x07 implicit
    // for keyboard events; the source_role = SOURCE_KEYBOARD already
    // identifies the page). Defensive: if the value is large enough
    // to be a (page << 16) | id encoding, mask to the low 16 bits and
    // continue. Production inputfs reports the ID alone.
    const id: u16 = if (hid_usage > 0xFF) @truncate(hid_usage & 0xFFFF) else @truncate(hid_usage);

    return switch (id) {
        // No event indicated and reserved values
        0x00...0x03 => 0,

        // Letters A-Z. HID 0x04..0x1D, evdev KEY_A..KEY_Z (30..44, 16..25, ...).
        // The mapping is not contiguous on either side and is enumerated.
        0x04 => 30,  // a → KEY_A
        0x05 => 48,  // b → KEY_B
        0x06 => 46,  // c → KEY_C
        0x07 => 32,  // d → KEY_D
        0x08 => 18,  // e → KEY_E
        0x09 => 33,  // f → KEY_F
        0x0A => 34,  // g → KEY_G
        0x0B => 35,  // h → KEY_H
        0x0C => 23,  // i → KEY_I
        0x0D => 36,  // j → KEY_J
        0x0E => 37,  // k → KEY_K
        0x0F => 38,  // l → KEY_L
        0x10 => 50,  // m → KEY_M
        0x11 => 49,  // n → KEY_N
        0x12 => 24,  // o → KEY_O
        0x13 => 25,  // p → KEY_P
        0x14 => 16,  // q → KEY_Q
        0x15 => 19,  // r → KEY_R
        0x16 => 31,  // s → KEY_S
        0x17 => 20,  // t → KEY_T
        0x18 => 22,  // u → KEY_U
        0x19 => 47,  // v → KEY_V
        0x1A => 17,  // w → KEY_W
        0x1B => 45,  // x → KEY_X
        0x1C => 21,  // y → KEY_Y
        0x1D => 44,  // z → KEY_Z

        // Top-row digits 1-9 then 0. HID 0x1E..0x27, evdev KEY_1..KEY_0 (2..11).
        0x1E => 2,   // 1
        0x1F => 3,   // 2
        0x20 => 4,   // 3
        0x21 => 5,   // 4
        0x22 => 6,   // 5
        0x23 => 7,   // 6
        0x24 => 8,   // 7
        0x25 => 9,   // 8
        0x26 => 10,  // 9
        0x27 => 11,  // 0

        // Editing and whitespace
        0x28 => 28,  // Return → KEY_ENTER
        0x29 => 1,   // Escape → KEY_ESC
        0x2A => 14,  // Backspace → KEY_BACKSPACE
        0x2B => 15,  // Tab → KEY_TAB
        0x2C => 57,  // Space → KEY_SPACE
        0x2D => 12,  // - and _ → KEY_MINUS
        0x2E => 13,  // = and + → KEY_EQUAL
        0x2F => 26,  // [ and { → KEY_LEFTBRACE
        0x30 => 27,  // ] and } → KEY_RIGHTBRACE
        0x31 => 43,  // \ and | → KEY_BACKSLASH
        0x32 => 43,  // # and ~ (non-US Hash) → KEY_BACKSLASH (same scancode)
        0x33 => 39,  // ; and : → KEY_SEMICOLON
        0x34 => 40,  // ' and " → KEY_APOSTROPHE
        0x35 => 41,  // ` and ~ → KEY_GRAVE
        0x36 => 51,  // , and < → KEY_COMMA
        0x37 => 52,  // . and > → KEY_DOT
        0x38 => 53,  // / and ? → KEY_SLASH
        0x39 => 58,  // CapsLock → KEY_CAPSLOCK

        // Function row F1-F12
        0x3A => 59,  // F1
        0x3B => 60,  // F2
        0x3C => 61,  // F3
        0x3D => 62,  // F4
        0x3E => 63,  // F5
        0x3F => 64,  // F6
        0x40 => 65,  // F7
        0x41 => 66,  // F8
        0x42 => 67,  // F9
        0x43 => 68,  // F10
        0x44 => 87,  // F11
        0x45 => 88,  // F12

        // Editing cluster and navigation
        0x46 => 99,  // PrintScreen → KEY_SYSRQ
        0x47 => 70,  // ScrollLock → KEY_SCROLLLOCK
        0x48 => 119, // Pause → KEY_PAUSE
        0x49 => 110, // Insert
        0x4A => 102, // Home
        0x4B => 104, // PageUp
        0x4C => 111, // Delete (forward) → KEY_DELETE
        0x4D => 107, // End
        0x4E => 109, // PageDown
        0x4F => 106, // RightArrow
        0x50 => 105, // LeftArrow
        0x51 => 108, // DownArrow
        0x52 => 103, // UpArrow

        // Numeric keypad
        0x53 => 69,  // NumLock
        0x54 => 98,  // Keypad / → KEY_KPSLASH
        0x55 => 55,  // Keypad * → KEY_KPASTERISK
        0x56 => 74,  // Keypad - → KEY_KPMINUS
        0x57 => 78,  // Keypad + → KEY_KPPLUS
        0x58 => 96,  // Keypad Enter → KEY_KPENTER
        0x59 => 79,  // Keypad 1
        0x5A => 80,  // Keypad 2
        0x5B => 81,  // Keypad 3
        0x5C => 75,  // Keypad 4
        0x5D => 76,  // Keypad 5
        0x5E => 77,  // Keypad 6
        0x5F => 71,  // Keypad 7
        0x60 => 72,  // Keypad 8
        0x61 => 73,  // Keypad 9
        0x62 => 82,  // Keypad 0
        0x63 => 83,  // Keypad . → KEY_KPDOT

        // Non-US backslash (ISO key)
        0x64 => 86,  // KEY_102ND
        0x65 => 127, // Application (Menu key) → KEY_COMPOSE
        0x66 => 116, // Power → KEY_POWER
        0x67 => 117, // Keypad = → KEY_KPEQUAL

        // F13-F24
        0x68 => 183, // F13
        0x69 => 184, // F14
        0x6A => 185, // F15
        0x6B => 186, // F16
        0x6C => 187, // F17
        0x6D => 188, // F18
        0x6E => 189, // F19
        0x6F => 190, // F20
        0x70 => 191, // F21
        0x71 => 192, // F22
        0x72 => 193, // F23
        0x73 => 194, // F24

        // Modifiers (HID 0xE0..0xE7 → KEY_LEFT/RIGHT_{CTRL,SHIFT,ALT,META})
        0xE0 => 29,  // LeftControl → KEY_LEFTCTRL
        0xE1 => 42,  // LeftShift → KEY_LEFTSHIFT
        0xE2 => 56,  // LeftAlt → KEY_LEFTALT
        0xE3 => 125, // LeftGUI → KEY_LEFTMETA
        0xE4 => 97,  // RightControl → KEY_RIGHTCTRL
        0xE5 => 54,  // RightShift → KEY_RIGHTSHIFT
        0xE6 => 100, // RightAlt → KEY_RIGHTALT
        0xE7 => 126, // RightGUI → KEY_RIGHTMETA

        else => 0, // Unmapped: caller drops the event.
    };
}

/// Translate a HID modifier byte (USB HID Boot Keyboard layout) to the
/// backend KeyEvent modifier byte format.
///
/// HID modifier byte layout (from USB HID Usage Tables 1.4 §10):
///   bit 0: Left Ctrl
///   bit 1: Left Shift
///   bit 2: Left Alt
///   bit 3: Left GUI / Meta
///   bit 4: Right Ctrl
///   bit 5: Right Shift
///   bit 6: Right Alt
///   bit 7: Right GUI / Meta
///
/// Backend KeyEvent.modifiers layout (from backend/backend.zig):
///   bit 0: Shift  (Modifiers.SHIFT in semadraw-term)
///   bit 1: Alt    (Modifiers.ALT)
///   bit 2: Ctrl   (Modifiers.CTRL)
///   bit 3: Meta
///
/// Pre-AD-14 follow-up (this commit): inputfs_input.zig forwarded the
/// raw HID modifier byte directly to KeyEvent.modifiers, which made
/// every modifier register as the wrong key. Alt+N (new session)
/// arrived at the client as Ctrl+N (HID bit 2 = LAlt; client bit 2 =
/// Ctrl), and the session-switch handler's `if (modifiers & ALT == 0)
/// return false` was always true. Symptom: framebuffer keyboard
/// could not open or close virtual consoles (Alt+N, Alt+W silently
/// dropped); could not switch sessions (Alt+F1..F8 also routed
/// through the same broken modifier byte). Diagnosed bare-metal
/// 2026-05-05 Sunday afternoon after AD-14 closure unblocked
/// release-build verification of multi-session features.
pub fn hidModifiersToBackend(hid_modifiers: u8) u8 {
    var out: u8 = 0;
    // Shift: bit 1 (left) or bit 5 (right) → out bit 0
    if ((hid_modifiers & 0x22) != 0) out |= 0x01;
    // Alt: bit 2 (left) or bit 6 (right) → out bit 1
    if ((hid_modifiers & 0x44) != 0) out |= 0x02;
    // Ctrl: bit 0 (left) or bit 4 (right) → out bit 2
    if ((hid_modifiers & 0x11) != 0) out |= 0x04;
    // Meta: bit 3 (left) or bit 7 (right) → out bit 3
    if ((hid_modifiers & 0x88) != 0) out |= 0x08;
    return out;
}

// ============================================================================
// Tests
// ============================================================================

test "letters map A through Z" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 30), hidUsageToEvdev(0x04)); // a
    try testing.expectEqual(@as(u32, 48), hidUsageToEvdev(0x05)); // b
    try testing.expectEqual(@as(u32, 17), hidUsageToEvdev(0x1A)); // w
    try testing.expectEqual(@as(u32, 44), hidUsageToEvdev(0x1D)); // z
}

test "modifiers map left and right" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 29),  hidUsageToEvdev(0xE0)); // LCtrl
    try testing.expectEqual(@as(u32, 42),  hidUsageToEvdev(0xE1)); // LShift
    try testing.expectEqual(@as(u32, 56),  hidUsageToEvdev(0xE2)); // LAlt
    try testing.expectEqual(@as(u32, 125), hidUsageToEvdev(0xE3)); // LGUI
    try testing.expectEqual(@as(u32, 97),  hidUsageToEvdev(0xE4)); // RCtrl
    try testing.expectEqual(@as(u32, 54),  hidUsageToEvdev(0xE5)); // RShift
    try testing.expectEqual(@as(u32, 100), hidUsageToEvdev(0xE6)); // RAlt
    try testing.expectEqual(@as(u32, 126), hidUsageToEvdev(0xE7)); // RGUI
}

test "function keys F1 through F12" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 59), hidUsageToEvdev(0x3A)); // F1
    try testing.expectEqual(@as(u32, 88), hidUsageToEvdev(0x45)); // F12
}

test "navigation cluster" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 103), hidUsageToEvdev(0x52)); // Up
    try testing.expectEqual(@as(u32, 108), hidUsageToEvdev(0x51)); // Down
    try testing.expectEqual(@as(u32, 105), hidUsageToEvdev(0x50)); // Left
    try testing.expectEqual(@as(u32, 106), hidUsageToEvdev(0x4F)); // Right
}

test "unmapped usages return zero" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), hidUsageToEvdev(0x00));   // reserved
    try testing.expectEqual(@as(u32, 0), hidUsageToEvdev(0x03));   // reserved
    try testing.expectEqual(@as(u32, 0), hidUsageToEvdev(0xA5));   // unassigned
    try testing.expectEqual(@as(u32, 0), hidUsageToEvdev(0x500));  // beyond page
}

test "page-prefixed usage masks to ID" {
    const testing = std.testing;
    // If kernel ever publishes (page << 16) | id, defensive masking
    // recovers the ID. Today inputfs publishes the ID alone.
    try testing.expectEqual(@as(u32, 30), hidUsageToEvdev(0x00070004)); // a
}

test "modifier translation maps left and right HID modifiers" {
    const testing = std.testing;
    // No modifiers
    try testing.expectEqual(@as(u8, 0x00), hidModifiersToBackend(0x00));
    // Single left modifiers
    try testing.expectEqual(@as(u8, 0x04), hidModifiersToBackend(0x01)); // LCtrl  → CTRL
    try testing.expectEqual(@as(u8, 0x01), hidModifiersToBackend(0x02)); // LShift → SHIFT
    try testing.expectEqual(@as(u8, 0x02), hidModifiersToBackend(0x04)); // LAlt   → ALT
    try testing.expectEqual(@as(u8, 0x08), hidModifiersToBackend(0x08)); // LMeta  → META
    // Single right modifiers (must produce same backend bits as left)
    try testing.expectEqual(@as(u8, 0x04), hidModifiersToBackend(0x10)); // RCtrl  → CTRL
    try testing.expectEqual(@as(u8, 0x01), hidModifiersToBackend(0x20)); // RShift → SHIFT
    try testing.expectEqual(@as(u8, 0x02), hidModifiersToBackend(0x40)); // RAlt   → ALT
    try testing.expectEqual(@as(u8, 0x08), hidModifiersToBackend(0x80)); // RMeta  → META
    // Combined left and right of the same modifier collapse to one bit
    try testing.expectEqual(@as(u8, 0x04), hidModifiersToBackend(0x11)); // LCtrl|RCtrl
    try testing.expectEqual(@as(u8, 0x02), hidModifiersToBackend(0x44)); // LAlt|RAlt
    // Multiple distinct modifiers produce multiple bits
    try testing.expectEqual(@as(u8, 0x06), hidModifiersToBackend(0x05)); // LCtrl+LAlt → CTRL+ALT
    try testing.expectEqual(@as(u8, 0x07), hidModifiersToBackend(0x07)); // LCtrl+LShift+LAlt → CTRL+SHIFT+ALT
    try testing.expectEqual(@as(u8, 0x0F), hidModifiersToBackend(0xFF)); // all modifiers
}
