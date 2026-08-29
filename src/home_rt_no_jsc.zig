//! Minimal runtime surface for Home-only compiler builds.
//!
//! JavaScriptCore-disabled builds must not analyze or link the vendored Bun
//! runtime. Keep the small CLI helpers used by the native Home compiler here;
//! JavaScript/TypeScript commands are rejected by `main.zig` before reaching
//! any runtime-only path.

const std = @import("std");

pub var argv: [][:0]const u8 = &[_][:0]const u8{};

pub const default_allocator = std.heap.c_allocator;

pub const Global = struct {
    // Keep these synchronized with packages/runtime/src/environment.zig, which
    // identifies the pinned Bun compatibility target used by JSC builds.
    pub const package_json_version = "1.4.0";
    pub const package_json_version_with_revision = "1.4.0+4982b91e3";
};

pub const StackCheck = struct {
    pub fn configureThread() void {}
};

pub fn dupeZ(allocator: std.mem.Allocator, comptime T: type, value: []const T) std.mem.Allocator.Error![:0]T {
    const result = try allocator.allocSentinel(T, value.len, 0);
    @memcpy(result, value);
    return result;
}
