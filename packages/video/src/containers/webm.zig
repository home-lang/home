// Home Video Library - WebM/Matroska Container
// EBML-based container format for VP8/VP9 video and Opus/Vorbis audio

const std = @import("std");
const types = @import("../core/types.zig");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// EBML Element IDs
// ============================================================================

pub const ElementId = enum(u32) {
    // EBML Header
    ebml = 0x1A45DFA3,
    ebml_version = 0x4286,
    ebml_read_version = 0x42F7,
    ebml_max_id_length = 0x42F2,
    ebml_max_size_length = 0x42F3,
    doc_type = 0x4282,
    doc_type_version = 0x4287,
    doc_type_read_version = 0x4285,

    // Segment
    segment = 0x18538067,

    // Segment Information
    info = 0x1549A966,
    timecode_scale = 0x2AD7B1,
    duration = 0x4489,
    muxing_app = 0x4D80,
    writing_app = 0x5741,
    date_utc = 0x4461,
    title = 0x7BA9,
    segment_uid = 0x73A4,

    // Tracks
    tracks = 0x1654AE6B,
    track_entry = 0xAE,
    track_number = 0xD7,
    track_uid = 0x73C5,
    track_type = 0x83,
    flag_enabled = 0xB9,
    flag_default = 0x88,
    flag_forced = 0x55AA,
    flag_lacing = 0x9C,
    min_cache = 0x6DE7,
    max_cache = 0x6DF8,
    default_duration = 0x23E383,
    max_block_addition_id = 0x55EE,
    name = 0x536E,
    language = 0x22B59C,
    codec_id = 0x86,
    codec_private = 0x63A2,
    codec_name = 0x258688,
    codec_delay = 0x56AA,
    seek_pre_roll = 0x56BB,

    // Video Track
    video = 0xE0,
    pixel_width = 0xB0,
    pixel_height = 0xBA,
    display_width = 0x54B0,
    display_height = 0x54BA,
    display_unit = 0x54B2,
    aspect_ratio_type = 0x54B3,
    color_space = 0x2EB524,
    stereo_mode = 0x53B8,
    alpha_mode = 0x53C0,
    frame_rate = 0x2383E3,

    // Video Color
    colour = 0x55B0,
    matrix_coefficients = 0x55B1,
    bits_per_channel = 0x55B2,
    chroma_subsampling_horz = 0x55B3,
    chroma_subsampling_vert = 0x55B4,
    cb_subsampling_horz = 0x55B5,
    cb_subsampling_vert = 0x55B6,
    chroma_siting_horz = 0x55B7,
    chroma_siting_vert = 0x55B8,
    range = 0x55B9,
    transfer_characteristics = 0x55BA,
    primaries = 0x55BB,
    max_cll = 0x55BC,
    max_fall = 0x55BD,

    // Audio Track
    audio = 0xE1,
    sampling_frequency = 0xB5,
    output_sampling_frequency = 0x78B5,
    channels = 0x9F,
    bit_depth = 0x6264,

    // Cluster
    cluster = 0x1F43B675,
    timestamp = 0xE7,
    silent_tracks = 0x5854,
    position = 0xA7,
    prev_size = 0xAB,
    simple_block = 0xA3,
    block_group = 0xA0,
    block = 0xA1,
    block_duration = 0x9B,
    reference_block = 0xFB,
    discard_padding = 0x75A2,

    // Cueing Data
    cues = 0x1C53BB6B,
    cue_point = 0xBB,
    cue_time = 0xB3,
    cue_track_positions = 0xB7,
    cue_track = 0xF7,
    cue_cluster_position = 0xF1,
    cue_relative_position = 0xF0,
    cue_duration = 0xB2,
    cue_block_number = 0x5378,

    // Seek Head
    seek_head = 0x114D9B74,
    seek = 0x4DBB,
    seek_id = 0x53AB,
    seek_position = 0x53AC,

    // Tags
    tags = 0x1254C367,
    tag = 0x7373,
    targets = 0x63C0,
    simple_tag = 0x67C8,
    tag_name = 0x45A3,
    tag_string = 0x4487,
    tag_binary = 0x4485,

    // Chapters
    chapters = 0x1043A770,

    // Attachments
    attachments = 0x1941A469,

    // Void element (padding)
    void_element = 0xEC,

    // CRC-32
    crc32 = 0xBF,

    _,

    pub fn isKnown(id: u32) bool {
        return @as(?ElementId, @enumFromInt(id)) != null;
    }
};

// ============================================================================
// Track Types
// ============================================================================

