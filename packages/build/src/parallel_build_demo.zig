const std = @import("std");
const parallel_build = @import("parallel_build.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer args_arena.deinit();
    const args = try init.args.toSlice(args_arena.allocator());

    var verbose = false;
    var benchmark = false;
    var num_threads: ?usize = null;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
            benchmark = true;
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-j")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --threads requires a number argument\n", .{});
                return error.InvalidArgument;
            }
            i += 1;
            num_threads = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Home Parallel Build System Demo            ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create parallel builder
    var builder = try parallel_build.ParallelBuilder.init(allocator, num_threads, null, null);
    defer builder.deinit();

    builder.verbose = verbose;
    builder.benchmark = benchmark;

    // Add demo tasks (simulating Home package compilation)
    const packages = [_]struct { name: []const u8, file: []const u8, deps: []const []const u8 }{
        .{ .name = "lexer", .file = "packages/lexer/src/lexer.zig", .deps = &.{} },
        .{ .name = "token", .file = "packages/lexer/src/token.zig", .deps = &.{} },
        .{ .name = "ast", .file = "packages/ast/src/ast.zig", .deps = &.{"lexer"} },
        .{ .name = "diagnostics", .file = "packages/diagnostics/src/diagnostics.zig", .deps = &.{"ast"} },
        .{ .name = "parser", .file = "packages/parser/src/parser.zig", .deps = &.{ "lexer", "ast", "diagnostics" } },
        .{ .name = "types", .file = "packages/types/src/type_system.zig", .deps = &.{ "ast", "diagnostics" } },
        .{ .name = "interpreter", .file = "packages/interpreter/src/interpreter.zig", .deps = &.{"ast"} },
        .{ .name = "codegen", .file = "packages/codegen/src/native_codegen.zig", .deps = &.{"ast"} },
        .{ .name = "formatter", .file = "packages/formatter/src/formatter.zig", .deps = &.{ "ast", "lexer", "parser" } },
        .{ .name = "queue", .file = "packages/queue/src/queue.zig", .deps = &.{} },
        .{ .name = "database", .file = "packages/database/src/database.zig", .deps = &.{} },
        .{ .name = "ir_cache", .file = "packages/cache/src/ir_cache.zig", .deps = &.{} },
    };

    std.debug.print("Adding {d} build tasks...\n", .{packages.len});

    for (packages) |pkg| {
        try builder.addTask(pkg.name, pkg.file, pkg.deps);
    }

    if (verbose) {
        try builder.analyzeDependencies();
        std.debug.print("\n", .{});
    }

    // Build all tasks
    std.debug.print("Starting parallel build...\n\n", .{});

    builder.build() catch |err| {
        std.debug.print("\n[31mBuild failed: {any}[0m\n", .{err});
        return err;
    };

    std.debug.print("\n[32m✓ Build completed successfully![0m\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Home Parallel Build System Demo
        \\
        \\Demonstrates parallel compilation with work-stealing thread pool.
        \\
        \\Usage: parallel-build-demo [OPTIONS]
        \\
        \\Options:
        \\  -v, --verbose      Print detailed build progress
        \\  -b, --benchmark    Print detailed benchmark statistics
        \\  -j, --threads N    Set number of worker threads (default: CPU count)
        \\  -h, --help         Show this help message
        \\
        \\Examples:
        \\  parallel-build-demo                    # Build with defaults
        \\  parallel-build-demo -v -b              # Verbose with benchmarks
        \\  parallel-build-demo -j 8               # Use 8 threads
        \\
    , .{});
}
