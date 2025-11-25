// Home Video Library - I/O Options
// Configuration for input/output operations

const std = @import("std");

// ============================================================================
// Input Options
// ============================================================================

pub const InputOptions = struct {
    // Format hints
    format_hint: ?[]const u8 = null, // Force specific input format
    codec_hint: ?[]const u8 = null, // Force specific codec

    // Buffering
    buffer_size: usize = 64 * 1024, // 64KB default
    enable_buffering: bool = true,
    read_ahead: bool = true,

    // Seeking
    accurate_seek: bool = true, // Seek to exact position vs nearest keyframe
    seek_threshold: u64 = 10_000_000, // 10 seconds in microseconds

    // Network-specific
    network_timeout: u32 = 30_000, // milliseconds
    max_retries: u8 = 3,
    retry_delay: u32 = 1000, // milliseconds
    follow_redirects: bool = true,
    max_redirects: u8 = 5,
    http_user_agent: ?[]const u8 = null,

    // Performance
    probe_size: usize = 5 * 1024 * 1024, // 5MB for format detection
    analyze_duration: u64 = 5_000_000, // 5 seconds in microseconds
    fps_probe_size: u32 = 50, // Number of frames to analyze for FPS detection

    // Security
    allow_local_files: bool = true,
    allow_network: bool = true,
    allow_pipes: bool = true,

    // Advanced
    thread_count: ?u32 = null, // Decoder threads (null = auto)
    skip_corrupted_frames: bool = true,
    error_detection: ErrorDetection = .normal,

    pub const ErrorDetection = enum {
        ignore, // Ignore errors
        normal, // Report errors but continue
        strict, // Fail on any error
        very_strict, // Extremely strict validation
    };

    pub fn default() InputOptions {
        return .{};
    }

    pub fn streaming() InputOptions {
        return .{
            .buffer_size = 256 * 1024, // Larger buffer
            .accurate_seek = false, // Faster seeking
            .network_timeout = 10_000, // Shorter timeout
            .fps_probe_size = 10, // Quick FPS detection
        };
    }

    pub fn reliable() InputOptions {
        return .{
            .max_retries = 10,
            .retry_delay = 2000,
            .error_detection = .strict,
            .skip_corrupted_frames = false,
        };
    }

    pub fn fast() InputOptions {
        return .{
            .buffer_size = 128 * 1024,
            .accurate_seek = false,
            .probe_size = 1024 * 1024, // 1MB
            .analyze_duration = 1_000_000, // 1 second
            .fps_probe_size = 10,
        };
    }
};

// ============================================================================
// Output Options
// ============================================================================

pub const OutputOptions = struct {
    // Format/Codec
    format: ?[]const u8 = null, // Output container format
    video_codec: ?[]const u8 = null,
    audio_codec: ?[]const u8 = null,
    subtitle_codec: ?[]const u8 = null,

    // Buffering
    buffer_size: usize = 64 * 1024,
    enable_buffering: bool = true,

    // Quality
    overwrite: bool = false,
    create_directories: bool = true,

    // Streaming
    streaming: bool = false, // Optimize for streaming
    movflags: ?[]const u8 = null, // MP4 muxer flags (e.g., "faststart")

    // Metadata
    preserve_metadata: bool = true,
    preserve_timestamps: bool = true,

    // Performance
    write_buffer_size: usize = 256 * 1024, // 256KB write buffer
    async_write: bool = false, // Use async I/O if available

    // Security
    max_file_size: ?u64 = null, // Maximum output file size
    max_duration: ?u64 = null, // Maximum duration in microseconds

    // Advanced
    thread_count: ?u32 = null, // Encoder threads (null = auto)
    error_resilience: bool = true,

    pub fn default() OutputOptions {
        return .{};
    }

    pub fn streaming_optimized() OutputOptions {
        return .{
            .streaming = true,
            .movflags = "frag_keyframe+empty_moov",
            .write_buffer_size = 512 * 1024,
            .async_write = true,
        };
    }

    pub fn fast_start() OutputOptions {
        return .{
            .movflags = "faststart", // Move moov atom to beginning
            .write_buffer_size = 512 * 1024,
        };
    }

    pub fn high_quality() OutputOptions {
        return .{
            .error_resilience = true,
            .preserve_metadata = true,
            .preserve_timestamps = true,
        };
    }
};

// ============================================================================
// I/O Statistics
// ============================================================================