pub const TrackType = enum(u8) {
    video = 1,
    audio = 2,
    complex = 3,
    logo = 16,
    subtitle = 17,
    buttons = 18,
    control = 32,
    metadata = 33,
};

// ============================================================================
// WebM Codec IDs
// ============================================================================

pub const CodecId = struct {
    // Video codecs
    pub const V_VP8 = "V_VP8";
    pub const V_VP9 = "V_VP9";
    pub const V_AV1 = "V_AV1";

    // Audio codecs
    pub const A_VORBIS = "A_VORBIS";
    pub const A_OPUS = "A_OPUS";
    pub const A_AAC = "A_AAC";
    pub const A_FLAC = "A_FLAC";
};

// ============================================================================
// EBML Element
// ============================================================================

pub const Element = struct {
    id: u32,
    size: u64,
    data_offset: u64,
    is_unknown_size: bool,

    pub fn getEndOffset(self: *const Element) u64 {
        if (self.is_unknown_size) {
            return std.math.maxInt(u64);
        }
        return self.data_offset + self.size;
    }
};

// ============================================================================
// Track Info
// ============================================================================

pub const VideoTrackInfo = struct {
    pixel_width: u32,
    pixel_height: u32,
    display_width: ?u32,
    display_height: ?u32,
    frame_rate: ?f64,
    stereo_mode: u8,
    alpha_mode: u8,
};

pub const AudioTrackInfo = struct {
    sampling_frequency: f64,
    output_sampling_frequency: ?f64,
    channels: u8,
    bit_depth: ?u8,
};

pub const TrackInfo = struct {
    track_number: u64,
    track_uid: u64,
    track_type: TrackType,
    codec_id: []const u8,
    codec_private: ?[]const u8,
    codec_delay: u64,
    seek_pre_roll: u64,
    default_duration: ?u64,
    language: ?[]const u8,
    name: ?[]const u8,
    video: ?VideoTrackInfo,
    audio: ?AudioTrackInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TrackInfo) void {
        if (self.codec_private) |cp| {
            self.allocator.free(cp);
        }
        self.allocator.free(self.codec_id);
        if (self.language) |lang| {
            self.allocator.free(lang);
        }
        if (self.name) |n| {
            self.allocator.free(n);
        }
    }
};

// ============================================================================
// Segment Info
// ============================================================================

