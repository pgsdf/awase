const std = @import("std");
const posix = std.posix;
const client = @import("semadraw_client");
const semadraw = @import("semadraw");

const log = std.log.scoped(.graphics_demo);

pub const std_options = std.Options{
    .log_level = .info,
};

const WIDTH: f32 = 400;
const HEIGHT: f32 = 300;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var socket_path: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i >= args.len) {
                log.err("missing argument for {s}", .{arg});
                return error.InvalidArgument;
            }
            socket_path = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
            try stdout_file.writeAll(
                \\semadraw-demo - Graphics demo for SemaDraw
                \\
                \\Usage: semadraw-demo [OPTIONS]
                \\
                \\Options:
                \\  -s, --socket PATH  Daemon socket path
                \\  -h, --help         Show this help
                \\
                \\This demo displays animated graphics using the SemaDraw API.
                \\Press Ctrl+C or close the window to exit.
                \\
            );
            return;
        }
    }

    // Connect to daemon
    log.info("connecting to semadrawd...", .{});
    const conn = if (socket_path) |path|
        try client.Connection.connectTo(allocator, path)
    else
        try client.Connection.connect(allocator);
    defer conn.disconnect();

    log.info("connected, creating surface...", .{});

    // Create surface
    var surface = try client.Surface.create(conn, WIDTH, HEIGHT);
    defer surface.destroy();

    // Set higher z-order so demo appears on top of other windows (like terminal)
    try surface.setZOrder(100);
    // Position demo in the bottom-right area (offset from top-left)
    try surface.setPosition(400, 300);
    try surface.setVisible(true);

    log.info("surface created, starting animation...", .{});

    // Animation state
    var encoder = semadraw.Encoder.init(allocator);
    defer encoder.deinit();

    var frame: u32 = 0;
    var running = true;

    while (running) {
        // Render frame
        try renderFrame(&encoder, frame);
        const sdcs_data = try encoder.finishBytesWithHeader();
        defer allocator.free(sdcs_data);

        try surface.attachAndCommit(sdcs_data);

        frame +%= 1;

        // Process events
        while (conn.poll() catch null) |event| {
            switch (event) {
                .key_press => |key| {
                    // ESC or Q to quit
                    if (key.key_code == 1 or key.key_code == 16) {
                        running = false;
                    }
                },
                .disconnected => {
                    running = false;
                },
                else => {},
            }
        }

        // ~30 FPS (33ms = 0 seconds, 33_000_000 nanoseconds)
        posix.nanosleep(0, 33_000_000);
    }

    log.info("demo finished", .{});
}

fn renderFrame(enc: *semadraw.Encoder, frame: u32) !void {
    try enc.reset();

    const t: f32 = @as(f32, @floatFromInt(frame)) * 0.02;

    // Semi-transparent dark background so terminal shows through
    const bg_r = 0.05 + 0.02 * @sin(t * 0.5);
    const bg_g = 0.05 + 0.02 * @sin(t * 0.7);
    const bg_b = 0.1 + 0.03 * @sin(t * 0.3);
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);
    try enc.fillRect(0, 0, WIDTH, HEIGHT, bg_r, bg_g, bg_b, 0.85); // 85% opacity
    try enc.setAntialias(true);

    // Rotating bezier curves
    const cx = WIDTH / 2;
    const cy = HEIGHT / 2;
    const radius: f32 = 120; // Scaled to fit within 400x300 surface

    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const angle = t + @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
        const next_angle = angle + std.math.pi / 3.0;

        const x1 = cx + radius * @cos(angle);
        const y1 = cy + radius * @sin(angle);
        const x2 = cx + radius * @cos(next_angle);
        const y2 = cy + radius * @sin(next_angle);

        // Control points spiral inward
        const ctrl_radius = radius * 0.6;
        const ctrl_angle = (angle + next_angle) / 2.0 + t * 0.5;
        const ctrl_x = cx + ctrl_radius * @cos(ctrl_angle);
        const ctrl_y = cy + ctrl_radius * @sin(ctrl_angle);

        // Rainbow colors
        const hue = @as(f32, @floatFromInt(i)) / 6.0 + t * 0.1;
        const r = 0.5 + 0.5 * @sin(hue * std.math.pi * 2.0);
        const g = 0.5 + 0.5 * @sin((hue + 0.33) * std.math.pi * 2.0);
        const b = 0.5 + 0.5 * @sin((hue + 0.66) * std.math.pi * 2.0);

        try enc.strokeQuadBezier(x1, y1, ctrl_x, ctrl_y, x2, y2, 3.0, r, g, b, 0.8);
    }

    // Orbiting circles
    var j: u32 = 0;
    while (j < 8) : (j += 1) {
        const orbit_angle = t * 1.5 + @as(f32, @floatFromInt(j)) * std.math.pi / 4.0;
        const orbit_radius: f32 = 80 + 30 * @sin(t * 2 + @as(f32, @floatFromInt(j)));
        const orb_x = cx + orbit_radius * @cos(orbit_angle);
        const orb_y = cy + orbit_radius * @sin(orbit_angle);
        const orb_size: f32 = 12 + 8 * @sin(t * 3 + @as(f32, @floatFromInt(j)));

        // Gradient-like effect with alpha
        const alpha = 0.6 + 0.3 * @sin(t * 2 + @as(f32, @floatFromInt(j)));
        try enc.fillRect(orb_x - orb_size / 2, orb_y - orb_size / 2, orb_size, orb_size, 1.0, 0.8, 0.2, alpha);
    }

    // Pulsing center
    const pulse = 30 + 20 * @sin(t * 4);
    try enc.setBlend(semadraw.Encoder.BlendMode.Add);
    try enc.fillRect(cx - pulse, cy - pulse, pulse * 2, pulse * 2, 0.3, 0.3, 0.5, 0.5);
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // Corner decorations
    const corner_size: f32 = 80;
    // Top-left
    try enc.strokeLine(10, 10, 10 + corner_size, 10, 2, 0.4, 0.8, 1.0, 0.7);
    try enc.strokeLine(10, 10, 10, 10 + corner_size, 2, 0.4, 0.8, 1.0, 0.7);
    // Top-right
    try enc.strokeLine(WIDTH - 10, 10, WIDTH - 10 - corner_size, 10, 2, 0.4, 0.8, 1.0, 0.7);
    try enc.strokeLine(WIDTH - 10, 10, WIDTH - 10, 10 + corner_size, 2, 0.4, 0.8, 1.0, 0.7);
    // Bottom-left
    try enc.strokeLine(10, HEIGHT - 10, 10 + corner_size, HEIGHT - 10, 2, 0.4, 0.8, 1.0, 0.7);
    try enc.strokeLine(10, HEIGHT - 10, 10, HEIGHT - 10 - corner_size, 2, 0.4, 0.8, 1.0, 0.7);
    // Bottom-right
    try enc.strokeLine(WIDTH - 10, HEIGHT - 10, WIDTH - 10 - corner_size, HEIGHT - 10, 2, 0.4, 0.8, 1.0, 0.7);
    try enc.strokeLine(WIDTH - 10, HEIGHT - 10, WIDTH - 10, HEIGHT - 10 - corner_size, 2, 0.4, 0.8, 1.0, 0.7);

    try enc.end();
}
