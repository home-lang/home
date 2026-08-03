//! Home JS/TS repository-tool runner.

const std = @import("std");
const build_options = @import("build_options");
const tool_runtime = @import("tool_runtime");
const ts_driver = @import("ts_driver");

const g_io = std.Io.Threaded.global_single_threaded.io();

fn usage() noreturn {
    std.debug.print(
        "usage: home-tool eval <typescript> [--print] | home-tool run <file> [args...]\n",
        .{},
    );
    std.process.exit(2);
}

fn isTypeScript(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".tsx") or
        std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts");
}

fn emitTypeScript(allocator: std.mem.Allocator, source: []const u8, is_tsx: bool) ![]u8 {
    var compilation = try ts_driver.compileSource(allocator, source, .{
        .continue_on_error = false,
        .is_tsx = is_tsx,
        .jsx_option_present = is_tsx,
        .emit = .{ .module_kind = .commonjs },
    });
    defer {
        compilation.deinit();
        allocator.destroy(compilation);
    }
    return allocator.dupe(u8, compilation.js);
}

fn runSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_url: []const u8,
    argv: []const []const u8,
    print_result: bool,
) !void {
    var engine = try tool_runtime.Engine.init(allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const global = engine.currentGlobalObject();
    tool_runtime.console.install(allocator, ctx, global);
    tool_runtime.process.install(allocator, ctx, global, argv);
    tool_runtime.host.install(allocator, ctx, global);

    const evaluation = try tool_runtime.evaluate.evaluateUtf8Detailed(allocator, ctx, source, source_url, 1);
    defer evaluation.deinit(allocator);
    if (evaluation.exception != null) {
        std.debug.print("home-tool ({s}): {s}\n", .{
            build_options.js_engine,
            evaluation.exception_message orelse "uncaught exception",
        });
        std.process.exit(1);
    }
    if (print_result) {
        if (evaluation.value) |value| {
            const rendered = try tool_runtime.evaluate.valueToUtf8(allocator, ctx, value);
            defer allocator.free(rendered);
            const stdout = std.Io.File.stdout();
            try stdout.writeStreamingAll(g_io, rendered);
            try stdout.writeStreamingAll(g_io, "\n");
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next();
    const command = iterator.next() orelse usage();

    if (std.mem.eql(u8, command, "eval")) {
        const input = iterator.next() orelse usage();
        const flag = iterator.next();
        if (flag != null and !std.mem.eql(u8, flag.?, "--print")) usage();
        const emitted = try emitTypeScript(allocator, input, false);
        defer allocator.free(emitted);
        const argv = [_][]const u8{ "home-tool", "eval" };
        return runSource(allocator, emitted, "home:tool-eval", &argv, flag != null);
    }

    if (std.mem.eql(u8, command, "run")) {
        const path = iterator.next() orelse usage();
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "home-tool");
        try argv.append(allocator, path);
        while (iterator.next()) |arg| try argv.append(allocator, arg);

        const source = try std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited);
        defer allocator.free(source);
        if (isTypeScript(path)) {
            const emitted = try emitTypeScript(allocator, source, std.mem.endsWith(u8, path, ".tsx"));
            defer allocator.free(emitted);
            return runSource(allocator, emitted, path, argv.items, false);
        }
        return runSource(allocator, source, path, argv.items, false);
    }

    usage();
}
