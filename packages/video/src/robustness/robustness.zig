// Home Video Library - Robustness Features
// Handle edge cases: corrupted files, VFR, large files, timecode discontinuities

const std = @import("std");
const types = @import("../core/types.zig");
const err = @import("../core/error.zig");

// ============================================================================
// Corrupted File Handling
// ============================================================================

/// Error recovery mode for corrupted media
pub const RecoveryMode = enum {
    /// Stop at first error
    strict,
    /// Skip corrupted frames, continue processing
    skip_frames,
    /// Attempt to reconstruct from partial data
    reconstruct,
    /// Best effort - try everything
    best_effort,
};

/// Corruption detection and handling
pub const CorruptionHandler = struct {
    allocator: std.mem.Allocator,
    recovery_mode: RecoveryMode = .skip_frames,
    max_consecutive_errors: u32 = 10,
    error_count: u32 = 0,
    recovered_frames: u64 = 0,
    skipped_frames: u64 = 0,
    corruption_regions: std.ArrayList(CorruptionRegion),

    const Self = @This();

    pub const CorruptionRegion = struct {
        start_offset: u64,
        end_offset: u64,
        error_type: CorruptionType,
        severity: Severity,
    };

    pub const CorruptionType = enum {
        invalid_header,
        invalid_frame_data,
        truncated_data,
        invalid_checksum,
        sync_lost,
        missing_keyframe,
        invalid_timestamp,
        unknown,
    };

    pub const Severity = enum {
        minor, // Recoverable, minimal impact
        moderate, // May affect some frames
        severe, // Major portion of file affected
        critical, // File likely unreadable
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .corruption_regions = std.ArrayList(CorruptionRegion).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.corruption_regions.deinit();
    }

    /// Set recovery mode
    pub fn setRecoveryMode(self: *Self, mode: RecoveryMode) void {
        self.recovery_mode = mode;
    }

    /// Report a detected corruption
    pub fn reportCorruption(self: *Self, start: u64, end: u64, error_type: CorruptionType, severity: Severity) !void {
        try self.corruption_regions.append(.{
            .start_offset = start,
            .end_offset = end,
            .error_type = error_type,
            .severity = severity,
        });

        self.error_count += 1;
    }

    /// Check if we should continue processing
    pub fn shouldContinue(self: *const Self) bool {
        if (self.recovery_mode == .strict) return self.error_count == 0;
        return self.error_count < self.max_consecutive_errors;
    }

    /// Reset consecutive error counter (call after successful frame)
    pub fn resetErrorCount(self: *Self) void {
        self.error_count = 0;
    }

    /// Record a recovered frame
    pub fn recordRecoveredFrame(self: *Self) void {
        self.recovered_frames += 1;
    }

    /// Record a skipped frame
    pub fn recordSkippedFrame(self: *Self) void {
        self.skipped_frames += 1;
    }

    /// Get corruption summary
    pub fn getSummary(self: *const Self) CorruptionSummary {
        var max_severity: Severity = .minor;
        for (self.corruption_regions.items) |region| {
            if (@intFromEnum(region.severity) > @intFromEnum(max_severity)) {
                max_severity = region.severity;
            }
        }

        return .{
            .total_corruption_regions = @intCast(self.corruption_regions.items.len),
            .recovered_frames = self.recovered_frames,
            .skipped_frames = self.skipped_frames,
            .max_severity = max_severity,
            .is_recoverable = max_severity != .critical,
        };
    }

    pub const CorruptionSummary = struct {
        total_corruption_regions: u32,
        recovered_frames: u64,
        skipped_frames: u64,
        max_severity: Severity,
        is_recoverable: bool,
    };

    /// Attempt to find next valid sync point
    pub fn findNextSyncPoint(self: *Self, data: []const u8, offset: usize) ?usize {
        _ = self;
        // Look for common sync patterns
        const sync_patterns = [_][]const u8{
            &[_]u8{ 0x00, 0x00, 0x00, 0x01 }, // H.264/HEVC NAL start code
            &[_]u8{ 0x00, 0x00, 0x01 }, // Short NAL start code
            &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 }, // EBML/WebM header
            &[_]u8{ 0x00, 0x00, 0x01, 0xBA }, // MPEG-PS pack header
            &[_]u8{ 0x47 }, // MPEG-TS sync byte (would need context)
        };

        var search_offset = offset;
        while (search_offset < data.len) : (search_offset += 1) {
            for (sync_patterns) |pattern| {
                if (search_offset + pattern.len <= data.len) {
                    if (std.mem.eql(u8, data[search_offset .. search_offset + pattern.len], pattern)) {
                        return search_offset;
                    }
                }
            }
        }

        return null;
    }
};

