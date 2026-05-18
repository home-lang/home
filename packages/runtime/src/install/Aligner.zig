// Copied from bun/src/install/install.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from `install.zig` (the `Aligner` struct + `alignment_bytes_to_repeat_buffer`
// constant it relies on) so the lockfile serialiser can call it without pulling
// in the full PackageManager. Pure Zig — no `@import("bun")` rewrite needed.

const std = @import("std");

/// 144 zero bytes — used as a scratch source for `Aligner.write` so the
/// alignment padding can be copied with a single `writeAll`. 144 is the LCM
/// of every alignment the lockfile currently needs (1, 2, 4, 8, 16, 24 for
/// `Semver.Version` arrays) and is intentionally larger than any single
/// alignment gap the serialiser produces.
///
/// Upstream writes this as `[_]u8{0} ** 144`; Zig 0.17-dev rejects the
/// array-repeat operator in this position (parser error: "binary operator
/// '*' has whitespace on one side, but not the other"). `@splat` over a
/// sized array type is the documented 0.17 replacement.
pub const alignment_bytes_to_repeat_buffer: [144]u8 = @splat(0);

/// Writes the zero-padding required to align the next field of type `Type`
/// to its natural alignment at byte offset `pos` of the lockfile stream.
///
/// Returns the number of padding bytes written so the caller can keep its
/// running offset in sync.
pub const Aligner = struct {
    pub fn write(comptime Type: type, comptime Writer: type, writer: Writer, pos: usize) !usize {
        const to_write = skipAmount(Type, pos);

        const remainder: []const u8 = alignment_bytes_to_repeat_buffer[0..@min(
            to_write,
            alignment_bytes_to_repeat_buffer.len,
        )];
        try writer.writeAll(remainder);

        return to_write;
    }

    pub inline fn skipAmount(comptime Type: type, pos: usize) usize {
        return std.mem.alignForward(usize, pos, @alignOf(Type)) - pos;
    }
};

test "Aligner.skipAmount reports the byte gap to the next aligned slot" {
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u64, 0));
    try std.testing.expectEqual(@as(usize, 7), Aligner.skipAmount(u64, 1));
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u64, 8));
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u32, 4));
    try std.testing.expectEqual(@as(usize, 2), Aligner.skipAmount(u32, 6));
}

test "Aligner.skipAmount returns zero for already-aligned positions" {
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u8, 0));
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u8, 7));
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u16, 2));
    try std.testing.expectEqual(@as(usize, 0), Aligner.skipAmount(u16, 4));
}

test "Aligner.write emits exactly skipAmount zero bytes" {
    var buf: [16]u8 = @splat(0xFF);
    var fbs = std.Io.Writer.fixed(&buf);
    // Start at offset 3, request u64 alignment → needs 5 bytes.
    const written = try Aligner.write(u64, *std.Io.Writer, &fbs, 3);
    try std.testing.expectEqual(@as(usize, 5), written);
    try std.testing.expectEqual(@as(usize, 5), fbs.end);
    for (buf[0..5]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // Bytes past the written window should be untouched.
    try std.testing.expectEqual(@as(u8, 0xFF), buf[5]);
}

test "alignment_bytes_to_repeat_buffer is 144 zero bytes" {
    try std.testing.expectEqual(@as(usize, 144), alignment_bytes_to_repeat_buffer.len);
    for (alignment_bytes_to_repeat_buffer) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
