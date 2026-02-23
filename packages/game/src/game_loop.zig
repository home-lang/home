// Home Game Development Framework - Game Loop Utilities
// Fixed timestep game loop with interpolation support

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ============================================================================
// Zig 0.16 Compatibility - Time Helper
// ============================================================================

/// Get current time in nanoseconds (Zig 0.16 compatible)
pub fn getNanoTimestamp() i128 {
    if (comptime native_os == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    }
}

// ============================================================================
// Game Loop Configuration
// ============================================================================

pub const LoopConfig = struct {
    /// Target updates per second (fixed timestep)
    target_ups: u32 = 60,
    /// Maximum updates per frame to prevent spiral of death
    max_updates_per_frame: u32 = 5,
    /// Whether to use interpolation for rendering
    use_interpolation: bool = true,
    /// Target frames per second (0 = unlimited)
    target_fps: u32 = 0,
    /// Enable vsync
    vsync: bool = true,
};

// ============================================================================
// Timing Statistics
// ============================================================================

pub const TimingStats = struct {
    /// Frames per second
    fps: f64 = 0,
    /// Updates per second
    ups: f64 = 0,
    /// Frame time in milliseconds
    frame_time_ms: f64 = 0,
    /// Update time in milliseconds
    update_time_ms: f64 = 0,
    /// Render time in milliseconds
    render_time_ms: f64 = 0,
    /// Total frame count
    total_frames: u64 = 0,
    /// Total update count
    total_updates: u64 = 0,
    /// Accumulated time
    total_time: f64 = 0,

    // For internal calculation
    fps_accumulator: f64 = 0,
    fps_frames: u32 = 0,
    ups_accumulator: f64 = 0,
    ups_updates: u32 = 0,
};

// ============================================================================
// Fixed Timestep Game Loop
// ============================================================================