pub const SegmentInfo = struct {
    timecode_scale: u64, // nanoseconds per tick (default 1000000 = 1ms)
    duration: ?f64, // duration in timecode scale units
    muxing_app: ?[]const u8,
    writing_app: ?[]const u8,
    title: ?[]const u8,
    date_utc: ?i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SegmentInfo {
        return .{
            .timecode_scale = 1000000, // default 1ms
            .duration = null,
            .muxing_app = null,
            .writing_app = null,
            .title = null,
            .date_utc = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SegmentInfo) void {
        if (self.muxing_app) |s| self.allocator.free(s);
        if (self.writing_app) |s| self.allocator.free(s);
        if (self.title) |s| self.allocator.free(s);
    }

    /// Get duration in seconds
    pub fn getDurationSeconds(self: *const SegmentInfo) ?f64 {
        if (self.duration) |d| {
            return d * @as(f64, @floatFromInt(self.timecode_scale)) / 1_000_000_000.0;
        }
        return null;
    }
};

// ============================================================================
// Cue Point
// ============================================================================

pub const CuePoint = struct {
    time: u64,
    track: u64,
    cluster_position: u64,
    relative_position: ?u64,
    duration: ?u64,
    block_number: ?u64,
};

// ============================================================================
// WebM Reader
// ============================================================================

pub const WebmReader = struct {
    data: []const u8,
    pos: usize,
    segment_offset: u64,
    segment_info: SegmentInfo,
    tracks: std.ArrayList(TrackInfo),
    cue_points: std.ArrayList(CuePoint),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = Self{
            .data = data,
            .pos = 0,
            .segment_offset = 0,
            .segment_info = SegmentInfo.init(allocator),
            .tracks = std.ArrayList(TrackInfo).init(allocator),
            .cue_points = std.ArrayList(CuePoint).init(allocator),
            .allocator = allocator,
        };

        try reader.parse();
        return reader;
    }

    pub fn deinit(self: *Self) void {
        self.segment_info.deinit();
        for (self.tracks.items) |*track| {
            track.deinit();
        }
        self.tracks.deinit();
        self.cue_points.deinit();
    }

    fn parse(self: *Self) !void {
        // Parse EBML header
        const ebml_element = try self.readElement();
        if (ebml_element.id != @intFromEnum(ElementId.ebml)) {
            return VideoError.InvalidMagicBytes;
        }

        // Skip to end of EBML header
        self.pos = @intCast(ebml_element.data_offset + ebml_element.size);

        // Parse Segment
        const segment_element = try self.readElement();
        if (segment_element.id != @intFromEnum(ElementId.segment)) {
            return VideoError.InvalidContainer;
        }

        self.segment_offset = segment_element.data_offset;

        // Parse segment contents
        const segment_end = if (segment_element.is_unknown_size)
            self.data.len
        else
            @as(usize, @intCast(segment_element.data_offset + segment_element.size));

        while (self.pos < segment_end) {
            const element = self.readElement() catch break;
            const element_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .info => try self.parseSegmentInfo(element),
                .tracks => try self.parseTracks(element),
                .cues => try self.parseCues(element),
                .cluster, .seek_head, .tags, .chapters, .attachments => {
                    // Skip these for now
                    self.pos = element_end;
                },
                else => {
                    self.pos = element_end;
                },
            }
        }
    }

    fn parseSegmentInfo(self: *Self, parent: Element) !void {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        while (self.pos < end) {
            const element = try self.readElement();
            const data_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .timecode_scale => {
                    self.segment_info.timecode_scale = try self.readUint(element.size);
                },
                .duration => {
                    self.segment_info.duration = try self.readFloat(element.size);
                },
                .muxing_app => {
                    self.segment_info.muxing_app = try self.readString(element.size);
                },
                .writing_app => {
                    self.segment_info.writing_app = try self.readString(element.size);
                },
                .title => {
                    self.segment_info.title = try self.readString(element.size);
                },
                .date_utc => {
                    self.segment_info.date_utc = try self.readInt(element.size);
                },
                else => {
                    self.pos = data_end;
                },
            }
        }
    }

    fn parseTracks(self: *Self, parent: Element) !void {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        while (self.pos < end) {
            const element = try self.readElement();

            if (@as(ElementId, @enumFromInt(element.id)) == .track_entry) {
                const track = try self.parseTrackEntry(element);
                try self.tracks.append(track);
            } else {
                self.pos = @intCast(element.data_offset + element.size);
            }
        }
    }

    fn parseTrackEntry(self: *Self, parent: Element) !TrackInfo {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        var track = TrackInfo{
            .track_number = 0,
            .track_uid = 0,
            .track_type = .video,
            .codec_id = undefined,
            .codec_private = null,
            .codec_delay = 0,
            .seek_pre_roll = 0,
            .default_duration = null,
            .language = null,
            .name = null,
            .video = null,
            .audio = null,
            .allocator = self.allocator,
        };

        var codec_id_set = false;

        while (self.pos < end) {
            const element = try self.readElement();
            const data_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .track_number => {
                    track.track_number = try self.readUint(element.size);
                },
                .track_uid => {
                    track.track_uid = try self.readUint(element.size);
                },
                .track_type => {
                    const type_val = try self.readUint(element.size);
                    track.track_type = @enumFromInt(@as(u8, @intCast(type_val)));
                },
                .codec_id => {
                    track.codec_id = try self.readString(element.size);
                    codec_id_set = true;
                },
                .codec_private => {
                    track.codec_private = try self.readBytes(element.size);
                },
                .codec_delay => {
                    track.codec_delay = try self.readUint(element.size);
                },
                .seek_pre_roll => {
                    track.seek_pre_roll = try self.readUint(element.size);
                },
                .default_duration => {
                    track.default_duration = try self.readUint(element.size);
                },
                .language => {
                    track.language = try self.readString(element.size);
                },
                .name => {
                    track.name = try self.readString(element.size);
                },
                .video => {
                    track.video = try self.parseVideoTrack(element);
                },
                .audio => {
                    track.audio = try self.parseAudioTrack(element);
                },
                else => {
                    self.pos = data_end;
                },
            }
        }

        if (!codec_id_set) {
            track.codec_id = try self.allocator.dupe(u8, "unknown");
        }

        return track;
    }

    fn parseVideoTrack(self: *Self, parent: Element) !VideoTrackInfo {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        var video = VideoTrackInfo{
            .pixel_width = 0,
            .pixel_height = 0,
            .display_width = null,
            .display_height = null,
            .frame_rate = null,
            .stereo_mode = 0,
            .alpha_mode = 0,
        };

        while (self.pos < end) {
            const element = try self.readElement();
            const data_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .pixel_width => {
                    video.pixel_width = @intCast(try self.readUint(element.size));
                },
                .pixel_height => {
                    video.pixel_height = @intCast(try self.readUint(element.size));
                },
                .display_width => {
                    video.display_width = @intCast(try self.readUint(element.size));
                },
                .display_height => {
                    video.display_height = @intCast(try self.readUint(element.size));
                },
                .frame_rate => {
                    video.frame_rate = try self.readFloat(element.size);
                },
                .stereo_mode => {
                    video.stereo_mode = @intCast(try self.readUint(element.size));
                },
                .alpha_mode => {
                    video.alpha_mode = @intCast(try self.readUint(element.size));
                },
                else => {
                    self.pos = data_end;
                },
            }
        }

        return video;
    }

    fn parseAudioTrack(self: *Self, parent: Element) !AudioTrackInfo {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        var audio = AudioTrackInfo{
            .sampling_frequency = 8000, // Default
            .output_sampling_frequency = null,
            .channels = 1,
            .bit_depth = null,
        };

        while (self.pos < end) {
            const element = try self.readElement();
            const data_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .sampling_frequency => {
                    audio.sampling_frequency = try self.readFloat(element.size);
                },
                .output_sampling_frequency => {
                    audio.output_sampling_frequency = try self.readFloat(element.size);
                },
                .channels => {
                    audio.channels = @intCast(try self.readUint(element.size));
                },
                .bit_depth => {
                    audio.bit_depth = @intCast(try self.readUint(element.size));
                },
                else => {
                    self.pos = data_end;
                },
            }
        }

        return audio;
    }

    fn parseCues(self: *Self, parent: Element) !void {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        while (self.pos < end) {
            const element = try self.readElement();

            if (@as(ElementId, @enumFromInt(element.id)) == .cue_point) {
                const cue = try self.parseCuePoint(element);
                try self.cue_points.append(cue);
            } else {
                self.pos = @intCast(element.data_offset + element.size);
            }
        }
    }

    fn parseCuePoint(self: *Self, parent: Element) !CuePoint {
        const end = @as(usize, @intCast(parent.data_offset + parent.size));

        var cue = CuePoint{
            .time = 0,
            .track = 0,
            .cluster_position = 0,
            .relative_position = null,
            .duration = null,
            .block_number = null,
        };

        while (self.pos < end) {
            const element = try self.readElement();
            const data_end = @as(usize, @intCast(element.data_offset + element.size));

            switch (@as(ElementId, @enumFromInt(element.id))) {
                .cue_time => {
                    cue.time = try self.readUint(element.size);
                },
                .cue_track_positions => {
                    // Parse nested cue track positions
                    const positions_end = data_end;
                    while (self.pos < positions_end) {
                        const pos_element = try self.readElement();
                        const pos_data_end = @as(usize, @intCast(pos_element.data_offset + pos_element.size));

                        switch (@as(ElementId, @enumFromInt(pos_element.id))) {
                            .cue_track => {
                                cue.track = try self.readUint(pos_element.size);
                            },
                            .cue_cluster_position => {
                                cue.cluster_position = try self.readUint(pos_element.size);
                            },
                            .cue_relative_position => {
                                cue.relative_position = try self.readUint(pos_element.size);
                            },
                            .cue_duration => {
                                cue.duration = try self.readUint(pos_element.size);
                            },
                            .cue_block_number => {
                                cue.block_number = try self.readUint(pos_element.size);
                            },
                            else => {
                                self.pos = pos_data_end;
                            },
                        }
                    }
                },
                else => {
                    self.pos = data_end;
                },
            }
        }

        return cue;
    }

    // EBML reading helpers
    fn readElement(self: *Self) !Element {
        const id = try self.readVint();
        const size_vint = try self.readVintWithUnknown();

        return Element{
            .id = @intCast(id),
            .size = size_vint.value,
            .data_offset = @intCast(self.pos),
            .is_unknown_size = size_vint.is_unknown,
        };
    }

    fn readVint(self: *Self) !u64 {
        if (self.pos >= self.data.len) {
            return VideoError.UnexpectedEof;
        }

        const first_byte = self.data[self.pos];
        const length = @clz(first_byte) + 1;

        if (self.pos + length > self.data.len) {
            return VideoError.TruncatedData;
        }

        var value: u64 = first_byte;
        for (1..length) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += length;
        return value;
    }

    const VintResult = struct {
        value: u64,
        is_unknown: bool,
    };

    fn readVintWithUnknown(self: *Self) !VintResult {
        if (self.pos >= self.data.len) {
            return VideoError.UnexpectedEof;
        }

        const first_byte = self.data[self.pos];
        const length: u8 = @as(u8, @clz(first_byte)) + 1;

        if (self.pos + length > self.data.len) {
            return VideoError.TruncatedData;
        }

        // Mask for the first byte (removes length indicator bits)
        const mask: u8 = @as(u8, 0xFF) >> @intCast(length);
        var value: u64 = first_byte & mask;

        for (1..length) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += length;

        // Check for unknown size (all bits set after masking)
        const unknown_value: u64 = (@as(u64, 1) << @intCast(7 * length)) - 1;
        const is_unknown = value == unknown_value;

        return .{
            .value = value,
            .is_unknown = is_unknown,
        };
    }

    fn readUint(self: *Self, size: u64) !u64 {
        const len: usize = @intCast(size);
        if (self.pos + len > self.data.len) {
            return VideoError.TruncatedData;
        }

        var value: u64 = 0;
        for (0..len) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += len;
        return value;
    }

    fn readInt(self: *Self, size: u64) !i64 {
        const len: usize = @intCast(size);
        if (self.pos + len > self.data.len or len == 0) {
            return VideoError.TruncatedData;
        }

        // Sign extend from first byte
        var value: i64 = @as(i8, @bitCast(self.data[self.pos]));
        for (1..len) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += len;
        return value;
    }

    fn readFloat(self: *Self, size: u64) !f64 {
        if (size == 4) {
            const bytes = self.data[self.pos..][0..4];
            self.pos += 4;
            return @floatCast(@as(f32, @bitCast([4]u8{
                bytes[3],
                bytes[2],
                bytes[1],
                bytes[0],
            })));
        } else if (size == 8) {
            const bytes = self.data[self.pos..][0..8];
            self.pos += 8;
            return @as(f64, @bitCast([8]u8{
                bytes[7],
                bytes[6],
                bytes[5],
                bytes[4],
                bytes[3],
                bytes[2],
                bytes[1],
                bytes[0],
            }));
        }
        return VideoError.InvalidHeader;
    }

    fn readString(self: *Self, size: u64) ![]u8 {
        const len: usize = @intCast(size);
        if (self.pos + len > self.data.len) {
            return VideoError.TruncatedData;
        }

        const str = try self.allocator.alloc(u8, len);
        @memcpy(str, self.data[self.pos..][0..len]);
        self.pos += len;
        return str;
    }

    fn readBytes(self: *Self, size: u64) ![]u8 {
        return self.readString(size);
    }

    // Public API
    pub fn getVideoTrack(self: *const Self) ?*const TrackInfo {
        for (self.tracks.items) |*track| {
            if (track.track_type == .video) {
                return track;
            }
        }
        return null;
    }

    pub fn getAudioTrack(self: *const Self) ?*const TrackInfo {
        for (self.tracks.items) |*track| {
            if (track.track_type == .audio) {
                return track;
            }
        }
        return null;
    }

    pub fn getDuration(self: *const Self) ?f64 {
        return self.segment_info.getDurationSeconds();
    }

    pub fn getTimecodeScale(self: *const Self) u64 {
        return self.segment_info.timecode_scale;
    }
};

