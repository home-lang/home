// Home Video Library - Media Probing
// Extract detailed information about video/audio files

const std = @import("std");
const core = @import("../core.zig");
const format_detection = @import("../containers/format_detection.zig");

/// Media stream information
pub const StreamInfo = struct {
    index: u32,
    type: StreamType,
    codec: []const u8,
    codec_tag: u32 = 0,
    duration: ?core.Duration = null,
    bit_rate: ?u32 = null,
    language: ?[]const u8 = null,
    title: ?[]const u8 = null,
    default: bool = false,
    forced: bool = false,

    // Video-specific
    width: ?u32 = null,
    height: ?u32 = null,
    fps: ?core.Rational = null,
    pixel_format: ?core.PixelFormat = null,
    color_space: ?[]const u8 = null,
    color_range: ?[]const u8 = null,
    has_b_frames: bool = false,
    level: ?u8 = null,
    profile: ?[]const u8 = null,

    // Audio-specific
    sample_rate: ?u32 = null,
    channels: ?u16 = null,
    channel_layout: ?[]const u8 = null,
    sample_format: ?core.AudioSampleFormat = null,
    bits_per_sample: ?u8 = null,

    pub const StreamType = enum {
        video,
        audio,
        subtitle,
        data,
        attachment,
        unknown,
    };
};

