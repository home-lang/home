const std = @import("std");
const Io = std.Io;

/// Test suite metadata for organizing and running tests.
pub const TestSuite = struct {
    name: []const u8,
    test_file: []const u8,
    dependencies: []const []const u8 = &.{},
    estimated_time_ms: u64 = 1000,
    requires_libc: bool = false,
    system_libs: []const []const u8 = &.{},

    pub fn hasNoDependencies(self: TestSuite) bool {
        return self.dependencies.len == 0;
    }

    pub fn dependsOn(self: TestSuite, suite_name: []const u8) bool {
        for (self.dependencies) |dependency| {
            if (std.mem.eql(u8, dependency, suite_name)) return true;
        }
        return false;
    }
};

/// Owned output from one test suite. `suite_name` remains borrowed from the
/// suite plan; `output` and `error_message` use the allocator passed to
/// `deinit`.
pub const TestResult = struct {
    suite_name: []const u8,
    success: bool,
    duration_ms: u64,
    output: []const u8,
    error_message: ?[]const u8 = null,
    cached: bool = false,

    pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }

    fn clone(self: TestResult, allocator: std.mem.Allocator) !TestResult {
        const output = try allocator.dupe(u8, self.output);
        errdefer allocator.free(output);
        const error_message = if (self.error_message) |message|
            try allocator.dupe(u8, message)
        else
            null;
        return .{
            .suite_name = self.suite_name,
            .success = self.success,
            .duration_ms = self.duration_ms,
            .output = output,
            .error_message = error_message,
            .cached = self.cached,
        };
    }
};

pub const CacheEntry = struct {
    /// Aliases the owning key in `TestCache.entries`.
    suite_name: []const u8,
    file_hash: [32]u8,
    success: bool,
    duration_ms: u64,
    timestamp: i64,
};

