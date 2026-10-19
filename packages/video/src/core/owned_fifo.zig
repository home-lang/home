//! Fixed-capacity owned operation FIFO. Caller serializes mutations. Keeping the
//! front until acknowledgement charges in-flight work against the same bounds.
const std = @import("std");
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { value: T, offset: usize, length: usize };
        allocator: std.mem.Allocator,
        bytes: []u8,
        entries: []Entry,
        head: usize = 0,
        count: usize = 0,
        used: usize = 0,
        write_pos: usize = 0,
        pub fn init(a: std.mem.Allocator, bytes: usize, items: usize) !Self {
            if (bytes == 0 or bytes > std.math.maxInt(usize) / 2 or items == 0 or items > std.math.maxInt(usize) / 2) return error.InvalidConfiguration;
            const arena = try a.alloc(u8, bytes);
            errdefer a.free(arena);
            return .{ .allocator = a, .bytes = arena, .entries = try a.alloc(Entry, items) };
        }
        pub fn deinit(s: *Self) void {
            s.allocator.free(s.bytes);
            s.allocator.free(s.entries);
        }
        pub fn fits(s: *const Self, length: usize) bool {
            return s.count < s.entries.len and length <= s.bytes.len - s.used;
        }
        /// Empty payloads still consume an entry (e.g. metadata or barriers).
        /// Rejected input leaves all state and payloads untouched.
        pub fn push(s: *Self, value: T, payload: []const u8) !void {
            if (payload.len > s.bytes.len) return error.PacketTooLarge;
            if (!s.fits(payload.len)) return error.BufferFull;
            const first = @min(payload.len, s.bytes.len - s.write_pos);
            @memcpy(s.bytes[s.write_pos..][0..first], payload[0..first]);
            @memcpy(s.bytes[0 .. payload.len - first], payload[first..]);
            s.entries[(s.head + s.count) % s.entries.len] = .{ .value = value, .offset = s.write_pos, .length = payload.len };
            s.write_pos = (s.write_pos + payload.len) % s.bytes.len;
            s.count += 1;
            s.used += payload.len;
        }
        pub fn front(s: *const Self) ?Entry {
            return if (s.count == 0) null else s.entries[s.head];
        }
        /// Copy without acknowledging: the producer cannot overwrite this
        /// operation's arena bytes while the consumer runs outside its lock.
        pub fn copyFront(s: *const Self, out: []u8) ![]const u8 {
            const e = s.front() orelse return error.EmptyBuffer;
            if (out.len < e.length) return error.BufferTooSmall;
            const first = @min(e.length, s.bytes.len - e.offset);
            @memcpy(out[0..first], s.bytes[e.offset..][0..first]);
            @memcpy(out[first..e.length], s.bytes[0 .. e.length - first]);
            return out[0..e.length];
        }
        pub fn pop(s: *Self) void {
            const e = s.front() orelse return;
            s.used -= e.length;
            s.head = (s.head + 1) % s.entries.len;
            s.count -= 1;
        }
        /// Caller must first account for any operation currently in flight.
        pub fn reset(s: *Self) void {
            s.head = 0;
            s.count = 0;
            s.used = 0;
            s.write_pos = 0;
        }
    };
}
test "wrap, in-flight accounting, metadata and atomic rejection" {
    var q = try Queue(u32).init(std.testing.allocator, 6, 3);
    defer q.deinit();
    try q.push(1, "abcd");
    var out: [6]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", try q.copyFront(&out));
    try std.testing.expectError(error.BufferFull, q.push(2, "xyz"));
    try std.testing.expectEqual(@as(usize, 4), q.used);
    q.pop();
    try q.push(2, "xyz");
    try q.push(3, "");
    try q.push(4, "12");
    try std.testing.expectError(error.BufferFull, q.push(5, ""));
    try std.testing.expectEqualStrings("xyz", try q.copyFront(&out));
    try std.testing.expectEqual(@as(u32, 2), q.front().?.value);
    q.pop();
    try std.testing.expectEqualStrings("", try q.copyFront(&out));
    q.pop();
    try std.testing.expectError(error.BufferTooSmall, q.copyFront(out[0..1]));
    try std.testing.expectEqualStrings("12", try q.copyFront(&out));
    try std.testing.expectError(error.PacketTooLarge, q.push(6, "1234567"));
    q.reset();
    try std.testing.expect(q.front() == null);
    try q.push(7, "reset");
    try std.testing.expectEqualStrings("reset", try q.copyFront(&out));
}
test "zero bounds and allocation failure release partial ownership" {
    try std.testing.expectError(error.InvalidConfiguration, Queue(u8).init(std.testing.allocator, 0, 1));
    try std.testing.expectError(error.InvalidConfiguration, Queue(u8).init(std.testing.allocator, 1, 0));
    try std.testing.expectError(error.InvalidConfiguration, Queue(u8).init(std.testing.allocator, std.math.maxInt(usize), 1));
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var q = try Queue(u8).init(a, 10, 4);
            defer q.deinit();
            try q.push(1, "owned");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
