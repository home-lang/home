const std = @import("std");
const builtin = @import("builtin");

/// Test suite metadata for organizing and running tests
pub const TestSuite = struct {
    name: []const u8,
    test_file: []const u8,
    dependencies: []const []const u8 = &.{},
    /// Estimated execution time in milliseconds (for scheduling)
    estimated_time_ms: u64 = 1000,
    /// Whether this test requires system libraries
    requires_libc: bool = false,
    system_libs: []const []const u8 = &.{},

    pub fn hasNoDependencies(self: TestSuite) bool {
        return self.dependencies.len == 0;
    }

    pub fn dependsOn(self: TestSuite, suite_name: []const u8) bool {
        for (self.dependencies) |dep| {
            if (std.mem.eql(u8, dep, suite_name)) return true;
        }
        return false;
    }
};

/// Test result for a single test suite
pub const TestResult = struct {
    suite_name: []const u8,
    success: bool,
    duration_ms: u64,
    output: []const u8,
    error_message: ?[]const u8 = null,
    cached: bool = false,

    pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Cache entry for test results
const CacheEntry = struct {
    suite_name: []const u8,
    file_hash: [32]u8,
    success: bool,
    duration_ms: u64,
    timestamp: i64,
};

/// Test result cache for avoiding redundant test runs
pub const TestCache = struct {
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    entries: std.StringHashMap(CacheEntry),
    modified: bool = false,

    const CACHE_FILE = ".home/test_cache.json";

    pub fn init(allocator: std.mem.Allocator) !TestCache {
        const cache_path = try getCachePath(allocator);
        errdefer allocator.free(cache_path);

        var cache = TestCache{
            .allocator = allocator,
            .cache_path = cache_path,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
        };

        // Try to load existing cache
        cache.load() catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("Warning: Failed to load test cache: {any}\n", .{err});
            }
        };

        return cache;
    }

    pub fn deinit(self: *TestCache) void {
        // Free all entries
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.suite_name);
        }
        self.entries.deinit();
        self.allocator.free(self.cache_path);
    }

    /// Load cache from disk
    fn load(self: *TestCache) !void {
        const file = std.fs.openFileAbsolute(self.cache_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            content,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidCacheFile;

        var obj_iter = root.object.iterator();
        while (obj_iter.next()) |entry| {
            const suite_name = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(suite_name);

            const cache_obj = entry.value_ptr.*;
            if (cache_obj != .object) continue;

            const cache_entry = try self.parseCacheEntry(cache_obj.object, suite_name);
            try self.entries.put(suite_name, cache_entry);
        }
    }

    /// Save cache to disk
    pub fn save(self: *TestCache) !void {
        if (!self.modified) return;

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(self.cache_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dir_path);

        const file = try std.fs.createFileAbsolute(self.cache_path, .{
            .read = true,
            .truncate = true,
        });
        defer file.close();

        var buffered = std.io.bufferedWriter(file.writer());
        const writer = buffered.writer();

        try writer.writeAll("{\n");

        var first = true;
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            try writer.writeAll("  ");
            try std.json.encodeJsonString(entry.key_ptr.*, .{}, writer);
            try writer.writeAll(": {\n");

            try writer.writeAll("    \"suite_name\": ");
            try std.json.encodeJsonString(entry.value_ptr.suite_name, .{}, writer);
            try writer.writeAll(",\n");

            try writer.writeAll("    \"file_hash\": \"");
            for (entry.value_ptr.file_hash) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\n");

            try writer.print("    \"success\": {s},\n", .{if (entry.value_ptr.success) "true" else "false"});
            try writer.print("    \"duration_ms\": {d},\n", .{entry.value_ptr.duration_ms});
            try writer.print("    \"timestamp\": {d}\n", .{entry.value_ptr.timestamp});

            try writer.writeAll("  }");
        }

        try writer.writeAll("\n}\n");
        try buffered.flush();

        self.modified = false;
    }

    /// Check if test result is cached and valid
    pub fn isCached(self: *TestCache, suite: TestSuite) !bool {
        const entry = self.entries.get(suite.name) orelse return false;

        // Compute current file hash
        const current_hash = try self.computeFileHash(suite.test_file);

        // Compare hashes
        return std.mem.eql(u8, &entry.file_hash, &current_hash);
    }

    /// Get cached result
    pub fn getCached(self: *TestCache, suite_name: []const u8) ?CacheEntry {
        return self.entries.get(suite_name);
    }

    /// Store test result in cache
    pub fn put(self: *TestCache, suite: TestSuite, result: TestResult) !void {
        const file_hash = try self.computeFileHash(suite.test_file);

        const suite_name_copy = try self.allocator.dupe(u8, suite.name);
        errdefer self.allocator.free(suite_name_copy);

        const entry = CacheEntry{
            .suite_name = suite_name_copy,
            .file_hash = file_hash,
            .success = result.success,
            .duration_ms = result.duration_ms,
            .timestamp = std.time.timestamp(),
        };

        // Remove old entry if it exists
        if (self.entries.fetchRemove(suite.name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.suite_name);
        }

        const key = try self.allocator.dupe(u8, suite.name);
        try self.entries.put(key, entry);
        self.modified = true;
    }

    /// Compute SHA-256 hash of a file
    fn computeFileHash(self: *TestCache, file_path: []const u8) ![32]u8 {
        _ = self;
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try file.read(&buf);
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }

        return hasher.finalResult();
    }

    /// Parse cache entry from JSON
    fn parseCacheEntry(self: *TestCache, obj: std.json.ObjectMap, suite_name: []const u8) !CacheEntry {
        const hash_str = obj.get("file_hash") orelse return error.MissingField;
        const success = obj.get("success") orelse return error.MissingField;
        const duration = obj.get("duration_ms") orelse return error.MissingField;
        const timestamp = obj.get("timestamp") orelse return error.MissingField;

        var file_hash: [32]u8 = undefined;
        if (hash_str.string.len != 64) return error.InvalidHash;

        for (0..32) |i| {
            const hex = hash_str.string[i * 2 .. i * 2 + 2];
            file_hash[i] = try std.fmt.parseInt(u8, hex, 16);
        }

        return CacheEntry{
            .suite_name = try self.allocator.dupe(u8, suite_name),
            .file_hash = file_hash,
            .success = success.bool,
            .duration_ms = @intCast(duration.integer),
            .timestamp = timestamp.integer,
        };
    }

    fn getCachePath(allocator: std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);

        return std.fs.path.join(allocator, &.{ cwd, CACHE_FILE });
    }
};

