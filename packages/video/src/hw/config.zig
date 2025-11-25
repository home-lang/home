// Home Video Library - Hardware Configuration
// Configure hardware acceleration settings

const std = @import("std");
const platform = @import("platform.zig");

pub const HWConfig = struct {
    enabled: bool = true,
    preferred: ?platform.HWAcceleration = null,
    fallback_to_software: bool = true,
    device_index: u32 = 0,

    pub fn auto() HWConfig {
        return .{};
    }

    pub fn software_only() HWConfig {
        return .{ .enabled = false };
    }

    pub fn hardware_only() HWConfig {
        return .{ .fallback_to_software = false };
    }
};
