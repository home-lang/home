// Home Video Library - Hardware Platform Detection
// Detect hardware capabilities and available acceleration

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    macos,
    linux,
    windows,
    other,

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .linux => .linux,
            .windows => .windows,
            else => .other,
        };
    }
};

pub const Arch = enum {
    x86_64,
    arm64,
    other,

    pub fn current() Arch {
        return switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .arm64,
            else => .other,
        };
    }
};

pub const HWAcceleration = enum {
    videotoolbox, // macOS
    vaapi, // Linux
    nvenc, // NVIDIA
    qsv, // Intel Quick Sync
    d3d11, // Windows Direct3D 11
    none,
};

pub const PlatformCapabilities = struct {
    platform: Platform,
    arch: Arch,
    available_hw_accel: []const HWAcceleration,

    pub fn detect(allocator: std.mem.Allocator) !PlatformCapabilities {
        const platform = Platform.current();
        const arch = Arch.current();

        var hw_list = std.ArrayList(HWAcceleration).init(allocator);
        errdefer hw_list.deinit();

        // Detect based on platform
        switch (platform) {
            .macos => try hw_list.append(.videotoolbox),
            .linux => try hw_list.append(.vaapi),
            .windows => try hw_list.append(.d3d11),
            .other => {},
        }

        return .{
            .platform = platform,
            .arch = arch,
            .available_hw_accel = try hw_list.toOwnedSlice(),
        };
    }
};