/// Persistent cache for test results.
pub const TestCache = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cache_path: []const u8,
    entries: std.StringHashMap(CacheEntry),
    modified: bool = false,

    const cache_file = ".home/test_cache.json";
    const max_cache_bytes = 10 * 1024 * 1024;
    const max_test_file_bytes = 64 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) !TestCache {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io) !TestCache {
        const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd);
        const cache_path = try std.fs.path.join(allocator, &.{ cwd, cache_file });
        defer allocator.free(cache_path);
        return initAtPath(allocator, io, cache_path);
    }

    pub fn initAtPath(allocator: std.mem.Allocator, io: Io, cache_path: []const u8) !TestCache {
        var cache = TestCache{
            .allocator = allocator,
            .io = io,
            .cache_path = try allocator.dupe(u8, cache_path),
            .entries = std.StringHashMap(CacheEntry).init(allocator),
        };
        errdefer cache.deinit();

        cache.load() catch |err| switch (err) {
            error.FileNotFound => {},
            error.OutOfMemory => return err,
            else => {
                cache.clearEntries();
                std.debug.print("Warning: ignoring invalid test cache: {s}\n", .{@errorName(err)});
            },
        };
        return cache;
    }

    pub fn deinit(self: *TestCache) void {
        self.clearEntries();
        self.entries.deinit();
        self.allocator.free(self.cache_path);
        self.* = undefined;
    }

    fn clearEntries(self: *TestCache) void {
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.entries.clearRetainingCapacity();
    }

    fn load(self: *TestCache) !void {
        const content = try Io.Dir.cwd().readFileAlloc(
            self.io,
            self.cache_path,
            self.allocator,
            .limited(max_cache_bytes),
        );
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCacheFile;

        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.* != .object) return error.InvalidCacheFile;

            const key = try self.allocator.dupe(u8, item.key_ptr.*);
            var owns_key = true;
            errdefer if (owns_key) self.allocator.free(key);

            var entry = try self.parseCacheEntry(item.value_ptr.object, key);
            const slot = try self.entries.getOrPut(key);
            if (slot.found_existing) {
                self.allocator.free(key);
                owns_key = false;
                entry.suite_name = slot.key_ptr.*;
            } else {
                slot.key_ptr.* = key;
                owns_key = false;
            }
            slot.value_ptr.* = entry;
        }
    }

    /// Atomically replaces the cache file after serializing every entry.
    pub fn save(self: *TestCache) !void {
        if (!self.modified) return;

        var output: Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writer.writeAll("{\n");

        var first = true;
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.writeAll("  ");
            try std.json.Stringify.value(item.key_ptr.*, .{}, writer);
            try writer.writeAll(": {\n    \"suite_name\": ");
            try std.json.Stringify.value(item.value_ptr.suite_name, .{}, writer);
            try writer.writeAll(",\n    \"file_hash\": \"");
            for (item.value_ptr.file_hash) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.writeAll("\",\n");
            try writer.print("    \"success\": {s},\n", .{if (item.value_ptr.success) "true" else "false"});
            try writer.print("    \"duration_ms\": {d},\n", .{item.value_ptr.duration_ms});
            try writer.print("    \"timestamp\": {d}\n  }}", .{item.value_ptr.timestamp});
        }
        try writer.writeAll("\n}\n");

        const directory = std.fs.path.dirname(self.cache_path) orelse return error.InvalidPath;
        try Io.Dir.cwd().createDirPath(self.io, directory);
        const temporary_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.cache_path});
        defer self.allocator.free(temporary_path);
        errdefer Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temporary_path, .data = output.written() });
        try Io.Dir.cwd().rename(temporary_path, Io.Dir.cwd(), self.cache_path, self.io);
        self.modified = false;
    }

    pub fn isCached(self: *TestCache, suite: TestSuite) !bool {
        const entry = self.entries.get(suite.name) orelse return false;
        const current_hash = try self.computeFileHash(suite.test_file);
        return std.mem.eql(u8, &entry.file_hash, &current_hash);
    }

    pub fn getCached(self: *const TestCache, suite_name: []const u8) ?CacheEntry {
        return self.entries.get(suite_name);
    }

    /// Inserts or replaces one entry without removing the previous value until
    /// every fallible allocation has succeeded.
    pub fn put(self: *TestCache, suite: TestSuite, result: TestResult) !void {
        const file_hash = try self.computeFileHash(suite.test_file);
        const key = try self.allocator.dupe(u8, suite.name);
        var owns_key = true;
        errdefer if (owns_key) self.allocator.free(key);

        const slot = try self.entries.getOrPut(suite.name);
        const stored_key = if (slot.found_existing) slot.key_ptr.* else key;
        if (slot.found_existing) {
            self.allocator.free(key);
            owns_key = false;
        } else {
            slot.key_ptr.* = key;
            owns_key = false;
        }
        slot.value_ptr.* = .{
            .suite_name = stored_key,
            .file_hash = file_hash,
            .success = result.success,
            .duration_ms = result.duration_ms,
            .timestamp = Io.Clock.real.now(self.io).toSeconds(),
        };
        self.modified = true;
    }

    fn computeFileHash(self: *TestCache, file_path: []const u8) ![32]u8 {
        const content = try Io.Dir.cwd().readFileAlloc(
            self.io,
            file_path,
            self.allocator,
            .limited(max_test_file_bytes),
        );
        defer self.allocator.free(content);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        return digest;
    }

    fn parseCacheEntry(self: *TestCache, object: std.json.ObjectMap, suite_name: []const u8) !CacheEntry {
        _ = self;
        const hash_value = object.get("file_hash") orelse return error.MissingField;
        const success_value = object.get("success") orelse return error.MissingField;
        const duration_value = object.get("duration_ms") orelse return error.MissingField;
        const timestamp_value = object.get("timestamp") orelse return error.MissingField;
        if (hash_value != .string or hash_value.string.len != 64) return error.InvalidHash;
        if (success_value != .bool or duration_value != .integer or timestamp_value != .integer) {
            return error.InvalidCacheFile;
        }
        if (duration_value.integer < 0) return error.InvalidCacheFile;

        var file_hash: [32]u8 = undefined;
        for (0..file_hash.len) |index| {
            file_hash[index] = try std.fmt.parseInt(u8, hash_value.string[index * 2 .. index * 2 + 2], 16);
        }
        return .{
            .suite_name = suite_name,
            .file_hash = file_hash,
            .success = success_value.bool,
            .duration_ms = @intCast(duration_value.integer),
            .timestamp = timestamp_value.integer,
        };
    }
};

