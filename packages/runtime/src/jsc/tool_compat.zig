const std = @import("std");
const build_options = @import("build_options");

/// Minimal environment identity consumed by the shared reduced-JSC process
/// implementation. The value is injected from the same build-level constant
/// as the full runtime rather than duplicated in this compatibility leaf.
pub const Environment = struct {
    pub const reported_nodejs_version = build_options.reported_nodejs_version;
    pub const ci_assert = true;
};

pub const yaml_backend = @import("tool_yaml_backend.zig");
pub const OOM = yaml_backend.OOM;
pub const assert = yaml_backend.assert;
pub const logger = yaml_backend.logger;
pub const StringHashMap = yaml_backend.StringHashMap;
pub const StackCheck = yaml_backend.StackCheck;
pub const throwStackOverflow = yaml_backend.throwStackOverflow;
pub const jsc = yaml_backend.jsc;
pub const BabyList = yaml_backend.BabyList;
pub const collections = yaml_backend.collections;
pub const ast = yaml_backend.ast;

/// Minimal compatibility leaf for the public-C tool runtime. Keeping this
/// separate prevents a console/evaluate callback from importing Home's full
/// Bun/WebCore runtime solely for sentinel-terminated string allocation.
pub fn dupeZ(allocator: std.mem.Allocator, comptime T: type, value: []const T) std.mem.Allocator.Error![:0]T {
    const copy = try allocator.allocSentinel(T, value.len, 0);
    @memcpy(copy, value);
    return copy;
}
