// Home Video Library - Container Remuxing
// Move streams between containers without re-encoding

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Stream Types
// ============================================================================

pub const StreamType = enum {
    video,
    audio,
    subtitle,
    data,
};

pub const VideoCodec = enum {
    h264,
    h265,
    h266,
    vp8,
    vp9,
    av1,
    unknown,
};

pub const AudioCodec = enum {
    aac,
    mp3,
    opus,
    vorbis,
    flac,
    pcm,
    ac3,
    eac3,
    dts,
    unknown,
};

pub const SubtitleCodec = enum {
    srt,
    vtt,
    ass,
    ttml,
    dvd_sub,
    dvb_sub,
    unknown,
};

// ============================================================================
// Stream Metadata
// ============================================================================

/// Represents a demuxed stream
pub const Stream = struct {
    id: u32,
    stream_type: StreamType,
    codec_data: []const u8 = &.{}, // Codec-specific config (avcC, etc.)
    language: ?[3]u8 = null, // ISO 639-2 language code
    title: ?[]const u8 = null,
    default: bool = false,
    forced: bool = false,

    // Video-specific
    video: ?VideoInfo = null,

    // Audio-specific
    audio: ?AudioInfo = null,

    // Subtitle-specific
    subtitle: ?SubtitleInfo = null,

    pub const VideoInfo = struct {
        codec: VideoCodec = .unknown,
        width: u32 = 0,
        height: u32 = 0,
        frame_rate_num: u32 = 0,
        frame_rate_den: u32 = 1,
        bit_depth: u8 = 8,
        color_primaries: u8 = 2, // Unspecified
        transfer_characteristics: u8 = 2,
        matrix_coefficients: u8 = 2,
    };

    pub const AudioInfo = struct {
        codec: AudioCodec = .unknown,
        sample_rate: u32 = 0,
        channels: u8 = 0,
        bit_depth: u8 = 0,
    };

    pub const SubtitleInfo = struct {
        codec: SubtitleCodec = .unknown,
        is_text: bool = true,
    };
};

/// Represents a packet/sample from a stream
pub const Packet = struct {
    stream_id: u32,
    pts: i64 = 0, // Presentation timestamp (in timebase units)
    dts: i64 = 0, // Decode timestamp
    duration: u64 = 0,
    data: []const u8,
    is_keyframe: bool = false,
    is_end_of_stream: bool = false,
};

// ============================================================================
// Container Types
// ============================================================================

pub const ContainerFormat = enum {
    mp4,
    webm,
    mkv,
    ogg,
    avi,
    ts,
    flv,

    /// Get file extension for this container
    pub fn extension(self: ContainerFormat) []const u8 {
        return switch (self) {
            .mp4 => "mp4",
            .webm => "webm",
            .mkv => "mkv",
            .ogg => "ogg",
            .avi => "avi",
            .ts => "ts",
            .flv => "flv",
        };
    }

    /// Check if container supports a video codec
    pub fn supportsVideoCodec(self: ContainerFormat, codec: VideoCodec) bool {
        return switch (self) {
            .mp4 => switch (codec) {
                .h264, .h265, .h266, .av1 => true,
                else => false,
            },
            .webm => switch (codec) {
                .vp8, .vp9, .av1 => true,
                else => false,
            },
            .mkv => true, // MKV supports everything
            .ogg => switch (codec) {
                .vp8 => true, // Theora technically, but rare
                else => false,
            },
            .avi => switch (codec) {
                .h264 => true, // Limited support
                else => false,
            },
            .ts => switch (codec) {
                .h264, .h265 => true,
                else => false,
            },
            .flv => switch (codec) {
                .h264 => true,
                else => false,
            },
        };
    }

    /// Check if container supports an audio codec
    pub fn supportsAudioCodec(self: ContainerFormat, codec: AudioCodec) bool {
        return switch (self) {
            .mp4 => switch (codec) {
                .aac, .mp3, .ac3, .eac3, .flac, .opus => true,
                else => false,
            },
            .webm => switch (codec) {
                .opus, .vorbis => true,
                else => false,
            },
            .mkv => true, // MKV supports everything
            .ogg => switch (codec) {
                .vorbis, .opus, .flac => true,
                else => false,
            },
            .avi => switch (codec) {
                .mp3, .pcm, .ac3 => true,
                else => false,
            },
            .ts => switch (codec) {
                .aac, .ac3, .mp3 => true,
                else => false,
            },
            .flv => switch (codec) {
                .aac, .mp3 => true,
                else => false,
            },
        };
    }
};

