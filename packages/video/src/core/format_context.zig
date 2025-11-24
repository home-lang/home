// Home Video Library - Format Context
// Muxer/demuxer state for container formats

const std = @import("std");
const types = @import("types.zig");
const packet_mod = @import("packet.zig");
const frame = @import("frame.zig");

pub const VideoFormat = types.VideoFormat;
pub const AudioFormat = types.AudioFormat;
pub const Rational = types.Rational;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Packet = packet_mod.Packet;
pub const Stream = packet_mod.Stream;
pub const MediaFile = packet_mod.MediaFile;
pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;

/// Seek flags
pub const SeekFlags = packed struct {
    backward: bool = false, // Seek to nearest keyframe before target
    forward: bool = false, // Seek to nearest keyframe after target
    byte: bool = false, // Seek by byte position instead of timestamp
    any: bool = false, // Seek to any frame (not just keyframes)
    frame: bool = false, // Seek by frame number
    _padding: u3 = 0,
};

/// Demuxer options
pub const DemuxerOptions = struct {
    /// Buffer size for reading
    buffer_size: usize = 65536,

    /// Analyze duration (microseconds) for format detection
    analyze_duration: u64 = 5_000_000, // 5 seconds

    /// Maximum analyze duration
    max_analyze_duration: u64 = 60_000_000, // 60 seconds

    /// Probe size for format detection
    probe_size: usize = 5_000_000, // 5 MB

    /// Maximum number of streams to detect
    max_streams: u32 = 32,

    /// Enable frame counting during demux
    count_frames: bool = false,

    /// Generate missing timestamps
    generate_pts: bool = true,
};

/// Muxer options
pub const MuxerOptions = struct {
    /// Write header immediately
    write_header: bool = true,

    /// Flush after each packet
    flush_packets: bool = false,

    /// Reserve space for moov atom at start (MP4 fast-start)
    reserve_index_space: bool = true,

    /// Fragment duration for fragmented formats
    fragment_duration: Duration = Duration.fromSeconds(2.0),

    /// Interleave packets by DTS
    interleave_packets: bool = true,

    /// Buffer size for writing
    buffer_size: usize = 65536,

    /// Auto-compute frame durations if missing
    auto_duration: bool = true,
};

/// Demuxer context (reading containers)
pub const DemuxerContext = struct {
    /// Media file info
    media_file: MediaFile,

    /// Options
    options: DemuxerOptions,

    /// Current read position
    position: u64 = 0,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Internal demuxer state (format-specific)
    state: ?*anyopaque = null,

    /// Has read header?
    header_read: bool = false,

    /// End of file reached?
    eof: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        media_file: MediaFile,
        options: DemuxerOptions,
    ) Self {
        return .{
            .media_file = media_file,
            .options = options,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.media_file.deinit();
        // Format-specific cleanup
    }

    /// Read the container header
    pub fn readHeader(self: *Self) !void {
        if (self.header_read) return;
        // Format-specific implementation
        self.header_read = true;
    }

    /// Read next packet from any stream
    pub fn readPacket(self: *Self) !?Packet {
        if (self.eof) return null;
        // Format-specific implementation
        return error.NotImplemented;
    }

    /// Read packet from specific stream
    pub fn readPacketFromStream(self: *Self, stream_index: u32) !?Packet {
        while (true) {
            const pkt = (try self.readPacket()) orelse return null;
            if (pkt.stream_index == stream_index) {
                return pkt;
            }
            // Wrong stream, free and continue
            var mut_pkt = pkt;
            mut_pkt.deinit();
        }
    }

    /// Seek to timestamp
    pub fn seek(self: *Self, timestamp: Timestamp, flags: SeekFlags) !void {
        _ = self;
        _ = timestamp;
        _ = flags;
        // Format-specific implementation
        return error.NotImplemented;
    }

    /// Seek to keyframe at or before timestamp
    pub fn seekToKeyFrame(self: *Self, timestamp: Timestamp) !void {
        return self.seek(timestamp, .{ .backward = true });
    }

    /// Get current position in microseconds
    pub fn tell(self: *const Self) Timestamp {
        return Timestamp.fromMicroseconds(@intCast(self.position));
    }

    /// Check if seekable
    pub fn isSeekable(self: *const Self) bool {
        return self.media_file.is_seekable;
    }
};

