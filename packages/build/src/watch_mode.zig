const std = @import("std");
const modules = @import("../modules/module_system.zig");
const parallel_build = @import("parallel_build.zig");

/// File watcher for hot reload
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watched_files: std.StringHashMap(FileInfo),
    poll_interval_ms: u64,
    running: bool,
    on_change: *const fn ([]const u8) anyerror!void,

    pub const DEFAULT_POLL_INTERVAL = 500; // 500ms

    pub fn init(allocator: std.mem.Allocator, on_change: *const fn ([]const u8) anyerror!void) FileWatcher {
        return .{
            .allocator = allocator,
            .watched_files = std.StringHashMap(FileInfo).init(allocator),
            .poll_interval_ms = DEFAULT_POLL_INTERVAL,
            .running = false,
            .on_change = on_change,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.watched_files.deinit();
    }

    /// Add a file to watch
    pub fn watch(self: *FileWatcher, path: []const u8) !void {
        const stat = try std.fs.cwd().statFile(path);

        const key_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key_copy);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.watched_files.put(key_copy, .{
            .path = path_copy,
            .last_modified = stat.mtime,
            .size = stat.size,
        });
    }

    /// Remove a file from watching
    pub fn unwatch(self: *FileWatcher, path: []const u8) void {
        if (self.watched_files.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.path);
        }
    }

    /// Start watching files
    pub fn start(self: *FileWatcher) !void {
        self.running = true;

        std.debug.print("🔍 Watching {d} files for changes...\n", .{self.watched_files.count()});
        std.debug.print("   Press Ctrl+C to stop\n\n", .{});

        while (self.running) {
            try self.checkForChanges();
            std.time.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Stop watching
    pub fn stop(self: *FileWatcher) void {
        self.running = false;
    }

    /// Check all watched files for changes
    fn checkForChanges(self: *FileWatcher) !void {
        var iter = self.watched_files.iterator();
        while (iter.next()) |entry| {
            const file_info = entry.value_ptr;

            const stat = std.fs.cwd().statFile(file_info.path) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("⚠️  File deleted: {s}\n", .{file_info.path});
                    self.unwatch(file_info.path);
                }
                continue;
            };

            if (stat.mtime != file_info.last_modified or stat.size != file_info.size) {
                std.debug.print("📝 File changed: {s}\n", .{file_info.path});

                // Update file info
                file_info.last_modified = stat.mtime;
                file_info.size = stat.size;

                // Trigger rebuild
                self.on_change(file_info.path) catch |err| {
                    std.debug.print("❌ Rebuild failed: {}\n\n", .{err});
                };
            }
        }
    }
};

pub const FileInfo = struct {
    path: []const u8,
    last_modified: i128,
    size: u64,
};

