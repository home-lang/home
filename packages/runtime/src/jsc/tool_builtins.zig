//! Real, deliberately bounded built-in adapters for the repository-tool host.
const std = @import("std");
const evaluate = @import("evaluate.zig");
const opaques = @import("opaques.zig");

pub fn install(allocator: std.mem.Allocator, ctx: *opaques.JSContextRef) void {
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_builtins.js"), "home:tool-builtins-install", 1) catch return;
    result.deinit(allocator);
}
