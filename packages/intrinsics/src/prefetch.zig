// Home Programming Language - Prefetch Intrinsics
// Cache prefetching hints for performance optimization

const std = @import("std");
const builtin = @import("builtin");

pub const PrefetchLocality = enum(u2) {
    none = 0, // No temporal locality (stream)
    low = 1, // Low temporal locality
    medium = 2, // Moderate temporal locality
    high = 3, // High temporal locality (will be reused soon)
};

pub const PrefetchRW = enum(u1) {
    read = 0,
    write = 1,
};

// Prefetch data for reading
pub fn prefetchRead(comptime T: type, ptr: *const T, comptime locality: PrefetchLocality) void {
    @prefetch(ptr, .{ .rw = .read, .locality = @intFromEnum(locality), .cache = .data });
}

// Prefetch data for writing
pub fn prefetchWrite(comptime T: type, ptr: *T, comptime locality: PrefetchLocality) void {
    @prefetch(ptr, .{ .rw = .write, .locality = @intFromEnum(locality), .cache = .data });
}

// Prefetch instruction cache
pub fn prefetchInstruction(ptr: *const anyopaque) void {
    @prefetch(ptr, .{ .rw = .read, .locality = 3, .cache = .instruction });
}

// Prefetch with full control
pub fn prefetch(
    comptime T: type,
    ptr: *const T,
    comptime rw: PrefetchRW,
    comptime locality: PrefetchLocality,
) void {
    const rw_val: std.builtin.PrefetchOptions.Rw = switch (rw) {
        .read => .read,
        .write => .write,
    };

    @prefetch(ptr, .{
        .rw = rw_val,
        .locality = @intFromEnum(locality),
        .cache = .data,
    });
}

// Streaming prefetch (non-temporal)
pub fn prefetchStream(comptime T: type, ptr: *const T) void {
    @prefetch(ptr, .{ .rw = .read, .locality = 0, .cache = .data });
}

// Prefetch for exclusive access (will modify)
pub fn prefetchExclusive(comptime T: type, ptr: *T) void {
    @prefetch(ptr, .{ .rw = .write, .locality = 3, .cache = .data });
}

// Prefetch array range
pub fn prefetchRange(comptime T: type, slice: []const T, comptime stride: usize) void {
    var i: usize = 0;
    while (i < slice.len) : (i += stride) {
        prefetchRead(T, &slice[i], .high);
    }
}

// Prefetch next cache line
pub fn prefetchNext(comptime T: type, ptr: *const T) void {
    const cache_line_size = 64;
    const next_line = @intFromPtr(ptr) + cache_line_size;
    const next_ptr: *const T = @ptrFromInt(next_line);
    prefetchRead(T, next_ptr, .high);
}

test "prefetch operations" {
    const testing = std.testing;

    var data: [100]u32 = undefined;
    for (&data, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Test basic prefetch operations
    prefetchRead(u32, &data[0], .high);
    prefetchWrite(u32, &data[0], .medium);
    prefetchStream(u32, &data[0]);
    prefetchExclusive(u32, &data[0]);

    // Test prefetch with custom parameters
    prefetch(u32, &data[0], .read, .low);
    prefetch(u32, &data[0], .write, .none);

    // Test range prefetch
    prefetchRange(u32, &data, 16);

    // Test next cache line prefetch
    prefetchNext(u32, &data[0]);

    // Verify data is still intact
    try testing.expectEqual(@as(u32, 0), data[0]);
    try testing.expectEqual(@as(u32, 99), data[99]);
}