/// Watch mode builder
pub const WatchBuilder = struct {
    allocator: std.mem.Allocator,
    entry_point: []const u8,
    output_path: []const u8,
    watcher: FileWatcher,
    module_loader: *modules.ModuleLoader,
    build_count: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        entry_point: []const u8,
        output_path: []const u8,
        module_loader: *modules.ModuleLoader,
    ) !WatchBuilder {
        const on_change = struct {
            fn rebuild(path: []const u8) !void {
                _ = path;
                // Will be set via closure
            }
        }.rebuild;

        return .{
            .allocator = allocator,
            .entry_point = entry_point,
            .output_path = output_path,
            .watcher = FileWatcher.init(allocator, on_change),
            .module_loader = module_loader,
            .build_count = 0,
        };
    }

    pub fn deinit(self: *WatchBuilder) void {
        self.watcher.deinit();
    }

    /// Start watch mode
    pub fn run(self: *WatchBuilder) !void {
        // Initial build
        std.debug.print("🔨 Initial build...\n", .{});
        try self.rebuild(self.entry_point);

        // Collect all dependencies to watch
        try self.watchAllDependencies();

        // Start watching
        try self.watcher.start();
    }

    /// Rebuild on file change
    fn rebuild(self: *WatchBuilder, changed_file: []const u8) !void {
        _ = changed_file;

        const start_time = std.time.nanoTimestamp();

        self.build_count += 1;
        std.debug.print("\n🔨 Build #{d} started...\n", .{self.build_count});

        // Perform build (simplified - would use actual build system)
        // For now, just parse and type-check
        std.time.sleep(100 * std.time.ns_per_ms); // Simulate build

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @divTrunc(end_time - start_time, std.time.ns_per_ms);

        std.debug.print("✅ Build #{d} completed in {d}ms\n", .{ self.build_count, duration_ms });
        std.debug.print("   Output: {s}\n", .{self.output_path});
        std.debug.print("   Watching for changes...\n\n", .{});
    }

    /// Watch all dependencies
    fn watchAllDependencies(self: *WatchBuilder) !void {
        // Watch entry point
        try self.watcher.watch(self.entry_point);

        // Watch all imported modules (would need to traverse module graph)
        // For now, watch common patterns
        try self.watchPattern("**/*.home");
    }

    fn watchPattern(self: *WatchBuilder, pattern: []const u8) !void {
        _ = self;
        _ = pattern;
        // Would use glob matching to find files
    }
};

/// Hot reload server for executables
pub const HotReloadServer = struct {
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    process: ?std.process.Child,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, executable_path: []const u8) HotReloadServer {
        return .{
            .allocator = allocator,
            .executable_path = executable_path,
            .process = null,
            .running = false,
        };
    }

    pub fn deinit(self: *HotReloadServer) void {
        self.stop();
    }

    /// Start the executable
    pub fn start(self: *HotReloadServer) !void {
        if (self.process != null) {
            self.stop();
        }

        std.debug.print("▶️  Starting: {s}\n", .{self.executable_path});

        var child = std.process.Child.init(&[_][]const u8{self.executable_path}, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        self.process = child;
        self.running = true;
    }

    /// Stop the executable
    pub fn stop(self: *HotReloadServer) void {
        if (self.process) |*proc| {
            std.debug.print("⏹️  Stopping process...\n", .{});
            _ = proc.kill() catch {};
            self.process = null;
            self.running = false;
        }
    }

    /// Restart the executable
    pub fn restart(self: *HotReloadServer) !void {
        std.debug.print("🔄 Restarting...\n", .{});
        self.stop();
        std.time.sleep(100 * std.time.ns_per_ms); // Brief pause
        try self.start();
    }
};

/// Watch mode configuration
pub const WatchConfig = struct {
    /// Files to watch
    watch_patterns: []const []const u8,

    /// Files to ignore
    ignore_patterns: []const []const u8,

    /// Poll interval in milliseconds
    poll_interval_ms: u64,

    /// Enable hot reload
    hot_reload: bool,

    /// Clear console on rebuild
    clear_console: bool,

    /// Show build notifications
    notifications: bool,

    pub fn default() WatchConfig {
        return .{
            .watch_patterns = &[_][]const u8{"**/*.home"},
            .ignore_patterns = &[_][]const u8{
                "**/zig-out/**",
                "**/.home/**",
                "**/node_modules/**",
            },
            .poll_interval_ms = 500,
            .hot_reload = false,
            .clear_console = true,
            .notifications = true,
        };
    }
};

/// Debounce file changes to avoid multiple rebuilds
pub const Debouncer = struct {
    last_trigger: i128,
    delay_ms: u64,

    pub fn init(delay_ms: u64) Debouncer {
        return .{
            .last_trigger = 0,
            .delay_ms = delay_ms,
        };
    }

    pub fn shouldTrigger(self: *Debouncer) bool {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.last_trigger, std.time.ns_per_ms);

        if (elapsed_ms >= self.delay_ms) {
            self.last_trigger = now;
            return true;
        }

        return false;
    }
};