/// Parallel test runner with caching and benchmarking
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    suites: []const TestSuite,
    cache: TestCache,
    max_parallel: usize,
    verbose: bool = false,
    benchmark: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        suites: []const TestSuite,
        max_parallel: ?usize,
    ) !TestRunner {
        const cache = try TestCache.init(allocator);

        return TestRunner{
            .allocator = allocator,
            .suites = suites,
            .cache = cache,
            .max_parallel = max_parallel orelse @max(1, try std.Thread.getCpuCount() - 1),
        };
    }

    pub fn deinit(self: *TestRunner) void {
        self.cache.save() catch |err| {
            std.debug.print("Warning: Failed to save test cache: {any}\n", .{err});
        };
        self.cache.deinit();
    }

    /// Run all tests with parallel execution and caching
    pub fn runAll(self: *TestRunner) ![]TestResult {
        var results = std.ArrayList(TestResult).init(self.allocator);
        errdefer {
            for (results.items) |*result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }

        // Group tests by dependencies
        const groups = try self.groupByDependencies();
        defer self.allocator.free(groups);

        const start_time = std.time.milliTimestamp();

        // Run each group (tests within a group can run in parallel)
        for (groups) |group| {
            const group_results = try self.runGroup(group);
            defer self.allocator.free(group_results);

            for (group_results) |result| {
                try results.append(result);
            }
        }

        const total_time = std.time.milliTimestamp() - start_time;

        // Print summary
        try self.printSummary(results.items, total_time);

        return results.toOwnedSlice();
    }

    /// Group tests by dependency levels (tests in same level can run in parallel)
    fn groupByDependencies(self: *TestRunner) ![][]TestSuite {
        var groups = std.ArrayList([]TestSuite).init(self.allocator);
        errdefer {
            for (groups.items) |group| {
                self.allocator.free(group);
            }
            groups.deinit();
        }

        var remaining = std.ArrayList(TestSuite).init(self.allocator);
        defer remaining.deinit();

        try remaining.appendSlice(self.suites);

        var completed = std.StringHashMap(void).init(self.allocator);
        defer completed.deinit();

        while (remaining.items.len > 0) {
            var current_group = std.ArrayList(TestSuite).init(self.allocator);

            var i: usize = 0;
            while (i < remaining.items.len) {
                const suite = remaining.items[i];

                // Check if all dependencies are completed
                var can_run = true;
                for (suite.dependencies) |dep| {
                    if (!completed.contains(dep)) {
                        can_run = false;
                        break;
                    }
                }

                if (can_run) {
                    try current_group.append(suite);
                    try completed.put(suite.name, {});
                    _ = remaining.swapRemove(i);
                } else {
                    i += 1;
                }
            }

            if (current_group.items.len == 0) {
                // Circular dependency or missing dependency
                std.debug.print("Error: Circular dependency detected or missing dependencies\n", .{});
                return error.CircularDependency;
            }

            try groups.append(try current_group.toOwnedSlice());
        }

        return groups.toOwnedSlice();
    }

    /// Run a group of independent tests in parallel
    fn runGroup(self: *TestRunner, group: []TestSuite) ![]TestResult {
        var results = std.ArrayList(TestResult).init(self.allocator);
        errdefer {
            for (results.items) |*result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }

        // Sort by estimated time (longest first) for better load balancing
        const sorted_group = try self.allocator.dupe(TestSuite, group);
        defer self.allocator.free(sorted_group);

        std.mem.sort(TestSuite, sorted_group, {}, struct {
            fn lessThan(_: void, a: TestSuite, b: TestSuite) bool {
                return a.estimated_time_ms > b.estimated_time_ms;
            }
        }.lessThan);

        // Run tests in parallel using thread pool
        const thread_count = @min(self.max_parallel, sorted_group.len);
        const threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        const work_queue = try self.allocator.alloc(TestSuite, sorted_group.len);
        defer self.allocator.free(work_queue);
        @memcpy(work_queue, sorted_group);

        var work_index = std.atomic.Value(usize).init(0);
        var result_mutex = std.Thread.Mutex{};

        const WorkerContext = struct {
            runner: *TestRunner,
            work_queue: []TestSuite,
            work_index: *std.atomic.Value(usize),
            results: *std.ArrayList(TestResult),
            result_mutex: *std.Thread.Mutex,
        };

        const worker_context = WorkerContext{
            .runner = self,
            .work_queue = work_queue,
            .work_index = &work_index,
            .results = &results,
            .result_mutex = &result_mutex,
        };

        // Spawn worker threads
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{worker_context});
        }

        // Wait for all threads to complete
        for (threads) |thread| {
            thread.join();
        }

        return results.toOwnedSlice();
    }

    /// Worker thread function
    fn workerThread(context: anytype) void {
        while (true) {
            const index = context.work_index.fetchAdd(1, .seq_cst);
            if (index >= context.work_queue.len) break;

            const suite = context.work_queue[index];
            const result = context.runner.runSuite(suite) catch |err| {
                std.debug.print("Error running test suite {s}: {any}\n", .{ suite.name, err });
                continue;
            };

            context.result_mutex.lock();
            context.results.append(result) catch |err| {
                std.debug.print("Error appending result: {any}\n", .{err});
            };
            context.result_mutex.unlock();
        }
    }

    /// Run a single test suite
    fn runSuite(self: *TestRunner, suite: TestSuite) !TestResult {
        // Check cache first
        if (try self.cache.isCached(suite)) {
            if (self.cache.getCached(suite.name)) |cached| {
                if (self.verbose) {
                    std.debug.print("✓ {s} (cached, {d}ms)\n", .{ suite.name, cached.duration_ms });
                }

                return TestResult{
                    .suite_name = suite.name,
                    .success = cached.success,
                    .duration_ms = cached.duration_ms,
                    .output = try self.allocator.dupe(u8, "[cached]"),
                    .cached = true,
                };
            }
        }

        const start_time = std.time.milliTimestamp();

        // Run the test
        var child = std.process.Child.init(&.{ "zig", "test", suite.test_file }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        errdefer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();
        const success = term == .Exited and term.Exited == 0;

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

        const result = TestResult{
            .suite_name = suite.name,
            .success = success,
            .duration_ms = duration,
            .output = stdout,
            .error_message = if (!success and stderr.len > 0)
                try self.allocator.dupe(u8, stderr)
            else
                null,
        };

        // Cache the result
        try self.cache.put(suite, result);

        if (self.verbose) {
            const status = if (success) "✓" else "✗";
            std.debug.print("{s} {s} ({d}ms)\n", .{ status, suite.name, duration });
        }

        return result;
    }

    /// Print test summary
    fn printSummary(self: *TestRunner, results: []TestResult, total_time: i64) !void {
        _ = self;

        var passed: usize = 0;
        var failed: usize = 0;
        var cached: usize = 0;

        for (results) |result| {
            if (result.success) {
                passed += 1;
            } else {
                failed += 1;
            }
            if (result.cached) {
                cached += 1;
            }
        }

        std.debug.print("\n", .{});
        std.debug.print("================== Test Summary ==================\n", .{});
        std.debug.print("Total:   {d}\n", .{results.len});
        std.debug.print("Passed:  {d}\n", .{passed});
        std.debug.print("Failed:  {d}\n", .{failed});
        std.debug.print("Cached:  {d}\n", .{cached});
        std.debug.print("Time:    {d}ms\n", .{total_time});
        std.debug.print("==================================================\n", .{});

        if (failed > 0) {
            std.debug.print("\nFailed tests:\n", .{});
            for (results) |result| {
                if (!result.success) {
                    std.debug.print("  ✗ {s}\n", .{result.suite_name});
                    if (result.error_message) |msg| {
                        std.debug.print("    {s}\n", .{msg});
                    }
                }
            }
        }
    }
};

