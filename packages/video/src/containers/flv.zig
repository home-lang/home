// Home Video Library - FLV Container Support
// Flash Video format parsing and demuxing

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// FLV Constants
// ============================================================================

pub const FLV_HEADER_SIZE = 9;
pub const FLV_TAG_HEADER_SIZE = 11;
pub const FLV_PREV_TAG_SIZE = 4;

// FLV signature
pub const FLV_SIGNATURE = [3]u8{ 'F', 'L', 'V' };

// ============================================================================
// FLV Types
// ============================================================================

pub const FlvTagType = enum(u8) {
    audio = 8,
    video = 9,
    script_data = 18,
    _,
};

pub const FlvAudioCodec = enum(u4) {
    linear_pcm_platform = 0,
    adpcm = 1,
    mp3 = 2,
    linear_pcm_le = 3,
    nellymoser_16k = 4,
    nellymoser_8k = 5,
    nellymoser = 6,
    g711_alaw = 7,
    g711_mulaw = 8,
    reserved = 9,
    aac = 10,
    speex = 11,
    mp3_8k = 14,
    device_specific = 15,
    _,
};

pub const FlvAudioSampleRate = enum(u2) {
    rate_5512 = 0,
    rate_11025 = 1,
    rate_22050 = 2,
    rate_44100 = 3,
};

pub const FlvVideoCodec = enum(u4) {
    sorenson_h263 = 2,
    screen_video = 3,
    vp6 = 4,
    vp6_alpha = 5,
    screen_video_v2 = 6,
    avc = 7, // H.264
    hevc = 12, // H.265 (enhanced FLV)
    av1 = 13, // AV1 (enhanced FLV)
    _,
};

pub const FlvVideoFrameType = enum(u4) {
    keyframe = 1,
    inter_frame = 2,
    disposable_inter = 3,
    generated_keyframe = 4,
    video_info = 5,
    _,
};

pub const AvcPacketType = enum(u8) {
    sequence_header = 0,
    nalu = 1,
    end_of_sequence = 2,
    _,
};

// ============================================================================
// FLV Header
// ============================================================================

pub const FlvHeader = struct {
    version: u8 = 1,
    has_audio: bool = false,
    has_video: bool = false,
    data_offset: u32 = FLV_HEADER_SIZE,

    pub fn parse(data: []const u8) ?FlvHeader {
        if (data.len < FLV_HEADER_SIZE) return null;

        // Check signature
        if (!std.mem.eql(u8, data[0..3], &FLV_SIGNATURE)) return null;

        const flags = data[4];

        return FlvHeader{
            .version = data[3],
            .has_audio = (flags & 0x04) != 0,
            .has_video = (flags & 0x01) != 0,
            .data_offset = std.mem.readInt(u32, data[5..9], .big),
        };
    }

    pub fn serialize(self: *const FlvHeader, out: []u8) void {
        if (out.len < FLV_HEADER_SIZE) return;

        out[0] = 'F';
        out[1] = 'L';
        out[2] = 'V';
        out[3] = self.version;

        var flags: u8 = 0;
        if (self.has_audio) flags |= 0x04;
        if (self.has_video) flags |= 0x01;
        out[4] = flags;

        std.mem.writeInt(u32, out[5..9], self.data_offset, .big);
    }
};

// ============================================================================
// FLV Tag
// ============================================================================

pub const FlvTag = struct {
    tag_type: FlvTagType,
    data_size: u24,
    timestamp: u32, // Extended timestamp (32-bit)
    stream_id: u24, // Always 0
    data: []const u8,

    pub fn parse(data: []const u8) ?FlvTag {
        if (data.len < FLV_TAG_HEADER_SIZE) return null;

        const tag_type: FlvTagType = @enumFromInt(data[0]);

        // Data size (24-bit big-endian)
        const data_size = (@as(u24, data[1]) << 16) |
            (@as(u24, data[2]) << 8) |
            @as(u24, data[3]);

        // Timestamp (24-bit + 8-bit extension)
        const timestamp_lower = (@as(u32, data[4]) << 16) |
            (@as(u32, data[5]) << 8) |
            @as(u32, data[6]);
        const timestamp_ext = @as(u32, data[7]) << 24;
        const timestamp = timestamp_lower | timestamp_ext;

        // Stream ID (always 0)
        const stream_id = (@as(u24, data[8]) << 16) |
            (@as(u24, data[9]) << 8) |
            @as(u24, data[10]);

        const tag_data_end = FLV_TAG_HEADER_SIZE + data_size;
        if (data.len < tag_data_end) return null;

        return FlvTag{
            .tag_type = tag_type,
            .data_size = data_size,
            .timestamp = timestamp,
            .stream_id = stream_id,
            .data = data[FLV_TAG_HEADER_SIZE..tag_data_end],
        };
    }

    pub fn totalSize(self: *const FlvTag) usize {
        return FLV_TAG_HEADER_SIZE + self.data_size + FLV_PREV_TAG_SIZE;
    }
};

