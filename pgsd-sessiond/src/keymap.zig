// pgsd-sessiond/src/keymap.zig
//
// evdev keycode constants and US-QWERTY ASCII translation for the
// login UI's text-entry fields.
//
// The keycode set is the Linux/FreeBSD evdev keycode table from
// <linux/input-event-codes.h>. semadrawd delivers key_press events
// with these codes; ui.zig consumes them as semadraw.AppEvent.key
// (a shape inherited from when this code used the App framework;
// main.zig now does the translation from the raw client.Event
// itself, since Stage 5 dropped App in favor of a direct-connection
// loop that can query output dimensions before surface creation).
// The keycode block here was lifted from semadraw/src/apps/term/main.zig
// (the Key struct, evdev codes 1-111). semadraw-term's full keymap
// covers function keys, arrows, page-up/down, etc.; pgsd-sessiond's
// login UI needs printable ASCII plus a few control keys (Enter,
// Backspace, Escape, Ctrl-Q for quit, and Stage 7 adds Tab and
// Up/Down arrows for the session-picker overlay), so this file is
// still a trimmed subset.
//
// Modifier bits per semadraw's KeyPressMsg:
//   bit 0 = shift
//   bit 1 = alt
//   bit 2 = ctrl
//   bit 3 = meta
//
// US-QWERTY only in v1. Stage 8 (or a separate ADR) would add
// alternate keymaps; for now, the login UI is operator-facing on
// systems where the operator's keyboard layout is known.

const std = @import("std");

// =============================================================================
// evdev keycodes
// =============================================================================

pub const Key = struct {
    pub const ESC: u32 = 1;
    pub const @"1": u32 = 2;
    pub const @"2": u32 = 3;
    pub const @"3": u32 = 4;
    pub const @"4": u32 = 5;
    pub const @"5": u32 = 6;
    pub const @"6": u32 = 7;
    pub const @"7": u32 = 8;
    pub const @"8": u32 = 9;
    pub const @"9": u32 = 10;
    pub const @"0": u32 = 11;
    pub const MINUS: u32 = 12;
    pub const EQUAL: u32 = 13;
    pub const BACKSPACE: u32 = 14;
    pub const TAB: u32 = 15;
    pub const Q: u32 = 16;
    pub const W: u32 = 17;
    pub const E: u32 = 18;
    pub const R: u32 = 19;
    pub const T: u32 = 20;
    pub const Y: u32 = 21;
    pub const U: u32 = 22;
    pub const I: u32 = 23;
    pub const O: u32 = 24;
    pub const P: u32 = 25;
    pub const LEFTBRACE: u32 = 26;
    pub const RIGHTBRACE: u32 = 27;
    pub const ENTER: u32 = 28;
    pub const A: u32 = 30;
    pub const S: u32 = 31;
    pub const D: u32 = 32;
    pub const F: u32 = 33;
    pub const G: u32 = 34;
    pub const H: u32 = 35;
    pub const J: u32 = 36;
    pub const K: u32 = 37;
    pub const L: u32 = 38;
    pub const SEMICOLON: u32 = 39;
    pub const APOSTROPHE: u32 = 40;
    pub const GRAVE: u32 = 41;
    pub const BACKSLASH: u32 = 43;
    pub const Z: u32 = 44;
    pub const X: u32 = 45;
    pub const C: u32 = 46;
    pub const V: u32 = 47;
    pub const B: u32 = 48;
    pub const N: u32 = 49;
    pub const M: u32 = 50;
    pub const COMMA: u32 = 51;
    pub const DOT: u32 = 52;
    pub const SLASH: u32 = 53;
    pub const SPACE: u32 = 57;

    // Navigation keys (Stage 7: session picker).
    pub const UP: u32 = 103;
    pub const DOWN: u32 = 108;
};

// =============================================================================
// Modifier bits per semadraw KeyPressMsg
// =============================================================================

