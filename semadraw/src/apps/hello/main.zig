//! Hello SemaDraw — minimal example using the App framework.
//!
//! Draws a colored rectangle that changes hue each frame.
//! Press any key or Ctrl-C to quit.
//!
//! Build:
//!   zig build hello
//!
//! Run (requires semadrawd running with drawfs backend):
//!   sudo semadrawd -b drawfs &
//!   ./zig-out/bin/hello

const std = @import("std");
const semadraw = @import("semadraw");

const App = semadraw.App;
const AppEvent = semadraw.AppEvent;
const Encoder = semadraw.Encoder;

const WIDTH: f32 = 1366;
const HEIGHT: f32 = 768;
const DISPLAY_W: f32 = 1366;
const DISPLAY_H: f32 = 768;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title      = "Hello SemaDraw",
        .width      = WIDTH,
        .height     = HEIGHT,
        .x          = 0,
        .y          = 0,
        .target_fps = 60,
    });
    defer app.deinit();

    var dummy: u8 = 0;
    try app.run(&dummy, onDraw, onEvent);
}

fn onDraw(ctx: *anyopaque, enc: *Encoder, frame: u64) !void {
    _ = ctx;
    _ = frame;

    // Dark blue background
    try enc.fillRect(0, 0, WIDTH, HEIGHT, 0.0, 0.0, 0.5, 1.0);

    // Bright red rectangle
    try enc.fillRect(100, 100, 300, 200, 1.0, 0.0, 0.0, 1.0);

    // Bright green rectangle
    try enc.fillRect(200, 200, 300, 200, 0.0, 1.0, 0.0, 1.0);
}

fn onEvent(ctx: *anyopaque, event: AppEvent) !bool {
    _ = ctx;
    return switch (event) {
        .quit => false,
        .key  => |k| if (k.pressed) false else true,
        else  => true,
    };
}