// ============================================================================
// Audio Tag Data
// ============================================================================

pub const FlvAudioData = struct {
    codec: FlvAudioCodec,
    sample_rate: FlvAudioSampleRate,
    sample_size: u1, // 0 = 8-bit, 1 = 16-bit
    channels: u1, // 0 = mono, 1 = stereo
    aac_packet_type: ?u8, // For AAC codec
    audio_data: []const u8,

    pub fn parse(data: []const u8) ?FlvAudioData {
        if (data.len < 1) return null;

        const header = data[0];
        const codec: FlvAudioCodec = @enumFromInt(@as(u4, @truncate(header >> 4)));
        const sample_rate: FlvAudioSampleRate = @enumFromInt(@as(u2, @truncate(header >> 2)));
        const sample_size: u1 = @truncate((header >> 1) & 0x01);
        const channels: u1 = @truncate(header & 0x01);

        var audio_data_start: usize = 1;
        var aac_packet_type: ?u8 = null;

        // AAC has an additional packet type byte
        if (codec == .aac) {
            if (data.len < 2) return null;
            aac_packet_type = data[1];
            audio_data_start = 2;
        }

        return FlvAudioData{
            .codec = codec,
            .sample_rate = sample_rate,
            .sample_size = sample_size,
            .channels = channels,
            .aac_packet_type = aac_packet_type,
            .audio_data = data[audio_data_start..],
        };
    }

    pub fn getSampleRateHz(self: *const FlvAudioData) u32 {
        return switch (self.sample_rate) {
            .rate_5512 => 5512,
            .rate_11025 => 11025,
            .rate_22050 => 22050,
            .rate_44100 => 44100,
        };
    }

    pub fn isAacSequenceHeader(self: *const FlvAudioData) bool {
        return self.codec == .aac and self.aac_packet_type == 0;
    }
};

// ============================================================================
// Video Tag Data
// ============================================================================

pub const FlvVideoData = struct {
    frame_type: FlvVideoFrameType,
    codec: FlvVideoCodec,
    avc_packet_type: ?AvcPacketType, // For AVC/HEVC
    composition_time: i32, // CTS offset in ms
    video_data: []const u8,

    pub fn parse(data: []const u8) ?FlvVideoData {
        if (data.len < 1) return null;

        const header = data[0];
        const frame_type: FlvVideoFrameType = @enumFromInt(@as(u4, @truncate(header >> 4)));
        const codec: FlvVideoCodec = @enumFromInt(@as(u4, @truncate(header)));

        var video_data_start: usize = 1;
        var avc_packet_type: ?AvcPacketType = null;
        var composition_time: i32 = 0;

        // AVC/HEVC have additional header
        if (codec == .avc or codec == .hevc) {
            if (data.len < 5) return null;
            avc_packet_type = @enumFromInt(data[1]);

            // Composition time offset (24-bit signed)
            const ct_bytes = data[2..5];
            const ct_unsigned = (@as(u32, ct_bytes[0]) << 16) |
                (@as(u32, ct_bytes[1]) << 8) |
                @as(u32, ct_bytes[2]);

            // Sign extend from 24-bit
            if (ct_unsigned & 0x800000 != 0) {
                composition_time = @bitCast(ct_unsigned | 0xFF000000);
            } else {
                composition_time = @intCast(ct_unsigned);
            }

            video_data_start = 5;
        }

        return FlvVideoData{
            .frame_type = frame_type,
            .codec = codec,
            .avc_packet_type = avc_packet_type,
            .composition_time = composition_time,
            .video_data = data[video_data_start..],
        };
    }

    pub fn isKeyframe(self: *const FlvVideoData) bool {
        return self.frame_type == .keyframe or self.frame_type == .generated_keyframe;
    }

    pub fn isSequenceHeader(self: *const FlvVideoData) bool {
        return (self.codec == .avc or self.codec == .hevc) and
            self.avc_packet_type == .sequence_header;
    }
};

// ============================================================================
// AMF Types (Script Data)
// ============================================================================

