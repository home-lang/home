const std = @import("std");
const testing = std.testing;
const cache_pkg = @import("cache");
const incremental_cache = @import("incremental_cache");
const dependency_tracker = @import("dependency_tracker");
const ir_cache = @import("ir_cache");
const ast = @import("ast");

// Cache system tests
// Tests for IR caching and build caching

test "cache - basic compilation" {
    testing.refAllDecls(cache_pkg);
    testing.refAllDecls(incremental_cache);
    testing.refAllDecls(dependency_tracker);
    testing.refAllDecls(dependency_tracker.DependencyTracker);
    testing.refAllDecls(cache_pkg.Cache);
    testing.refAllDecls(cache_pkg.MemoryCacheDriver);
    testing.refAllDecls(cache_pkg.FilesystemCacheDriver);
    testing.refAllDecls(cache_pkg.RedisCacheDriver);
}

fn freeOwnedNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn nameIndex(names: []const []const u8, expected: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, expected)) return index;
    }
    return null;
}

test "dependency tracker owns edges orders dependencies and propagates invalidation" {
    const allocator = testing.allocator;
    var tracker = dependency_tracker.DependencyTracker.init(allocator);
    defer tracker.deinit();

    var app = [_]u8{ 'a', 'p', 'p' };
    var library = [_]u8{ 'l', 'i', 'b' };
    var core = [_]u8{ 'c', 'o', 'r', 'e' };
    try tracker.addDependency(&app, &library);
    try tracker.addDependency(&library, &core);
    try tracker.addDependency(&app, &library);
    @memset(&app, 'x');
    @memset(&library, 'y');
    @memset(&core, 'z');

    try testing.expectEqual(@as(usize, 1), tracker.getDependencies("app").len);
    try testing.expectEqualStrings("lib", tracker.getDependencies("app")[0]);
    try testing.expectEqualStrings("app", tracker.getDependents("lib")[0]);
    try testing.expectEqual(@as(usize, 3), tracker.getStats().total_modules);
    try testing.expectEqual(@as(usize, 2), tracker.getStats().total_dependencies);

    const order = try tracker.getCompilationOrder();
    defer freeOwnedNames(allocator, order);
    try testing.expect(nameIndex(order, "core").? < nameIndex(order, "lib").?);
    try testing.expect(nameIndex(order, "lib").? < nameIndex(order, "app").?);

    try tracker.invalidate("core");
    try testing.expect(tracker.isInvalidated("core"));
    try testing.expect(tracker.isInvalidated("lib"));
    try testing.expect(tracker.isInvalidated("app"));
    try testing.expectEqual(@as(usize, 3), tracker.getStats().invalidated_modules);
    tracker.clearInvalidations();
    try testing.expectEqual(@as(usize, 0), tracker.getStats().invalidated_modules);
}

test "dependency tracker extracts segmented imports and reports the exact cycle" {
    const allocator = testing.allocator;
    var tracker = dependency_tracker.DependencyTracker.init(allocator);
    defer tracker.deinit();

    var import_path = [_][]const u8{ "standard", "io" };
    var import_decl = ast.ImportDecl{
        .node = .{ .type = .ImportDecl, .loc = .{ .line = 1, .column = 1 } },
        .path = &import_path,
        .imports = null,
    };
    var statements = [_]ast.Stmt{.{ .ImportDecl = &import_decl }};
    var program = ast.Program{ .statements = &statements };
    try tracker.extractFromAST("entry", &program);
    try testing.expectEqualStrings("standard/io", tracker.getDependencies("entry")[0]);

    try tracker.addDependency("standard/io", "codec");
    try tracker.addDependency("codec", "standard/io");
    const cycle = (try tracker.detectCycles()).?;
    defer freeOwnedNames(allocator, cycle);
    try testing.expectEqual(@as(usize, 3), cycle.len);
    try testing.expectEqualStrings("standard/io", cycle[0]);
    try testing.expectEqualStrings("codec", cycle[1]);
    try testing.expectEqualStrings("standard/io", cycle[2]);
}

fn exerciseDependencyTrackerAllocationFailures(allocator: std.mem.Allocator) !void {
    var tracker = dependency_tracker.DependencyTracker.init(allocator);
    defer tracker.deinit();

    try tracker.addDependency("app", "library");
    try tracker.addDependency("library", "core");
    const order = try tracker.getCompilationOrder();
    defer freeOwnedNames(allocator, order);
    try tracker.invalidate("core");
    try testing.expect((try tracker.detectCycles()) == null);

    try tracker.addDependency("core", "app");
    const cycle = (try tracker.detectCycles()).?;
    defer freeOwnedNames(allocator, cycle);
}

