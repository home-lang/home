// Home Programming Language - Incremental Build System Tests
// Comprehensive tests for IR caching and incremental compilation

const std = @import("std");
const parallel_build = @import("parallel_build.zig");
const ir_cache = @import("ir_cache.zig");
const file_watcher = @import("file_watcher.zig");

/// Test incremental build with cache hits
test "incremental build cache hits" {
    const allocator = std.testing.allocator;

    // Create test directory
    const test_dir = "test-build-cache";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test source files
    try createTestFile(test_dir, "main.home", "fn main() { print(\"Hello\"); }");
    try createTestFile(test_dir, "utils.home", "fn helper() { return 42; }");

    // First build - all cache misses
    {
        var builder = try parallel_build.ParallelBuilder.init(
            allocator,
            2, // 2 threads
            test_dir,
            "0.1.0-test",
        );
        defer builder.deinit();

        builder.verbose = true;
        builder.setAggressiveMode(true);

        try builder.addTask("main", "test-build-cache/main.home", &[_][]const u8{"utils"});
        try builder.addTask("utils", "test-build-cache/utils.home", &[_][]const u8{});

        try builder.build();

        const stats = builder.getCacheStats();
        try std.testing.expectEqual(@as(usize, 0), stats.hits); // First build - no cache hits
        try std.testing.expectEqual(@as(usize, 2), stats.entry_count);
    }

    // Second build - should have cache hits
    {
        var builder = try parallel_build.ParallelBuilder.init(
            allocator,
            2,
            test_dir,
            "0.1.0-test",
        );
        defer builder.deinit();

        builder.verbose = true;

        try builder.addTask("main", "test-build-cache/main.home", &[_][]const u8{"utils"});
        try builder.addTask("utils", "test-build-cache/utils.home", &[_][]const u8{});

        try builder.build();

        const stats = builder.getCacheStats();
        try std.testing.expect(stats.hits > 0); // Should have cache hits
        std.debug.print("Cache hits: {d}/{d}\n", .{ stats.hits, stats.hits + stats.misses });
    }
}

/// Test cache invalidation on file modification
test "cache invalidation on modification" {
    const allocator = std.testing.allocator;

    const test_dir = "test-invalidation";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    try createTestFile(test_dir, "module.home", "fn version() { return 1; }");

    // First build
    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        1,
        test_dir,
        "0.1.0-test",
    );
    defer builder.deinit();

    try builder.addTask("module", "test-invalidation/module.home", &[_][]const u8{});
    try builder.build();

    var stats = builder.getCacheStats();
    const initial_misses = stats.misses;

    // Modify file
    std.Thread.sleep(10 * std.time.ns_per_ms); // Ensure mtime changes
    try createTestFile(test_dir, "module.home", "fn version() { return 2; }");

    // Rebuild - should invalidate cache
    var builder2 = try parallel_build.ParallelBuilder.init(
        allocator,
        1,
        test_dir,
        "0.1.0-test",
    );
    defer builder2.deinit();

    try builder2.addTask("module", "test-invalidation/module.home", &[_][]const u8{});
    try builder2.build();

    stats = builder2.getCacheStats();
    // Should have more misses due to invalidation
    try std.testing.expect(stats.misses > initial_misses);
}

/// Test parallel compilation with caching
test "parallel compilation with cache" {
    const allocator = std.testing.allocator;

    const test_dir = "test-parallel-cache";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create multiple test files
    const modules = [_][]const u8{
        "core", "utils", "helpers", "data", "io",
        "parser", "lexer", "ast", "codegen", "optimizer",
    };

    for (modules) |module| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}.home", .{module});
        try createTestFile(test_dir, path, "fn init() { }");
    }

    // Build with multiple threads
    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        4, // 4 threads
        test_dir,
        "0.1.0-test",
    );
    defer builder.deinit();

    builder.benchmark = true;
    builder.setAggressiveMode(true);

    for (modules) |module| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.home", .{ test_dir, module });
        try builder.addTask(module, path, &[_][]const u8{});
    }

    try builder.build();

    const build_stats = builder.stats;
    try std.testing.expectEqual(@as(usize, modules.len), build_stats.completed_tasks);
    try std.testing.expect(build_stats.parallel_speedup > 1.0);

    builder.printCacheStats();
}

/// Test file watcher
test "file watcher detects changes" {
    const allocator = std.testing.allocator;

    const test_dir = "test-watcher";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    try createTestFile(test_dir, "watched.home", "// original");

    var watcher = try file_watcher.FileWatcher.init(allocator, 50); // 50ms poll
    defer watcher.deinit();

    try watcher.watch("test-watcher/watched.home");

    // Start watching
    const thread = try watcher.start();
    defer {
        watcher.stop();
        thread.join();
    }

    // Wait and modify file
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try createTestFile(test_dir, "watched.home", "// modified");
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Check for events
    const events = try watcher.pollEvents(allocator);
    defer allocator.free(events);

    try std.testing.expect(events.len > 0);
    if (events.len > 0) {
        try std.testing.expectEqual(file_watcher.FileEvent.EventType.Modified, events[0].event_type);
    }
}

