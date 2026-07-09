// bas_boot.zig: the loader-side BAS read path (L3a.2 increment 1).
// Resolves the active slot per BOOT-ARTIFACT-STORE 0.3 section 7.2
// via the shared bas.zig record code, then verifies the slot per
// the three integrity layers (7.7) before anything relies on it
// (I5). Increment 1 verifies and reports only; control transfer is
// a later increment.

const std = @import("std");
const uefi = std.os.uefi;
const bas = @import("bas.zig");

pub const ReportS = *const fn ([]const u8) void;

const Sha256 = std.crypto.hash.sha2.Sha256;

fn widen(comptime max: usize, ascii: []const u8, out: *[max:0]u16) [*:0]const u16 {
    var i: usize = 0;
    while (i < ascii.len and i < max) : (i += 1) out[i] = ascii[i];
    out[i] = 0;
    return @ptrCast(out);
}

fn readWholeFile(root: *uefi.protocol.File, path16: [*:0]const u16) ![]u8 {
    const f = try root.open(path16, .read, .{});
    defer f.close() catch {};
    const info_len = try f.getInfoSize(.file);
    const info_buf = try uefi.pool_allocator.alignedAlloc(u8, .of(uefi.protocol.File.Info.File), info_len);
    defer uefi.pool_allocator.free(info_buf);
    const info = try f.getInfo(.file, info_buf);
    const size: usize = @intCast(info.file_size);
    const data = try uefi.pool_allocator.alloc(u8, size);
    errdefer uefi.pool_allocator.free(data);
    var got: usize = 0;
    while (got < size) {
        const n = try f.read(data[got..]);
        if (n == 0) return error.ShortRead;
        got += n;
    }
    return data;
}

fn hexLine(h: []const u8, out: []u8) []const u8 {
    const d = "0123456789abcdef";
    for (h, 0..) |c, i| {
        out[i * 2] = d[c >> 4];
        out[i * 2 + 1] = d[c & 0xf];
    }
    return out[0 .. h.len * 2];
}

pub const SlotResult = struct {
    slot: u32,
    generation: u64,
    artifact_count: usize,
};

/// Read the selector, verify the active slot completely.
/// print/prints report progress; every artifact is hashed against
/// the manifest, the manifest against the selector record.
pub fn verifyActiveSlot(
    device_handle: uefi.Handle,
    prints: ReportS,
) !SlotResult {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const sfs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch
        return error.NoFilesystem) orelse return error.NoFilesystem;
    const root = sfs.openVolume() catch return error.NoVolume;
    defer root.close() catch {};

    // Layer 1: selector integrity (bas.zig validates per record).
    const sel = readWholeFile(root, std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\pgsd\\bas\\selector")) catch {
        prints("BAS: selector missing or unreadable (destroyed)\r\n");
        return error.DestroyedSelector;
    };
    defer uefi.pool_allocator.free(sel);
    if (sel.len != bas.selector_size) {
        prints("BAS: selector wrong size (destroyed)\r\n");
        return error.DestroyedSelector;
    }
    const rr = bas.read(sel[0..bas.selector_size]);
    const win = rr.winner orelse {
        prints("BAS: both selector records invalid (destroyed)\r\n");
        return error.DestroyedSelector;
    };

    var numbuf: [16]u8 = undefined;
    var line: [128]u8 = undefined;
    prints(std.fmt.bufPrint(&line, "BAS: selector gen={d} slot={d}\r\n", .{ win.generation, win.active_slot }) catch "");

    // Layer 2: publication identity, manifest hash vs the record.
    const slot_str = std.fmt.bufPrint(&numbuf, "{d}", .{win.active_slot}) catch return error.Overflow;
    var pathbuf: [96]u8 = undefined;
    var path16: [96:0]u16 = undefined;
    const mpath = std.fmt.bufPrint(&pathbuf, "\\EFI\\pgsd\\bas\\slots\\{s}\\manifest", .{slot_str}) catch return error.Overflow;
    const manifest = readWholeFile(root, widen(96, mpath, &path16)) catch {
        prints("BAS: manifest missing; slot refused\r\n");
        return error.SlotRefused;
    };
    defer uefi.pool_allocator.free(manifest);
    var mh: [32]u8 = undefined;
    Sha256.hash(manifest, &mh, .{});
    if (!std.mem.eql(u8, &mh, &win.manifest_sha256)) {
        prints("BAS: manifest hash mismatch; slot refused\r\n");
        return error.SlotRefused;
    }
    prints("BAS: manifest identity verified\r\n");

    // Layer 3: artifact integrity, every artifact hashed.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, manifest, '\n');
    const header = it.next() orelse return error.SlotRefused;
    if (!std.mem.eql(u8, header, "PGSD-BAS-MANIFEST 1")) {
        prints("BAS: unknown manifest format; slot refused\r\n");
        return error.SlotRefused;
    }
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        var fit = std.mem.splitScalar(u8, raw, ' ');
        const hhex = fit.next() orelse return error.SlotRefused;
        const szs = fit.next() orelse return error.SlotRefused;
        const name = fit.rest();
        if (hhex.len != 64 or name.len == 0) return error.SlotRefused;
        var want: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&want, hhex) catch return error.SlotRefused;
        const want_size = std.fmt.parseInt(u64, szs, 10) catch return error.SlotRefused;

        const apath = std.fmt.bufPrint(&pathbuf, "\\EFI\\pgsd\\bas\\slots\\{s}\\{s}", .{ slot_str, name }) catch return error.Overflow;
        const data = readWholeFile(root, widen(96, apath, &path16)) catch {
            prints(std.fmt.bufPrint(&line, "BAS: artifact {s} unreadable; slot refused\r\n", .{name}) catch "");
            return error.SlotRefused;
        };
        defer uefi.pool_allocator.free(data);
        var got: [32]u8 = undefined;
        Sha256.hash(data, &got, .{});
        if (data.len != want_size or !std.mem.eql(u8, &got, &want)) {
            prints(std.fmt.bufPrint(&line, "BAS: artifact {s} FAILED verification; slot refused\r\n", .{name}) catch "");
            return error.SlotRefused;
        }
        prints(std.fmt.bufPrint(&line, "BAS: artifact {s} verified ({d} bytes)\r\n", .{ name, data.len }) catch "");
        count += 1;
    }
    if (count == 0) {
        prints("BAS: empty manifest; slot refused\r\n");
        return error.SlotRefused;
    }
    return .{ .slot = win.active_slot, .generation = win.generation, .artifact_count = count };
}