// ============================================================================
// WebM Detection
// ============================================================================

pub fn isWebm(data: []const u8) bool {
    // Check for EBML header
    if (data.len < 4) return false;
    return data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3;
}

pub fn isMatroska(data: []const u8) bool {
    return isWebm(data); // Same container format
}

// ============================================================================
// Tests
// ============================================================================

test "ElementId values" {
    try std.testing.expectEqual(@as(u32, 0x1A45DFA3), @intFromEnum(ElementId.ebml));
    try std.testing.expectEqual(@as(u32, 0x18538067), @intFromEnum(ElementId.segment));
    try std.testing.expectEqual(@as(u32, 0x1654AE6B), @intFromEnum(ElementId.tracks));
}

test "TrackType values" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TrackType.video));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TrackType.audio));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(TrackType.subtitle));
}

test "isWebm detection" {
    const webm_header = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x00, 0x00 };
    try std.testing.expect(isWebm(&webm_header));

    const not_webm = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(!isWebm(&not_webm));
}

test "SegmentInfo initialization" {
    const allocator = std.testing.allocator;
    var info = SegmentInfo.init(allocator);
    defer info.deinit();

    try std.testing.expectEqual(@as(u64, 1000000), info.timecode_scale);
    try std.testing.expect(info.duration == null);
}

test "CodecId constants" {
    try std.testing.expectEqualStrings("V_VP9", CodecId.V_VP9);
    try std.testing.expectEqualStrings("A_OPUS", CodecId.A_OPUS);
}