// ============================================================================
// Remuxer
// ============================================================================

/// Container-agnostic remuxing context
pub const RemuxContext = struct {
    allocator: Allocator,
    streams: std.ArrayListUnmanaged(Stream) = .empty,
    global_timebase_num: u32 = 1,
    global_timebase_den: u32 = 90000,

    // Container metadata
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    date: ?[]const u8 = null,
    comment: ?[]const u8 = null,

    // Duration in global timebase units
    duration: u64 = 0,

    pub fn init(allocator: Allocator) RemuxContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RemuxContext) void {
        self.streams.deinit(self.allocator);
    }

    /// Add a stream to the context
    pub fn addStream(self: *RemuxContext, stream: Stream) !u32 {
        const id: u32 = @intCast(self.streams.items.len);
        var new_stream = stream;
        new_stream.id = id;
        try self.streams.append(self.allocator, new_stream);
        return id;
    }

    /// Get a stream by ID
    pub fn getStream(self: *const RemuxContext, id: u32) ?*const Stream {
        if (id >= self.streams.items.len) return null;
        return &self.streams.items[id];
    }

    /// Check if all streams can be remuxed to target container
    pub fn canRemuxTo(self: *const RemuxContext, target: ContainerFormat) bool {
        for (self.streams.items) |stream| {
            switch (stream.stream_type) {
                .video => {
                    if (stream.video) |v| {
                        if (!target.supportsVideoCodec(v.codec)) return false;
                    }
                },
                .audio => {
                    if (stream.audio) |a| {
                        if (!target.supportsAudioCodec(a.codec)) return false;
                    }
                },
                else => {},
            }
        }
        return true;
    }

    /// Get streams that need transcoding for target container
    pub fn getIncompatibleStreams(
        self: *const RemuxContext,
        target: ContainerFormat,
        allocator: Allocator,
    ) !std.ArrayListUnmanaged(u32) {
        var incompatible: std.ArrayListUnmanaged(u32) = .empty;
        errdefer incompatible.deinit(allocator);

        for (self.streams.items) |stream| {
            var is_incompatible = false;

            switch (stream.stream_type) {
                .video => {
                    if (stream.video) |v| {
                        if (!target.supportsVideoCodec(v.codec)) {
                            is_incompatible = true;
                        }
                    }
                },
                .audio => {
                    if (stream.audio) |a| {
                        if (!target.supportsAudioCodec(a.codec)) {
                            is_incompatible = true;
                        }
                    }
                },
                else => {},
            }

            if (is_incompatible) {
                try incompatible.append(allocator, stream.id);
            }
        }

        return incompatible;
    }
};

// ============================================================================
// Timestamp Conversion
// ============================================================================

/// Convert timestamp between timebases
pub fn convertTimestamp(
    ts: i64,
    src_num: u32,
    src_den: u32,
    dst_num: u32,
    dst_den: u32,
) i64 {
    // ts * src_num / src_den * dst_den / dst_num
    // = ts * src_num * dst_den / (src_den * dst_num)
    const numerator = @as(i128, ts) * src_num * dst_den;
    const denominator: i128 = @as(i128, src_den) * dst_num;
    return @intCast(@divTrunc(numerator + @divTrunc(denominator, 2), denominator));
}

/// Common timebase conversions
pub const Timebase = struct {
    pub const mpeg_ts = .{ .num = 1, .den = 90000 }; // MPEG-TS (90kHz)
    pub const mp4 = .{ .num = 1, .den = 1000 }; // MP4 (milliseconds)
    pub const webm = .{ .num = 1, .den = 1000000 }; // WebM (microseconds)
    pub const flac = .{ .num = 1, .den = 44100 }; // FLAC (sample rate)
};

