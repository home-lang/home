//! Allocation-free indexed recording names. The caller owns the pattern and
//! destination buffer and creates each output exclusively; no retention policy.
const std = @import("std");
pub const Pattern = struct {
    prefix: []const u8,
    suffix: []const u8,
    width: usize,
    pub fn init(text: []const u8) !Pattern {
        if (text.len == 0 or text.len > 4096 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidPattern;
        const begin = std.mem.indexOfScalar(u8, text, '{') orelse return error.InvalidPattern;
        const end = std.mem.indexOfScalarPos(u8, text, begin, '}') orelse return error.InvalidPattern;
        const field = text[begin + 1 .. end];
        var width: usize = 0;
        if (!std.mem.eql(u8, field, "index")) {
            if (!std.mem.startsWith(u8, field, "index:0") or field.len <= 7) return error.InvalidPattern;
            for (field[7..]) |char| if (char < '0' or char > '9') return error.InvalidPattern;
            width = std.fmt.parseInt(usize, field[7..], 10) catch return error.InvalidPattern;
            if (width == 0 or width > 128) return error.InvalidPattern;
        }
        const prefix = text[0..begin];
        const suffix = text[end + 1 ..];
        if (std.mem.indexOfAny(u8, prefix, "{}") != null or std.mem.indexOfAny(u8, suffix, "{}") != null) return error.InvalidPattern;
        return .{ .prefix = prefix, .suffix = suffix, .width = width };
    }
    pub fn format(self: Pattern, buffer: []u8, index: u64) ![:0]u8 {
        var digits: [20]u8 = undefined;
        const number = try std.fmt.bufPrint(&digits, "{d}", .{index});
        const width = @max(number.len, self.width);
        const size = self.prefix.len + width + self.suffix.len;
        if (size > 4096 or size >= buffer.len) return error.NoSpaceLeft;
        @memcpy(buffer[0..self.prefix.len], self.prefix);
        @memset(buffer[self.prefix.len..][0 .. width - number.len], '0');
        @memcpy(buffer[self.prefix.len + width - number.len ..][0..number.len], number);
        @memcpy(buffer[self.prefix.len + width ..][0..self.suffix.len], self.suffix);
        buffer[size] = 0;
        return buffer[0..size :0];
    }
};
test "indexed names pad without truncating and include the maximum index" {
    const p = try Pattern.init("trail-{index:06}.mp4");
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("trail-000012.mp4", try p.format(&buffer, 12));
    try std.testing.expectEqualStrings("trail-18446744073709551615.mp4", try p.format(&buffer, std.math.maxInt(u64)));
    const plain = try Pattern.init("{index}");
    try std.testing.expectEqualStrings("0", try plain.format(&buffer, 0));
    try std.testing.expectError(error.NoSpaceLeft, plain.format(buffer[0..1], 0));
}
test "malformed fields, embedded NUL and unbounded widths are rejected" {
    for ([_][]const u8{ "", "trail.mp4", "{index}{index}", "{index:0}", "{index:00}", "{index:0129}", "{index:-1}", "{other}", "{index:01x}", "{index}}", "}{index}", "{index}\x00" }) |text| {
        try std.testing.expectError(error.InvalidPattern, Pattern.init(text));
    }
}
