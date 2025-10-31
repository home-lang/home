// Home Programming Language - File Watcher
// Watches source files for changes and triggers incremental rebuilds

const std = @import("std");
const ir_cache = @import("ir_cache.zig");

/// File change event
pub const FileEvent = struct {
    path: []const u8,
    event_type: EventType,
    timestamp: i64,

    pub const EventType = enum {
        Created,
        Modified,
        Deleted,
        Renamed,
    };
};

/// File watcher for monitoring source file changes
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watched_files: std.StringHashMap(FileInfo),
    event_queue: std.ArrayList(FileEvent),
    mutex: std.Thread.Mutex,
    running: std.atomic.Value(bool),
    poll_interval_ms: u64,

    const FileInfo = struct {
        path: []const u8,
        last_mtime: i128,
        size: u64,
    };

    pub fn init(allocator: std.mem.Allocator, poll_interval_ms: u64) !FileWatcher {
        return .{
            .allocator = allocator,
            .watched_files = std.StringHashMap(FileInfo).init(allocator),
            .event_queue = std.ArrayList(FileEvent).init(allocator),
            .mutex = .{},
            .running = std.atomic.Value(bool).init(false),
            .poll_interval_ms = poll_interval_ms,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.stop();

        var it = self.watched_files.valueIterator();
        while (it.next()) |info| {
            self.allocator.free(info.path);
        }
        self.watched_files.deinit();

        for (self.event_queue.items) |event| {
            self.allocator.free(event.path);
        }
        self.event_queue.deinit();
    }

    /// Watch a file for changes
    pub fn watch(self: *FileWatcher, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get initial file info
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const path_copy = try self.allocator.dupe(u8, path);

        try self.watched_files.put(path_copy, .{
            .path = path_copy,
            .last_mtime = stat.mtime,
            .size = stat.size,
        });
    }

    /// Unwatch a file
    pub fn unwatch(self: *FileWatcher, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.watched_files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.value.path);
        }
    }

    /// Start watching files in background thread
    pub fn start(self: *FileWatcher) !std.Thread {
        self.running.store(true, .seq_cst);
        return try std.Thread.spawn(.{}, watcherThread, .{self});
    }

    /// Stop watching files
    pub fn stop(self: *FileWatcher) void {
        self.running.store(false, .seq_cst);
    }

    /// Check for file changes (polling-based)
    fn watcherThread(self: *FileWatcher) void {
        while (self.running.load(.seq_cst)) {
            self.checkForChanges() catch |err| {
                std.debug.print("File watcher error: {any}\n", .{err});
            };

            std.Thread.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Check all watched files for changes
    fn checkForChanges(self: *FileWatcher) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.watched_files.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;

            // Try to stat the file
            const file = std.fs.cwd().openFile(info.path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    // File was deleted
                    try self.queueEvent(.{
                        .path = try self.allocator.dupe(u8, info.path),
                        .event_type = .Deleted,
                        .timestamp = std.time.milliTimestamp(),
                    });
                }
                continue;
            };
            defer file.close();

            const stat = file.stat() catch continue;

            // Check if modified
            if (stat.mtime != info.last_mtime or stat.size != info.size) {
                try self.queueEvent(.{
                    .path = try self.allocator.dupe(u8, info.path),
                    .event_type = .Modified,
                    .timestamp = std.time.milliTimestamp(),
                });

                info.last_mtime = stat.mtime;
                info.size = stat.size;
            }
        }
    }

    fn queueEvent(self: *FileWatcher, event: FileEvent) !void {
        try self.event_queue.append(event);
    }

    /// Get pending file events
    pub fn pollEvents(self: *FileWatcher, allocator: std.mem.Allocator) ![]FileEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        const events = try allocator.dupe(FileEvent, self.event_queue.items);

        // Clear processed events
        for (self.event_queue.items) |event| {
            self.allocator.free(event.path);
        }
        self.event_queue.clearRetainingCapacity();

        return events;
    }

    /// Check if any files have pending changes
    pub fn hasPendingChanges(self: *FileWatcher) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.event_queue.items.len > 0;
    }
};

