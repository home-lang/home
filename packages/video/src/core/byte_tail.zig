//! Fixed caller-owned diagnostic tail. No allocation, I/O, threads or text
//! decoding. Preserve the last capacity bytes and an exact accepted-byte count.
const std = @import("std");
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x <= y) y - x < a.len else x - y < b.len;
}
pub const Tail = struct {
    arena: []u8,
    head: usize = 0,
    len: usize = 0,
    total: u64 = 0,
    pub fn init(arena: []u8) Tail {
        return .{ .arena = arena };
    }
    pub fn validate(self: Tail) !void {
        if (self.len > self.arena.len or self.total < self.len or
            (if (self.arena.len == 0) self.head != 0 else self.head >= self.arena.len)) return error.InvalidState;
    }
    /// Reject overlap and count overflow before changing bytes or state.
    pub fn append(self: *Tail, input: []const u8) !void {
        try self.validate();
        if (overlaps(input, self.arena)) return error.OverlappingBuffers;
        const total = std.math.add(u64, self.total, input.len) catch return error.SequenceOverflow;
        const capacity = self.arena.len;
        if (capacity == 0) {
            self.total = total;
            return;
        }
        if (input.len >= capacity) {
            @memcpy(self.arena, input[input.len - capacity ..]);
            self.head = 0;
            self.len = capacity;
        } else if (input.len != 0) {
            const end = if (self.len >= capacity - self.head) self.len - (capacity - self.head) else self.head + self.len;
            const first = @min(input.len, capacity - end);
            @memcpy(self.arena[end..][0..first], input[0..first]);
            @memcpy(self.arena[0 .. input.len - first], input[first..]);
            const dropped = input.len - @min(input.len, capacity - self.len);
            self.head = if (dropped >= capacity - self.head) dropped - (capacity - self.head) else self.head + dropped;
            self.len = self.len - dropped + input.len;
        }
        self.total = total;
    }
    /// Copy chronological bytes. Query len for storage; short/overlapping
    /// output and invalid state leave destination and tail unchanged.
    pub fn copy(self: Tail, output: []u8) ![]const u8 {
        try self.validate();
        if (output.len < self.len) return error.BufferTooSmall;
        if (overlaps(self.arena, output[0..self.len])) return error.OverlappingBuffers;
        const first = @min(self.len, self.arena.len - self.head);
        @memcpy(output[0..first], self.arena[self.head..][0..first]);
        @memcpy(output[first..self.len], self.arena[0 .. self.len - first]);
        return output[0..self.len];
    }
};
test "tail preserves chronological suffix across wrap and oversized appends" {
    var arena: [5]u8 = undefined;
    var tail = Tail.init(&arena);
    var out: [5]u8 = undefined;
    try tail.append("abc");
    try tail.append("de");
    try tail.append("fg");
    try std.testing.expectEqualStrings("cdefg", try tail.copy(&out));
    try tail.append("0123456789");
    try std.testing.expectEqualStrings("56789", try tail.copy(&out));
    try std.testing.expectEqual(@as(u64, 17), tail.total);
    try tail.append("");
    try std.testing.expectEqualStrings("56789", try tail.copy(&out));
}
test "zero capacity counts bytes without retaining them and errors are atomic" {
    var empty = Tail.init(&.{});
    try empty.append("discarded");
    try std.testing.expectEqual(@as(u64, 9), empty.total);
    try std.testing.expectEqual(@as(usize, 0), (try empty.copy(&.{})).len);
    var arena: [4]u8 = @splat(0xa5);
    var tail = Tail.init(&arena);
    try tail.append("abc");
    var out: [4]u8 = @splat(0xa5);
    try std.testing.expectError(error.BufferTooSmall, tail.copy(out[0..2]));
    for (out) |v| try std.testing.expectEqual(@as(u8, 0xa5), v);
    const before = arena;
    try std.testing.expectError(error.OverlappingBuffers, tail.append(arena[0..1]));
    try std.testing.expectError(error.OverlappingBuffers, tail.copy(&arena));
    try std.testing.expectEqualSlices(u8, &before, &arena);
    tail.total = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceOverflow, tail.append("x"));
    try std.testing.expectEqualSlices(u8, &before, &arena);
    tail.head = arena.len;
    try std.testing.expectError(error.InvalidState, tail.copy(&out));
}
test "every short capacity and input partition agrees with an independent suffix" {
    var input: [97]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..32) |capacity| for (1..24) |chunk| {
        var arena: [32]u8 = undefined;
        var output: [32]u8 = undefined;
        var tail = Tail.init(arena[0..capacity]);
        var offset: usize = 0;
        while (offset < input.len) {
            const size = @min(chunk, input.len - offset);
            try tail.append(input[offset..][0..size]);
            offset += size;
            const keep = @min(offset, capacity);
            try std.testing.expectEqualSlices(u8, input[offset - keep .. offset], try tail.copy(&output));
            try std.testing.expectEqual(@as(u64, offset), tail.total);
        }
    };
}
