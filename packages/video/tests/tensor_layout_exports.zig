const std = @import("std");
const video = @import("video");
test "public video root exposes checked row and column tensor layouts" {
    const tensor = try video.tensor_layout.Layout.init(&.{ 2, 3 }, .column_major, 6);
    try std.testing.expectEqual(@as(usize, 3), try tensor.offset(&.{ 1, 1 }));
}
test "raw frame tensor allocation checks image geometry before asking the allocator" {
    const Raw = video.RawFrameData;
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, Raw.init(alloc, 0, 1, 3, .hwc));
    try std.testing.expectError(error.InvalidDimensions, Raw.init(alloc, 1, 1, 0, .chw));
    try std.testing.expectError(error.TensorTooLarge, Raw.init(alloc, std.math.maxInt(u32), std.math.maxInt(u32), 255, .hwc));
    var tensor = try Raw.init(alloc, 3, 2, 3, .chw);
    defer tensor.deinit();
    tensor.set(1, 2, 2, 0.375);
    try std.testing.expectEqual(@as(f32, 0.375), tensor.get(1, 2, 2));
    try std.testing.expectEqual(@as(usize, 18), tensor.data.len);
}
