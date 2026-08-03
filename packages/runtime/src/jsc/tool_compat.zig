const std = @import("std");

/// Minimal compatibility leaf for the public-C tool runtime. Keeping this
/// separate prevents a console/evaluate callback from importing Home's full
/// Bun/WebCore runtime solely for sentinel-terminated string allocation.
pub fn dupeZ(allocator: std.mem.Allocator, comptime T: type, value: []const T) std.mem.Allocator.Error![:0]T {
    const copy = try allocator.allocSentinel(T, value.len, 0);
    @memcpy(copy, value);
    return copy;
}
