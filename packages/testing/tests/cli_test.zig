const std = @import("std");
const cli = @import("testing_cli");
const runner = @import("cached_test_runner");

fn runCli(args: []const []const u8, config: cli.RunnerConfig, output: *std.Io.Writer.Allocating) !u8 {
    return cli.runWithConfig(std.testing.allocator, std.testing.io, args, &output.writer, config);
}

test "help and invalid arguments are reported without exiting the process" {
    var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCli(&.{"--help"}, .{}, &help));
    try std.testing.expect(std.mem.indexOf(u8, help.written(), "Usage: home-test") != null);

    var invalid: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid.deinit();
    try std.testing.expectEqual(@as(u8, 2), try runCli(&.{ "--parallel", "0" }, .{}, &invalid));
    try std.testing.expect(std.mem.indexOf(u8, invalid.written(), "positive integer") != null);
}

test "discover mode parses and executes real Home tests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "passing.test.home", .data = "@test\nfn passing() {}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "failing.test.hm", .data = "it(\"failing inline test\") { break }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.home", .data = "@test\nfn must_not_run() { break }\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runCli(&.{ "--discover", root }, .{}, &output));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Found 2 test file(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Total tests: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Total passed: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Total failed: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "failing inline test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "must_not_run") == null);
}

test "discover mode reports parser failures as failed input files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.test.home", .data = "fn broken( {\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runCli(&.{ "--discover", root }, .{}, &output));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Failed to parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Total failed: 1") != null);
}

const ExecutionState = struct {
    mutex: std.Io.Mutex = .init,
    calls: usize = 0,
};

fn fakeExecutor(
    context_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    suite: runner.TestSuite,
) !runner.TestResult {
    const state: *ExecutionState = @ptrCast(@alignCast(context_ptr.?));
    state.mutex.lockUncancelable(io);
    state.calls += 1;
    state.mutex.unlock(io);
    return .{
        .suite_name = suite.name,
        .success = true,
        .duration_ms = 1,
        .output = try allocator.dupe(u8, "executed"),
    };
}

test "no-cache bypasses cache reads and writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "suite.zig", .data = "test {}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "suite.zig" });
    defer std.testing.allocator.free(source_path);
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ root, "cache/results.json" });
    defer std.testing.allocator.free(cache_path);
    const suites = [_]runner.TestSuite{.{ .name = "fixture", .test_file = source_path }};
    var state = ExecutionState{};
    const config = cli.RunnerConfig{
        .suites = &suites,
        .cache_path = cache_path,
        .executor_context = &state,
        .executor = fakeExecutor,
    };

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCli(&.{ "--no-cache", "--parallel", "1" }, config, &first));
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCli(&.{ "--no-cache", "--parallel", "1" }, config, &second));
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "cache/results.json", .{}));
}

test "cache-enabled mode reuses persisted results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "suite.zig", .data = "test {}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root, "suite.zig" });
    defer std.testing.allocator.free(source_path);
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ root, "cache/results.json" });
    defer std.testing.allocator.free(cache_path);
    const suites = [_]runner.TestSuite{.{ .name = "fixture", .test_file = source_path }};
    var state = ExecutionState{};
    const config = cli.RunnerConfig{
        .suites = &suites,
        .cache_path = cache_path,
        .executor_context = &state,
        .executor = fakeExecutor,
    };

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCli(&.{ "--parallel", "1" }, config, &first));
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCli(&.{ "--parallel", "1" }, config, &second));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}