test "dependency tracker preserves ownership across every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        exerciseDependencyTrackerAllocationFailures,
        .{},
    );
}

test "incremental source cache owns registrations and metadata" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, "source-cache" });
    defer allocator.free(cache_dir);
    const source_path = try std.fs.path.join(allocator, &.{ root, "entry.home" });
    defer allocator.free(source_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ root, "entry.ir" });
    defer allocator.free(artifact_path);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = source_path, .data = "return 1" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = artifact_path, .data = "owned-ir" });

    var compiler = try incremental_cache.IncrementalCompiler.init(allocator, cache_dir, testing.io);
    defer compiler.deinit();
    try compiler.registerModule(source_path, &.{}, .{ .ir_path = artifact_path });
    try testing.expect(!try compiler.needsRecompilation(source_path));

    try compiler.saveMetadata(source_path, "type-metadata");
    const metadata = (try compiler.loadMetadata(source_path)).?;
    defer allocator.free(metadata);
    try testing.expectEqualStrings("type-metadata", metadata);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = source_path, .data = "return 2" });
    try testing.expect(try compiler.needsRecompilation(source_path));
    try compiler.registerModule(source_path, &.{}, .{ .ir_path = artifact_path });
    try testing.expect(!try compiler.needsRecompilation(source_path));
    try testing.expectEqual(@as(usize, 1), compiler.getStats().cached_modules);

    try compiler.cleanCache(0);
    try testing.expect(compiler.getCachedArtifacts(source_path) == null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, artifact_path, .{}));
}

test "incremental source cache invalidates transitive dependents" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, "source-cache" });
    defer allocator.free(cache_dir);
    const dependency_path = try std.fs.path.join(allocator, &.{ root, "dependency.home" });
    defer allocator.free(dependency_path);
    const dependent_path = try std.fs.path.join(allocator, &.{ root, "dependent.home" });
    defer allocator.free(dependent_path);
    const dependency_ir = try std.fs.path.join(allocator, &.{ root, "dependency.ir" });
    defer allocator.free(dependency_ir);
    const dependent_ir = try std.fs.path.join(allocator, &.{ root, "dependent.ir" });
    defer allocator.free(dependent_ir);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dependency_path, .data = "dependency" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dependent_path, .data = "dependent" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dependency_ir, .data = "dependency-ir" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dependent_ir, .data = "dependent-ir" });

    var compiler = try incremental_cache.IncrementalCompiler.init(allocator, cache_dir, testing.io);
    defer compiler.deinit();
    try compiler.registerModule(dependency_path, &.{}, .{ .ir_path = dependency_ir });
    try compiler.registerModule(dependent_path, &.{dependency_path}, .{ .ir_path = dependent_ir });
    try testing.expect(!try compiler.needsRecompilation(dependent_path));

    try compiler.invalidate(dependency_path);
    try testing.expect(compiler.getCachedArtifacts(dependency_path) == null);
    try testing.expect(compiler.getCachedArtifacts(dependent_path) == null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dependency_ir, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dependent_ir, .{}));
}

test "cache - shipped memory driver" {
    var instance = try cache_pkg.Cache.init(testing.allocator, cache_pkg.CacheConfig.memory(testing.io));
    defer instance.deinit();

    try instance.set("key", "value", null);
    try testing.expectEqualStrings("value", instance.get("key").?);
    try testing.expect(instance.has("key"));
    try testing.expect(instance.del("key"));
    try testing.expect(!instance.has("key"));
}

test "incremental cache stores and validates a complete artifact" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_dir);
    const source_path = try std.fs.path.join(allocator, &.{ root, "entry.home" });
    defer allocator.free(source_path);
    const source = "fn main() -> i32 { return 7 }";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = source_path, .data = source });

    var compiler = try ir_cache.IncrementalCompiler.init(allocator, cache_dir, false, testing.io);
    defer compiler.deinit();

    const artifact = "complete-native-executable";
    try compiler.storeCompilation(source_path, source, artifact, &.{});
    try testing.expect(try compiler.canUseCached(source_path, source));

    const restored = (try compiler.getCachedObject(source_path)).?;
    defer allocator.free(restored);
    try testing.expectEqualSlices(u8, artifact, restored);
    try testing.expect(!try compiler.canUseCached(source_path, "changed source"));
}

test "incremental cache rejects an empty artifact" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_dir);

    var compiler = try ir_cache.IncrementalCompiler.init(allocator, cache_dir, false, testing.io);
    defer compiler.deinit();
    try testing.expectError(
        error.EmptyObjectArtifact,
        compiler.storeCompilation("entry.home", "source", &.{}, &.{}),
    );
}