// ============================================================================
// Variable Frame Rate (VFR) Handling
// ============================================================================

/// VFR detection and handling
pub const VfrHandler = struct {
    allocator: std.mem.Allocator,
    frame_times: std.ArrayList(u64), // Microseconds
    is_vfr: ?bool = null,
    min_frame_duration: u64 = std.math.maxInt(u64),
    max_frame_duration: u64 = 0,
    average_frame_duration: u64 = 0,
    target_cfr: ?types.Rational = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .frame_times = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.frame_times.deinit();
    }

    /// Record a frame timestamp
    pub fn recordFrameTime(self: *Self, timestamp_us: u64) !void {
        if (self.frame_times.items.len > 0) {
            const last = self.frame_times.items[self.frame_times.items.len - 1];
            const duration = timestamp_us -| last; // Saturating subtraction

            if (duration > 0) {
                if (duration < self.min_frame_duration) self.min_frame_duration = duration;
                if (duration > self.max_frame_duration) self.max_frame_duration = duration;
            }
        }

        try self.frame_times.append(timestamp_us);
        self.invalidateAnalysis();
    }

    fn invalidateAnalysis(self: *Self) void {
        self.is_vfr = null;
        self.average_frame_duration = 0;
    }

    /// Analyze frame times to detect VFR
    pub fn analyze(self: *Self) !VfrAnalysis {
        if (self.frame_times.items.len < 2) {
            return VfrAnalysis{ .frame_count = @intCast(self.frame_times.items.len) };
        }

        // Calculate durations
        var total_duration: u128 = 0;
        var duration_variance: u128 = 0;
        var durations = std.ArrayList(u64).init(self.allocator);
        defer durations.deinit();

        for (1..self.frame_times.items.len) |i| {
            const duration = self.frame_times.items[i] -| self.frame_times.items[i - 1];
            try durations.append(duration);
            total_duration += duration;
        }

        if (durations.items.len == 0) {
            return VfrAnalysis{ .frame_count = @intCast(self.frame_times.items.len) };
        }

        const avg_duration = @divFloor(total_duration, durations.items.len);
        self.average_frame_duration = @intCast(avg_duration);

        // Calculate variance
        for (durations.items) |d| {
            const diff = if (d > avg_duration) d - avg_duration else avg_duration - @as(u128, d);
            duration_variance += diff * diff;
        }
        duration_variance = @divFloor(duration_variance, durations.items.len);

        // VFR if variance is high (more than 10% of average)
        const threshold = @divFloor(avg_duration * avg_duration, 100); // 10% variance threshold
        self.is_vfr = duration_variance > threshold;

        // Calculate detected frame rate
        const fps_num: u32 = 1000000;
        const fps_den: u32 = @intCast(avg_duration);
        const detected_fps = types.Rational{ .num = fps_num, .den = fps_den };

        return .{
            .is_vfr = self.is_vfr.?,
            .frame_count = @intCast(self.frame_times.items.len),
            .min_fps = types.Rational{ .num = 1000000, .den = @intCast(self.max_frame_duration) },
            .max_fps = types.Rational{ .num = 1000000, .den = @intCast(self.min_frame_duration) },
            .average_fps = detected_fps,
            .variance_us = @intCast(@as(u64, @truncate(duration_variance))),
        };
    }

    pub const VfrAnalysis = struct {
        is_vfr: bool = false,
        frame_count: u32 = 0,
        min_fps: types.Rational = .{ .num = 0, .den = 1 },
        max_fps: types.Rational = .{ .num = 0, .den = 1 },
        average_fps: types.Rational = .{ .num = 0, .den = 1 },
        variance_us: u64 = 0,
    };

    /// Set target CFR for conversion
    pub fn setTargetCfr(self: *Self, fps: types.Rational) void {
        self.target_cfr = fps;
    }

    /// Get interpolated timestamp for CFR output
    pub fn getCfrTimestamp(self: *const Self, frame_index: u64) ?u64 {
        if (self.target_cfr) |fps| {
            // timestamp = frame_index * (1,000,000 / fps)
            const frame_duration_us = @divFloor(@as(u64, 1000000) * fps.den, fps.num);
            return frame_index * frame_duration_us;
        }
        return null;
    }

    /// Determine if a frame should be dropped for CFR conversion
    pub fn shouldDropFrame(self: *const Self, source_timestamp: u64, target_timestamp: u64) bool {
        if (self.target_cfr == null) return false;

        // Drop if source is too far ahead of target
        const tolerance: u64 = @divFloor(self.average_frame_duration, 4);
        return source_timestamp > target_timestamp + tolerance;
    }

    /// Determine if a frame should be duplicated for CFR conversion
    pub fn shouldDuplicateFrame(self: *const Self, source_timestamp: u64, target_timestamp: u64) bool {
        if (self.target_cfr == null) return false;

        // Duplicate if target is too far ahead of source
        const tolerance: u64 = @divFloor(self.average_frame_duration, 4);
        return target_timestamp > source_timestamp + tolerance;
    }
};

