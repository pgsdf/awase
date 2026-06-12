const std = @import("std");
const backend = @import("backend");
pub fn create(_: std.mem.Allocator) !backend.Backend {
    return error.BackendNotAvailable;
}
