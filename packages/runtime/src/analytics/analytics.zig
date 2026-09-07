// Copied from bun/src/analytics/analytics.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Rewritten imports: `@import("bun")` → `@import("home")`.
// Two upstream chunks are intentionally omitted from this leaf:
//
//   1. `pub const Features = struct { ... }` — the `builtin_modules`
//      field is `std.enums.EnumSet(bun.jsc.ModuleLoader.HardcodedModule)`
//      and the `Formatter` walks comptime decls in a shape that needs
//      `bun.Output`-tier writers. Re-attaches once the JSC ModuleLoader
//      enum lands.
//
//   2. `packed_features_list`, `PackedFeatures`, `packedFeatures()` —
//      derived from `Features`; parks alongside.
//
// What's preserved is the analytics gate (`isEnabled`, `enabled`,
// `is_ci`), the `EventName` enum, `validateFeatureName`, and Bun's platform
// detector used by `/bun:info` and kernel feature gates.

const std = @import("std");
const home_rt = @import("home");
const analytics = @import("schema.zig").analytics;
const Environment = home_rt.Environment;
const Semver = home_rt.Semver;

const assert = home_rt.assert;

/// Enables analytics. This is used by:
/// - crash_handler.zig's `report` function to anonymously report crashes
///
/// Since this field can be .unknown, it makes more sense to call `isEnabled`
/// instead of processing this field directly.
pub var enabled: enum { yes, no, unknown } = .unknown;
pub var is_ci: enum { yes, no, unknown } = .unknown;

pub fn isEnabled() bool {
    return switch (enabled) {
        .yes => true,
        .no => false,
        .unknown => {
            enabled = detect: {
                if (home_rt.env_var.DO_NOT_TRACK.get()) {
                    break :detect .no;
                }
                if (home_rt.env_var.HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET.get() != null) {
                    break :detect .no;
                }
                break :detect .yes;
            };
            assert(enabled == .yes or enabled == .no);
            return enabled == .yes;
        },
    };
}

pub fn validateFeatureName(name: []const u8) void {
    if (name.len > 64) @compileError("Invalid feature name: " ++ name);
    for (name) |char| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', ':', '-' => {},
            else => @compileError("Invalid feature name: " ++ name),
        }
    }
}

pub const EventName = enum(u8) {
    bundle_success,
    bundle_fail,
    bundle_start,
    http_start,
    http_build,
};

const platform_arch = if (Environment.isAarch64) analytics.Architecture.arm else analytics.Architecture.x64;

