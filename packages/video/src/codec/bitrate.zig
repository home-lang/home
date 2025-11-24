const std = @import("std");

/// Bitrate calculator and analyzer for video streams
pub const BitrateAnalyzer = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(Sample),
    total_bytes: u64,
    total_duration_ms: u64,
    start_timestamp: ?u64,
    min_bitrate: f64,
    max_bitrate: f64,
    window_ms: u64, // Moving average window in milliseconds

    pub const Sample = struct {
        timestamp_ms: u64,
        frame_size_bytes: u32,
        frame_type: FrameType,
        is_keyframe: bool,
    };

    pub const FrameType = enum {
        i_frame,
        p_frame,
        b_frame,
        unknown,
    };

    pub const BitrateStats = struct {
        average_bitrate_bps: f64,
        min_bitrate_bps: f64,
        max_bitrate_bps: f64,
        peak_bitrate_bps: f64,
        total_bytes: u64,
        total_frames: u64,
        duration_seconds: f64,
        i_frame_count: u64,
        p_frame_count: u64,
        b_frame_count: u64,
        i_frame_avg_size: f64,
        p_frame_avg_size: f64,
        b_frame_avg_size: f64,
        bitrate_variance: f64,
        vbv_buffer_violations: u64, // Count of buffer overflow/underflow
    };

    pub fn init(allocator: std.mem.Allocator, window_ms: u64) BitrateAnalyzer {
        return .{
            .allocator = allocator,
            .samples = std.ArrayList(Sample).init(allocator),
            .total_bytes = 0,
            .total_duration_ms = 0,
            .start_timestamp = null,
            .min_bitrate = std.math.floatMax(f64),
            .max_bitrate = 0.0,
            .window_ms = window_ms,
        };
    }

    pub fn deinit(self: *BitrateAnalyzer) void {
        self.samples.deinit();
    }

    /// Add a frame sample
    pub fn addFrame(self: *BitrateAnalyzer, timestamp_ms: u64, size_bytes: u32, frame_type: FrameType, is_keyframe: bool) !void {
        if (self.start_timestamp == null) {
            self.start_timestamp = timestamp_ms;
        }

        const sample = Sample{
            .timestamp_ms = timestamp_ms,
            .frame_size_bytes = size_bytes,
            .frame_type = frame_type,
            .is_keyframe = is_keyframe,
        };

        try self.samples.append(sample);
        self.total_bytes += size_bytes;
        self.total_duration_ms = timestamp_ms - (self.start_timestamp orelse 0);

        // Update min/max with moving window
        if (self.samples.items.len > 1) {
            const instant_bitrate = try self.calculateInstantBitrate(self.samples.items.len - 1);
            self.min_bitrate = @min(self.min_bitrate, instant_bitrate);
            self.max_bitrate = @max(self.max_bitrate, instant_bitrate);
        }
    }

    /// Calculate instantaneous bitrate at a specific sample index
    fn calculateInstantBitrate(self: *BitrateAnalyzer, index: usize) !f64 {
        if (index == 0 or index >= self.samples.items.len) return 0.0;

        const current = self.samples.items[index];
        const window_start_time = if (current.timestamp_ms > self.window_ms)
            current.timestamp_ms - self.window_ms
        else
            0;

        // Find samples within window
        var window_bytes: u64 = 0;
        var window_start_index = index;

        while (window_start_index > 0) : (window_start_index -= 1) {
            if (self.samples.items[window_start_index].timestamp_ms < window_start_time) {
                break;
            }
        }

        for (self.samples.items[window_start_index..index + 1]) |sample| {
            window_bytes += sample.frame_size_bytes;
        }

        const window_duration_ms = current.timestamp_ms - self.samples.items[window_start_index].timestamp_ms;
        if (window_duration_ms == 0) return 0.0;

        const window_duration_s = @as(f64, @floatFromInt(window_duration_ms)) / 1000.0;
        return (@as(f64, @floatFromInt(window_bytes)) * 8.0) / window_duration_s;
    }

    /// Get comprehensive bitrate statistics
    pub fn getStats(self: *BitrateAnalyzer) !BitrateStats {
        if (self.samples.items.len == 0) {
            return BitrateStats{
                .average_bitrate_bps = 0.0,
                .min_bitrate_bps = 0.0,
                .max_bitrate_bps = 0.0,
                .peak_bitrate_bps = 0.0,
                .total_bytes = 0,
                .total_frames = 0,
                .duration_seconds = 0.0,
                .i_frame_count = 0,
                .p_frame_count = 0,
                .b_frame_count = 0,
                .i_frame_avg_size = 0.0,
                .p_frame_avg_size = 0.0,
                .b_frame_avg_size = 0.0,
                .bitrate_variance = 0.0,
                .vbv_buffer_violations = 0,
            };
        }

        const duration_s = @as(f64, @floatFromInt(self.total_duration_ms)) / 1000.0;
        const avg_bitrate = if (duration_s > 0.0)
            (@as(f64, @floatFromInt(self.total_bytes)) * 8.0) / duration_s
        else
            0.0;

        // Count frame types and calculate sizes
        var i_count: u64 = 0;
        var p_count: u64 = 0;
        var b_count: u64 = 0;
        var i_total_size: u64 = 0;
        var p_total_size: u64 = 0;
        var b_total_size: u64 = 0;
        var peak_bitrate: f64 = 0.0;

        for (self.samples.items, 0..) |sample, i| {
            switch (sample.frame_type) {
                .i_frame => {
                    i_count += 1;
                    i_total_size += sample.frame_size_bytes;
                },
                .p_frame => {
                    p_count += 1;
                    p_total_size += sample.frame_size_bytes;
                },
                .b_frame => {
                    b_count += 1;
                    b_total_size += sample.frame_size_bytes;
                },
                .unknown => {},
            }

            if (i > 0) {
                const instant_bitrate = try self.calculateInstantBitrate(i);
                peak_bitrate = @max(peak_bitrate, instant_bitrate);
            }
        }

        const i_avg = if (i_count > 0) @as(f64, @floatFromInt(i_total_size)) / @as(f64, @floatFromInt(i_count)) else 0.0;
        const p_avg = if (p_count > 0) @as(f64, @floatFromInt(p_total_size)) / @as(f64, @floatFromInt(p_count)) else 0.0;
        const b_avg = if (b_count > 0) @as(f64, @floatFromInt(b_total_size)) / @as(f64, @floatFromInt(b_count)) else 0.0;

        // Calculate variance
        var variance_sum: f64 = 0.0;
        for (self.samples.items, 0..) |_, i| {
            if (i > 0) {
                const instant_bitrate = try self.calculateInstantBitrate(i);
                const diff = instant_bitrate - avg_bitrate;
                variance_sum += diff * diff;
            }
        }
        const variance = if (self.samples.items.len > 1)
            variance_sum / @as(f64, @floatFromInt(self.samples.items.len - 1))
        else
            0.0;

        return BitrateStats{
            .average_bitrate_bps = avg_bitrate,
            .min_bitrate_bps = if (self.min_bitrate != std.math.floatMax(f64)) self.min_bitrate else 0.0,
            .max_bitrate_bps = self.max_bitrate,
            .peak_bitrate_bps = peak_bitrate,
            .total_bytes = self.total_bytes,
            .total_frames = self.samples.items.len,
            .duration_seconds = duration_s,
            .i_frame_count = i_count,
            .p_frame_count = p_count,
            .b_frame_count = b_count,
            .i_frame_avg_size = i_avg,
            .p_frame_avg_size = p_avg,
            .b_frame_avg_size = b_avg,
            .bitrate_variance = variance,
            .vbv_buffer_violations = 0, // Would need VBV simulation
        };
    }

    /// Get bitrate at specific time
    pub fn getBitrateAtTime(self: *BitrateAnalyzer, timestamp_ms: u64) !f64 {
        // Find sample closest to timestamp
        var closest_index: usize = 0;
        var closest_diff: u64 = std.math.maxInt(u64);

        for (self.samples.items, 0..) |sample, i| {
            const diff = if (sample.timestamp_ms > timestamp_ms)
                sample.timestamp_ms - timestamp_ms
            else
                timestamp_ms - sample.timestamp_ms;

            if (diff < closest_diff) {
                closest_diff = diff;
                closest_index = i;
            }
        }

        return self.calculateInstantBitrate(closest_index);
    }

    /// Export bitrate graph data
    pub fn exportGraph(self: *BitrateAnalyzer, allocator: std.mem.Allocator) ![]GraphPoint {
        var points = try allocator.alloc(GraphPoint, self.samples.items.len);

        for (self.samples.items, 0..) |sample, i| {
            const bitrate = if (i > 0) try self.calculateInstantBitrate(i) else 0.0;
            points[i] = .{
                .timestamp_s = @as(f64, @floatFromInt(sample.timestamp_ms)) / 1000.0,
                .bitrate_bps = bitrate,
                .frame_size = sample.frame_size_bytes,
                .is_keyframe = sample.is_keyframe,
            };
        }

        return points;
    }

    pub const GraphPoint = struct {
        timestamp_s: f64,
        bitrate_bps: f64,
        frame_size: u32,
        is_keyframe: bool,
    };
};