pub const AmfType = enum(u8) {
    number = 0,
    boolean = 1,
    string = 2,
    object = 3,
    movie_clip = 4, // Reserved
    null = 5,
    undefined = 6,
    reference = 7,
    ecma_array = 8,
    object_end = 9,
    strict_array = 10,
    date = 11,
    long_string = 12,
    unsupported = 13,
    record_set = 14, // Reserved
    xml_document = 15,
    typed_object = 16,
    _,
};

pub const AmfValue = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    null_value: void,
    undefined: void,
    // Complex types would need allocator
};

/// Parse AMF0 number
pub fn parseAmfNumber(data: []const u8) ?f64 {
    if (data.len < 8) return null;
    const bits = std.mem.readInt(u64, data[0..8], .big);
    return @bitCast(bits);
}

/// Parse AMF0 string
pub fn parseAmfString(data: []const u8) ?struct { value: []const u8, bytes_read: usize } {
    if (data.len < 2) return null;
    const length = std.mem.readInt(u16, data[0..2], .big);
    if (data.len < 2 + length) return null;
    return .{
        .value = data[2 .. 2 + length],
        .bytes_read = 2 + length,
    };
}

// ============================================================================
// FLV Metadata
// ============================================================================

pub const FlvMetadata = struct {
    duration: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    video_codec_id: f64 = 0,
    audio_codec_id: f64 = 0,
    video_data_rate: f64 = 0,
    audio_data_rate: f64 = 0,
    frame_rate: f64 = 0,
    audio_sample_rate: f64 = 0,
    audio_sample_size: f64 = 0,
    stereo: bool = false,
    file_size: f64 = 0,

    // Keyframe index for seeking
    keyframe_timestamps: ?[]f64 = null,
    keyframe_positions: ?[]f64 = null,

    pub fn deinit(self: *FlvMetadata, allocator: Allocator) void {
        if (self.keyframe_timestamps) |ts| {
            allocator.free(ts);
        }
        if (self.keyframe_positions) |pos| {
            allocator.free(pos);
        }
    }

    pub fn getWidth(self: *const FlvMetadata) u32 {
        return @intFromFloat(self.width);
    }

    pub fn getHeight(self: *const FlvMetadata) u32 {
        return @intFromFloat(self.height);
    }

    pub fn getDurationMs(self: *const FlvMetadata) u64 {
        return @intFromFloat(self.duration * 1000);
    }
};

/// Parse onMetaData script tag
pub fn parseMetadata(data: []const u8, allocator: Allocator) ?FlvMetadata {
    _ = allocator; // Would be used for keyframe arrays

    if (data.len < 3) return null;

    // First byte is AMF type (should be string "onMetaData")
    if (data[0] != @intFromEnum(AmfType.string)) return null;

    const name_result = parseAmfString(data[1..]) orelse return null;
    if (!std.mem.eql(u8, name_result.value, "onMetaData")) return null;

    var meta = FlvMetadata{};
    var offset: usize = 1 + name_result.bytes_read;

    // Second value is typically ECMA array or object
    if (offset >= data.len) return meta;

    const value_type: AmfType = @enumFromInt(data[offset]);
    offset += 1;

    if (value_type == .ecma_array) {
        // Skip array count (4 bytes)
        if (offset + 4 > data.len) return meta;
        offset += 4;
    }

    // Parse key-value pairs
    while (offset + 2 < data.len) {
        // Read key
        const key_result = parseAmfString(data[offset..]) orelse break;
        offset += key_result.bytes_read;

        if (offset >= data.len) break;

        // Read value type and value
        const val_type: AmfType = @enumFromInt(data[offset]);
        offset += 1;

        switch (val_type) {
            .number => {
                const num = parseAmfNumber(data[offset..]) orelse break;
                offset += 8;

                // Match known metadata fields
                if (std.mem.eql(u8, key_result.value, "duration")) {
                    meta.duration = num;
                } else if (std.mem.eql(u8, key_result.value, "width")) {
                    meta.width = num;
                } else if (std.mem.eql(u8, key_result.value, "height")) {
                    meta.height = num;
                } else if (std.mem.eql(u8, key_result.value, "videocodecid")) {
                    meta.video_codec_id = num;
                } else if (std.mem.eql(u8, key_result.value, "audiocodecid")) {
                    meta.audio_codec_id = num;
                } else if (std.mem.eql(u8, key_result.value, "videodatarate")) {
                    meta.video_data_rate = num;
                } else if (std.mem.eql(u8, key_result.value, "audiodatarate")) {
                    meta.audio_data_rate = num;
                } else if (std.mem.eql(u8, key_result.value, "framerate")) {
                    meta.frame_rate = num;
                } else if (std.mem.eql(u8, key_result.value, "audiosamplerate")) {
                    meta.audio_sample_rate = num;
                } else if (std.mem.eql(u8, key_result.value, "audiosamplesize")) {
                    meta.audio_sample_size = num;
                } else if (std.mem.eql(u8, key_result.value, "filesize")) {
                    meta.file_size = num;
                }
            },
            .boolean => {
                if (offset >= data.len) break;
                const bool_val = data[offset] != 0;
                offset += 1;

                if (std.mem.eql(u8, key_result.value, "stereo")) {
                    meta.stereo = bool_val;
                }
            },
            .string => {
                const str_result = parseAmfString(data[offset..]) orelse break;
                offset += str_result.bytes_read;
                // Skip string values for now
            },
            .object_end => break,
            else => break, // Skip complex types
        }
    }

    return meta;
}