// ============================================================================
// Large File Support
// ============================================================================

/// Large file handling (>4GB, >2 hours)
pub const LargeFileHandler = struct {
    allocator: std.mem.Allocator,
    file_size: u64 = 0,
    use_64bit_offsets: bool = false,
    chunk_size: u64 = 64 * 1024 * 1024, // 64MB default chunks
    current_chunk: u64 = 0,
    total_chunks: u64 = 0,

    const Self = @This();

    /// Size thresholds
    pub const SIZE_4GB: u64 = 4 * 1024 * 1024 * 1024;
    pub const SIZE_2GB: u64 = 2 * 1024 * 1024 * 1024;

    /// Duration thresholds (in microseconds)
    pub const DURATION_2_HOURS: u64 = 2 * 60 * 60 * 1000000;
    pub const DURATION_12_HOURS: u64 = 12 * 60 * 60 * 1000000;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Set file size and configure accordingly
    pub fn setFileSize(self: *Self, size: u64) void {
        self.file_size = size;
        self.use_64bit_offsets = size > SIZE_4GB;
        self.total_chunks = @divFloor(size, self.chunk_size) + 1;
    }

    /// Check if file requires special handling
    pub fn requiresLargeFileSupport(self: *const Self) bool {
        return self.file_size > SIZE_2GB;
    }

    /// Get recommended container format for large file
    pub fn getRecommendedFormat(self: *const Self) RecommendedFormat {
        if (self.file_size > SIZE_4GB) {
            return .{
                .primary = .mkv, // MKV has native 64-bit support
                .alternatives = &[_]Format{ .mov, .mp4_64bit },
                .reason = "File exceeds 4GB; requires 64-bit atom/box support",
            };
        }
        return .{
            .primary = .mp4,
            .alternatives = &[_]Format{ .mkv, .mov },
            .reason = "Standard file size; any modern container works",
        };
    }

    pub const Format = enum { mp4, mp4_64bit, mkv, mov, avi_odml };

    pub const RecommendedFormat = struct {
        primary: Format,
        alternatives: []const Format,
        reason: []const u8,
    };

    /// Calculate chunk boundaries for chunked processing
    pub fn getChunkBounds(self: *const Self, chunk_index: u64) ?ChunkBounds {
        if (chunk_index >= self.total_chunks) return null;

        const start = chunk_index * self.chunk_size;
        const end = @min(start + self.chunk_size, self.file_size);

        return .{
            .start_offset = start,
            .end_offset = end,
            .size = end - start,
            .is_last = chunk_index == self.total_chunks - 1,
        };
    }

    pub const ChunkBounds = struct {
        start_offset: u64,
        end_offset: u64,
        size: u64,
        is_last: bool,
    };

    /// Get memory-efficient read strategy
    pub fn getReadStrategy(self: *const Self) ReadStrategy {
        if (self.file_size > 16 * SIZE_4GB) {
            return .{
                .method = .chunked_streaming,
                .buffer_size = 16 * 1024 * 1024, // 16MB buffer
                .use_mmap = false,
            };
        } else if (self.file_size > SIZE_4GB) {
            return .{
                .method = .chunked_streaming,
                .buffer_size = 64 * 1024 * 1024, // 64MB buffer
                .use_mmap = false,
            };
        } else if (self.file_size > SIZE_2GB) {
            return .{
                .method = .buffered,
                .buffer_size = 256 * 1024 * 1024, // 256MB buffer
                .use_mmap = true,
            };
        }
        return .{
            .method = .full_load,
            .buffer_size = 0,
            .use_mmap = true,
        };
    }

    pub const ReadStrategy = struct {
        method: ReadMethod,
        buffer_size: u64,
        use_mmap: bool,

        pub const ReadMethod = enum {
            full_load, // Load entire file into memory
            buffered, // Use fixed-size buffer
            chunked_streaming, // Process in chunks
        };
    };
};