/// Armed-mode detection (ADR 0004 Decision 2): the BAS path runs
/// only when this binary was loaded under the dedicated test name,
/// selected by the operator (a test entry plus BootNext), so
/// selection authority stays outside the loader. Walks the
/// LoadedImage file path for the last Media File Path node and
/// compares its basename, ASCII case-insensitively (FAT).
/// Open an artifact within the given slot for reading. The caller
/// owns closing both returned handles (file, then root). Used by
/// increment 2 to hand the verified kernel to the ELF loader.
pub const SlotFile = struct {
    root: *uefi.protocol.File,
    file: *uefi.protocol.File,
    pub fn close(self: SlotFile) void {
        self.file.close() catch {};
        self.root.close() catch {};
    }
};

pub fn openSlotFile(
    device_handle: uefi.Handle,
    slot: u32,
    name: []const u8,
) !SlotFile {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const sfs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch
        return error.NoFilesystem) orelse return error.NoFilesystem;
    const root = sfs.openVolume() catch return error.NoVolume;
    errdefer root.close() catch {};
    var pathbuf: [96]u8 = undefined;
    var path16: [96:0]u16 = undefined;
    const p = std.fmt.bufPrint(&pathbuf, "\\EFI\\pgsd\\bas\\slots\\{d}\\{s}", .{ slot, name }) catch return error.Overflow;
    const f = root.open(widen(96, p, &path16), .read, .{}) catch return error.NotFound;
    return .{ .root = root, .file = f };
}

pub fn armed(file_path: ?*const uefi.protocol.DevicePath) bool {
    return armedAs(file_path, "pgsd-loader-bas.efi");
}

/// Boot arming is a DISTINCT file name so the safe attest-and-
/// chainload cycle (-bas.efi) never attempts a transfer; only a
/// loader deployed as -boot.efi crosses ExitBootServices.
pub fn bootArmed(file_path: ?*const uefi.protocol.DevicePath) bool {
    return armedAs(file_path, "pgsd-loader-boot.efi");
}

fn armedAs(file_path: ?*const uefi.protocol.DevicePath, want: []const u8) bool {
    var node: *const uefi.protocol.DevicePath = file_path orelse return false;
    var last_name: ?[]const u16 = null;
    while (true) {
        const t: u8 = @intFromEnum(node.type);
        const len: u16 = node.length;
        if (t == 0x7f) break; // end of device path
        if (t == 4 and node.subtype == 4 and len > 4) {
            const chars: [*]const u16 = @ptrFromInt(@intFromPtr(node) + 4);
            var n: usize = (len - 4) / 2;
            while (n > 0 and chars[n - 1] == 0) n -= 1;
            last_name = chars[0..n];
        }
        if (len < 4) break;
        node = @ptrFromInt(@intFromPtr(node) + len);
    }
    const full = last_name orelse return false;
    // basename after the last backslash
    var start: usize = 0;
    for (full, 0..) |c, i| {
        if (c == '\\') start = i + 1;
    }
    const base = full[start..];
    if (base.len != want.len) return false;
    for (base, 0..) |c, i| {
        if (c > 0x7f) return false;
        var a: u8 = @intCast(c);
        if (a >= 'A' and a <= 'Z') a += 32;
        if (a != want[i]) return false;
    }
    return true;
}
