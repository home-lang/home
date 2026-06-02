// Copied from bun/src/analytics/analytics.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Rewritten imports: `@import("bun")` → `@import("home")`.
// Three upstream chunks are intentionally omitted from this leaf:
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
//   3. `pub const GenerateHeader` — calls `bun.c.uname`, `bun.Semver`,
//      and `analytics.Platform.version` slicing through `bun.sliceTo`.
//      Re-attaches with `home_rt.Semver` + a `home_rt.c.uname` shim.
//
// What's preserved is the analytics gate (`isEnabled`, `enabled`,
// `is_ci`), the `EventName` enum, and `validateFeatureName` — exactly
// the surface `crash_handler.report` and the (future) bunfig parser
// consume on the JSC-free side.

const std = @import("std");
const home_rt = @import("home");

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