// ============================================================================
// Timecode Discontinuity Handling
// ============================================================================

/// Handle timecode jumps and discontinuities
pub const TimecodeDiscontinuityHandler = struct {
    allocator: std.mem.Allocator,
    discontinuities: std.ArrayList(Discontinuity),
    last_timestamp: ?u64 = null,
    expected_next: ?u64 = null,
    tolerance_us: u64 = 33333, // ~1 frame at 30fps

    const Self = @This();

    pub const Discontinuity = struct {
        position: u64, // Byte offset or frame number
        expected_timestamp: u64,
        actual_timestamp: u64,
        gap_us: i64, // Signed to handle both forward and backward jumps
        type: Type,

        pub const Type = enum {
            forward_jump, // Timestamp jumps ahead
            backward_jump, // Timestamp jumps back (wrap or reset)
            missing_frames, // Gap suggests missing frames
            wrap_around, // 32-bit timestamp wrap
        };
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .discontinuities = std.ArrayList(Discontinuity).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.discontinuities.deinit();
    }

    /// Set tolerance for discontinuity detection
    pub fn setTolerance(self: *Self, tolerance_us: u64) void {
        self.tolerance_us = tolerance_us;
    }

    /// Check timestamp for discontinuity
    pub fn checkTimestamp(self: *Self, timestamp: u64, frame_duration_us: u64, position: u64) !?Discontinuity {
        defer {
            self.last_timestamp = timestamp;
            self.expected_next = timestamp + frame_duration_us;
        }

        if (self.expected_next) |expected| {
            const diff: i64 = @as(i64, @intCast(timestamp)) - @as(i64, @intCast(expected));

            // Check if within tolerance
            if (@abs(diff) <= self.tolerance_us) {
                return null;
            }

            // Determine discontinuity type
            const disc_type: Discontinuity.Type = if (diff > 0) blk: {
                // Forward jump - check if it's a 32-bit wrap
                if (self.last_timestamp) |last| {
                    const max_32bit: u64 = 0xFFFFFFFF;
                    if (last > max_32bit - frame_duration_us * 100 and timestamp < frame_duration_us * 100) {
                        break :blk .wrap_around;
                    }
                }
                // Check if it looks like missing frames
                const frames_missing = @divFloor(@as(u64, @intCast(diff)), frame_duration_us);
                if (frames_missing > 0 and frames_missing < 1000) {
                    break :blk .missing_frames;
                }
                break :blk .forward_jump;
            } else .backward_jump;

            const disc = Discontinuity{
                .position = position,
                .expected_timestamp = expected,
                .actual_timestamp = timestamp,
                .gap_us = diff,
                .type = disc_type,
            };

            try self.discontinuities.append(disc);
            return disc;
        }

        return null;
    }

    /// Get corrected timestamp (accounting for discontinuities)
    pub fn getCorrectedTimestamp(self: *const Self, timestamp: u64) u64 {
        var correction: i64 = 0;

        for (self.discontinuities.items) |disc| {
            if (timestamp >= disc.actual_timestamp) {
                // Apply cumulative correction
                correction -= disc.gap_us;
            }
        }

        // Apply correction with saturation
        if (correction < 0 and @as(u64, @intCast(-correction)) > timestamp) {
            return 0;
        }
        return @intCast(@as(i64, @intCast(timestamp)) + correction);
    }

    /// Get discontinuity summary
    pub fn getSummary(self: *const Self) DiscontinuitySummary {
        var forward_jumps: u32 = 0;
        var backward_jumps: u32 = 0;
        var missing_frames: u32 = 0;
        var wraps: u32 = 0;
        var total_gap: i64 = 0;

        for (self.discontinuities.items) |disc| {
            total_gap += disc.gap_us;
            switch (disc.type) {
                .forward_jump => forward_jumps += 1,
                .backward_jump => backward_jumps += 1,
                .missing_frames => missing_frames += 1,
                .wrap_around => wraps += 1,
            }
        }

        return .{
            .total_discontinuities = @intCast(self.discontinuities.items.len),
            .forward_jumps = forward_jumps,
            .backward_jumps = backward_jumps,
            .missing_frame_events = missing_frames,
            .wrap_arounds = wraps,
            .total_gap_us = total_gap,
        };
    }

    pub const DiscontinuitySummary = struct {
        total_discontinuities: u32,
        forward_jumps: u32,
        backward_jumps: u32,
        missing_frame_events: u32,
        wrap_arounds: u32,
        total_gap_us: i64,
    };
};