/// Smart invalidation system that tracks dependencies
pub const SmartInvalidator = struct {
    allocator: std.mem.Allocator,
    cache: *ir_cache.IRCache,
    dependency_graph: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator, cache: *ir_cache.IRCache) SmartInvalidator {
        return .{
            .allocator = allocator,
            .cache = cache,
            .dependency_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *SmartInvalidator) void {
        var it = self.dependency_graph.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit();
        }
        self.dependency_graph.deinit();
    }

    /// Record that module depends on other modules
    pub fn recordDependency(self: *SmartInvalidator, module: []const u8, depends_on: []const u8) !void {
        const result = try self.dependency_graph.getOrPut(module);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, module);
            result.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }

        try result.value_ptr.append(try self.allocator.dupe(u8, depends_on));
    }

    /// Invalidate a module and all modules that depend on it (transitive)
    pub fn invalidateModuleTransitively(
        self: *SmartInvalidator,
        module: []const u8,
        visited: *std.StringHashMap(void),
    ) !void {
        // Avoid infinite recursion with circular dependencies
        if (visited.contains(module)) return;
        try visited.put(try self.allocator.dupe(u8, module), {});

        // Find all modules that depend on this module
        var it = self.dependency_graph.iterator();
        while (it.next()) |entry| {
            const dependent = entry.key_ptr.*;
            const deps = entry.value_ptr;

            for (deps.items) |dep| {
                if (std.mem.eql(u8, dep, module)) {
                    // This module depends on the changed module
                    // Recursively invalidate it
                    try self.invalidateModuleTransitively(dependent, visited);
                    break;
                }
            }
        }

        // Invalidate this module in cache
        // Note: We need the cache key, which we don't have here
        // In practice, we'd store a module_name -> cache_key mapping
    }

    /// Handle file change events and invalidate affected modules
    pub fn handleFileEvents(self: *SmartInvalidator, events: []const FileEvent) !usize {
        var invalidated_count: usize = 0;
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        for (events) |event| {
            if (event.event_type == .Modified or event.event_type == .Deleted) {
                // Extract module name from path
                // This is simplified - in practice we'd have a proper path -> module mapping
                const module_name = std.fs.path.stem(event.path);

                try self.invalidateModuleTransitively(module_name, &visited);
                invalidated_count += 1;
            }
        }

        return invalidated_count;
    }
};

/// Incremental rebuild manager
pub const IncrementalBuilder = struct {
    allocator: std.mem.Allocator,
    watcher: FileWatcher,
    invalidator: SmartInvalidator,
    rebuild_callback: *const fn ([]const []const u8) anyerror!void,

    pub fn init(
        allocator: std.mem.Allocator,
        cache: *ir_cache.IRCache,
        rebuild_callback: *const fn ([]const []const u8) anyerror!void,
    ) !IncrementalBuilder {
        return .{
            .allocator = allocator,
            .watcher = try FileWatcher.init(allocator, 1000), // Poll every 1s
            .invalidator = SmartInvalidator.init(allocator, cache),
            .rebuild_callback = rebuild_callback,
        };
    }

    pub fn deinit(self: *IncrementalBuilder) void {
        self.watcher.deinit();
        self.invalidator.deinit();
    }

    /// Watch source files
    pub fn watchFiles(self: *IncrementalBuilder, files: []const []const u8) !void {
        for (files) |file| {
            try self.watcher.watch(file);
        }
    }

    /// Start incremental build mode
    pub fn start(self: *IncrementalBuilder) !std.Thread {
        return try self.watcher.start();
    }

    /// Stop incremental build mode
    pub fn stop(self: *IncrementalBuilder) void {
        self.watcher.stop();
    }

    /// Check for changes and trigger rebuilds if needed
    pub fn checkAndRebuild(self: *IncrementalBuilder) !bool {
        if (!self.watcher.hasPendingChanges()) {
            return false;
        }

        const events = try self.watcher.pollEvents(self.allocator);
        defer self.allocator.free(events);

        if (events.len == 0) {
            return false;
        }

        std.debug.print("Detected {d} file changes\n", .{events.len});

        const invalidated = try self.invalidator.handleFileEvents(events);
        std.debug.print("Invalidated {d} modules\n", .{invalidated});

        // Extract changed modules
        var changed_modules = std.ArrayList([]const u8).init(self.allocator);
        defer changed_modules.deinit();

        for (events) |event| {
            const module_name = std.fs.path.stem(event.path);
            try changed_modules.append(module_name);
        }

        // Trigger rebuild
        try self.rebuild_callback(changed_modules.items);

        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "file watcher creation" {
    const allocator = std.testing.allocator;

    var watcher = try FileWatcher.init(allocator, 100);
    defer watcher.deinit();

    try std.testing.expect(!watcher.running.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), watcher.watched_files.count());
}

test "smart invalidator dependency tracking" {
    const allocator = std.testing.allocator;

    var cache = try ir_cache.IRCache.init(allocator, ".test-cache");
    defer cache.deinit();

    var invalidator = SmartInvalidator.init(allocator, &cache);
    defer invalidator.deinit();

    // Record dependencies: main -> utils -> core
    try invalidator.recordDependency("main", "utils");
    try invalidator.recordDependency("utils", "core");

    try std.testing.expectEqual(@as(usize, 2), invalidator.dependency_graph.count());
}