// TODO: move this code somewhere more appropriate, and remove it from "analytics".
// This matches Bun's platform metadata and kernel feature detection. `/bun:info`
// serializes the same schema, including the real host OS version.
pub const GenerateHeader = struct {
    pub const GeneratePlatform = struct {
        var osversion_name: [32]u8 = undefined;
        var freebsd_os_version: [256]u8 = undefined;

        fn forMac() analytics.Platform {
            @memset(&osversion_name, 0);

            var platform = analytics.Platform{
                .os = .macos,
                .version = &.{},
                .arch = platform_arch,
            };
            var len = osversion_name.len - 1;
            if (std.c.sysctlbyname("kern.osproductversion", &osversion_name, &len, null, 0) == -1) return platform;

            platform.version = home_rt.sliceTo(&osversion_name, 0);
            return platform;
        }

        pub var linux_os_name: if (Environment.isLinux) std.c.utsname else void = undefined;
        var platform_: analytics.Platform = undefined;
        pub const Platform = analytics.Platform;
        var linux_kernel_version: Semver.Version = undefined;
        var run_once = home_rt.once(struct {
            fn run() void {
                if (comptime Environment.isMac) {
                    platform_ = forMac();
                } else if (comptime Environment.isLinux) {
                    platform_ = forLinux();

                    const release = home_rt.sliceTo(&linux_os_name.release, 0);
                    const sliced_string = Semver.SlicedString.init(release, release);
                    const result = Semver.Version.parse(sliced_string);
                    linux_kernel_version = result.version.min();
                } else if (comptime Environment.isFreeBSD) {
                    platform_ = forFreeBSD();
                } else if (Environment.isWindows) {
                    platform_ = .{
                        .os = .windows,
                        .version = &.{},
                        .arch = platform_arch,
                    };
                }
            }
        }.run);

        pub fn forOS() analytics.Platform {
            run_once.call(.{});
            return platform_;
        }

        var use_msgx_on_macos_14_or_later: bool = undefined;
        var detect_use_msgx_once = home_rt.once(detectUseMsgXOnMacOS14OrLater);

        fn detectUseMsgXOnMacOS14OrLater() void {
            const version = Semver.Version.parseUTF8(forOS().version);
            use_msgx_on_macos_14_or_later = version.valid and version.version.max().major >= 14;
        }

        pub export fn Bun__doesMacOSVersionSupportSendRecvMsgX() i32 {
            if (comptime !Environment.isMac) return 0;

            detect_use_msgx_once.call(.{});
            return @intFromBool(use_msgx_on_macos_14_or_later);
        }

        pub fn kernelVersion() Semver.Version {
            if (comptime !Environment.isLinux) {
                @compileError("This function is only implemented on Linux");
            }
            _ = forOS();
            return linux_kernel_version;
        }

        export fn Bun__isEpollPwait2SupportedOnLinuxKernel() i32 {
            if (comptime !Environment.isLinux) return 0;

            const min_epoll_pwait2 = Semver.Version{
                .major = 5,
                .minor = 11,
                .patch = 0,
            };

            return switch (kernelVersion().order(min_epoll_pwait2, "", "")) {
                .gt, .eq => 1,
                .lt => 0,
            };
        }

        fn forLinux() analytics.Platform {
            linux_os_name = std.mem.zeroes(@TypeOf(linux_os_name));
            _ = std.c.uname(&linux_os_name);

            const release = home_rt.sliceTo(&linux_os_name.release, 0);
            if (comptime Environment.isAndroid) {
                return .{ .os = .android, .version = release, .arch = platform_arch };
            }
            if (std.mem.indexOf(u8, release, "microsoft") != null) {
                return .{ .os = .wsl, .version = release, .arch = platform_arch };
            }
            return .{ .os = .linux, .version = release, .arch = platform_arch };
        }

        fn forFreeBSD() analytics.Platform {
            // std.posix.uname is backed by the target libc and avoids depending
            // on Bun's generated translate-c header bundle.
            const os_name = std.posix.uname();
            const release = home_rt.sliceTo(&os_name.release, 0);
            @memcpy(freebsd_os_version[0..release.len], release);
            return .{
                .os = .freebsd,
                .version = freebsd_os_version[0..release.len],
                .arch = platform_arch,
            };
        }
    };
};

// ---- Inline tests ------------------------------------------------------

test "analytics: enabled starts unknown" {
    // The global is process-wide; restore after the assertion so we don't
    // poison adjacent tests that touch isEnabled().
    const original = enabled;
    defer enabled = original;
    enabled = .unknown;
    try std.testing.expectEqual(@as(@TypeOf(enabled), .unknown), enabled);
}

test "analytics: isEnabled latches to .yes or .no" {
    const original_enabled = enabled;
    defer enabled = original_enabled;
    enabled = .unknown;
    _ = isEnabled();
    try std.testing.expect(enabled == .yes or enabled == .no);
}

test "analytics: isEnabled is idempotent once latched" {
    const original_enabled = enabled;
    defer enabled = original_enabled;
    enabled = .yes;
    try std.testing.expect(isEnabled());
    enabled = .no;
    try std.testing.expect(!isEnabled());
}

test "analytics: EventName tags match the wire layout" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EventName.bundle_success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EventName.bundle_fail));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EventName.bundle_start));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(EventName.http_start));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(EventName.http_build));
}

test "analytics: validateFeatureName accepts the upstream charset" {
    // The function is comptime-only (its only failure path is @compileError),
    // so the inline test just confirms it can be invoked at comptime for the
    // sentinel "valid" inputs without tripping the compiler.
    comptime validateFeatureName("Bun.serve");
    comptime validateFeatureName("ssr_render");
    comptime validateFeatureName("http_server");
    comptime validateFeatureName("postgres-tls");
}
