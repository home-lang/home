// Home Video Library - Temporal Video Filters
// Trim, frame rate conversion, speed adjustment, reverse, frame extraction

const std = @import("std");
const core = @import("../../core.zig");
const VideoFrame = core.VideoFrame;
const Timestamp = core.Timestamp;
const Duration = core.Duration;

/// Trim filter - cut video by timestamp
pub const TrimFilter = struct {
    start_time: Timestamp,
    end_time: ?Timestamp = null, // null = to end
    duration: ?Duration = null,   // Alternative to end_time

    const Self = @This();

    pub fn init(start_time: Timestamp, end_time: ?Timestamp, duration: ?Duration) Self {
        return .{
            .start_time = start_time,
            .end_time = end_time,
            .duration = duration,
        };
    }

    pub fn shouldIncludeFrame(self: *const Self, pts: Timestamp) bool {
        if (pts.compare(self.start_time) == .lt) return false;

        if (self.end_time) |end| {
            if (pts.compare(end) == .gt) return false;
        }

        if (self.duration) |dur| {
            const end = self.start_time.add(dur);
            if (pts.compare(end) == .gt) return false;
        }

        return true;
    }

    pub fn adjustTimestamp(self: *const Self, pts: Timestamp) Timestamp {
        return pts.sub(self.start_time.toMicroseconds());
    }
};

/// Frame rate conversion mode
pub const FrameRateMode = enum {
    drop_dup,      // Drop or duplicate frames
    interpolate,   // Simple frame blending
    motion_comp,   // Motion compensated (future)
};

/// Frame rate converter
pub const FrameRateConverter = struct {
    source_fps: core.Rational,
    target_fps: core.Rational,
    mode: FrameRateMode = .drop_dup,
    allocator: std.mem.Allocator,

    // State
    frame_count: u64 = 0,
    accumulated_time: f64 = 0.0,
    last_frame: ?*VideoFrame = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source_fps: core.Rational, target_fps: core.Rational, mode: FrameRateMode) Self {
        return .{
            .allocator = allocator,
            .source_fps = source_fps,
            .target_fps = target_fps,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_frame) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
    }

    pub fn convert(self: *Self, input_frame: *const VideoFrame) !?*VideoFrame {
        const source_fps_f: f64 = @as(f64, @floatFromInt(self.source_fps.num)) / @as(f64, @floatFromInt(self.source_fps.den));
        const target_fps_f: f64 = @as(f64, @floatFromInt(self.target_fps.num)) / @as(f64, @floatFromInt(self.target_fps.den));

        const source_frame_time = 1.0 / source_fps_f;
        const target_frame_time = 1.0 / target_fps_f;

        self.accumulated_time += source_frame_time;

        switch (self.mode) {
            .drop_dup => {
                // Simple drop/duplicate strategy
                if (self.accumulated_time >= target_frame_time) {
                    self.accumulated_time -= target_frame_time;

                    // Clone frame
                    const output = try self.allocator.create(VideoFrame);
                    output.* = try input_frame.clone(self.allocator);
                    return output;
                }
                return null; // Drop frame
            },
            .interpolate => {
                if (self.accumulated_time >= target_frame_time) {
                    self.accumulated_time -= target_frame_time;

                    if (self.last_frame) |last| {
                        // Blend last and current frame
                        const output = try self.blendFrames(last, input_frame, 0.5);
                        return output;
                    } else {
                        const output = try self.allocator.create(VideoFrame);
                        output.* = try input_frame.clone(self.allocator);
                        return output;
                    }
                }

                // Store frame for next interpolation
                if (self.last_frame) |old| {
                    old.deinit();
                    self.allocator.destroy(old);
                }
                self.last_frame = try self.allocator.create(VideoFrame);
                self.last_frame.?.* = try input_frame.clone(self.allocator);

                return null;
            },
            .motion_comp => {
                // Motion compensated interpolation - placeholder
                return error.NotImplemented;
            },
        }
    }

    fn blendFrames(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame, ratio: f32) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try VideoFrame.init(self.allocator, frame1.width, frame1.height, frame1.format);

        const ratio1 = 1.0 - ratio;
        const ratio2 = ratio;

        // Blend luma
        for (0..frame1.width * frame1.height) |i| {
            const val1: f32 = @floatFromInt(frame1.data[0][i]);
            const val2: f32 = @floatFromInt(frame2.data[0][i]);
            output.data[0][i] = @intFromFloat(val1 * ratio1 + val2 * ratio2);
        }

        // Blend chroma (if present)
        if (frame1.format == .yuv420p or frame1.format == .yuv422p or frame1.format == .yuv444p) {
            const chroma_size = switch (frame1.format) {
                .yuv420p => (frame1.width / 2) * (frame1.height / 2),
                .yuv422p => (frame1.width / 2) * frame1.height,
                .yuv444p => frame1.width * frame1.height,
                else => 0,
            };

            for (0..chroma_size) |i| {
                const u1: f32 = @floatFromInt(frame1.data[1][i]);
                const u2: f32 = @floatFromInt(frame2.data[1][i]);
                output.data[1][i] = @intFromFloat(u1 * ratio1 + u2 * ratio2);

                const v1: f32 = @floatFromInt(frame1.data[2][i]);
                const v2: f32 = @floatFromInt(frame2.data[2][i]);
                output.data[2][i] = @intFromFloat(v1 * ratio1 + v2 * ratio2);
            }
        }

        return output;
    }
};

