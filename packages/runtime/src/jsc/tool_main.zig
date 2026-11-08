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
    var compilation = try ts_driver.prepareSource(allocator, source, .{
        .continue_on_error = false,
        .is_tsx = is_tsx,
        .jsx_option_present = is_tsx,
        .emit = .{ .module_kind = .commonjs },
    });
    defer {
        compilation.deinit();
        allocator.destroy(compilation);
    }
    return ts_driver.emitPreparedSource(compilation, .{ .module_kind = .commonjs });
}

fn runSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_url: []const u8,
    argv: []const []const u8,
    print_result: bool,
    module_completion: bool,
) !u8 {
    var engine = try tool_runtime.Engine.init(allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const global = engine.currentGlobalObject();
    tool_runtime.console.install(allocator, ctx, global);
    const uncaught_handler = tool_runtime.process.installWithUncaughtHandler(allocator, ctx, global, argv) orelse return error.MissingUncaughtHandler;
    defer tool_runtime.extern_fns.JSValueUnprotect(ctx, uncaught_handler);
    tool_runtime.host.install(allocator, ctx, global);
    tool_runtime.yaml.install(allocator, ctx, global);
    tool_runtime.tty.install(ctx, global);
    tool_runtime.crypto.install(ctx, global);
    tool_runtime.gzip.install(ctx, global);
    tool_runtime.async_context.install(ctx, global);
    tool_runtime.os.install(ctx, global);
    tool_runtime.fs.install(ctx, global);
    tool_runtime.builtins.install(allocator, ctx);
    tool_runtime.modules.install(allocator, ctx, global);

    const evaluation = try tool_runtime.evaluate.evaluateUtf8Detailed(allocator, ctx, source, source_url, 1);
    defer evaluation.deinit(allocator);
    if (evaluation.exception != null) {
        std.debug.print("home-tool ({s}): {s}\n", .{
            build_options.js_engine,
            evaluation.exception_message orelse "uncaught exception",
        });
        return 1;
    }
    if (module_completion) {
        // JSEvaluateScript performs the backend's microtask checkpoint. Keep
        // the returned private completion closure alive while checking that
        // the entry actually fulfilled (including rejection with undefined).
        const completion = evaluation.value orelse return error.MissingModuleCompletion;
        tool_runtime.extern_fns.JSValueProtect(ctx, completion);
        defer tool_runtime.extern_fns.JSValueUnprotect(ctx, completion);
        const function = tool_runtime.extern_fns.JSValueToObject(ctx, completion, null) orelse return error.InvalidModuleCompletion;
        if (!tool_runtime.extern_fns.JSObjectIsFunction(ctx, function)) return error.InvalidModuleCompletion;
        var exception: ?*tool_runtime.opaques.JSValue = null;
        _ = tool_runtime.extern_fns.JSObjectCallAsFunction(ctx, function, null, 0, null, &exception);
        if (exception) |thrown| {
            const message = try tool_runtime.evaluate.valueToUtf8(allocator, ctx, thrown);
            defer allocator.free(message);
            std.debug.print("home-tool ({s}): {s}\n", .{ build_options.js_engine, message });
            return 1;
        }
    }
    if (comptime build_options.use_zig_js) {
        if (try tool_runtime.rejections.checkpoint(allocator, ctx, uncaught_handler)) |diagnostic| {
            defer allocator.free(diagnostic);
            std.debug.print("home-tool ({s}): {s}\n", .{ build_options.js_engine, diagnostic });
            return 1;
        }
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
    var natural_exit = try tool_runtime.process.emitNaturalExit(allocator, ctx);
    defer natural_exit.deinit(allocator);
    if (natural_exit.exception_message) |message| {
        std.debug.print("home-tool ({s}): {s}\n", .{ build_options.js_engine, message });
    }
    return natural_exit.exit_code;
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
        const code = try runSource(allocator, emitted, "home:tool-eval", &argv, flag != null, false);
        if (code != 0) std.process.exit(code);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        const path = iterator.next() orelse usage();
        const cwd = try std.process.currentPathAlloc(g_io, allocator);
        defer allocator.free(cwd);
        // Node/Bun expose a lexical absolute entry path, even when invoked
        // relatively. Entry guards compare argv[1] with the module filename.
        const entry_path = try std.fs.path.resolve(allocator, &.{ cwd, path });
        defer allocator.free(entry_path);
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "home-tool");
        try argv.append(allocator, entry_path);
        while (iterator.next()) |arg| try argv.append(allocator, arg);

        const code = try runSource(allocator, "Home.startModule(process.argv[1]);", entry_path, argv.items, false, true);
        if (code != 0) std.process.exit(code);
        return;
    }

    usage();
}
