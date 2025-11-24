// Home Audio Library - Batch Conversion Support
// Tools for batch processing and converting audio files

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Conversion job status
pub const JobStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,
};

/// Conversion job
pub const ConversionJob = struct {
    input_path: []const u8,
    output_path: []const u8,
    status: JobStatus,
    progress: f32, // 0.0 - 1.0
    error_message: ?[]const u8,

    // Timing
    start_time: ?i64,
    end_time: ?i64,

    pub fn deinit(self: *ConversionJob, allocator: Allocator) void {
        allocator.free(self.input_path);
        allocator.free(self.output_path);
        if (self.error_message) |msg| allocator.free(msg);
    }

    /// Get duration in seconds
    pub fn getDuration(self: ConversionJob) ?f64 {
        if (self.start_time != null and self.end_time != null) {
            return @as(f64, @floatFromInt(self.end_time.? - self.start_time.?)) / 1000.0;
        }
        return null;
    }
};

/// Batch conversion options
pub const BatchOptions = struct {
    // Output format
    output_format: OutputFormat = .wav,

    // Quality settings
    quality: QualityLevel = .high,
    sample_rate: ?u32 = null, // null = keep original
    channels: ?u8 = null, // null = keep original
    bit_depth: ?u8 = null, // null = keep original

    // Naming options
    output_dir: ?[]const u8 = null, // null = same as input
    preserve_structure: bool = true, // Preserve subdirectory structure
    name_pattern: []const u8 = "{name}", // {name}, {artist}, {album}, {track}

    // Processing options
    normalize: bool = false,
    normalize_target_db: f32 = -1.0,
    trim_silence: bool = false,
    fade_in_ms: f32 = 0,
    fade_out_ms: f32 = 0,

    // Behavior
    overwrite_existing: bool = false,
    skip_errors: bool = true,
    parallel_jobs: u8 = 1,
};

/// Output format
pub const OutputFormat = enum {
    wav,
    aiff,
    flac,
    mp3,
    aac,
    opus,
    ogg,

    pub fn getExtension(self: OutputFormat) []const u8 {
        return switch (self) {
            .wav => ".wav",
            .aiff => ".aiff",
            .flac => ".flac",
            .mp3 => ".mp3",
            .aac => ".m4a",
            .opus => ".opus",
            .ogg => ".ogg",
        };
    }
};

/// Quality level
pub const QualityLevel = enum {
    low,
    medium,
    high,
    best,
    lossless,

    pub fn getBitrate(self: QualityLevel) u32 {
        return switch (self) {
            .low => 64,
            .medium => 128,
            .high => 192,
            .best => 320,
            .lossless => 0, // Not applicable
        };
    }
};

/// Progress callback type
pub const ProgressCallback = *const fn (
    job_index: usize,
    total_jobs: usize,
    current_job: *const ConversionJob,
    user_data: ?*anyopaque,
) void;