/// Muxer context (writing containers)
pub const MuxerContext = struct {
    /// Format to write
    format: VideoFormat,

    /// Streams to mux
    streams: []Stream,

    /// Options
    options: MuxerOptions,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Internal muxer state (format-specific)
    state: ?*anyopaque = null,

    /// Has written header?
    header_written: bool = false,

    /// Has written trailer?
    trailer_written: bool = false,

    /// Packet count
    packet_count: u64 = 0,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        format: VideoFormat,
        streams: []Stream,
        options: MuxerOptions,
    ) Self {
        return .{
            .format = format,
            .streams = streams,
            .options = options,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Don't free streams (caller owns them)
        // Format-specific cleanup
        _ = self;
    }

    /// Write the container header
    pub fn writeHeader(self: *Self) !void {
        if (self.header_written) return error.AlreadyWritten;
        // Format-specific implementation
        self.header_written = true;
    }

    /// Write a packet
    pub fn writePacket(self: *Self, pkt: *const Packet) !void {
        if (!self.header_written) return error.HeaderNotWritten;
        if (self.trailer_written) return error.TrailerAlreadyWritten;

        // Validate stream index
        if (pkt.stream_index >= self.streams.len) {
            return error.InvalidStreamIndex;
        }

        // Format-specific implementation
        self.packet_count += 1;
        return error.NotImplemented;
    }

    /// Write multiple packets (interleaved)
    pub fn writePackets(self: *Self, packets: []const Packet) !void {
        for (packets) |*pkt| {
            try self.writePacket(pkt);
        }
    }

    /// Write video frame (encodes to packet first)
    pub fn writeVideoFrame(
        self: *Self,
        stream_index: u32,
        video_frame: *const VideoFrame,
    ) !void {
        _ = self;
        _ = stream_index;
        _ = video_frame;
        // Requires encoder
        return error.NotImplemented;
    }

    /// Write audio frame (encodes to packet first)
    pub fn writeAudioFrame(
        self: *Self,
        stream_index: u32,
        audio_frame: *const AudioFrame,
    ) !void {
        _ = self;
        _ = stream_index;
        _ = audio_frame;
        // Requires encoder
        return error.NotImplemented;
    }

    /// Flush buffered packets
    pub fn flush(self: *Self) !void {
        // Format-specific implementation
        _ = self;
    }

    /// Write the container trailer
    pub fn writeTrailer(self: *Self) !void {
        if (!self.header_written) return error.HeaderNotWritten;
        if (self.trailer_written) return error.AlreadyWritten;

        // Format-specific implementation
        self.trailer_written = true;
    }

    /// Get stream by index
    pub fn getStream(self: *Self, index: u32) ?*Stream {
        if (index >= self.streams.len) return null;
        return &self.streams[index];
    }

    /// Get primary video stream index
    pub fn getPrimaryVideoStreamIndex(self: *const Self) ?u32 {
        for (self.streams, 0..) |*stream, i| {
            if (stream.stream_type == .video) {
                if (stream.disposition.is_default) return @intCast(i);
            }
        }
        for (self.streams, 0..) |*stream, i| {
            if (stream.stream_type == .video) return @intCast(i);
        }
        return null;
    }

    /// Get primary audio stream index
    pub fn getPrimaryAudioStreamIndex(self: *const Self) ?u32 {
        for (self.streams, 0..) |*stream, i| {
            if (stream.stream_type == .audio) {
                if (stream.disposition.is_default) return @intCast(i);
            }
        }
        for (self.streams, 0..) |*stream, i| {
            if (stream.stream_type == .audio) return @intCast(i);
        }
        return null;
    }
};

/// Container format detection
pub const FormatDetector = struct {
    pub fn detectFromBytes(data: []const u8) ?VideoFormat {
        if (data.len < 12) return null;

        // MP4/MOV - starts with ftyp
        if (data.len >= 8 and
            std.mem.eql(u8, data[4..8], "ftyp"))
        {
            if (data.len >= 12) {
                const brand = data[8..12];
                if (std.mem.eql(u8, brand, "qt  ")) return .mov;
                if (std.mem.eql(u8, brand, "isom")) return .mp4;
                if (std.mem.eql(u8, brand, "mp41")) return .mp4;
                if (std.mem.eql(u8, brand, "mp42")) return .mp4;
                if (std.mem.eql(u8, brand, "M4A ")) return .mp4;
                if (std.mem.eql(u8, brand, "M4V ")) return .mp4;
            }
            return .mp4;
        }

        // WebM/MKV - EBML header
        if (data.len >= 4 and
            std.mem.eql(u8, data[0..4], "\x1a\x45\xdf\xa3"))
        {
            return .webm; // Could be .mkv, need to check DocType
        }

        // AVI - RIFF....AVI
        if (data.len >= 12 and
            std.mem.eql(u8, data[0..4], "RIFF") and
            std.mem.eql(u8, data[8..12], "AVI "))
        {
            return .avi;
        }

        // FLV
        if (data.len >= 3 and
            std.mem.eql(u8, data[0..3], "FLV"))
        {
            return .flv;
        }

        // MPEG-TS
        if (data.len >= 188 and data[0] == 0x47) {
            // Check sync byte at multiples of 188
            if (data.len >= 376 and data[188] == 0x47) {
                return .ts;
            }
        }

        return null;
    }

    pub fn detectFromPath(path: []const u8) ?VideoFormat {
        var ext_start: ?usize = null;
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '.') {
                ext_start = i;
                break;
            }
            if (path[i] == '/' or path[i] == '\\') break;
        }

        if (ext_start) |start| {
            const ext = path[start..];
            return VideoFormat.fromExtension(ext);
        }

        return null;
    }
};

/// Best codec selection for format
pub fn getBestVideoCodec(format: VideoFormat) types.VideoCodec {
    return switch (format) {
        .mp4, .mov => .h264,
        .webm, .mkv => .vp9,
        .avi => .mjpeg,
        .flv => .h264,
        .ts, .m2ts => .h264,
        .unknown => .h264,
    };
}

pub fn getBestAudioCodec(format: VideoFormat) types.AudioCodec {
    return switch (format) {
        .mp4, .mov => .aac,
        .webm, .mkv => .opus,
        .avi => .mp3,
        .flv => .aac,
        .ts, .m2ts => .aac,
        .unknown => .aac,
    };
}
