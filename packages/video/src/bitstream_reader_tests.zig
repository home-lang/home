//! Legacy public import remains wired to the shared portable reader.
const std = @import("std");
const legacy = @import("util/bitstream.zig");
const shared = @import("codecs/video/bit_reader.zig");
test "legacy bitstream import retains the same public Reader type" {
    try std.testing.expect(legacy.BitstreamReader == shared.Reader);
    var r = legacy.BitstreamReader.init(&.{ 0x80, 42 });
    try std.testing.expectEqual(@as(u32, 0), try r.readUE());
    try std.testing.expectEqualSlices(u8, &.{42}, try r.readBytes(1));
}