test "cache - cache entry structure" {
    const CacheEntry = struct {
        key: []const u8,
        value: []const u8,
        timestamp: i64,

        pub fn isExpired(self: @This(), current_time: i64, ttl: i64) bool {
            return (current_time - self.timestamp) > ttl;
        }
    };

    const entry = CacheEntry{
        .key = "test",
        .value = "data",
        .timestamp = 1000,
    };

    try testing.expect(!entry.isExpired(1500, 1000)); // Not expired
    try testing.expect(entry.isExpired(3000, 1000)); // Expired
}

test "cache - simple hash map cache" {
    const allocator = testing.allocator;

    var cache = std.StringHashMap([]const u8).init(allocator);
    defer cache.deinit();

    try cache.put("key1", "value1");
    try cache.put("key2", "value2");

    try testing.expectEqualStrings("value1", cache.get("key1").?);
    try testing.expectEqualStrings("value2", cache.get("key2").?);
    try testing.expect(cache.get("key3") == null);
}

test "cache - LRU eviction simulation" {
    const LRUEntry = struct {
        key: []const u8,
        value: i32,
        access_count: usize,

        pub fn touch(self: *@This()) void {
            self.access_count += 1;
        }
    };

    const entry1 = LRUEntry{ .key = "a", .value = 1, .access_count = 5 };
    var entry2 = LRUEntry{ .key = "b", .value = 2, .access_count = 2 };

    entry2.touch();

    // entry1 has higher access count, so it should be kept
    try testing.expect(entry1.access_count > entry2.access_count);
}

test "cache - cache invalidation" {
    const allocator = testing.allocator;

    const CacheState = struct {
        valid: std.StringHashMap(bool),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .valid = std.StringHashMap(bool).init(alloc) };
        }

        pub fn deinit(self: *@This()) void {
            self.valid.deinit();
        }

        pub fn mark(self: *@This(), key: []const u8) !void {
            try self.valid.put(key, true);
        }

        pub fn invalidate(self: *@This(), key: []const u8) !void {
            try self.valid.put(key, false);
        }

        pub fn isValid(self: @This(), key: []const u8) bool {
            return self.valid.get(key) orelse false;
        }
    };

    var state = CacheState.init(allocator);
    defer state.deinit();

    try state.mark("file1");
    try testing.expect(state.isValid("file1"));

    try state.invalidate("file1");
    try testing.expect(!state.isValid("file1"));
}

test "cache - content hash for cache keys" {
    const hashContent = struct {
        fn hash(content: []const u8) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(content);
            return hasher.final();
        }
    }.hash;

    const hash1 = hashContent("hello");
    const hash2 = hashContent("hello");
    const hash3 = hashContent("world");

    try testing.expect(hash1 == hash2);
    try testing.expect(hash1 != hash3);
}

test "cache - cache hit rate tracking" {
    const CacheStats = struct {
        hits: usize,
        misses: usize,

        pub fn init() @This() {
            return .{ .hits = 0, .misses = 0 };
        }

        pub fn recordHit(self: *@This()) void {
            self.hits += 1;
        }

        pub fn recordMiss(self: *@This()) void {
            self.misses += 1;
        }

        pub fn hitRate(self: @This()) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };

    var stats = CacheStats.init();
    stats.recordHit();
    stats.recordHit();
    stats.recordMiss();

    const rate = stats.hitRate();
    try testing.expect(rate > 0.66 and rate < 0.67);
}

test "cache - size-based eviction" {
    const CacheWithSize = struct {
        max_size: usize,
        current_size: usize,

        pub fn init(max: usize) @This() {
            return .{ .max_size = max, .current_size = 0 };
        }

        pub fn canFit(self: @This(), size: usize) bool {
            return self.current_size + size <= self.max_size;
        }

        pub fn add(self: *@This(), size: usize) !void {
            if (!self.canFit(size)) {
                return error.CacheFull;
            }
            self.current_size += size;
        }

        pub fn remove(self: *@This(), size: usize) void {
            self.current_size -= size;
        }
    };

    var cache = CacheWithSize.init(100);

    try cache.add(50);
    try testing.expect(cache.canFit(50));
    try testing.expect(!cache.canFit(51));

    try testing.expectError(error.CacheFull, cache.add(51));

    cache.remove(25);
    try testing.expect(cache.canFit(25));
}

test "cache - timestamp-based expiration" {
    const TimestampedEntry = struct {
        created_at: i64,
        ttl_seconds: i64,

        pub fn isExpired(self: @This(), now: i64) bool {
            return (now - self.created_at) >= self.ttl_seconds;
        }
    };

    const entry = TimestampedEntry{
        .created_at = 1000,
        .ttl_seconds = 60,
    };

    try testing.expect(!entry.isExpired(1030)); // 30 seconds old
    try testing.expect(entry.isExpired(1070)); // 70 seconds old
}