pub const Mod = struct {
    pub const SHIFT: u8 = 1 << 0;
    pub const ALT: u8 = 1 << 1;
    pub const CTRL: u8 = 1 << 2;
    pub const META: u8 = 1 << 3;
};

// =============================================================================
// Translation
// =============================================================================
//
// Map (keycode, modifiers) to a printable ASCII character, OR to one of
// a small set of named control actions. The action set is what the
// login UI cares about distinguishing: print a character, delete the
// previous character, submit the field, clear the field, quit the app.
//
// Unknown keys and key combinations the UI doesn't care about return
// .none.

pub const Action = union(enum) {
    none,
    print: u8, // printable ASCII byte to append to the active field
    backspace,
    enter,
    clear, // ESC - clear current field, stay in current state

    /// Ctrl-Q - open the power menu (Stage 8). Replaces the
    /// previous Stage 6 semantics of "exit the daemon". Once
    /// session looping landed, exiting the daemon from the login
    /// screen stopped making sense; the operator powers off,
    /// restarts, or suspends via the menu instead. From any
    /// state where it's reasonable (identify, password, picker),
    /// Ctrl-Q opens a centered overlay with three power options.
    /// SIGTERM from another shell is the only way to exit the
    /// daemon in v1 (used by the supervisor in Stage 9).
    power_menu,

    // Stage 7: session picker navigation.
    tab, // Tab - open picker from password field, or confirm + close
    up, // Up arrow - move picker cursor up
    down, // Down arrow - move picker cursor down
};

