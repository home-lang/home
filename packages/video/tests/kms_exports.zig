const std = @import("std");
const video = @import("video");
test "portable video root exposes KMS policy without unsupported native imports" {
    const layout = try video.kms_scanout.Layout.init("BGR888", 1, 1, 3, &.{.{ .fd = 0, .offset = 0, .length = 3, .used = 3 }});
    try std.testing.expectEqual(video.kms_catalog.fourcc("BG24"), layout.fourcc);
    const cpu = try video.kms_scanout.CpuLayout.init(3, 2, 16, 4096);
    try std.testing.expectEqual(@as(usize, 4096), cpu.size);
    const version = @import("builtin").zig_version;
    try std.testing.expectEqual(version.major == 0 and version.minor == 15, video.kms_host_toolchain_supported);
}

test "portable root exposes strict overlay stacking" {
    try std.testing.expectEqual(@as(u64, 2), try video.kms_scanout.overlayZ(1, 0, .{ .min = 0, .max = 5 }));
    try std.testing.expectError(error.Unsupported, video.kms_scanout.overlayZ(null, 2, null));
}
