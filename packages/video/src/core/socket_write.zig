//! Allocation-free progress for byte-stream and raw-datagram media sinks.
//! Own no sockets or bytes. Advance only after local transport acceptance.
const std = @import("std");
pub const Mode = enum { stream, datagram };
pub const Cursor = struct {
    total: u64,
    offset: u64 = 0,
    chunk: u32,
    mode: Mode,
    pub fn init(total: u64, chunk: u32, mode: Mode) !Cursor {
        if (chunk == 0 or chunk > (if (mode == .datagram) @as(u32, 65507) else 1024 * 1024)) return error.InvalidChunk;
        return .{ .total = total, .chunk = chunk, .mode = mode };
    }
    pub fn next(self: Cursor) !u32 {
        _ = try init(self.total, self.chunk, self.mode);
        if (self.offset > self.total) return error.InvalidProgress;
        return @intCast(@min(self.total - self.offset, self.chunk));
    }
    /// Zero is backpressure. A datagram is all-or-nothing; TCP may accept a
    /// prefix. Invalid progress preserves the cursor, including at EOF.
    pub fn accept(self: *Cursor, count: u32) !void {
        const size = try self.next();
        if (count > size or (self.mode == .datagram and count != 0 and count != size)) return error.InvalidProgress;
        self.offset += count;
    }
};
test "stream progress retains every unsent suffix and rejects impossible counts atomically" {
    var c = try Cursor.init(9, 4, .stream);
    try std.testing.expectEqual(@as(u32, 4), try c.next());
    try c.accept(2);
    try c.accept(0);
    try std.testing.expectEqual(@as(u64, 2), c.offset);
    try std.testing.expectError(error.InvalidProgress, c.accept(5));
    try std.testing.expectEqual(@as(u64, 2), c.offset);
    try c.accept(4);
    try std.testing.expectEqual(@as(u32, 3), try c.next());
    try c.accept(3);
    try std.testing.expectEqual(@as(u32, 0), try c.next());
    try std.testing.expectError(error.InvalidProgress, c.accept(1));
    try c.accept(0);
}
test "raw datagrams preserve split boundaries across blocked writes and a short tail" {
    var c = try Cursor.init(10, 4, .datagram);
    try std.testing.expectError(error.InvalidProgress, c.accept(2));
    try c.accept(0);
    try std.testing.expectEqual(@as(u64, 0), c.offset);
    try c.accept(4);
    try c.accept(4);
    try std.testing.expectEqual(@as(u32, 2), try c.next());
    try c.accept(2);
    try std.testing.expectEqual(@as(u32, 0), try c.next());
}
test "cursor limits and u64 endpoints use checked subtraction without overflow" {
    for ([_]Mode{ .stream, .datagram }) |mode| {
        try std.testing.expectError(error.InvalidChunk, Cursor.init(1, 0, mode));
        try std.testing.expectError(error.InvalidChunk, Cursor.init(1, 1024 * 1024 + 1, mode));
        var empty = try Cursor.init(0, 1, mode);
        try std.testing.expectEqual(@as(u32, 0), try empty.next());
        try std.testing.expectError(error.InvalidProgress, empty.accept(1));
        var end = try Cursor.init(std.math.maxInt(u64), 7, mode);
        end.offset = std.math.maxInt(u64) - 3;
        try std.testing.expectEqual(@as(u32, 3), try end.next());
        try end.accept(3);
        try std.testing.expectEqual(@as(u32, 0), try end.next());
        empty.offset = 1;
        try std.testing.expectError(error.InvalidProgress, empty.next());
    }
    _ = try Cursor.init(1, 65507, .datagram);
    try std.testing.expectError(error.InvalidChunk, Cursor.init(1, 65508, .datagram));
    _ = try Cursor.init(1, 1024 * 1024, .stream);
}
test "all short lengths and chunk widths cover bytes once with blocked and partial writes" {
    for ([_]Mode{ .stream, .datagram }) |mode| for (0..128) |length| {
        for (1..24) |width| {
            var c = try Cursor.init(length, @intCast(width), mode);
            var visited: [128]u8 = @splat(0);
            while (try c.next() != 0) {
                const n = try c.next();
                try c.accept(0);
                const accepted = if (mode == .stream) @max(1, n / 2) else n;
                for (visited[@intCast(c.offset)..][0..accepted]) |*value| value.* += 1;
                try c.accept(accepted);
            }
            for (visited[0..length]) |value| try std.testing.expectEqual(@as(u8, 1), value);
            for (visited[length..]) |value| try std.testing.expectEqual(@as(u8, 0), value);
        }
    };
}