pub fn translate(key_code: u32, modifiers: u8) Action {
    const shift = (modifiers & Mod.SHIFT) != 0;
    const ctrl = (modifiers & Mod.CTRL) != 0;

    // Ctrl-Q opens the Stage 8 power menu regardless of shift.
    if (ctrl and key_code == Key.Q) return .power_menu;

    // Other Ctrl combos: ignored. The login UI does not need Ctrl-C
    // (no copy/paste in v1), Ctrl-U (would clear; we use ESC for
    // that), or any other control combination.
    if (ctrl) return .none;

    // Named control keys.
    switch (key_code) {
        Key.ENTER => return .enter,
        Key.BACKSPACE => return .backspace,
        Key.ESC => return .clear,
        Key.SPACE => return .{ .print = ' ' },
        Key.TAB => return .tab,
        Key.UP => return .up,
        Key.DOWN => return .down,
        else => {},
    }

    // Letter keys: ASCII-26 lowercase, shift-uppercase. ctrl was
    // already returned above.
    const letter: ?u8 = switch (key_code) {
        Key.A => 'a',
        Key.B => 'b',
        Key.C => 'c',
        Key.D => 'd',
        Key.E => 'e',
        Key.F => 'f',
        Key.G => 'g',
        Key.H => 'h',
        Key.I => 'i',
        Key.J => 'j',
        Key.K => 'k',
        Key.L => 'l',
        Key.M => 'm',
        Key.N => 'n',
        Key.O => 'o',
        Key.P => 'p',
        Key.Q => 'q',
        Key.R => 'r',
        Key.S => 's',
        Key.T => 't',
        Key.U => 'u',
        Key.V => 'v',
        Key.W => 'w',
        Key.X => 'x',
        Key.Y => 'y',
        Key.Z => 'z',
        else => null,
    };
    if (letter) |c| {
        return .{ .print = if (shift) c - 32 else c };
    }

    // Digit row with shift symbols matching US QWERTY.
    const digit_pair: ?[2]u8 = switch (key_code) {
        Key.@"1" => .{ '1', '!' },
        Key.@"2" => .{ '2', '@' },
        Key.@"3" => .{ '3', '#' },
        Key.@"4" => .{ '4', '$' },
        Key.@"5" => .{ '5', '%' },
        Key.@"6" => .{ '6', '^' },
        Key.@"7" => .{ '7', '&' },
        Key.@"8" => .{ '8', '*' },
        Key.@"9" => .{ '9', '(' },
        Key.@"0" => .{ '0', ')' },
        else => null,
    };
    if (digit_pair) |pair| {
        return .{ .print = if (shift) pair[1] else pair[0] };
    }

    // Punctuation row.
    const punct_pair: ?[2]u8 = switch (key_code) {
        Key.MINUS => .{ '-', '_' },
        Key.EQUAL => .{ '=', '+' },
        Key.LEFTBRACE => .{ '[', '{' },
        Key.RIGHTBRACE => .{ ']', '}' },
        Key.SEMICOLON => .{ ';', ':' },
        Key.APOSTROPHE => .{ '\'', '"' },
        Key.GRAVE => .{ '`', '~' },
        Key.BACKSLASH => .{ '\\', '|' },
        Key.COMMA => .{ ',', '<' },
        Key.DOT => .{ '.', '>' },
        Key.SLASH => .{ '/', '?' },
        else => null,
    };
    if (punct_pair) |pair| {
        return .{ .print = if (shift) pair[1] else pair[0] };
    }

    return .none;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "translate lowercase letter without modifiers" {
    const act = translate(Key.A, 0);
    try testing.expect(act == .print);
    try testing.expectEqual(@as(u8, 'a'), act.print);
}

test "translate uppercase letter with shift" {
    const act = translate(Key.A, Mod.SHIFT);
    try testing.expect(act == .print);
    try testing.expectEqual(@as(u8, 'A'), act.print);
}

test "translate digit without modifier" {
    const act = translate(Key.@"1", 0);
    try testing.expect(act == .print);
    try testing.expectEqual(@as(u8, '1'), act.print);
}

test "translate digit with shift produces symbol" {
    const act = translate(Key.@"1", Mod.SHIFT);
    try testing.expect(act == .print);
    try testing.expectEqual(@as(u8, '!'), act.print);
}

test "translate punctuation pairs" {
    try testing.expectEqual(@as(u8, '-'), translate(Key.MINUS, 0).print);
    try testing.expectEqual(@as(u8, '_'), translate(Key.MINUS, Mod.SHIFT).print);
    try testing.expectEqual(@as(u8, '.'), translate(Key.DOT, 0).print);
    try testing.expectEqual(@as(u8, '/'), translate(Key.SLASH, 0).print);
    try testing.expectEqual(@as(u8, '?'), translate(Key.SLASH, Mod.SHIFT).print);
}

test "translate space" {
    const act = translate(Key.SPACE, 0);
    try testing.expect(act == .print);
    try testing.expectEqual(@as(u8, ' '), act.print);
}

test "translate enter, backspace, escape" {
    try testing.expectEqual(Action.enter, translate(Key.ENTER, 0));
    try testing.expectEqual(Action.backspace, translate(Key.BACKSPACE, 0));
    try testing.expectEqual(Action.clear, translate(Key.ESC, 0));
}

test "Ctrl-Q opens the power menu regardless of shift (Stage 8)" {
    try testing.expectEqual(Action.power_menu, translate(Key.Q, Mod.CTRL));
    try testing.expectEqual(Action.power_menu, translate(Key.Q, Mod.CTRL | Mod.SHIFT));
}

test "other Ctrl combos are ignored" {
    try testing.expectEqual(Action.none, translate(Key.A, Mod.CTRL));
    try testing.expectEqual(Action.none, translate(Key.C, Mod.CTRL));
    try testing.expectEqual(Action.none, translate(Key.V, Mod.CTRL));
}

test "Tab translates to .tab action" {
    try testing.expectEqual(Action.tab, translate(Key.TAB, 0));
}

test "Up arrow translates to .up" {
    try testing.expectEqual(Action.up, translate(Key.UP, 0));
}

test "Down arrow translates to .down" {
    try testing.expectEqual(Action.down, translate(Key.DOWN, 0));
}

test "unknown keycode returns none" {
    try testing.expectEqual(Action.none, translate(999, 0));
}