/// VBV (Video Buffering Verifier) buffer model simulator
pub const VbvSimulator = struct {
    buffer_size_bits: u64,
    max_bitrate_bps: u64,
    current_buffer_bits: i64,
    underflow_count: u64,
    overflow_count: u64,

    pub fn init(buffer_size_bits: u64, max_bitrate_bps: u64) VbvSimulator {
        return .{
            .buffer_size_bits = buffer_size_bits,
            .max_bitrate_bps = max_bitrate_bps,
            .current_buffer_bits = @intCast(buffer_size_bits), // Start full
            .underflow_count = 0,
            .overflow_count = 0,
        };
    }

    /// Process a frame
    pub fn processFrame(self: *VbvSimulator, frame_size_bits: u64, frame_duration_ms: u64) void {
        // Add bits from decoder
        const frame_duration_s = @as(f64, @floatFromInt(frame_duration_ms)) / 1000.0;
        const bits_from_decoder = @as(i64, @intFromFloat(@as(f64, @floatFromInt(self.max_bitrate_bps)) * frame_duration_s));

        self.current_buffer_bits += bits_from_decoder;

        // Check overflow before removing frame
        if (self.current_buffer_bits > @as(i64, @intCast(self.buffer_size_bits))) {
            self.overflow_count += 1;
            self.current_buffer_bits = @intCast(self.buffer_size_bits);
        }

        // Remove frame bits
        self.current_buffer_bits -= @as(i64, @intCast(frame_size_bits));

        // Check underflow
        if (self.current_buffer_bits < 0) {
            self.underflow_count += 1;
            self.current_buffer_bits = 0;
        }
    }

    pub fn getViolations(self: *VbvSimulator) u64 {
        return self.underflow_count + self.overflow_count;
    }

    pub fn getBufferFullness(self: *VbvSimulator) f64 {
        return @as(f64, @floatFromInt(self.current_buffer_bits)) / @as(f64, @floatFromInt(self.buffer_size_bits));
    }
};

