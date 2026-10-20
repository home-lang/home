//! Owned bounded device IDs across asynchronous reopens. IDs are opaque UTF-8
//! bytes: no case folding, trimming, path normalization or prefix matching.
const std = @import("std");
pub fn Identity(comptime capacity: usize) type {
    if (capacity == 0 or capacity > std.math.maxInt(u32)) @compileError("invalid identity capacity");
    return struct {
        const Self = @This();
        storage: [capacity]u8 = undefined,
        length: u32 = 0,
        pub fn init(id: []const u8) !Self {
            if (id.len == 0 or std.mem.indexOfScalar(u8, id, 0) != null or !std.unicode.utf8ValidateSlice(id)) return error.InvalidIdentity;
            if (id.len > capacity) return error.IdentityTooLong;
            var result: Self = .{};
            @memcpy(result.storage[0..id.len], id);
            result.length = @intCast(id.len);
            return result;
        }
        pub fn bytes(self: *const Self) []const u8 {
            return self.storage[0..self.length];
        }
        pub fn matches(self: *const Self, id: []const u8) bool {
            return std.mem.eql(u8, self.bytes(), id);
        }
        /// Returns the byte count; no terminator is appended. Short copies never
        /// write a partial ID. The caller supplies synchronization and lifetime.
        pub fn copy(self: *const Self, output: []u8) !usize {
            if (output.len < self.length) return error.BufferTooSmall;
            @memcpy(output[0..self.length], self.bytes());
            return self.length;
        }
    };
}
test "device identifiers are owned exact UTF8 keys without normalization or prefix matching" {
    var source = [_]u8{ 'C', 'a', 'm', '/', '1' };
    const identity = try Identity(8).init(&source);
    @memset(&source, 0);
    try std.testing.expectEqualStrings("Cam/1", identity.bytes());
    try std.testing.expect(identity.matches("Cam/1"));
    for ([_][]const u8{ "cam/1", " Cam/1", "Cam/1 ", "Cam/", "Cam/10", "Cam/./1" }) |other| try std.testing.expect(!identity.matches(other));
    const utf8 = try Identity(4).init("éß");
    try std.testing.expectEqual(@as(u32, 4), utf8.length);
    try std.testing.expectError(error.IdentityTooLong, Identity(3).init("éß"));
}
test "malformed and oversized identities reject; short copies preserve output" {
    for ([_][]const u8{ "", "a\x00b", "\xc0\x80", "\xed\xa0\x80", "\xff" }) |bad| try std.testing.expectError(error.InvalidIdentity, Identity(8).init(bad));
    try std.testing.expectError(error.IdentityTooLong, Identity(4).init("abcde"));
    const id = try Identity(4).init("abcd");
    var output: [5]u8 = @splat(0xaa);
    try std.testing.expectError(error.BufferTooSmall, id.copy(output[0..3]));
    for (output) |b| try std.testing.expectEqual(@as(u8, 0xaa), b);
    try std.testing.expectEqual(@as(usize, 4), try id.copy(&output));
    try std.testing.expectEqualStrings("abcd", output[0..4]);
    try std.testing.expectEqual(@as(u8, 0xaa), output[4]);
}