// ============================================================================
// FLV Demuxer
// ============================================================================

pub const FlvDemuxer = struct {
    header: FlvHeader,
    metadata: ?FlvMetadata,
    current_offset: usize,
    data: []const u8,
    allocator: Allocator,

    // Sequence headers (needed for decoder init)
    avc_sequence_header: ?[]const u8 = null,
    aac_sequence_header: ?[]const u8 = null,

    pub fn init(data: []const u8, allocator: Allocator) ?FlvDemuxer {
        const header = FlvHeader.parse(data) orelse return null;

        var demuxer = FlvDemuxer{
            .header = header,
            .metadata = null,
            .current_offset = header.data_offset,
            .data = data,
            .allocator = allocator,
        };

        // Skip PreviousTagSize0 (4 bytes of zeros)
        demuxer.current_offset += FLV_PREV_TAG_SIZE;

        // Try to parse first tag as metadata
        if (demuxer.readNextTag()) |first_tag| {
            if (first_tag.tag_type == .script_data) {
                demuxer.metadata = parseMetadata(first_tag.data, allocator);
            } else {
                // Rewind if not metadata
                demuxer.current_offset = header.data_offset + FLV_PREV_TAG_SIZE;
            }
        }

        return demuxer;
    }

    pub fn deinit(self: *FlvDemuxer) void {
        if (self.metadata) |*meta| {
            meta.deinit(self.allocator);
        }
        if (self.avc_sequence_header) |header| {
            self.allocator.free(header);
        }
        if (self.aac_sequence_header) |header| {
            self.allocator.free(header);
        }
    }

    pub fn readNextTag(self: *FlvDemuxer) ?FlvTag {
        if (self.current_offset >= self.data.len) return null;

        const remaining = self.data[self.current_offset..];
        const tag = FlvTag.parse(remaining) orelse return null;

        // Store sequence headers
        if (tag.tag_type == .video) {
            if (FlvVideoData.parse(tag.data)) |video| {
                if (video.isSequenceHeader()) {
                    if (self.avc_sequence_header) |old| {
                        self.allocator.free(old);
                    }
                    self.avc_sequence_header = self.allocator.dupe(u8, video.video_data) catch null;
                }
            }
        } else if (tag.tag_type == .audio) {
            if (FlvAudioData.parse(tag.data)) |audio| {
                if (audio.isAacSequenceHeader()) {
                    if (self.aac_sequence_header) |old| {
                        self.allocator.free(old);
                    }
                    self.aac_sequence_header = self.allocator.dupe(u8, audio.audio_data) catch null;
                }
            }
        }

        self.current_offset += tag.totalSize();
        return tag;
    }

    pub fn seekToTimestamp(self: *FlvDemuxer, target_ms: u32) bool {
        // If we have keyframe index, use it
        if (self.metadata) |meta| {
            if (meta.keyframe_timestamps) |timestamps| {
                if (meta.keyframe_positions) |positions| {
                    // Binary search for nearest keyframe
                    const target_s = @as(f64, @floatFromInt(target_ms)) / 1000.0;
                    var best_idx: usize = 0;

                    for (timestamps, 0..) |ts, i| {
                        if (ts <= target_s) {
                            best_idx = i;
                        } else {
                            break;
                        }
                    }

                    if (best_idx < positions.len) {
                        self.current_offset = @intFromFloat(positions[best_idx]);
                        return true;
                    }
                }
            }
        }

        // Linear search fallback
        self.current_offset = self.header.data_offset + FLV_PREV_TAG_SIZE;

        while (self.readNextTag()) |tag| {
            if (tag.timestamp >= target_ms) {
                // Found a tag at or after target
                // Rewind to this tag
                self.current_offset -= tag.totalSize();
                return true;
            }
        }

        return false;
    }

    pub fn reset(self: *FlvDemuxer) void {
        self.current_offset = self.header.data_offset + FLV_PREV_TAG_SIZE;
    }
};

