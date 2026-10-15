const std = @import("std");
const runner = @import("cached_test_runner");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    cache_path: []const u8,
    parent_path: []const u8,
    peer_path: []const u8,
    child_path: []const u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "parent.zig", .data = "test {}" });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "peer.zig", .data = "test {}" });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "child.zig", .data = "test {}" });

        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(root);
        const cache_path = try std.fs.path.join(allocator, &.{ root, "cache/test-results.json" });
        errdefer allocator.free(cache_path);
        const parent_path = try std.fs.path.join(allocator, &.{ root, "parent.zig" });
        errdefer allocator.free(parent_path);
        const peer_path = try std.fs.path.join(allocator, &.{ root, "peer.zig" });
        errdefer allocator.free(peer_path);
        const child_path = try std.fs.path.join(allocator, &.{ root, "child.zig" });
        return .{
            .tmp = tmp,
            .root = root,
            .cache_path = cache_path,
            .parent_path = parent_path,
            .peer_path = peer_path,
            .child_path = child_path,
        };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.child_path);
        allocator.free(self.peer_path);
        allocator.free(self.parent_path);
        allocator.free(self.cache_path);
        allocator.free(self.root);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn result(success: bool, duration_ms: u64) runner.TestResult {
    return .{
        .suite_name = "fixture",
        .success = success,
        .duration_ms = duration_ms,
        .output = "borrowed for cache insertion",
    };
}

fn deinitResults(allocator: std.mem.Allocator, results: []runner.TestResult) void {
    for (results) |*item| item.deinit(allocator);
    allocator.free(results);
}

test "suite dependency metadata" {
    const suite = runner.TestSuite{
        .name = "parser",
        .test_file = "parser_test.zig",
        .dependencies = &.{ "lexer", "ast" },
    };
    try std.testing.expect(!suite.hasNoDependencies());
    try std.testing.expect(suite.dependsOn("lexer"));
    try std.testing.expect(!suite.dependsOn("codegen"));
}

test "cache replacement round trips atomically" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    const suite = runner.TestSuite{ .name = "parent", .test_file = fixture.parent_path };

    {
        var cache = try runner.TestCache.initAtPath(std.testing.allocator, std.testing.io, fixture.cache_path);
        defer cache.deinit();
        try cache.put(suite, result(true, 4));
        try cache.put(suite, result(false, 9));
        try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
        try cache.save();
    }

    var reopened = try runner.TestCache.initAtPath(std.testing.allocator, std.testing.io, fixture.cache_path);
    defer reopened.deinit();
    try std.testing.expect(try reopened.isCached(suite));
    const cached = reopened.getCached("parent").?;
    try std.testing.expect(!cached.success);
    try std.testing.expectEqual(@as(u64, 9), cached.duration_ms);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = fixture.parent_path,
        .data = "test { _ = 1; }",
    });
    try std.testing.expect(!try reopened.isCached(suite));
}

const CacheAllocationContext = struct {
    cache_path: []const u8,
    source_path: []const u8,
};

fn exerciseCacheAllocation(allocator: std.mem.Allocator, context: CacheAllocationContext) !void {
    var cache = try runner.TestCache.initAtPath(allocator, std.testing.io, context.cache_path);
    defer cache.deinit();
    try cache.put(.{ .name = "fixture", .test_file = context.source_path }, result(true, 1));
}

test "cache insertion releases every partial allocation" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCacheAllocation,
        .{CacheAllocationContext{
            .cache_path = fixture.cache_path,
            .source_path = fixture.parent_path,
        }},
    );
}

const ExecutionState = struct {
    mutex: std.Io.Mutex = .init,
    calls: usize = 0,
    parent_completed: bool = false,
    fail_name: ?[]const u8 = null,
};

