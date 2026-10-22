//! Bounded GIF LZW dictionary and streaming LSB-first code writer (Home, MIT).
//! Width scheduling adapts Home video GifWriter.LzwEncoder; phrase hashing adds
//! real dictionary compression to the old image literal-only encoder.
//! Input slices are consumed synchronously; no pointer to caller pixels is kept.
const std = @import("std");
pub const Encoder = struct {
    minimum: u8,
    clear: u16,
    end: u16,
    next_encoder: u16,
    next_decoder: u16,
    width: u8,
    previous: bool = false,
    prefix: ?u16 = null,
    bits: u8 = 0,
    buffer: u32 = 0,
    state: enum { fresh, open, finished, failed } = .fresh,
    keys: [8192]u32 = @splat(std.math.maxInt(u32)),
    values: [8192]u16 = undefined,

    pub fn init(minimum: u8) !Encoder {
        if (minimum < 2 or minimum > 8) return error.InvalidCodeSize;
        const clear = @as(u16, 1) << @intCast(minimum);
        return .{ .minimum = minimum, .clear = clear, .end = clear + 1, .next_encoder = clear + 2, .next_decoder = clear + 2, .width = minimum + 1 };
    }
    fn resetDictionary(self: *Encoder) void {
        @memset(&self.keys, std.math.maxInt(u32));
        self.next_encoder = self.end + 1;
    }
    fn code(self: *Encoder, value: u16, sink: anytype) !void {
        self.buffer |= @as(u32, value) << @intCast(self.bits);
        self.bits += self.width;
        var bytes: [2]u8 = undefined;
        var n: usize = 0;
        while (self.bits >= 8) {
            bytes[n] = @truncate(self.buffer);
            n += 1;
            self.buffer >>= 8;
            self.bits -= 8;
        }
        if (n != 0) try sink.writeAll(bytes[0..n]);
        // Track the decoder's table rather than the encoder's one-entry-ahead
        // dictionary. This also handles the width boundary just before EOI.
        if (value == self.clear) {
            self.width = self.minimum + 1;
            self.next_decoder = self.end + 1;
            self.previous = false;
        } else if (value != self.end) {
            if (self.previous) {
                if (self.next_decoder < 4096) {
                    self.next_decoder += 1;
                    if (self.width < 12 and self.next_decoder == (@as(u16, 1) << @intCast(self.width))) self.width += 1;
                }
            } else self.previous = true;
        }
    }
    fn start(self: *Encoder, sink: anytype) !void {
        if (self.state == .fresh) {
            try self.code(self.clear, sink);
            self.state = .open;
        }
    }
    /// Each write checks every index before changing the stream. Sink failure
    /// poisons the encoder; invalid indices leave it available for a fresh write.
    pub fn write(self: *Encoder, data: []const u8, sink: anytype) !void {
        if (self.state == .finished or self.state == .failed) return error.InvalidState;
        for (data) |value| if (@as(u16, value) >= self.clear) return error.InvalidIndex;
        if (data.len == 0) return;
        errdefer self.state = .failed;
        try self.start(sink);
        for (data) |value| {
            const prefix = self.prefix orelse {
                self.prefix = value;
                continue;
            };
            const key = (@as(u32, prefix) << 8) | value;
            var slot: usize = @intCast((key *% 2654435761) >> 19);
            while (self.keys[slot] != std.math.maxInt(u32) and self.keys[slot] != key) slot = (slot + 1) & 8191;
            if (self.keys[slot] == key) {
                self.prefix = self.values[slot];
                continue;
            }
            try self.code(prefix, sink);
            if (self.next_encoder < 4096) {
                self.keys[slot] = key;
                self.values[slot] = self.next_encoder;
                self.next_encoder += 1;
            } else {
                try self.code(self.clear, sink);
                self.resetDictionary();
            }
            self.prefix = value;
        }
    }
    pub fn finish(self: *Encoder, sink: anytype) !void {
        if (self.state == .finished or self.state == .failed) return error.InvalidState;
        errdefer self.state = .failed;
        try self.start(sink);
        if (self.prefix) |value| try self.code(value, sink);
        try self.code(self.end, sink);
        if (self.bits != 0) try sink.writeAll(&.{@as(u8, @truncate(self.buffer))});
        self.buffer = 0;
        self.bits = 0;
        self.state = .finished;
    }
};
const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pub fn writeAll(self: *Buffer, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};
pub fn encode(allocator: std.mem.Allocator, data: []const u8, minimum: u8) ![]u8 {
    var encoder = try Encoder.init(minimum);
    var sink: Buffer = .{ .allocator = allocator };
    errdefer sink.bytes.deinit(allocator);
    try encoder.write(data, &sink);
    try encoder.finish(&sink);
    return sink.bytes.toOwnedSlice(allocator);
}
test "GIF LZW chunk boundaries do not change compressed bytes and finish seals the stream" {
    const t = std.testing;
    const data = try t.allocator.alloc(u8, 50000);
    defer t.allocator.free(data);
    for ([_]u8{ 2, 3, 4, 5, 6, 7, 8 }) |minimum| {
        var seed: u32 = 0x7ac0ffee;
        for (data) |*v| {
            seed = seed *% 1664525 +% 1013904223;
            v.* = @as(u8, @truncate(seed >> 24)) & (@as(u8, 255) >> @as(u3, @intCast(8 - minimum)));
        }
        const expected = try encode(t.allocator, data, minimum);
        defer t.allocator.free(expected);
        for ([_]usize{ 1, 17, 254, 1023, 4096 }) |chunk| {
            var encoder = try Encoder.init(minimum);
            var sink: Buffer = .{ .allocator = t.allocator };
            defer sink.bytes.deinit(t.allocator);
            var at: usize = 0;
            while (at < data.len) {
                const n = @min(chunk, data.len - at);
                try encoder.write(data[at..][0..n], &sink);
                at += n;
            }
            try encoder.finish(&sink);
            try t.expectEqualSlices(u8, expected, sink.bytes.items);
            try t.expectError(error.InvalidState, encoder.write(&.{0}, &sink));
            try t.expectError(error.InvalidState, encoder.finish(&sink));
        }
    }
    const empty = try encode(t.allocator, &.{}, 2);
    defer t.allocator.free(empty);
    try t.expectEqualSlices(u8, &.{0x2c}, empty);
}
test "GIF LZW invalid indices reject atomically and sink failure poisons further writes" {
    const t = std.testing;
    try t.expectError(error.InvalidCodeSize, Encoder.init(1));
    try t.expectError(error.InvalidCodeSize, Encoder.init(9));
    var sink: Buffer = .{ .allocator = t.allocator };
    defer sink.bytes.deinit(t.allocator);
    var encoder = try Encoder.init(2);
    try t.expectError(error.InvalidIndex, encoder.write(&.{ 0, 1, 2, 4 }, &sink));
    try t.expectEqual(@as(usize, 0), sink.bytes.items.len);
    try encoder.write(&.{ 0, 1, 2, 3 }, &sink);
    const before = sink.bytes.items.len;
    try t.expectError(error.InvalidIndex, encoder.write(&.{ 0, 255 }, &sink));
    try t.expectEqual(before, sink.bytes.items.len);
    try encoder.finish(&sink);
    const Fail = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {
            return error.SinkFailed;
        }
    };
    var fail: Fail = .{};
    var broken = try Encoder.init(8);
    try t.expectError(error.SinkFailed, broken.write(&.{ 0, 1 }, &fail));
    try t.expectError(error.InvalidState, broken.finish(&fail));
    try t.expectError(error.InvalidState, broken.write(&.{2}, &fail));
}
fn allocations(a: std.mem.Allocator) !void {
    var data: [4096]u8 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i % 4);
    const bytes = try encode(a, &data, 2);
    defer a.free(bytes);
    try std.testing.expect(bytes.len < 1024);
}
test "GIF LZW compresses repeated patterns and frees failed output allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{});
}