/// Speed adjustment filter
pub const SpeedFilter = struct {
    speed_factor: f32, // 0.25x - 4.0x
    preserve_pitch: bool = false, // Audio pitch preservation (future)

    const Self = @This();

    pub fn init(speed_factor: f32, preserve_pitch: bool) !Self {
        if (speed_factor < 0.25 or speed_factor > 4.0) {
            return error.InvalidSpeedFactor;
        }

        return .{
            .speed_factor = speed_factor,
            .preserve_pitch = preserve_pitch,
        };
    }

    pub fn adjustTimestamp(self: *const Self, pts: Timestamp) Timestamp {
        const pts_us = pts.toMicroseconds();
        const adjusted: i64 = @intFromFloat(@as(f64, @floatFromInt(pts_us)) / self.speed_factor);
        return Timestamp.fromMicroseconds(adjusted);
    }

    pub fn adjustDuration(self: *const Self, duration: Duration) Duration {
        const dur_us = duration.toMicroseconds();
        const adjusted: i64 = @intFromFloat(@as(f64, @floatFromInt(dur_us)) / self.speed_factor);
        return Duration.fromMicroseconds(adjusted);
    }

    pub fn shouldIncludeFrame(self: *const Self, frame_index: u64, source_fps: core.Rational) bool {
        // For slow motion, include all frames
        if (self.speed_factor < 1.0) return true;

        // For fast motion, skip frames
        const fps_f: f64 = @as(f64, @floatFromInt(source_fps.num)) / @as(f64, @floatFromInt(source_fps.den));
        const target_fps = fps_f / self.speed_factor;
        const frame_interval = fps_f / target_fps;

        const target_index: u64 = @intFromFloat(@as(f64, @floatFromInt(frame_index)) / frame_interval);
        const should_include = (@as(f64, @floatFromInt(frame_index)) - @as(f64, @floatFromInt(target_index)) * frame_interval) < 0.5;

        return should_include;
    }
};

/// Reverse playback filter
pub const ReverseFilter = struct {
    allocator: std.mem.Allocator,
    frame_buffer: std.ArrayList(*VideoFrame),
    total_duration: Timestamp,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, total_duration: Timestamp) Self {
        return .{
            .allocator = allocator,
            .frame_buffer = std.ArrayList(*VideoFrame).init(allocator),
            .total_duration = total_duration,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frame_buffer.items) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
        self.frame_buffer.deinit();
    }

    pub fn addFrame(self: *Self, frame: *VideoFrame) !void {
        const cloned = try self.allocator.create(VideoFrame);
        cloned.* = try frame.clone(self.allocator);
        try self.frame_buffer.append(cloned);
    }

    pub fn getReversedFrames(self: *Self) []const *VideoFrame {
        // Reverse the buffer in place
        std.mem.reverse(*VideoFrame, self.frame_buffer.items);

        // Adjust timestamps
        for (self.frame_buffer.items, 0..) |frame, i| {
            const new_pts_us = @as(i64, @intCast(i)) * (self.total_duration.toMicroseconds() / @as(i64, @intCast(self.frame_buffer.items.len)));
            frame.pts = Timestamp.fromMicroseconds(new_pts_us);
        }

        return self.frame_buffer.items;
    }
};