pub const IOStatistics = struct {
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    read_operations: u64 = 0,
    write_operations: u64 = 0,
    seek_operations: u64 = 0,
    errors: u64 = 0,
    start_time: i64,
    last_update: i64,

    const Self = @This();

    pub fn init() Self {
        const now = std.time.timestamp();
        return .{
            .start_time = now,
            .last_update = now,
        };
    }

    pub fn recordRead(self: *Self, bytes: u64) void {
        self.bytes_read += bytes;
        self.read_operations += 1;
        self.last_update = std.time.timestamp();
    }

    pub fn recordWrite(self: *Self, bytes: u64) void {
        self.bytes_written += bytes;
        self.write_operations += 1;
        self.last_update = std.time.timestamp();
    }

    pub fn recordSeek(self: *Self) void {
        self.seek_operations += 1;
        self.last_update = std.time.timestamp();
    }

    pub fn recordError(self: *Self) void {
        self.errors += 1;
        self.last_update = std.time.timestamp();
    }

    pub fn getReadSpeed(self: *const Self) f64 {
        const elapsed = @as(f64, @floatFromInt(self.last_update - self.start_time));
        if (elapsed == 0) return 0;
        return @as(f64, @floatFromInt(self.bytes_read)) / elapsed;
    }

    pub fn getWriteSpeed(self: *const Self) f64 {
        const elapsed = @as(f64, @floatFromInt(self.last_update - self.start_time));
        if (elapsed == 0) return 0;
        return @as(f64, @floatFromInt(self.bytes_written)) / elapsed;
    }

    pub fn getElapsedSeconds(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.last_update - self.start_time));
    }

    pub fn format(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const read_speed = self.getReadSpeed();
        const write_speed = self.getWriteSpeed();
        const elapsed = self.getElapsedSeconds();

        return try std.fmt.allocPrint(
            allocator,
            \\I/O Statistics:
            \\  Bytes Read:        {d} ({d:.2} MB)
            \\  Bytes Written:     {d} ({d:.2} MB)
            \\  Read Operations:   {d}
            \\  Write Operations:  {d}
            \\  Seek Operations:   {d}
            \\  Errors:            {d}
            \\  Elapsed Time:      {d:.2}s
            \\  Read Speed:        {d:.2} bytes/sec
            \\  Write Speed:       {d:.2} bytes/sec
            \\
            ,
            .{
                self.bytes_read,
                @as(f64, @floatFromInt(self.bytes_read)) / (1024.0 * 1024.0),
                self.bytes_written,
                @as(f64, @floatFromInt(self.bytes_written)) / (1024.0 * 1024.0),
                self.read_operations,
                self.write_operations,
                self.seek_operations,
                self.errors,
                elapsed,
                read_speed,
                write_speed,
            },
        );
    }
};

// ============================================================================
// Protocol Options
// ============================================================================

pub const ProtocolOptions = struct {
    // HTTP/HTTPS
    http: HTTPOptions = .{},

    // RTSP
    rtsp: RTSPOptions = .{},

    // File
    file: FileOptions = .{},

    pub const HTTPOptions = struct {
        user_agent: []const u8 = "Home Video Library/1.0",
        headers: ?std.StringHashMap([]const u8) = null,
        cookies: ?[]const u8 = null,
        reconnect: bool = true,
        reconnect_at_eof: bool = false,
        reconnect_delay: u32 = 1000, // milliseconds
        icy_metadata: bool = true, // Parse ICY/Shoutcast metadata
    };

    pub const RTSPOptions = struct {
        transport: Transport = .udp,
        rtcp_port: ?u16 = null,
        timeout: u32 = 30_000, // milliseconds
        reorder_queue_size: u32 = 500, // RTP packet reordering

        pub const Transport = enum {
            udp,
            tcp,
            udp_multicast,
            http,
        };
    };

    pub const FileOptions = struct {
        follow_symlinks: bool = true,
        truncate: bool = false,
        append: bool = false,
        direct_io: bool = false, // Use O_DIRECT if available
    };
};

// ============================================================================
// Progress Reporting
// ============================================================================

pub const ProgressReporter = struct {
    callback: *const fn (ProgressInfo) void,
    interval: u64 = 1_000_000, // Report every 1 second
    last_report: i64 = 0,

    const Self = @This();

    pub const ProgressInfo = struct {
        bytes_processed: u64,
        total_bytes: ?u64,
        frames_processed: u64,
        total_frames: ?u64,
        elapsed_us: u64,
        estimated_remaining_us: ?u64,
        speed_bps: u64,
    };

    pub fn init(callback: *const fn (ProgressInfo) void) Self {
        return .{
            .callback = callback,
            .last_report = std.time.microTimestamp(),
        };
    }

    pub fn report(self: *Self, info: ProgressInfo) void {
        const now = std.time.microTimestamp();
        const elapsed = now - self.last_report;

        if (elapsed >= @as(i64, @intCast(self.interval))) {
            self.callback(info);
            self.last_report = now;
        }
    }

    pub fn forceReport(self: *Self, info: ProgressInfo) void {
        self.callback(info);
        self.last_report = std.time.microTimestamp();
    }
};