// ============================================================================
// Codec String Helpers
// ============================================================================

/// Get codec string for MP4 (codecs parameter)
pub fn getMP4CodecString(stream: *const Stream) ?[]const u8 {
    switch (stream.stream_type) {
        .video => {
            if (stream.video) |v| {
                return switch (v.codec) {
                    .h264 => "avc1.640028", // High profile, level 4.0
                    .h265 => "hev1.1.6.L93.B0",
                    .h266 => "vvc1.1.L93.CQA",
                    .av1 => "av01.0.04M.08",
                    else => null,
                };
            }
        },
        .audio => {
            if (stream.audio) |a| {
                return switch (a.codec) {
                    .aac => "mp4a.40.2",
                    .mp3 => "mp4a.40.34",
                    .opus => "Opus",
                    .flac => "fLaC",
                    .ac3 => "ac-3",
                    .eac3 => "ec-3",
                    else => null,
                };
            }
        },
        else => {},
    }
    return null;
}

/// Get codec string for WebM
pub fn getWebMCodecString(stream: *const Stream) ?[]const u8 {
    switch (stream.stream_type) {
        .video => {
            if (stream.video) |v| {
                return switch (v.codec) {
                    .vp8 => "V_VP8",
                    .vp9 => "V_VP9",
                    .av1 => "V_AV1",
                    else => null,
                };
            }
        },
        .audio => {
            if (stream.audio) |a| {
                return switch (a.codec) {
                    .opus => "A_OPUS",
                    .vorbis => "A_VORBIS",
                    else => null,
                };
            }
        },
        else => {},
    }
    return null;
}

// ============================================================================
// Stream Selection
// ============================================================================

/// Options for selecting streams during remux
pub const StreamSelection = struct {
    video: SelectionMode = .all,
    audio: SelectionMode = .all,
    subtitle: SelectionMode = .all,

    // Specific stream IDs to include (when mode is .specific)
    specific_ids: []const u32 = &.{},

    // Language filter (ISO 639-2 codes)
    preferred_languages: []const [3]u8 = &.{},

    pub const SelectionMode = enum {
        all, // Include all streams of this type
        none, // Exclude all streams of this type
        first, // Only first stream of this type
        default_only, // Only default-flagged streams
        specific, // Specific IDs from specific_ids
    };
};

/// Filter streams based on selection criteria
pub fn selectStreams(
    ctx: *const RemuxContext,
    selection: StreamSelection,
    allocator: Allocator,
) !std.ArrayListUnmanaged(u32) {
    var selected: std.ArrayListUnmanaged(u32) = .empty;
    errdefer selected.deinit(allocator);

    var first_video = true;
    var first_audio = true;
    var first_subtitle = true;

    for (ctx.streams.items) |stream| {
        var include = false;

        switch (stream.stream_type) {
            .video => {
                include = switch (selection.video) {
                    .all => true,
                    .none => false,
                    .first => blk: {
                        if (first_video) {
                            first_video = false;
                            break :blk true;
                        }
                        break :blk false;
                    },
                    .default_only => stream.default,
                    .specific => isInList(stream.id, selection.specific_ids),
                };
            },
            .audio => {
                include = switch (selection.audio) {
                    .all => true,
                    .none => false,
                    .first => blk: {
                        if (first_audio) {
                            first_audio = false;
                            break :blk true;
                        }
                        break :blk false;
                    },
                    .default_only => stream.default,
                    .specific => isInList(stream.id, selection.specific_ids),
                };
            },
            .subtitle => {
                include = switch (selection.subtitle) {
                    .all => true,
                    .none => false,
                    .first => blk: {
                        if (first_subtitle) {
                            first_subtitle = false;
                            break :blk true;
                        }
                        break :blk false;
                    },
                    .default_only => stream.default,
                    .specific => isInList(stream.id, selection.specific_ids),
                };
            },
            .data => include = false, // Skip data streams by default
        }

        // Apply language filter
        if (include and selection.preferred_languages.len > 0) {
            if (stream.language) |lang| {
                var lang_match = false;
                for (selection.preferred_languages) |pref| {
                    if (std.mem.eql(u8, &lang, &pref)) {
                        lang_match = true;
                        break;
                    }
                }
                include = lang_match;
            }
        }

        if (include) {
            try selected.append(allocator, stream.id);
        }
    }

    return selected;
}