/// Dependency-aware parallel test runner with persistent result caching.
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    suites: []const TestSuite,
    cache: ?TestCache,
    max_parallel: usize,
    verbose: bool = false,
    benchmark: bool = false,
    executor_context: ?*anyopaque = null,
    executor: ExecuteFn = executeZigTest,
    state_mutex: Io.Mutex = .init,

    pub const ExecuteFn = *const fn (?*anyopaque, std.mem.Allocator, Io, TestSuite) anyerror!TestResult;

    const WorkerContext = struct {
        runner: *TestRunner,
        work_queue: []const TestSuite,
        next_index: usize = 0,
        first_error: ?anyerror = null,
        results: *std.ArrayList(TestResult),
    };

    pub fn init(allocator: std.mem.Allocator, suites: []const TestSuite, max_parallel: ?usize) !TestRunner {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io(), suites, max_parallel);
    }

    pub fn initWithIo(
        allocator: std.mem.Allocator,
        io: Io,
        suites: []const TestSuite,
        max_parallel: ?usize,
    ) !TestRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .suites = suites,
            .cache = try TestCache.initWithIo(allocator, io),
            .max_parallel = max_parallel orelse @max(1, try std.Thread.getCpuCount() - 1),
        };
    }

    pub fn initWithCachePath(
        allocator: std.mem.Allocator,
        io: Io,
        suites: []const TestSuite,
        max_parallel: ?usize,
        cache_path: []const u8,
    ) !TestRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .suites = suites,
            .cache = try TestCache.initAtPath(allocator, io, cache_path),
            .max_parallel = max_parallel orelse @max(1, try std.Thread.getCpuCount() - 1),
        };
    }

    /// Initializes a runner that never reads, hashes, mutates, or writes the
    /// persistent cache. This is intentionally distinct from clearing a loaded
    /// cache: `--no-cache` must not touch cache state at all.
    pub fn initWithoutCache(
        allocator: std.mem.Allocator,
        io: Io,
        suites: []const TestSuite,
        max_parallel: ?usize,
    ) !TestRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .suites = suites,
            .cache = null,
            .max_parallel = max_parallel orelse @max(1, try std.Thread.getCpuCount() - 1),
        };
    }

    pub fn deinit(self: *TestRunner) void {
        if (self.cache) |*cache| cache.deinit();
        self.* = undefined;
    }

    pub fn setExecutor(self: *TestRunner, context: ?*anyopaque, executor: ExecuteFn) void {
        self.executor_context = context;
        self.executor = executor;
    }

    pub fn saveCache(self: *TestRunner) !void {
        if (self.cache) |*cache| try cache.save();
    }

    pub fn runAll(self: *TestRunner) ![]TestResult {
        var results: std.ArrayList(TestResult) = .empty;
        errdefer {
            for (results.items) |*result| result.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        const groups = try self.groupByDependencies();
        defer {
            for (groups) |group| self.allocator.free(group);
            self.allocator.free(groups);
        }

        const start = Io.Clock.awake.now(self.io);
        for (groups) |group| {
            const group_results = try self.runGroup(group);
            var transferred = false;
            defer {
                if (!transferred) for (group_results) |*result| result.deinit(self.allocator);
                self.allocator.free(group_results);
            }
            try results.appendSlice(self.allocator, group_results);
            transferred = true;
        }

        const elapsed: u64 = @intCast(start.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds());
        try self.saveCache();
        self.printSummary(results.items, elapsed);
        return results.toOwnedSlice(self.allocator);
    }

    fn groupByDependencies(self: *TestRunner) ![][]TestSuite {
        var known = std.StringHashMap(void).init(self.allocator);
        defer known.deinit();
        for (self.suites) |suite| {
            const inserted = try known.getOrPut(suite.name);
            if (inserted.found_existing) return error.DuplicateSuite;
            inserted.value_ptr.* = {};
        }
        for (self.suites) |suite| {
            for (suite.dependencies) |dependency| {
                if (!known.contains(dependency)) return error.MissingDependency;
            }
        }

        var groups: std.ArrayList([]TestSuite) = .empty;
        errdefer {
            for (groups.items) |group| self.allocator.free(group);
            groups.deinit(self.allocator);
        }
        var remaining: std.ArrayList(TestSuite) = .empty;
        defer remaining.deinit(self.allocator);
        try remaining.appendSlice(self.allocator, self.suites);
        var completed = std.StringHashMap(void).init(self.allocator);
        defer completed.deinit();

        while (remaining.items.len > 0) {
            var current: std.ArrayList(TestSuite) = .empty;
            errdefer current.deinit(self.allocator);
            var index: usize = 0;
            while (index < remaining.items.len) {
                const suite = remaining.items[index];
                var runnable = true;
                for (suite.dependencies) |dependency| {
                    if (!completed.contains(dependency)) {
                        runnable = false;
                        break;
                    }
                }
                if (runnable) {
                    try current.append(self.allocator, suite);
                    _ = remaining.swapRemove(index);
                } else {
                    index += 1;
                }
            }
            if (current.items.len == 0) return error.CircularDependency;
            for (current.items) |suite| try completed.put(suite.name, {});
            const owned = try current.toOwnedSlice(self.allocator);
            current = .empty;
            errdefer self.allocator.free(owned);
            try groups.append(self.allocator, owned);
        }
        return groups.toOwnedSlice(self.allocator);
    }

    fn runGroup(self: *TestRunner, group: []const TestSuite) ![]TestResult {
        if (group.len == 0) return self.allocator.alloc(TestResult, 0);
        if (self.max_parallel == 0) return error.InvalidThreadCount;

        var results: std.ArrayList(TestResult) = .empty;
        errdefer {
            for (results.items) |*result| result.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        const sorted = try self.allocator.dupe(TestSuite, group);
        defer self.allocator.free(sorted);
        std.mem.sort(TestSuite, sorted, {}, struct {
            fn lessThan(_: void, lhs: TestSuite, rhs: TestSuite) bool {
                return lhs.estimated_time_ms > rhs.estimated_time_ms;
            }
        }.lessThan);

        const thread_count = @min(self.max_parallel, sorted.len);
        const threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);
        var context = WorkerContext{
            .runner = self,
            .work_queue = sorted,
            .results = &results,
        };

        var spawned: usize = 0;
        var joined = false;
        errdefer if (!joined) for (threads[0..spawned]) |thread| thread.join();
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{&context});
            spawned += 1;
        }
        for (threads) |thread| thread.join();
        joined = true;
        if (context.first_error) |err| return err;
        return results.toOwnedSlice(self.allocator);
    }

    fn workerThread(context: *WorkerContext) void {
        while (true) {
            context.runner.state_mutex.lockUncancelable(context.runner.io);
            if (context.first_error != null or context.next_index >= context.work_queue.len) {
                context.runner.state_mutex.unlock(context.runner.io);
                return;
            }
            const index = context.next_index;
            context.next_index += 1;
            context.runner.state_mutex.unlock(context.runner.io);

            var temporary = context.runner.runSuite(std.heap.smp_allocator, context.work_queue[index]) catch |err| {
                context.runner.recordWorkerError(context, err);
                return;
            };
            defer temporary.deinit(std.heap.smp_allocator);

            context.runner.state_mutex.lockUncancelable(context.runner.io);
            var owned = temporary.clone(context.runner.allocator) catch |err| {
                if (context.first_error == null) context.first_error = err;
                context.runner.state_mutex.unlock(context.runner.io);
                return;
            };
            context.results.append(context.runner.allocator, owned) catch |err| {
                owned.deinit(context.runner.allocator);
                if (context.first_error == null) context.first_error = err;
                context.runner.state_mutex.unlock(context.runner.io);
                return;
            };
            context.runner.state_mutex.unlock(context.runner.io);
        }
    }

    fn recordWorkerError(self: *TestRunner, context: *WorkerContext, err: anyerror) void {
        self.state_mutex.lockUncancelable(self.io);
        if (context.first_error == null) context.first_error = err;
        self.state_mutex.unlock(self.io);
    }

    fn runSuite(self: *TestRunner, work_allocator: std.mem.Allocator, suite: TestSuite) !TestResult {
        const cached_result: ?TestResult = cached: {
            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);
            const cache = if (self.cache) |*cache| cache else break :cached null;
            if (!try cache.isCached(suite)) break :cached null;
            const entry = cache.getCached(suite.name) orelse break :cached null;
            break :cached .{
                .suite_name = suite.name,
                .success = entry.success,
                .duration_ms = entry.duration_ms,
                .output = try work_allocator.dupe(u8, "[cached]"),
                .cached = true,
            };
        };
        if (cached_result) |result| return result;

        var result = try self.executor(self.executor_context, work_allocator, self.io, suite);
        errdefer result.deinit(work_allocator);
        result.suite_name = suite.name;
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.cache) |*cache| try cache.put(suite, result);
        return result;
    }

    fn executeZigTest(_: ?*anyopaque, allocator: std.mem.Allocator, io: Io, suite: TestSuite) !TestResult {
        const start = Io.Clock.awake.now(io);
        var process_result = try std.process.run(allocator, io, .{
            .argv = &.{ "zig", "test", suite.test_file },
            .stdout_limit = .limited(10 * 1024 * 1024),
            .stderr_limit = .limited(10 * 1024 * 1024),
        });
        var owns_stdout = true;
        var owns_stderr = true;
        errdefer {
            if (owns_stdout) allocator.free(process_result.stdout);
            if (owns_stderr) allocator.free(process_result.stderr);
        }

        const success = process_result.term.success();
        const error_message = if (!success and process_result.stderr.len > 0) message: {
            owns_stderr = false;
            break :message process_result.stderr;
        } else message: {
            allocator.free(process_result.stderr);
            owns_stderr = false;
            break :message null;
        };
        owns_stdout = false;
        return .{
            .suite_name = suite.name,
            .success = success,
            .duration_ms = @intCast(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds()),
            .output = process_result.stdout,
            .error_message = error_message,
        };
    }

    fn printSummary(self: *TestRunner, results: []const TestResult, elapsed_ms: u64) void {
        _ = self;
        var passed: usize = 0;
        var failed: usize = 0;
        var cached: usize = 0;
        for (results) |result| {
            if (result.success) passed += 1 else failed += 1;
            if (result.cached) cached += 1;
        }
        std.debug.print("\n================== Test Summary ==================\n", .{});
        std.debug.print("Total:   {d}\nPassed:  {d}\nFailed:  {d}\nCached:  {d}\nTime:    {d}ms\n", .{
            results.len,
            passed,
            failed,
            cached,
            elapsed_ms,
        });
        std.debug.print("==================================================\n", .{});
    }
};