/// Frame extraction filter
pub const FrameExtractor = struct {
    allocator: std.mem.Allocator,
    timestamps: std.ArrayList(Timestamp), // Specific timestamps to extract
    tolerance: Duration, // How close to timestamp to match

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tolerance: Duration) Self {
        return .{
            .allocator = allocator,
            .timestamps = std.ArrayList(Timestamp).init(allocator),
            .tolerance = tolerance,
        };
    }

    pub fn deinit(self: *Self) void {
        self.timestamps.deinit();
    }

    pub fn addTimestamp(self: *Self, ts: Timestamp) !void {
        try self.timestamps.append(ts);
    }

    pub fn addIntervalFrames(self: *Self, start: Timestamp, end: Timestamp, interval: Duration) !void {
        var current = start;
        while (current.compare(end) != .gt) {
            try self.timestamps.append(current);
            current = current.add(interval.toMicroseconds());
        }
    }

    pub fn shouldExtractFrame(self: *const Self, frame_pts: Timestamp) bool {
        const tolerance_us = self.tolerance.toMicroseconds();

        for (self.timestamps.items) |target_ts| {
            const diff = @abs(frame_pts.toMicroseconds() - target_ts.toMicroseconds());
            if (diff <= tolerance_us) {
                return true;
            }
        }

        return false;
    }

    pub fn extractFrame(self: *Self, frame: *const VideoFrame) !*VideoFrame {
        const output = try self.allocator.create(VideoFrame);
        output.* = try frame.clone(self.allocator);
        return output;
    }
};

/// Scene change detection
pub const SceneDetector = struct {
    threshold: f32 = 0.3, // Difference threshold (0-1)
    last_frame: ?*VideoFrame = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, threshold: f32) Self {
        return .{
            .allocator = allocator,
            .threshold = threshold,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_frame) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
    }

    pub fn detectSceneChange(self: *Self, frame: *const VideoFrame) !bool {
        defer {
            if (self.last_frame) |old| {
                old.deinit();
                self.allocator.destroy(old);
            }
            self.last_frame = self.allocator.create(VideoFrame) catch null;
            if (self.last_frame) |new| {
                new.* = frame.clone(self.allocator) catch {
                    self.allocator.destroy(new);
                    self.last_frame = null;
                    return;
                };
            }
        }

        if (self.last_frame) |last| {
            const diff = try self.calculateFrameDifference(last, frame);
            return diff > self.threshold;
        }

        return false; // First frame
    }

    fn calculateFrameDifference(self: *Self, frame1: *const VideoFrame, frame2: *const VideoFrame) !f32 {
        _ = self;

        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;
        var sum_diff: u64 = 0;

        // Compare luma plane
        for (0..pixel_count) |i| {
            const diff = @abs(@as(i32, frame1.data[0][i]) - @as(i32, frame2.data[0][i]));
            sum_diff += @intCast(diff);
        }

        const avg_diff: f32 = @as(f32, @floatFromInt(sum_diff)) / @as(f32, @floatFromInt(pixel_count));
        return avg_diff / 255.0; // Normalize to 0-1
    }
};

/// Black frame detector
pub const BlackFrameDetector = struct {
    threshold: f32 = 0.1, // Brightness threshold (0-1)

    const Self = @This();

    pub fn init(threshold: f32) Self {
        return .{ .threshold = threshold };
    }

    pub fn isBlackFrame(self: *const Self, frame: *const VideoFrame) bool {
        const pixel_count = frame.width * frame.height;
        var sum: u64 = 0;

        // Check luma plane
        for (0..pixel_count) |i| {
            sum += frame.data[0][i];
        }

        const avg_brightness: f32 = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(pixel_count));
        const normalized = avg_brightness / 255.0;

        return normalized < self.threshold;
    }
};