/// Complete media file information
pub const MediaInfo = struct {
    container_format: format_detection.ContainerFormat,
    duration: ?core.Duration = null,
    start_time: ?core.Timestamp = null,
    bit_rate: ?u32 = null,
    file_size: ?u64 = null,
    streams: []StreamInfo,
    metadata: std.StringHashMap([]const u8),
    chapters: []Chapter,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        for (self.streams) |stream| {
            self.allocator.free(stream.codec);
            if (stream.language) |lang| self.allocator.free(lang);
            if (stream.title) |title| self.allocator.free(title);
            if (stream.color_space) |cs| self.allocator.free(cs);
            if (stream.color_range) |cr| self.allocator.free(cr);
            if (stream.profile) |prof| self.allocator.free(prof);
            if (stream.channel_layout) |layout| self.allocator.free(layout);
        }
        self.allocator.free(self.streams);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();

        for (self.chapters) |chapter| {
            if (chapter.title) |title| self.allocator.free(title);
        }
        self.allocator.free(self.chapters);
    }

    pub fn format(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try result.writer().print("Container: {s}\n", .{@tagName(self.container_format)});

        if (self.duration) |dur| {
            const seconds = @as(f64, @floatFromInt(dur.toMicroseconds())) / 1_000_000.0;
            try result.writer().print("Duration: {d:.2}s\n", .{seconds});
        }

        if (self.bit_rate) |br| {
            try result.writer().print("Bitrate: {d} bps\n", .{br});
        }

        if (self.file_size) |size| {
            const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
            try result.writer().print("File Size: {d:.2} MB\n", .{mb});
        }

        try result.writer().print("\nStreams ({d}):\n", .{self.streams.len});
        for (self.streams) |stream| {
            try result.writer().print("  #{d} [{s}] {s}", .{
                stream.index,
                @tagName(stream.type),
                stream.codec,
            });

            if (stream.type == .video) {
                if (stream.width) |w| {
                    if (stream.height) |h| {
                        try result.writer().print(" {d}x{d}", .{ w, h });
                    }
                }
                if (stream.fps) |fps| {
                    try result.writer().print(" @{d}/{d}fps", .{ fps.num, fps.den });
                }
            } else if (stream.type == .audio) {
                if (stream.sample_rate) |sr| {
                    try result.writer().print(" {d}Hz", .{sr});
                }
                if (stream.channels) |ch| {
                    try result.writer().print(" {d}ch", .{ch});
                }
            }

            try result.appendSlice("\n");
        }

        if (self.metadata.count() > 0) {
            try result.appendSlice("\nMetadata:\n");
            var iter = self.metadata.iterator();
            while (iter.next()) |entry| {
                try result.writer().print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        return result.toOwnedSlice();
    }

    pub const Chapter = struct {
        start: core.Timestamp,
        end: core.Timestamp,
        title: ?[]const u8 = null,
    };
};

/// Media prober
pub const Prober = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn probeFile(self: *Self, file_path: []const u8) !MediaInfo {
        // Open file
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Get file size
        const file_size = try file.getEndPos();

        // Read header for format detection
        var header_buf: [4096]u8 = undefined;
        const header_len = try file.read(&header_buf);

        // Detect container format
        const detection = format_detection.detectFromMagicBytes(header_buf[0..header_len]);

        var info = MediaInfo{
            .container_format = detection.format,
            .file_size = file_size,
            .streams = &[_]StreamInfo{},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
            .chapters = &[_]MediaInfo.Chapter{},
            .allocator = self.allocator,
        };

        // Parse format-specific details
        switch (detection.format) {
            .mp4, .quicktime => try self.probeMP4(file, &info),
            .webm, .matroska => try self.probeMatroska(file, &info),
            .avi => try self.probeAVI(file, &info),
            else => {},
        }

        return info;
    }

    fn probeMP4(self: *Self, file: std.fs.File, info: *MediaInfo) !void {
        // Reset to start
        try file.seekTo(0);

        var streams = std.ArrayList(StreamInfo).init(self.allocator);
        errdefer streams.deinit();

        var stream_index: u32 = 0;

        // Parse MP4 boxes
        var buf: [8]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read < 8) break;

            const size = std.mem.readInt(u32, buf[0..4], .big);
            const box_type = buf[4..8];

            if (size == 0) break; // Extends to end of file
            if (size == 1) {
                // 64-bit size follows
                var size64_buf: [8]u8 = undefined;
                _ = try file.read(&size64_buf);
                // Handle 64-bit box size
                try file.seekBy(@intCast(std.mem.readInt(u64, &size64_buf, .big) - 16));
                continue;
            }

            // Parse specific boxes
            if (std.mem.eql(u8, box_type, "moov")) {
                // Movie metadata box - contains track info
                const moov_data = try self.allocator.alloc(u8, size - 8);
                defer self.allocator.free(moov_data);
                _ = try file.read(moov_data);

                // Parse mvhd for duration and timescale
                if (std.mem.indexOf(u8, moov_data, "mvhd")) |mvhd_pos| {
                    if (mvhd_pos + 24 < moov_data.len) {
                        const timescale = std.mem.readInt(u32, moov_data[mvhd_pos + 12 ..][0..4], .big);
                        const duration_units = std.mem.readInt(u32, moov_data[mvhd_pos + 16 ..][0..4], .big);
                        if (timescale > 0) {
                            const duration_us = (@as(u64, duration_units) * 1_000_000) / timescale;
                            info.duration = core.Duration.fromMicroseconds(duration_us);
                        }
                    }
                }

                // Parse trak boxes for streams
                var search_pos: usize = 0;
                while (std.mem.indexOfPos(u8, moov_data, search_pos, "trak")) |trak_pos| {
                    var stream = StreamInfo{
                        .index = stream_index,
                        .type = .unknown,
                        .codec = try self.allocator.dupe(u8, "unknown"),
                    };

                    // Determine if video or audio by looking for vmhd/smhd
                    if (std.mem.indexOfPos(u8, moov_data, trak_pos, "vmhd")) |_| {
                        stream.type = .video;
                        stream.codec = try self.allocator.dupe(u8, "h264"); // Simplified

                        // Try to extract resolution from tkhd
                        if (std.mem.indexOfPos(u8, moov_data, trak_pos, "tkhd")) |tkhd_pos| {
                            if (tkhd_pos + 84 < moov_data.len) {
                                const width_fixed = std.mem.readInt(u32, moov_data[tkhd_pos + 76 ..][0..4], .big);
                                const height_fixed = std.mem.readInt(u32, moov_data[tkhd_pos + 80 ..][0..4], .big);
                                stream.width = width_fixed >> 16;
                                stream.height = height_fixed >> 16;
                            }
                        }
                    } else if (std.mem.indexOfPos(u8, moov_data, trak_pos, "smhd")) |_| {
                        stream.type = .audio;
                        stream.codec = try self.allocator.dupe(u8, "aac"); // Simplified
                        stream.sample_rate = 48000; // Simplified
                        stream.channels = 2; // Simplified
                    }

                    try streams.append(stream);
                    stream_index += 1;
                    search_pos = trak_pos + 4;
                }
            } else if (std.mem.eql(u8, box_type, "mdat")) {
                // Media data - skip
                try file.seekBy(@intCast(size - 8));
            } else {
                // Skip unknown box
                try file.seekBy(@intCast(size - 8));
            }
        }

        info.streams = try streams.toOwnedSlice();
    }

    fn probeMatroska(self: *Self, file: std.fs.File, info: *MediaInfo) !void {
        try file.seekTo(0);

        var streams = std.ArrayList(StreamInfo).init(self.allocator);
        errdefer streams.deinit();

        // Read EBML header
        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        // Look for Segment element (0x18538067)
        if (std.mem.indexOf(u8, header[0..header_len], &[_]u8{ 0x18, 0x53, 0x80, 0x67 })) |segment_pos| {
            // Parse segment
            var search_pos: usize = segment_pos + 4;

            // Look for Duration element (0x4489)
            if (std.mem.indexOfPos(u8, header[0..header_len], search_pos, &[_]u8{ 0x44, 0x89 })) |dur_pos| {
                if (dur_pos + 10 < header_len) {
                    const duration_ms_float = std.mem.readInt(u64, header[dur_pos + 3 ..][0..8], .big);
                    const duration_float: f64 = @bitCast(duration_ms_float);
                    info.duration = core.Duration.fromMicroseconds(@intFromFloat(duration_float * 1000.0));
                }
            }

            // Look for Tracks element (0x1654AE6B)
            if (std.mem.indexOfPos(u8, header[0..header_len], search_pos, &[_]u8{ 0x16, 0x54, 0xAE, 0x6B })) |_| {
                // Simplified: assume one video and one audio track
                var video_stream = StreamInfo{
                    .index = 0,
                    .type = .video,
                    .codec = try self.allocator.dupe(u8, "vp9"),
                    .width = 1920,
                    .height = 1080,
                };
                try streams.append(video_stream);

                var audio_stream = StreamInfo{
                    .index = 1,
                    .type = .audio,
                    .codec = try self.allocator.dupe(u8, "opus"),
                    .sample_rate = 48000,
                    .channels = 2,
                };
                try streams.append(audio_stream);
            }
        }

        info.streams = try streams.toOwnedSlice();
    }

    fn probeAVI(self: *Self, file: std.fs.File, info: *MediaInfo) !void {
        try file.seekTo(0);

        var streams = std.ArrayList(StreamInfo).init(self.allocator);
        errdefer streams.deinit();

        // Read RIFF header
        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        if (header_len < 12) return error.InvalidAvi;

        // Check for RIFF...AVI header
        if (!std.mem.eql(u8, header[0..4], "RIFF")) return error.InvalidAvi;
        if (!std.mem.eql(u8, header[8..12], "AVI ")) return error.InvalidAvi;

        // Look for hdrl (header list)
        if (std.mem.indexOf(u8, header[0..header_len], "hdrl")) |hdrl_pos| {
            // Parse avih (AVI header)
            if (std.mem.indexOfPos(u8, header[0..header_len], hdrl_pos, "avih")) |avih_pos| {
                if (avih_pos + 40 < header_len) {
                    const us_per_frame = std.mem.readInt(u32, header[avih_pos + 8 ..][0..4], .little);
                    const total_frames = std.mem.readInt(u32, header[avih_pos + 16 ..][0..4], .little);
                    const width = std.mem.readInt(u32, header[avih_pos + 32 ..][0..4], .little);
                    const height = std.mem.readInt(u32, header[avih_pos + 36 ..][0..4], .little);

                    // Calculate duration
                    if (us_per_frame > 0) {
                        const duration_us = @as(u64, total_frames) * us_per_frame;
                        info.duration = core.Duration.fromMicroseconds(duration_us);
                    }

                    // Add video stream
                    var video_stream = StreamInfo{
                        .index = 0,
                        .type = .video,
                        .codec = try self.allocator.dupe(u8, "mjpeg"), // Simplified
                        .width = width,
                        .height = height,
                    };
                    if (us_per_frame > 0) {
                        video_stream.fps = core.Rational{
                            .num = 1_000_000,
                            .den = us_per_frame,
                        };
                    }
                    try streams.append(video_stream);
                }
            }

            // Look for strl (stream list) for audio
            if (std.mem.indexOfPos(u8, header[0..header_len], hdrl_pos, "strl")) |strl_pos| {
                if (std.mem.indexOfPos(u8, header[0..header_len], strl_pos, "auds")) |_| {
                    var audio_stream = StreamInfo{
                        .index = 1,
                        .type = .audio,
                        .codec = try self.allocator.dupe(u8, "pcm"),
                        .sample_rate = 44100, // Simplified
                        .channels = 2, // Simplified
                    };
                    try streams.append(audio_stream);
                }
            }
        }

        info.streams = try streams.toOwnedSlice();
    }
};

