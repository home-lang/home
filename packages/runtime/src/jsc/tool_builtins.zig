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
    const glob = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_glob.js"), "home:tool-glob-factory-install", 1) catch return;
    defer glob.deinit(allocator);
    if (glob.exception != null) return;
    const file = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_file.js"), "home:tool-file-factory-install", 1) catch return;
    defer file.deinit(allocator);
    if (file.exception != null) return;
    const async_hooks = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_async_hooks.js"), "home:tool-async-hooks-factory-install", 1) catch return;
    defer async_hooks.deinit(allocator);
    if (async_hooks.exception != null) return;
    const performance = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_performance.js"), "home:tool-performance-install", 1) catch return;
    defer performance.deinit(allocator);
    if (performance.exception != null) return;
    const markdown = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_markdown.js"), "home:tool-markdown-install", 1) catch return;
    defer markdown.deinit(allocator);
    if (markdown.exception != null) return;
    const timers = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_timers.js"), "home:tool-timers-install", 1) catch return;
    defer timers.deinit(allocator);
    if (timers.exception != null) return;
    const spawn = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_spawn.js"), "home:tool-spawn-install", 1) catch return;
    defer spawn.deinit(allocator);
    if (spawn.exception != null) return;
    const exec = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_exec.js"), "home:tool-exec-factory-install", 1) catch return;
    defer exec.deinit(allocator);
    if (exec.exception != null) return;
    const sqlite = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_sqlite.js"), "home:tool-sqlite-factory-install", 1) catch return;
    defer sqlite.deinit(allocator);
    if (sqlite.exception != null) return;
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, @embedFile("tool_builtins.js"), "home:tool-builtins-install", 1) catch return;
    result.deinit(allocator);
}
