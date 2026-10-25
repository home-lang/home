const std = @import("std");
const video = @import("video");
test "public video root exposes bounded CNN shape and storage interpretation" {
    var bytes: [712]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[64..68], 1, .little);
    std.mem.writeInt(u32, bytes[68..72], 6, .little);
    std.mem.writeInt(u32, bytes[72..76], 2, .little);
    std.mem.writeInt(u16, bytes[76..78], 2, .little);
    std.mem.writeInt(u16, bytes[78..80], 3, .little);
    const info = try video.cnn_outputs.Info.parse(&bytes, 6, 6);
    try std.testing.expectEqual(@as(u8, 1), info.count);
    try std.testing.expectEqual(@as(usize, 5), try info.tensors[0].?.layout.offset(&.{ 1, 2 }));
}