// ============================================================================
// FLV Muxer
// ============================================================================

pub const FlvMuxer = struct {
    buffer: std.ArrayList(u8),
    has_audio: bool,
    has_video: bool,
    last_tag_size: u32,

    pub fn init(allocator: Allocator, has_video: bool, has_audio: bool) FlvMuxer {
        var muxer = FlvMuxer{
            .buffer = std.ArrayList(u8).init(allocator),
            .has_audio = has_audio,
            .has_video = has_video,
            .last_tag_size = 0,
        };

        // Write header
        var header_buf: [FLV_HEADER_SIZE]u8 = undefined;
        const header = FlvHeader{
            .has_audio = has_audio,
            .has_video = has_video,
        };
        header.serialize(&header_buf);
        muxer.buffer.appendSlice(&header_buf) catch {};

        // Write PreviousTagSize0
        muxer.buffer.appendSlice(&[4]u8{ 0, 0, 0, 0 }) catch {};

        return muxer;
    }

    pub fn deinit(self: *FlvMuxer) void {
        self.buffer.deinit();
    }

    pub fn writeVideoTag(
        self: *FlvMuxer,
        frame_type: FlvVideoFrameType,
        codec: FlvVideoCodec,
        timestamp_ms: u32,
        data: []const u8,
        composition_time: i32,
    ) !void {
        var tag_header: [FLV_TAG_HEADER_SIZE]u8 = undefined;

        // Tag type
        tag_header[0] = @intFromEnum(FlvTagType.video);

        // Data size (1 byte video header + optional 4 bytes AVC header + data)
        var extra_header_size: usize = 1;
        if (codec == .avc or codec == .hevc) {
            extra_header_size = 5;
        }
        const data_size: u32 = @intCast(extra_header_size + data.len);
        tag_header[1] = @truncate(data_size >> 16);
        tag_header[2] = @truncate(data_size >> 8);
        tag_header[3] = @truncate(data_size);

        // Timestamp
        tag_header[4] = @truncate(timestamp_ms >> 16);
        tag_header[5] = @truncate(timestamp_ms >> 8);
        tag_header[6] = @truncate(timestamp_ms);
        tag_header[7] = @truncate(timestamp_ms >> 24); // Extended timestamp

        // Stream ID (always 0)
        tag_header[8] = 0;
        tag_header[9] = 0;
        tag_header[10] = 0;

        try self.buffer.appendSlice(&tag_header);

        // Video tag data header
        const video_header = (@as(u8, @intFromEnum(frame_type)) << 4) | @as(u8, @intFromEnum(codec));
        try self.buffer.append(video_header);

        // AVC/HEVC specific header
        if (codec == .avc or codec == .hevc) {
            const avc_type: u8 = if (frame_type == .keyframe and data.len < 100) 0 else 1;
            try self.buffer.append(avc_type);

            // Composition time (24-bit signed)
            const ct: u32 = @bitCast(composition_time);
            try self.buffer.append(@truncate(ct >> 16));
            try self.buffer.append(@truncate(ct >> 8));
            try self.buffer.append(@truncate(ct));
        }

        try self.buffer.appendSlice(data);

        // PreviousTagSize
        self.last_tag_size = @intCast(FLV_TAG_HEADER_SIZE + data_size);
        var prev_tag_size: [4]u8 = undefined;
        std.mem.writeInt(u32, &prev_tag_size, self.last_tag_size, .big);
        try self.buffer.appendSlice(&prev_tag_size);
    }

    pub fn writeAudioTag(
        self: *FlvMuxer,
        codec: FlvAudioCodec,
        sample_rate: FlvAudioSampleRate,
        sample_size: u1,
        channels: u1,
        timestamp_ms: u32,
        data: []const u8,
        aac_packet_type: ?u8,
    ) !void {
        var tag_header: [FLV_TAG_HEADER_SIZE]u8 = undefined;

        // Tag type
        tag_header[0] = @intFromEnum(FlvTagType.audio);

        // Data size
        var extra_header_size: usize = 1;
        if (codec == .aac) {
            extra_header_size = 2;
        }
        const data_size: u32 = @intCast(extra_header_size + data.len);
        tag_header[1] = @truncate(data_size >> 16);
        tag_header[2] = @truncate(data_size >> 8);
        tag_header[3] = @truncate(data_size);

        // Timestamp
        tag_header[4] = @truncate(timestamp_ms >> 16);
        tag_header[5] = @truncate(timestamp_ms >> 8);
        tag_header[6] = @truncate(timestamp_ms);
        tag_header[7] = @truncate(timestamp_ms >> 24);

        // Stream ID
        tag_header[8] = 0;
        tag_header[9] = 0;
        tag_header[10] = 0;

        try self.buffer.appendSlice(&tag_header);

        // Audio tag header
        const audio_header = (@as(u8, @intFromEnum(codec)) << 4) |
            (@as(u8, @intFromEnum(sample_rate)) << 2) |
            (@as(u8, sample_size) << 1) |
            channels;
        try self.buffer.append(audio_header);

        // AAC packet type
        if (codec == .aac) {
            try self.buffer.append(aac_packet_type orelse 1);
        }

        try self.buffer.appendSlice(data);

        // PreviousTagSize
        self.last_tag_size = @intCast(FLV_TAG_HEADER_SIZE + data_size);
        var prev_tag_size: [4]u8 = undefined;
        std.mem.writeInt(u32, &prev_tag_size, self.last_tag_size, .big);
        try self.buffer.appendSlice(&prev_tag_size);
    }

    pub fn getData(self: *const FlvMuxer) []const u8 {
        return self.buffer.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FLV header parsing" {
    const testing = std.testing;

    // Valid FLV header with audio and video
    const data = [_]u8{ 'F', 'L', 'V', 0x01, 0x05, 0x00, 0x00, 0x00, 0x09 };

    const header = FlvHeader.parse(&data);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u8, 1), header.?.version);
    try testing.expect(header.?.has_audio);
    try testing.expect(header.?.has_video);
    try testing.expectEqual(@as(u32, 9), header.?.data_offset);
}