// ============================================================================
// Robustness Manager
// ============================================================================

/// Central manager for all robustness features
pub const RobustnessManager = struct {
    allocator: std.mem.Allocator,
    corruption_handler: CorruptionHandler,
    vfr_handler: VfrHandler,
    large_file_handler: LargeFileHandler,
    timecode_handler: TimecodeDiscontinuityHandler,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .corruption_handler = CorruptionHandler.init(allocator),
            .vfr_handler = VfrHandler.init(allocator),
            .large_file_handler = LargeFileHandler.init(allocator),
            .timecode_handler = TimecodeDiscontinuityHandler.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.corruption_handler.deinit();
        self.vfr_handler.deinit();
        self.timecode_handler.deinit();
    }

    /// Configure from file analysis
    pub fn configureFromFile(self: *Self, file_size: u64) void {
        self.large_file_handler.setFileSize(file_size);
    }

    /// Get overall health report
    pub fn getHealthReport(self: *Self) !HealthReport {
        return .{
            .corruption = self.corruption_handler.getSummary(),
            .vfr = try self.vfr_handler.analyze(),
            .large_file = self.large_file_handler.requiresLargeFileSupport(),
            .timecode = self.timecode_handler.getSummary(),
        };
    }

    pub const HealthReport = struct {
        corruption: CorruptionHandler.CorruptionSummary,
        vfr: VfrHandler.VfrAnalysis,
        large_file: bool,
        timecode: TimecodeDiscontinuityHandler.DiscontinuitySummary,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "CorruptionHandler basic" {
    const allocator = std.testing.allocator;
    var handler = CorruptionHandler.init(allocator);
    defer handler.deinit();

    try handler.reportCorruption(100, 200, .invalid_frame_data, .moderate);
    try std.testing.expect(handler.shouldContinue());

    const summary = handler.getSummary();
    try std.testing.expectEqual(@as(u32, 1), summary.total_corruption_regions);
    try std.testing.expect(summary.is_recoverable);
}

test "VfrHandler detection" {
    const allocator = std.testing.allocator;
    var handler = VfrHandler.init(allocator);
    defer handler.deinit();

    // Add constant frame rate timestamps (30fps = 33333us per frame)
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try handler.recordFrameTime(i * 33333);
    }

    const analysis = try handler.analyze();
    try std.testing.expect(!analysis.is_vfr);
}

test "LargeFileHandler strategy" {
    const allocator = std.testing.allocator;
    var handler = LargeFileHandler.init(allocator);

    // Small file
    handler.setFileSize(500 * 1024 * 1024); // 500MB
    try std.testing.expect(!handler.requiresLargeFileSupport());
    try std.testing.expectEqual(LargeFileHandler.ReadStrategy.ReadMethod.full_load, handler.getReadStrategy().method);

    // Large file
    handler.setFileSize(10 * LargeFileHandler.SIZE_4GB);
    try std.testing.expect(handler.requiresLargeFileSupport());
    try std.testing.expectEqual(LargeFileHandler.ReadStrategy.ReadMethod.chunked_streaming, handler.getReadStrategy().method);
}

test "TimecodeDiscontinuityHandler" {
    const allocator = std.testing.allocator;
    var handler = TimecodeDiscontinuityHandler.init(allocator);
    defer handler.deinit();

    const frame_duration: u64 = 33333; // 30fps

    // Normal progression
    _ = try handler.checkTimestamp(0, frame_duration, 0);
    _ = try handler.checkTimestamp(33333, frame_duration, 1);
    _ = try handler.checkTimestamp(66666, frame_duration, 2);

    // Forward jump (missing frames)
    const disc = try handler.checkTimestamp(200000, frame_duration, 3);
    try std.testing.expect(disc != null);

    const summary = handler.getSummary();
    try std.testing.expectEqual(@as(u32, 1), summary.total_discontinuities);
}