/// GOP (Group of Pictures) analyzer
pub const GopAnalyzer = struct {
    allocator: std.mem.Allocator,
    gops: std.ArrayList(GopStats),
    current_gop: ?GopStats,

    pub const GopStats = struct {
        start_timestamp_ms: u64,
        end_timestamp_ms: u64,
        i_frame_count: u32,
        p_frame_count: u32,
        b_frame_count: u32,
        total_bytes: u64,
        max_frame_size: u32,
        min_frame_size: u32,

        pub fn getDuration(self: *const GopStats) u64 {
            return self.end_timestamp_ms - self.start_timestamp_ms;
        }

        pub fn getAverageBitrate(self: *const GopStats) f64 {
            const duration_s = @as(f64, @floatFromInt(self.getDuration())) / 1000.0;
            if (duration_s == 0.0) return 0.0;
            return (@as(f64, @floatFromInt(self.total_bytes)) * 8.0) / duration_s;
        }

        pub fn getFrameCount(self: *const GopStats) u32 {
            return self.i_frame_count + self.p_frame_count + self.b_frame_count;
        }
    };

    pub fn init(allocator: std.mem.Allocator) GopAnalyzer {
        return .{
            .allocator = allocator,
            .gops = std.ArrayList(GopStats).init(allocator),
            .current_gop = null,
        };
    }

    pub fn deinit(self: *GopAnalyzer) void {
        self.gops.deinit();
    }

    /// Add a frame (starts new GOP on I-frame)
    pub fn addFrame(self: *GopAnalyzer, timestamp_ms: u64, size_bytes: u32, frame_type: BitrateAnalyzer.FrameType, is_keyframe: bool) !void {
        if (is_keyframe or frame_type == .i_frame) {
            // Finish current GOP
            if (self.current_gop) |gop| {
                try self.gops.append(gop);
            }

            // Start new GOP
            self.current_gop = GopStats{
                .start_timestamp_ms = timestamp_ms,
                .end_timestamp_ms = timestamp_ms,
                .i_frame_count = 1,
                .p_frame_count = 0,
                .b_frame_count = 0,
                .total_bytes = size_bytes,
                .max_frame_size = size_bytes,
                .min_frame_size = size_bytes,
            };
        } else if (self.current_gop) |*gop| {
            // Add to current GOP
            gop.end_timestamp_ms = timestamp_ms;
            gop.total_bytes += size_bytes;
            gop.max_frame_size = @max(gop.max_frame_size, size_bytes);
            gop.min_frame_size = @min(gop.min_frame_size, size_bytes);

            switch (frame_type) {
                .i_frame => gop.i_frame_count += 1,
                .p_frame => gop.p_frame_count += 1,
                .b_frame => gop.b_frame_count += 1,
                .unknown => {},
            }
        }
    }

    /// Finish analysis
    pub fn finish(self: *GopAnalyzer) !void {
        if (self.current_gop) |gop| {
            try self.gops.append(gop);
            self.current_gop = null;
        }
    }

    /// Get GOP statistics
    pub fn getGops(self: *GopAnalyzer) []const GopStats {
        return self.gops.items;
    }

    /// Get average GOP size
    pub fn getAverageGopSize(self: *GopAnalyzer) u32 {
        if (self.gops.items.len == 0) return 0;

        var total_frames: u32 = 0;
        for (self.gops.items) |gop| {
            total_frames += gop.getFrameCount();
        }

        return total_frames / @as(u32, @intCast(self.gops.items.len));
    }
};
