const std = @import("std");
const Io = std.Io;

/// Beautiful progress bar UI (Bun-inspired)
pub const ProgressBar = struct {
    allocator: std.mem.Allocator,
    io: Io,
    name: []const u8,
    current: usize,
    total: usize,
    start_time: i64,
    last_update: i64,
    completed: bool,
    counted_complete: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, total: usize) !Self {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io(), name, total);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io, name: []const u8, total: usize) !Self {
        const now = Io.Clock.awake.now(io).toMilliseconds();
        return .{
            .allocator = allocator,
            .io = io,
            .name = try allocator.dupe(u8, name),
            .current = 0,
            .total = total,
            .start_time = now,
            .last_update = now,
            .completed = false,
            .counted_complete = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn update(self: *Self, current: usize) void {
        self.current = @min(current, self.total);
        self.last_update = Io.Clock.awake.now(self.io).toMilliseconds();
        if (current >= self.total) {
            self.completed = true;
        }
    }

    pub fn finish(self: *Self) void {
        self.current = self.total;
        self.completed = true;
        self.last_update = Io.Clock.awake.now(self.io).toMilliseconds();
    }

    pub fn getSpeed(self: *const Self) f64 {
        const elapsed_ms = self.last_update - self.start_time;
        if (elapsed_ms == 0) return 0.0;

        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const bytes = @as(f64, @floatFromInt(self.current));
        const mb = bytes / (1024.0 * 1024.0);

        return mb / elapsed_s;
    }

    pub fn getPercent(self: *const Self) f64 {
        if (self.total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }

    pub fn render(self: *const Self) void {
        const percent = self.getPercent();
        const speed = self.getSpeed();
        const bar_width = 20;
        const filled = @as(usize, @intFromFloat(percent / 100.0 * @as(f64, @floatFromInt(bar_width))));

        // Spinner animation
        const spinner = if (self.completed) "✓" else blk: {
            const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
            const now = Io.Clock.awake.now(self.io).toMilliseconds();
            const frame_idx = @as(usize, @intCast(@mod(@divFloor(now, 100), 10)));
            break :blk frames[frame_idx];
        };

        std.debug.print("\r{s} {s:<30} [", .{ spinner, self.name });

        var i: usize = 0;
        while (i < bar_width) : (i += 1) {
            if (i < filled) {
                std.debug.print("█", .{});
            } else {
                std.debug.print("░", .{});
            }
        }

        if (self.completed) {
            std.debug.print("] {d:>3.0}% | Done   ", .{percent});
        } else {
            std.debug.print("] {d:>3.0}% | {d:.1} MB/s", .{ percent, speed });
        }
    }
};

/// Multi-package progress tracker
pub const ProgressTracker = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bars: std.ArrayList(*ProgressBar),
    total_packages: usize,
    completed_packages: usize,
    start_time: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, total: usize) !Self {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io(), total);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io, total: usize) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .bars = std.ArrayList(*ProgressBar).empty,
            .total_packages = total,
            .completed_packages = 0,
            .start_time = Io.Clock.awake.now(io).toMilliseconds(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.bars.items) |bar| {
            bar.deinit();
            self.allocator.destroy(bar);
        }
        self.bars.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addPackage(self: *Self, name: []const u8, size: usize) !*ProgressBar {
        const bar = try self.allocator.create(ProgressBar);
        errdefer self.allocator.destroy(bar);
        bar.* = try ProgressBar.initWithIo(self.allocator, self.io, name, size);
        errdefer bar.deinit();
        try self.bars.append(self.allocator, bar);
        return bar;
    }

    pub fn markComplete(self: *Self, bar: *ProgressBar) void {
        if (bar.counted_complete) return;
        bar.finish();
        bar.counted_complete = true;
        self.completed_packages += 1;
    }

    pub fn renderAll(self: *const Self) void {
        // Clear previous output
        std.debug.print("\x1b[2J\x1b[H", .{});

        // Header
        std.debug.print("📦 Installing {d} packages...\n\n", .{self.total_packages});

        // Show up to 5 active downloads
        var shown: usize = 0;
        for (self.bars.items) |bar| {
            if (!bar.completed and shown < 5) {
                bar.render();
                std.debug.print("\n", .{});
                shown += 1;
            }
        }

        // Summary line
        const elapsed_ms = Io.Clock.awake.now(self.io).toMilliseconds() - self.start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        if (self.completed_packages < self.total_packages) {
            const avg_speed = self.getAverageSpeed();
            std.debug.print("\n⠋ {d}/{d} packages | {d:.1}s elapsed | avg {d:.1} MB/s\n", .{
                self.completed_packages,
                self.total_packages,
                elapsed_s,
                avg_speed,
            });
        } else {
            std.debug.print("\n✨ All packages installed in {d:.1}s!\n", .{elapsed_s});
        }
    }

    fn getAverageSpeed(self: *const Self) f64 {
        if (self.bars.items.len == 0) return 0.0;

        var total_speed: f64 = 0.0;
        var active_count: usize = 0;

        for (self.bars.items) |bar| {
            if (!bar.completed) {
                total_speed += bar.getSpeed();
                active_count += 1;
            }
        }

        if (active_count == 0) return 0.0;
        return total_speed / @as(f64, @floatFromInt(active_count));
    }
};

/// Installation summary (Bun-style)
pub const InstallSummary = struct {
    total_packages: usize,
    from_cache: usize,
    downloaded: usize,
    total_size_mb: f64,
    duration_s: f64,
    avg_speed_mbps: f64,

    pub fn render(self: *const InstallSummary) void {
        std.debug.print("\n✨ Installation complete!\n\n", .{});
        std.debug.print("📦 {d} packages installed\n", .{self.total_packages});
        std.debug.print("⏱️  {d:.1}s (avg {d:.0} KB/s)\n", .{ self.duration_s, self.avg_speed_mbps * 1024.0 });
        std.debug.print("💾 {d:.1} MB disk space used\n", .{self.total_size_mb});

        if (self.from_cache > 0) {
            std.debug.print("🔗 {d} packages from cache (instant)\n", .{self.from_cache});
        }

        if (self.downloaded > 0) {
            std.debug.print("📥 {d} packages downloaded\n", .{self.downloaded});
        }

        std.debug.print("\n", .{});
    }
};