/// Batch converter
pub const BatchConverter = struct {
    allocator: Allocator,
    options: BatchOptions,
    jobs: std.ArrayList(ConversionJob),

    // Callbacks
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,

    // Statistics
    completed_count: usize,
    failed_count: usize,
    skipped_count: usize,
    total_bytes_processed: u64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .options = .{},
            .jobs = .{},
            .progress_callback = null,
            .callback_user_data = null,
            .completed_count = 0,
            .failed_count = 0,
            .skipped_count = 0,
            .total_bytes_processed = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |*job| {
            job.deinit(self.allocator);
        }
        self.jobs.deinit(self.allocator);
    }

    /// Set batch options
    pub fn setOptions(self: *Self, options: BatchOptions) void {
        self.options = options;
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *Self, callback: ProgressCallback, user_data: ?*anyopaque) void {
        self.progress_callback = callback;
        self.callback_user_data = user_data;
    }

    /// Add a single file to the batch
    pub fn addFile(self: *Self, input_path: []const u8) !void {
        const output_path = try self.generateOutputPath(input_path);

        try self.jobs.append(self.allocator, ConversionJob{
            .input_path = try self.allocator.dupe(u8, input_path),
            .output_path = output_path,
            .status = .pending,
            .progress = 0,
            .error_message = null,
            .start_time = null,
            .end_time = null,
        });
    }

    /// Add files matching a glob pattern
    pub fn addGlob(self: *Self, pattern: []const u8) !void {
        _ = self;
        _ = pattern;
        // In real implementation, would use glob matching
        // For now, this is a placeholder
    }

    /// Add all files in a directory
    pub fn addDirectory(self: *Self, dir_path: []const u8, recursive: bool) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.basename);
                if (self.isAudioExtension(ext)) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.path });
                    defer self.allocator.free(full_path);
                    try self.addFile(full_path);
                }
            }

            if (!recursive and entry.kind == .directory) {
                continue;
            }
        }
    }

    fn isAudioExtension(self: *Self, ext: []const u8) bool {
        _ = self;
        const audio_exts = [_][]const u8{
            ".wav", ".mp3", ".flac", ".ogg", ".aac",
            ".m4a", ".aiff", ".aif",  ".opus", ".wma",
        };
        for (audio_exts) |audio_ext| {
            if (std.ascii.eqlIgnoreCase(ext, audio_ext)) {
                return true;
            }
        }
        return false;
    }

    fn generateOutputPath(self: *Self, input_path: []const u8) ![]u8 {
        const dirname = std.fs.path.dirname(input_path) orelse ".";
        const basename = std.fs.path.basename(input_path);
        const stem = std.fs.path.stem(basename);
        const new_ext = self.options.output_format.getExtension();

        const output_dir = self.options.output_dir orelse dirname;

        var new_name = try self.allocator.alloc(u8, stem.len + new_ext.len);
        @memcpy(new_name[0..stem.len], stem);
        @memcpy(new_name[stem.len..], new_ext);

        const output_path = try std.fs.path.join(self.allocator, &.{ output_dir, new_name });
        self.allocator.free(new_name);

        return output_path;
    }

    /// Start batch conversion
    pub fn start(self: *Self) !void {
        self.completed_count = 0;
        self.failed_count = 0;
        self.skipped_count = 0;
        self.total_bytes_processed = 0;

        for (self.jobs.items, 0..) |*job, i| {
            if (job.status == .pending) {
                try self.processJob(job, i);
            }
        }
    }

    fn processJob(self: *Self, job: *ConversionJob, index: usize) !void {
        job.status = .running;
        job.start_time = std.time.milliTimestamp();

        // Notify progress
        if (self.progress_callback) |callback| {
            callback(index, self.jobs.items.len, job, self.callback_user_data);
        }

        // Check if output exists
        if (!self.options.overwrite_existing) {
            if (std.fs.cwd().access(job.output_path, .{})) |_| {
                job.status = .skipped;
                job.error_message = try self.allocator.dupe(u8, "Output file exists");
                self.skipped_count += 1;
                return;
            } else |_| {}
        }

        // In real implementation, would perform actual conversion here
        // This is a placeholder that simulates the conversion
        job.progress = 1.0;
        job.status = .completed;
        job.end_time = std.time.milliTimestamp();
        self.completed_count += 1;

        // Final progress notification
        if (self.progress_callback) |callback| {
            callback(index, self.jobs.items.len, job, self.callback_user_data);
        }
    }

    /// Get batch statistics
    pub fn getStatistics(self: *Self) BatchStatistics {
        return BatchStatistics{
            .total_jobs = self.jobs.items.len,
            .completed = self.completed_count,
            .failed = self.failed_count,
            .skipped = self.skipped_count,
            .pending = self.jobs.items.len - self.completed_count - self.failed_count - self.skipped_count,
            .total_bytes_processed = self.total_bytes_processed,
        };
    }

    /// Clear all jobs
    pub fn clear(self: *Self) void {
        for (self.jobs.items) |*job| {
            job.deinit(self.allocator);
        }
        self.jobs.clearRetainingCapacity();
        self.completed_count = 0;
        self.failed_count = 0;
        self.skipped_count = 0;
    }

    /// Get job by index
    pub fn getJob(self: *Self, index: usize) ?*ConversionJob {
        if (index >= self.jobs.items.len) return null;
        return &self.jobs.items[index];
    }

    /// Get job count
    pub fn jobCount(self: *Self) usize {
        return self.jobs.items.len;
    }
};

/// Batch statistics
pub const BatchStatistics = struct {
    total_jobs: usize,
    completed: usize,
    failed: usize,
    skipped: usize,
    pending: usize,
    total_bytes_processed: u64,

    pub fn getProgressPercent(self: BatchStatistics) f32 {
        if (self.total_jobs == 0) return 100.0;
        return @as(f32, @floatFromInt(self.completed + self.failed + self.skipped)) /
            @as(f32, @floatFromInt(self.total_jobs)) * 100.0;
    }
};

/// Conversion preset
pub const ConversionPreset = enum {
    web_audio, // Small files for web
    podcast, // Podcast-optimized
    archive, // Lossless archive
    mobile, // Mobile-friendly

    pub fn getOptions(self: ConversionPreset) BatchOptions {
        return switch (self) {
            .web_audio => .{
                .output_format = .mp3,
                .quality = .medium,
                .sample_rate = 44100,
                .channels = 2,
                .normalize = true,
            },
            .podcast => .{
                .output_format = .mp3,
                .quality = .medium,
                .sample_rate = 44100,
                .channels = 1,
                .normalize = true,
                .normalize_target_db = -16,
            },
            .archive => .{
                .output_format = .flac,
                .quality = .lossless,
            },
            .mobile => .{
                .output_format = .aac,
                .quality = .high,
                .sample_rate = 44100,
            },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BatchConverter init" {
    const allocator = std.testing.allocator;

    var converter = BatchConverter.init(allocator);
    defer converter.deinit();

    try std.testing.expectEqual(@as(usize, 0), converter.jobCount());
}

test "BatchConverter addFile" {
    const allocator = std.testing.allocator;

    var converter = BatchConverter.init(allocator);
    defer converter.deinit();

    try converter.addFile("/path/to/audio.wav");
    try std.testing.expectEqual(@as(usize, 1), converter.jobCount());
}

test "BatchStatistics progressPercent" {
    const stats = BatchStatistics{
        .total_jobs = 10,
        .completed = 5,
        .failed = 1,
        .skipped = 1,
        .pending = 3,
        .total_bytes_processed = 0,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 70.0), stats.getProgressPercent(), 0.01);
}

test "ConversionPreset options" {
    const options = ConversionPreset.podcast.getOptions();
    try std.testing.expectEqual(OutputFormat.mp3, options.output_format);
    try std.testing.expectEqual(@as(u8, 1), options.channels.?);
}

test "OutputFormat extension" {
    try std.testing.expectEqualSlices(u8, ".mp3", OutputFormat.mp3.getExtension());
    try std.testing.expectEqualSlices(u8, ".flac", OutputFormat.flac.getExtension());
}