test "FLV header serialization" {
    const testing = std.testing;

    const header = FlvHeader{
        .version = 1,
        .has_audio = true,
        .has_video = true,
    };

    var buf: [FLV_HEADER_SIZE]u8 = undefined;
    header.serialize(&buf);

    try testing.expect(std.mem.eql(u8, buf[0..3], "FLV"));
    try testing.expectEqual(@as(u8, 0x05), buf[4]); // Audio + Video flags
}

test "FLV video data parsing" {
    const testing = std.testing;

    // AVC keyframe with sequence header
    const data = [_]u8{
        0x17, // Keyframe + AVC
        0x00, // Sequence header
        0x00, 0x00, 0x00, // Composition time = 0
        0xDE, 0xAD, 0xBE, 0xEF, // Data
    };

    const video = FlvVideoData.parse(&data);
    try testing.expect(video != null);
    try testing.expectEqual(FlvVideoFrameType.keyframe, video.?.frame_type);
    try testing.expectEqual(FlvVideoCodec.avc, video.?.codec);
    try testing.expect(video.?.isKeyframe());
    try testing.expect(video.?.isSequenceHeader());
}

test "FLV audio data parsing" {
    const testing = std.testing;

    // AAC stereo 44100Hz
    const data = [_]u8{
        0xAF, // AAC, 44100, 16-bit, stereo
        0x00, // Sequence header
        0x12, 0x10, // AAC config data
    };

    const audio = FlvAudioData.parse(&data);
    try testing.expect(audio != null);
    try testing.expectEqual(FlvAudioCodec.aac, audio.?.codec);
    try testing.expectEqual(FlvAudioSampleRate.rate_44100, audio.?.sample_rate);
    try testing.expectEqual(@as(u32, 44100), audio.?.getSampleRateHz());
    try testing.expect(audio.?.isAacSequenceHeader());
}

test "AMF parsing" {
    const testing = std.testing;

    // AMF number (8.0)
    const num_data = [_]u8{ 0x40, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const num = parseAmfNumber(&num_data);
    try testing.expect(num != null);
    try testing.expectApproxEqAbs(@as(f64, 8.0), num.?, 0.001);

    // AMF string
    const str_data = [_]u8{ 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const str = parseAmfString(&str_data);
    try testing.expect(str != null);
    try testing.expect(std.mem.eql(u8, str.?.value, "hello"));
}