/// Test smart invalidation with dependencies
test "smart dependency invalidation" {
    const allocator = std.testing.allocator;

    var cache = try ir_cache.IRCache.init(allocator, ".test-smart-cache");
    defer cache.deinit();
    defer std.fs.cwd().deleteTree(".test-smart-cache") catch {};

    var invalidator = file_watcher.SmartInvalidator.init(allocator, &cache);
    defer invalidator.deinit();

    // Build dependency graph: app -> lib -> core
    try invalidator.recordDependency("app", "lib");
    try invalidator.recordDependency("lib", "core");

    // Simulate file change to core
    const events = [_]file_watcher.FileEvent{.{
        .path = "core.home",
        .event_type = .Modified,
        .timestamp = std.time.milliTimestamp(),
    }};

    const invalidated = try invalidator.handleFileEvents(&events);
    try std.testing.expect(invalidated > 0);
}

/// Test cache statistics accuracy
test "cache statistics" {
    const allocator = std.testing.allocator;

    const test_dir = "test-stats";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    try createTestFile(test_dir, "test.home", "fn test() { }");

    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        1,
        test_dir,
        "0.1.0-test",
    );
    defer builder.deinit();

    try builder.addTask("test", "test-stats/test.home", &[_][]const u8{});

    // First build
    try builder.build();
    var stats = builder.getCacheStats();
    const first_misses = stats.misses;
    try std.testing.expectEqual(@as(usize, 0), stats.hits);

    // Second build (cache hit)
    var builder2 = try parallel_build.ParallelBuilder.init(
        allocator,
        1,
        test_dir,
        "0.1.0-test",
    );
    defer builder2.deinit();

    try builder2.addTask("test", "test-stats/test.home", &[_][]const u8{});
    try builder2.build();

    stats = builder2.getCacheStats();
    try std.testing.expect(stats.hits > 0);
    try std.testing.expectEqual(first_misses, stats.misses);
}

/// Test cache eviction under size pressure
test "cache eviction" {
    const allocator = std.testing.allocator;

    var cache = try ir_cache.IRCache.init(allocator, ".test-eviction");
    defer cache.deinit();
    defer std.fs.cwd().deleteTree(".test-eviction") catch {};

    cache.max_cache_size_mb = 1; // Very small cache to force evictions

    // Add many entries to trigger eviction
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "module{d}", .{i});

        const key = ir_cache.generateCacheKey(
            "dummy source content that is fairly long to consume cache space",
            &[_]ir_cache.CacheHash{},
            "0.1.0",
            "",
        );

        try cache.put(
            key,
            name,
            "/dev/null",
            0,
            &[_]ir_cache.CacheHash{},
            "/dev/null",
            "/dev/null",
            100,
        );
    }

    const stats = cache.stats;
    try std.testing.expect(stats.evictions > 0);
    std.debug.print("Evictions triggered: {d}\n", .{stats.evictions});
}

// ============================================================================
// Helper Functions
// ============================================================================

fn createTestFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(content);
}

// ============================================================================
// Example Usage
// ============================================================================

/// Example: Basic incremental build
pub fn exampleBasicBuild() !void {
    const allocator = std.heap.page_allocator;

    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        null, // Auto-detect thread count
        ".home-cache",
        "0.1.0",
    );
    defer builder.deinit();

    builder.verbose = true;
    builder.setAggressiveMode(true);

    // Add modules
    try builder.addTask("main", "src/main.home", &[_][]const u8{ "utils", "core" });
    try builder.addTask("utils", "src/utils.home", &[_][]const u8{"core"});
    try builder.addTask("core", "src/core.home", &[_][]const u8{});

    // Build
    try builder.build();

    // Print statistics
    builder.printCacheStats();
}

/// Example: Watch mode with automatic rebuilds
pub fn exampleWatchMode() !void {
    const allocator = std.heap.page_allocator;

    var cache = try ir_cache.IRCache.init(allocator, ".home-cache");
    defer cache.deinit();

    // Dummy rebuild callback
    const rebuildCallback = struct {
        fn rebuild(modules: []const []const u8) !void {
            std.debug.print("Rebuilding {d} modules...\n", .{modules.len});
            for (modules) |module| {
                std.debug.print("  - {s}\n", .{module});
            }
        }
    }.rebuild;

    var incremental = try file_watcher.IncrementalBuilder.init(
        allocator,
        &cache,
        rebuildCallback,
    );
    defer incremental.deinit();

    // Watch source files
    try incremental.watchFiles(&[_][]const u8{
        "src/main.home",
        "src/utils.home",
        "src/core.home",
    });

    // Record dependencies
    try incremental.invalidator.recordDependency("main", "utils");
    try incremental.invalidator.recordDependency("main", "core");
    try incremental.invalidator.recordDependency("utils", "core");

    // Start watching
    const thread = try incremental.start();
    defer {
        incremental.stop();
        thread.join();
    }

    // Run for a while
    std.debug.print("Watching for changes (Ctrl+C to exit)...\n", .{});
    var i: usize = 0;
    while (i < 60) : (i += 1) { // Run for 60 seconds
        std.Thread.sleep(1 * std.time.ns_per_s);
        _ = try incremental.checkAndRebuild();
    }
}
