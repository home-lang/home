const std = @import("std");
const video = @import("video");
test "portable video root exposes KMS policy without unsupported native imports" {
    const layout = try video.kms_scanout.Layout.init("BGR888", 1, 1, 3, &.{.{ .fd = 0, .offset = 0, .length = 3, .used = 3 }});
    try std.testing.expectEqual(video.kms_catalog.fourcc("BG24"), layout.fourcc);
    const native = video.kms_host_toolchain_supported and @import("builtin").os.tag == .linux;
    try std.testing.expectEqual(native, video.kms_discovery_host.available);
    try std.testing.expectEqual(native, video.kms_scanout_host.available);
}
