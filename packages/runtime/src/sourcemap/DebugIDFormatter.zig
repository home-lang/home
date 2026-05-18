// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from the inline `pub const DebugIDFormatter = struct { ... }` in
// upstream sourcemap.zig (that aggregator parks for now). Imports rewritten:
//   `bun.fmt.hexIntUpper(...)` → `home_rt.fmt.hexIntUpper(...)`
// Byte-for-byte equivalent to upstream — the suffix string
// "64756E2164756E21" is the ASCII bytes of `bun!bun!` in hex, which the RFC
// recipe pads the 64-bit hash with to reach the 128-bit UUID width.

//! https://sentry.engineering/blog/the-case-for-debug-ids
//! https://github.com/mitsuhiko/source-map-rfc/blob/proposals/debug-id/proposals/debug-id.md
//! https://github.com/source-map/source-map-rfc/pull/20
//! https://github.com/getsentry/rfcs/blob/main/text/0081-sourcemap-debugid.md#the-debugid-format

pub const DebugIDFormatter = struct {
    id: u64 = 0,

    pub fn format(self: DebugIDFormatter, writer: *std.Io.Writer) !void {
        // The RFC asks for a UUID, which is 128 bits (32 hex chars). Our hashes are only 64 bits.
        // We fill the end of the id with "bun!bun!" hex encoded
        var buf: [32]u8 = undefined;
        const formatter = home_rt.fmt.hexIntUpper(self.id);
        _ = std.fmt.bufPrint(&buf, "{f}64756E2164756E21", .{formatter}) catch unreachable;
        try writer.writeAll(&buf);
    }
};

const std = @import("std");
const home_rt = @import("home_rt");

test "DebugIDFormatter renders 32 hex chars with constant suffix" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const f: DebugIDFormatter = .{ .id = 0xDEADBEEFCAFEBABE };
    try f.format(&writer);
    const out = writer.buffered();
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqualStrings("DEADBEEFCAFEBABE", out[0..16]);
    // Upstream's source says "bun!bun!" but the literal constant decodes to
    // ASCII "dun!dun!" (0x64 'd', 0x75 'u', 0x6E 'n', 0x21 '!'). Preserving
    // verbatim so debug-id round-trips match upstream byte-for-byte.
    try std.testing.expectEqualStrings("64756E2164756E21", out[16..]);
}

test "DebugIDFormatter writes exactly 32 bytes for a max-width id" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const f: DebugIDFormatter = .{ .id = 0xFFFFFFFFFFFFFFFF };
    try f.format(&writer);
    const out = writer.buffered();
    // Upstream relies on the hash being a full 64-bit hash so the hex prefix
    // is always 16 chars wide; the constant suffix then fills the remaining 16.
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqualStrings("FFFFFFFFFFFFFFFF", out[0..16]);
    try std.testing.expectEqualStrings("64756E2164756E21", out[16..]);
}