fn fakeExecutor(
    context_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    suite: runner.TestSuite,
) !runner.TestResult {
    const context: *ExecutionState = @ptrCast(@alignCast(context_ptr.?));
    context.mutex.lockUncancelable(io);
    defer context.mutex.unlock(io);
    if (context.fail_name) |name| {
        if (std.mem.eql(u8, name, suite.name)) return error.SyntheticExecutionFailure;
    }
    if (std.mem.eql(u8, suite.name, "child") and !context.parent_completed) {
        return error.DependencyOrderViolation;
    }
    context.calls += 1;
    if (std.mem.eql(u8, suite.name, "parent")) context.parent_completed = true;
    return .{
        .suite_name = suite.name,
        .success = true,
        .duration_ms = 1,
        .output = try allocator.dupe(u8, suite.name),
    };
}

test "runner respects dependency waves and reuses cache" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    const suites = [_]runner.TestSuite{
        .{ .name = "child", .test_file = fixture.child_path, .dependencies = &.{"parent"} },
        .{ .name = "peer", .test_file = fixture.peer_path },
        .{ .name = "parent", .test_file = fixture.parent_path },
    };
    var state = ExecutionState{};
    var test_runner = try runner.TestRunner.initWithCachePath(
        std.testing.allocator,
        std.testing.io,
        &suites,
        2,
        fixture.cache_path,
    );
    defer test_runner.deinit();
    test_runner.setExecutor(&state, fakeExecutor);

    const first = try test_runner.runAll();
    defer deinitResults(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(usize, 3), state.calls);
    for (first) |item| try std.testing.expect(!item.cached);

    const second = try test_runner.runAll();
    defer deinitResults(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 3), second.len);
    try std.testing.expectEqual(@as(usize, 3), state.calls);
    for (second) |item| try std.testing.expect(item.cached);
}

test "runner distinguishes invalid dependency plans" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    const missing = [_]runner.TestSuite{
        .{ .name = "child", .test_file = fixture.child_path, .dependencies = &.{"absent"} },
    };
    var missing_runner = try runner.TestRunner.initWithCachePath(
        std.testing.allocator,
        std.testing.io,
        &missing,
        1,
        fixture.cache_path,
    );
    defer missing_runner.deinit();
    try std.testing.expectError(error.MissingDependency, missing_runner.runAll());

    const cyclic = [_]runner.TestSuite{
        .{ .name = "a", .test_file = fixture.parent_path, .dependencies = &.{"b"} },
        .{ .name = "b", .test_file = fixture.peer_path, .dependencies = &.{"a"} },
    };
    var cyclic_runner = try runner.TestRunner.initWithCachePath(
        std.testing.allocator,
        std.testing.io,
        &cyclic,
        1,
        fixture.cache_path,
    );
    defer cyclic_runner.deinit();
    try std.testing.expectError(error.CircularDependency, cyclic_runner.runAll());
}

test "worker execution errors propagate" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    const suites = [_]runner.TestSuite{
        .{ .name = "broken", .test_file = fixture.parent_path },
    };
    var state = ExecutionState{ .fail_name = "broken" };
    var test_runner = try runner.TestRunner.initWithCachePath(
        std.testing.allocator,
        std.testing.io,
        &suites,
        1,
        fixture.cache_path,
    );
    defer test_runner.deinit();
    test_runner.setExecutor(&state, fakeExecutor);
    try std.testing.expectError(error.SyntheticExecutionFailure, test_runner.runAll());
}

test "default executor runs a real Zig test process" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    const suites = [_]runner.TestSuite{
        .{ .name = "real", .test_file = fixture.parent_path },
    };
    var test_runner = try runner.TestRunner.initWithCachePath(
        std.testing.allocator,
        std.testing.io,
        &suites,
        1,
        fixture.cache_path,
    );
    defer test_runner.deinit();
    const results = try test_runner.runAll();
    defer deinitResults(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].success);
    try std.testing.expect(!results[0].cached);
}

test "compatibility runner executes an empty plan" {
    var test_runner = try runner.TestRunner.init(std.testing.allocator, &.{}, 1);
    defer test_runner.deinit();
    const results = try test_runner.runAll();
    defer deinitResults(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
