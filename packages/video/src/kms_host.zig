//! Explicit native C-translation entry point, supported with Zig 0.15.2.
//! Keep this separate from video.zig so portable imports work on newer Zig.
pub const discovery = @import("display/kms_discovery_host.zig");
pub const scanout = @import("display/kms_scanout_host.zig");
test "native KMS entry exposes platform availability" {
    const expected = @import("builtin").os.tag == .linux;
    try @import("std").testing.expectEqual(expected, discovery.available);
    try @import("std").testing.expectEqual(expected, scanout.available);
}