/// Predefined test suites for Ion
pub const ION_TEST_SUITES = [_]TestSuite{
    .{
        .name = "lexer",
        .test_file = "packages/lexer/tests/lexer_test.zig",
        .estimated_time_ms = 500,
    },
    .{
        .name = "ast",
        .test_file = "packages/ast/tests/ast_test.zig",
        .dependencies = &.{"lexer"},
        .estimated_time_ms = 800,
    },
    .{
        .name = "parser",
        .test_file = "packages/parser/tests/parser_test.zig",
        .dependencies = &.{ "lexer", "ast" },
        .estimated_time_ms = 1500,
    },
    .{
        .name = "diagnostics",
        .test_file = "packages/diagnostics/tests/diagnostics_test.zig",
        .dependencies = &.{"ast"},
        .estimated_time_ms = 600,
    },
    .{
        .name = "interpreter",
        .test_file = "packages/interpreter/tests/interpreter_test.zig",
        .dependencies = &.{ "ast", "parser" },
        .estimated_time_ms = 2000,
    },
    .{
        .name = "formatter",
        .test_file = "packages/formatter/tests/formatter_test.zig",
        .dependencies = &.{ "lexer", "parser", "ast" },
        .estimated_time_ms = 1000,
    },
    .{
        .name = "codegen",
        .test_file = "packages/codegen/tests/codegen_test.zig",
        .dependencies = &.{"ast"},
        .estimated_time_ms = 1800,
    },
    .{
        .name = "queue",
        .test_file = "packages/queue/tests/queue_test.zig",
        .estimated_time_ms = 400,
    },
    .{
        .name = "database",
        .test_file = "packages/database/tests/database_test.zig",
        .estimated_time_ms = 1200,
        .requires_libc = true,
        .system_libs = &.{"sqlite3"},
    },
    .{
        .name = "package_manager",
        .test_file = "packages/pkg/tests/package_manager_test.zig",
        .estimated_time_ms = 1500,
    },
    .{
        .name = "http_router",
        .test_file = "packages/basics/tests/http_router_test.zig",
        .estimated_time_ms = 900,
    },
};