pub const HOME_TEST_SUITES = [_]TestSuite{
    .{ .name = "lexer", .test_file = "packages/lexer/tests/lexer_test.zig", .estimated_time_ms = 500 },
    .{ .name = "ast", .test_file = "packages/ast/tests/ast_test.zig", .dependencies = &.{"lexer"}, .estimated_time_ms = 800 },
    .{ .name = "parser", .test_file = "packages/parser/tests/parser_test.zig", .dependencies = &.{ "lexer", "ast" }, .estimated_time_ms = 1500 },
    .{ .name = "diagnostics", .test_file = "packages/diagnostics/tests/diagnostics_test.zig", .dependencies = &.{"ast"}, .estimated_time_ms = 600 },
    .{ .name = "interpreter", .test_file = "packages/interpreter/tests/interpreter_test.zig", .dependencies = &.{ "ast", "parser" }, .estimated_time_ms = 2000 },
    .{ .name = "formatter", .test_file = "packages/formatter/tests/formatter_test.zig", .dependencies = &.{ "lexer", "parser", "ast" } },
    .{ .name = "codegen", .test_file = "packages/codegen/tests/codegen_test.zig", .dependencies = &.{"ast"}, .estimated_time_ms = 1800 },
    .{ .name = "queue", .test_file = "packages/queue/tests/queue_test.zig", .estimated_time_ms = 400 },
    .{ .name = "database", .test_file = "packages/database/tests/database_test.zig", .estimated_time_ms = 1200, .requires_libc = true, .system_libs = &.{"sqlite3"} },
    .{ .name = "package_manager", .test_file = "packages/pkg/tests/package_manager_test.zig", .estimated_time_ms = 1500 },
    .{ .name = "http_router", .test_file = "packages/basics/tests/http_router_test.zig", .estimated_time_ms = 900 },
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(TestCache);
    std.testing.refAllDecls(TestRunner);
}
