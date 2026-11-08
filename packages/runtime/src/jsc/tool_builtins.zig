//! Real, deliberately bounded built-in adapters for the repository-tool host.
const std = @import("std");
const evaluate = @import("evaluate.zig");
const opaques = @import("opaques.zig");

pub fn install(allocator: std.mem.Allocator, ctx: *opaques.JSContextRef) void {
    const events = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_events.js"), "home:tool-events-install", 1) catch return;
    defer events.deinit(allocator);
    if (events.exception != null) return;
    const buffer = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_buffer.js"), "home:tool-buffer-factory-install", 1) catch return;
    defer buffer.deinit(allocator);
    if (buffer.exception != null) return;
    const streams = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_streams.js"), "home:tool-streams-factory-install", 1) catch return;
    defer streams.deinit(allocator);
    if (streams.exception != null) return;
    const zlib = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_zlib.js"), "home:tool-zlib-factory-install", 1) catch return;
    defer zlib.deinit(allocator);
    if (zlib.exception != null) return;
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_builtins.js"), "home:tool-builtins-install", 1) catch return;
    result.deinit(allocator);
}