fn isInList(id: u32, list: []const u32) bool {
    for (list) |item| {
        if (item == id) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "Container format properties" {
    const testing = std.testing;

    try testing.expectEqualStrings("mp4", ContainerFormat.mp4.extension());
    try testing.expectEqualStrings("webm", ContainerFormat.webm.extension());

    // MP4 codec support
    try testing.expect(ContainerFormat.mp4.supportsVideoCodec(.h264));
    try testing.expect(ContainerFormat.mp4.supportsVideoCodec(.h265));
    try testing.expect(!ContainerFormat.mp4.supportsVideoCodec(.vp9));

    // WebM codec support
    try testing.expect(ContainerFormat.webm.supportsVideoCodec(.vp9));
    try testing.expect(!ContainerFormat.webm.supportsVideoCodec(.h264));
    try testing.expect(ContainerFormat.webm.supportsAudioCodec(.opus));
}

test "RemuxContext basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = RemuxContext.init(allocator);
    defer ctx.deinit();

    // Add a video stream
    const video_id = try ctx.addStream(.{
        .id = 0,
        .stream_type = .video,
        .video = .{
            .codec = .h264,
            .width = 1920,
            .height = 1080,
        },
    });

    try testing.expectEqual(@as(u32, 0), video_id);

    // Add an audio stream
    const audio_id = try ctx.addStream(.{
        .id = 0,
        .stream_type = .audio,
        .audio = .{
            .codec = .aac,
            .sample_rate = 48000,
            .channels = 2,
        },
    });

    try testing.expectEqual(@as(u32, 1), audio_id);
    try testing.expectEqual(@as(usize, 2), ctx.streams.items.len);

    // Check remux compatibility
    try testing.expect(ctx.canRemuxTo(.mp4));
    try testing.expect(!ctx.canRemuxTo(.webm)); // H.264 not supported in WebM
    try testing.expect(ctx.canRemuxTo(.mkv)); // MKV supports everything
}

test "Timestamp conversion" {
    const testing = std.testing;

    // Convert from 90kHz to 1kHz (milliseconds)
    const ts_90khz: i64 = 90000; // 1 second at 90kHz
    const ts_1khz = convertTimestamp(ts_90khz, 1, 90000, 1, 1000);
    try testing.expectEqual(@as(i64, 1000), ts_1khz); // 1000 milliseconds

    // Convert from milliseconds to microseconds
    const ts_ms: i64 = 1500;
    const ts_us = convertTimestamp(ts_ms, 1, 1000, 1, 1000000);
    try testing.expectEqual(@as(i64, 1500000), ts_us);
}

test "Stream selection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = RemuxContext.init(allocator);
    defer ctx.deinit();

    _ = try ctx.addStream(.{ .id = 0, .stream_type = .video, .default = true });
    _ = try ctx.addStream(.{ .id = 0, .stream_type = .video, .default = false });
    _ = try ctx.addStream(.{ .id = 0, .stream_type = .audio, .default = true });
    _ = try ctx.addStream(.{ .id = 0, .stream_type = .subtitle, .default = false });

    // Select first video only
    {
        var selected = try selectStreams(&ctx, .{
            .video = .first,
            .audio = .all,
            .subtitle = .none,
        }, allocator);
        defer selected.deinit(allocator);

        try testing.expectEqual(@as(usize, 2), selected.items.len); // 1 video + 1 audio
    }

    // Select defaults only
    {
        var selected = try selectStreams(&ctx, .{
            .video = .default_only,
            .audio = .default_only,
            .subtitle = .default_only,
        }, allocator);
        defer selected.deinit(allocator);

        try testing.expectEqual(@as(usize, 2), selected.items.len); // 1 default video + 1 default audio
    }
}