/// Quick info extraction without full parsing
pub const QuickProbe = struct {
    const Self = @This();

    pub fn getResolution(file_path: []const u8) !struct { width: u32, height: u32 } {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Read header
        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        // Detect format and extract resolution
        const detection = format_detection.detectFromMagicBytes(header[0..header_len]);

        switch (detection.format) {
            .mp4, .quicktime => {
                // Look for tkhd box with resolution
                if (std.mem.indexOf(u8, header[0..header_len], "tkhd")) |tkhd_pos| {
                    if (tkhd_pos + 84 < header_len) {
                        const width_fixed = std.mem.readInt(u32, header[tkhd_pos + 76 ..][0..4], .big);
                        const height_fixed = std.mem.readInt(u32, header[tkhd_pos + 80 ..][0..4], .big);
                        return .{
                            .width = width_fixed >> 16,
                            .height = height_fixed >> 16,
                        };
                    }
                }
            },
            .avi => {
                // Look for avih header
                if (std.mem.indexOf(u8, header[0..header_len], "avih")) |avih_pos| {
                    if (avih_pos + 40 < header_len) {
                        const width = std.mem.readInt(u32, header[avih_pos + 32 ..][0..4], .little);
                        const height = std.mem.readInt(u32, header[avih_pos + 36 ..][0..4], .little);
                        return .{ .width = width, .height = height };
                    }
                }
            },
            else => {},
        }

        return .{ .width = 1920, .height = 1080 }; // Default fallback
    }

    pub fn getDuration(file_path: []const u8) !core.Duration {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        const detection = format_detection.detectFromMagicBytes(header[0..header_len]);

        switch (detection.format) {
            .mp4, .quicktime => {
                // Look for mvhd box
                if (std.mem.indexOf(u8, header[0..header_len], "mvhd")) |mvhd_pos| {
                    if (mvhd_pos + 24 < header_len) {
                        const timescale = std.mem.readInt(u32, header[mvhd_pos + 12 ..][0..4], .big);
                        const duration_units = std.mem.readInt(u32, header[mvhd_pos + 16 ..][0..4], .big);
                        if (timescale > 0) {
                            const duration_us = (@as(u64, duration_units) * 1_000_000) / timescale;
                            return core.Duration.fromMicroseconds(duration_us);
                        }
                    }
                }
            },
            .avi => {
                // Look for avih header
                if (std.mem.indexOf(u8, header[0..header_len], "avih")) |avih_pos| {
                    if (avih_pos + 24 < header_len) {
                        const us_per_frame = std.mem.readInt(u32, header[avih_pos + 8 ..][0..4], .little);
                        const total_frames = std.mem.readInt(u32, header[avih_pos + 16 ..][0..4], .little);
                        if (us_per_frame > 0) {
                            const duration_us = @as(u64, total_frames) * us_per_frame;
                            return core.Duration.fromMicroseconds(duration_us);
                        }
                    }
                }
            },
            else => {},
        }

        return core.Duration.fromMicroseconds(0);
    }

    pub fn getCodec(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        const detection = format_detection.detectFromMagicBytes(header[0..header_len]);

        switch (detection.format) {
            .mp4, .quicktime => {
                // Look for stsd box containing codec
                if (std.mem.indexOf(u8, header[0..header_len], "avc1")) |_| {
                    return try allocator.dupe(u8, "h264");
                } else if (std.mem.indexOf(u8, header[0..header_len], "hvc1")) |_| {
                    return try allocator.dupe(u8, "hevc");
                } else if (std.mem.indexOf(u8, header[0..header_len], "av01")) |_| {
                    return try allocator.dupe(u8, "av1");
                }
            },
            .webm, .matroska => {
                if (std.mem.indexOf(u8, header[0..header_len], "V_VP9")) |_| {
                    return try allocator.dupe(u8, "vp9");
                } else if (std.mem.indexOf(u8, header[0..header_len], "V_VP8")) |_| {
                    return try allocator.dupe(u8, "vp8");
                } else if (std.mem.indexOf(u8, header[0..header_len], "V_AV1")) |_| {
                    return try allocator.dupe(u8, "av1");
                }
            },
            else => {},
        }

        return try allocator.dupe(u8, "unknown");
    }

    pub fn getFrameCount(file_path: []const u8) !u64 {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var header: [4096]u8 = undefined;
        const header_len = try file.read(&header);

        const detection = format_detection.detectFromMagicBytes(header[0..header_len]);

        switch (detection.format) {
            .avi => {
                // Look for avih header
                if (std.mem.indexOf(u8, header[0..header_len], "avih")) |avih_pos| {
                    if (avih_pos + 20 < header_len) {
                        const total_frames = std.mem.readInt(u32, header[avih_pos + 16 ..][0..4], .little);
                        return total_frames;
                    }
                }
            },
            else => {
                // For other formats, estimate from duration and fps
                // This is simplified - real implementation would count frames
            },
        }

        return 0;
    }
};

/// Bitrate analyzer
pub const BitrateAnalyzer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const BitrateStats = struct {
        average: u32,
        min: u32,
        max: u32,
        variance: f64,
        samples: []u32,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn analyze(self: *Self, file_path: []const u8, sample_interval: core.Duration) !BitrateStats {
        _ = self;
        _ = file_path;
        _ = sample_interval;

        // Placeholder - would sample bitrate throughout file
        return .{
            .average = 5_000_000, // 5 Mbps
            .min = 3_000_000,
            .max = 8_000_000,
            .variance = 1_000_000.0,
            .samples = &[_]u32{},
        };
    }
};