pub fn FixedTimestepLoop(comptime GameState: type) type {
    return struct {
        const Self = @This();

        config: LoopConfig,
        stats: TimingStats,
        running: bool,
        paused: bool,

        // Timing
        fixed_dt: f64, // Fixed delta time in seconds
        accumulator: f64,
        last_time: i128,
        current_time: i128,

        // State for interpolation
        game_state: ?*GameState,

        pub fn init(config: LoopConfig) Self {
            const fixed_dt = 1.0 / @as(f64, @floatFromInt(config.target_ups));
            return Self{
                .config = config,
                .stats = TimingStats{},
                .running = false,
                .paused = false,
                .fixed_dt = fixed_dt,
                .accumulator = 0,
                .last_time = getNanoTimestamp(),
                .current_time = getNanoTimestamp(),
                .game_state = null,
            };
        }

        pub fn setGameState(self: *Self, state: *GameState) void {
            self.game_state = state;
        }

        pub fn start(self: *Self) void {
            self.running = true;
            self.last_time = getNanoTimestamp();
        }

        pub fn stop(self: *Self) void {
            self.running = false;
        }

        pub fn pause(self: *Self) void {
            self.paused = true;
        }

        pub fn @"resume"(self: *Self) void {
            self.paused = false;
            self.last_time = getNanoTimestamp();
        }

        pub fn tick(
            self: *Self,
            comptime update_fn: fn (*GameState, f64) void,
            comptime render_fn: fn (*GameState, f64) void,
        ) void {
            if (!self.running or self.game_state == null) return;

            self.current_time = getNanoTimestamp();
            var frame_time = @as(f64, @floatFromInt(self.current_time - self.last_time)) / 1_000_000_000.0;
            self.last_time = self.current_time;

            // Prevent spiral of death
            const max_frame_time = @as(f64, @floatFromInt(self.config.max_updates_per_frame)) * self.fixed_dt;
            if (frame_time > max_frame_time) {
                frame_time = max_frame_time;
            }

            if (!self.paused) {
                self.accumulator += frame_time;

                // Fixed timestep updates
                var updates_this_frame: u32 = 0;
                const update_start = getNanoTimestamp();

                while (self.accumulator >= self.fixed_dt and updates_this_frame < self.config.max_updates_per_frame) {
                    update_fn(self.game_state.?, self.fixed_dt);
                    self.accumulator -= self.fixed_dt;
                    self.stats.total_updates += 1;
                    updates_this_frame += 1;
                }

                const update_end = getNanoTimestamp();
                self.stats.update_time_ms = @as(f64, @floatFromInt(update_end - update_start)) / 1_000_000.0;

                // Update UPS stats
                self.stats.ups_updates += updates_this_frame;
                self.stats.ups_accumulator += frame_time;
                if (self.stats.ups_accumulator >= 1.0) {
                    self.stats.ups = @as(f64, @floatFromInt(self.stats.ups_updates)) / self.stats.ups_accumulator;
                    self.stats.ups_updates = 0;
                    self.stats.ups_accumulator = 0;
                }
            }

            // Render with interpolation alpha
            const render_start = getNanoTimestamp();
            const alpha = if (self.config.use_interpolation) self.accumulator / self.fixed_dt else 1.0;
            render_fn(self.game_state.?, alpha);
            const render_end = getNanoTimestamp();

            self.stats.render_time_ms = @as(f64, @floatFromInt(render_end - render_start)) / 1_000_000.0;
            self.stats.total_frames += 1;
            self.stats.frame_time_ms = frame_time * 1000.0;
            self.stats.total_time += frame_time;

            // Update FPS stats
            self.stats.fps_frames += 1;
            self.stats.fps_accumulator += frame_time;
            if (self.stats.fps_accumulator >= 1.0) {
                self.stats.fps = @as(f64, @floatFromInt(self.stats.fps_frames)) / self.stats.fps_accumulator;
                self.stats.fps_frames = 0;
                self.stats.fps_accumulator = 0;
            }

            // Frame limiting (if not vsync)
            if (self.config.target_fps > 0 and !self.config.vsync) {
                const target_frame_time = 1.0 / @as(f64, @floatFromInt(self.config.target_fps));
                const actual_frame_time = @as(f64, @floatFromInt(getNanoTimestamp() - self.current_time)) / 1_000_000_000.0;
                if (actual_frame_time < target_frame_time) {
                    const sleep_ns: u64 = @intFromFloat((target_frame_time - actual_frame_time) * 1_000_000_000.0);
                    std.posix.nanosleep(0, sleep_ns);
                }
            }
        }

        pub fn getStats(self: *const Self) TimingStats {
            return self.stats;
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        pub fn isPaused(self: *const Self) bool {
            return self.paused;
        }
    };
}

// ============================================================================
// Simple Variable Timestep Loop
// ============================================================================

pub const VariableTimestepLoop = struct {
    running: bool = false,
    paused: bool = false,
    last_time: i128 = 0,
    stats: TimingStats = .{},
    min_dt: f64 = 1.0 / 240.0, // Max 240 updates per second
    max_dt: f64 = 1.0 / 10.0, // Min 10 updates per second

    pub fn init() VariableTimestepLoop {
        return .{
            .last_time = getNanoTimestamp(),
        };
    }

    pub fn start(self: *VariableTimestepLoop) void {
        self.running = true;
        self.last_time = getNanoTimestamp();
    }

    pub fn stop(self: *VariableTimestepLoop) void {
        self.running = false;
    }

    pub fn getDeltaTime(self: *VariableTimestepLoop) f64 {
        const current = getNanoTimestamp();
        var dt = @as(f64, @floatFromInt(current - self.last_time)) / 1_000_000_000.0;
        self.last_time = current;

        // Clamp delta time
        if (dt < self.min_dt) dt = self.min_dt;
        if (dt > self.max_dt) dt = self.max_dt;

        if (!self.paused) {
            self.stats.total_time += dt;
            self.stats.total_frames += 1;
        }

        return if (self.paused) 0.0 else dt;
    }
};

// ============================================================================
// Frame Limiter
// ============================================================================

pub const FrameLimiter = struct {
    target_fps: u32,
    frame_time_ns: i128,
    last_frame: i128,

    pub fn init(target_fps: u32) FrameLimiter {
        return .{
            .target_fps = target_fps,
            .frame_time_ns = @divFloor(1_000_000_000, target_fps),
            .last_frame = getNanoTimestamp(),
        };
    }

    pub fn limit(self: *FrameLimiter) void {
        const now = getNanoTimestamp();
        const elapsed = now - self.last_frame;

        if (elapsed < self.frame_time_ns) {
            const sleep_ns: u64 = @intCast(self.frame_time_ns - elapsed);
            std.posix.nanosleep(0, sleep_ns);
        }

        self.last_frame = getNanoTimestamp();
    }

    pub fn setTargetFPS(self: *FrameLimiter, fps: u32) void {
        self.target_fps = fps;
        self.frame_time_ns = @divFloor(1_000_000_000, fps);
    }
};

// ============================================================================
// Delta Time Smoother
// ============================================================================

pub const DeltaTimeSmoother = struct {
    samples: [10]f64 = [_]f64{0} ** 10,
    index: usize = 0,
    count: usize = 0,

    pub fn add(self: *DeltaTimeSmoother, dt: f64) void {
        self.samples[self.index] = dt;
        self.index = (self.index + 1) % 10;
        if (self.count < 10) self.count += 1;
    }

    pub fn getSmoothed(self: *const DeltaTimeSmoother) f64 {
        if (self.count == 0) return 0;

        var sum: f64 = 0;
        for (self.samples[0..self.count]) |sample| {
            sum += sample;
        }
        return sum / @as(f64, @floatFromInt(self.count));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FrameLimiter" {
    var limiter = FrameLimiter.init(60);
    try std.testing.expectEqual(@as(u32, 60), limiter.target_fps);
}

test "DeltaTimeSmoother" {
    var smoother = DeltaTimeSmoother{};

    smoother.add(0.016);
    smoother.add(0.017);
    smoother.add(0.015);

    const smoothed = smoother.getSmoothed();
    try std.testing.expect(smoothed > 0.015 and smoothed < 0.018);
}

test "VariableTimestepLoop" {
    var loop = VariableTimestepLoop.init();
    loop.start();

    try std.testing.expect(loop.running);
    try std.testing.expect(!loop.paused);
}

test "getNanoTimestamp" {
    const t1 = getNanoTimestamp();
    std.posix.nanosleep(0, 1_000_000); // Sleep 1ms
    const t2 = getNanoTimestamp();

    try std.testing.expect(t2 > t1);
}
