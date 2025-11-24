// Home Audio Library - Matroska/WebM Format
// MKA (Matroska audio) and WebM audio container reader

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// Matroska codec IDs
pub const MatroskaCodec = enum {
    opus,
    vorbis,
    aac,
    mp3,
    flac,
    alac,
    ac3,
    dts,
    pcm_s16le,
    pcm_s24le,
    pcm_s32le,
    pcm_f32le,
    unknown,

    pub fn fromCodecId(id: []const u8) MatroskaCodec {
        if (std.mem.eql(u8, id, "A_OPUS")) return .opus;
        if (std.mem.eql(u8, id, "A_VORBIS")) return .vorbis;
        if (std.mem.eql(u8, id, "A_AAC")) return .aac;
        if (std.mem.startsWith(u8, id, "A_AAC/")) return .aac;
        if (std.mem.eql(u8, id, "A_MPEG/L3")) return .mp3;
        if (std.mem.eql(u8, id, "A_FLAC")) return .flac;
        if (std.mem.eql(u8, id, "A_ALAC")) return .alac;
        if (std.mem.eql(u8, id, "A_AC3")) return .ac3;
        if (std.mem.eql(u8, id, "A_DTS")) return .dts;
        if (std.mem.eql(u8, id, "A_PCM/INT/LIT")) return .pcm_s16le;
        if (std.mem.eql(u8, id, "A_PCM/FLOAT/IEEE")) return .pcm_f32le;
        return .unknown;
    }

    pub fn toString(self: MatroskaCodec) []const u8 {
        return switch (self) {
            .opus => "Opus",
            .vorbis => "Vorbis",
            .aac => "AAC",
            .mp3 => "MP3",
            .flac => "FLAC",
            .alac => "Apple Lossless",
            .ac3 => "AC-3",
            .dts => "DTS",
            .pcm_s16le => "PCM S16LE",
            .pcm_s24le => "PCM S24LE",
            .pcm_s32le => "PCM S32LE",
            .pcm_f32le => "PCM Float",
            .unknown => "Unknown",
        };
    }
};

/// EBML element IDs
const EBML_ID = 0x1A45DFA3;
const SEGMENT_ID = 0x18538067;
const INFO_ID = 0x1549A966;
const TRACKS_ID = 0x1654AE6B;
const TRACK_ENTRY_ID = 0xAE;
const TRACK_TYPE_ID = 0x83;
const CODEC_ID_ID = 0x86;
const AUDIO_ID = 0xE1;
const SAMPLING_FREQ_ID = 0xB5;
const CHANNELS_ID = 0x9F;
const BIT_DEPTH_ID = 0x6264;
const DURATION_ID = 0x4489;
const TIMECODE_SCALE_ID = 0x2AD7B1;
const TITLE_ID = 0x7BA9;
const CLUSTER_ID = 0x1F43B675;

/// Matroska/WebM audio reader
pub const MatroskaReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Track info
    codec: MatroskaCodec,
    codec_id: ?[]const u8,
    sample_rate: f64,
    channels: u8,
    bit_depth: u8,

    // File info
    duration_ns: u64,
    timecode_scale: u64,
    title: ?[]const u8,

    // First cluster position (for audio data)
    cluster_offset: u64,

    // DocType
    is_webm: bool,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .codec = .unknown,
            .codec_id = null,
            .sample_rate = 44100,
            .channels = 2,
            .bit_depth = 16,
            .duration_ns = 0,
            .timecode_scale = 1000000, // Default 1ms
            .title = null,
            .cluster_offset = 0,
            .is_webm = false,
        };

        try self.parse();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.codec_id) |id| self.allocator.free(id);
        if (self.title) |t| self.allocator.free(t);
    }

    /// Read EBML variable-size integer
    fn readVint(self: *Self) ?u64 {
        if (self.pos >= self.data.len) return null;

        const first = self.data[self.pos];
        if (first == 0) return null;

        // Count leading zeros to determine size
        const size: u8 = @intCast(@clz(first) + 1);
        if (self.pos + size > self.data.len) return null;

        var value: u64 = first & ((@as(u8, 0xFF) >> @intCast(size)));
        for (1..size) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += size;
        return value;
    }

    /// Read EBML element ID
    fn readElementId(self: *Self) ?u32 {
        if (self.pos >= self.data.len) return null;

        const first = self.data[self.pos];
        if (first == 0) return null;

        const size: u8 = @intCast(@clz(first) + 1);
        if (size > 4 or self.pos + size > self.data.len) return null;

        var value: u32 = first;
        for (1..size) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }

        self.pos += size;
        return value;
    }

    fn skip(self: *Self, count: u64) bool {
        if (self.pos + count > self.data.len) return false;
        self.pos += @intCast(count);
        return true;
    }

    fn readU64(self: *Self, size: usize) ?u64 {
        if (self.pos + size > self.data.len) return null;
        var value: u64 = 0;
        for (0..size) |i| {
            value = (value << 8) | self.data[self.pos + i];
        }
        self.pos += size;
        return value;
    }

    fn readF64(self: *Self, size: usize) ?f64 {
        if (size == 4) {
            const u = self.readU64(4) orelse return null;
            return @floatCast(@as(f32, @bitCast(@as(u32, @truncate(u)))));
        } else if (size == 8) {
            const u = self.readU64(8) orelse return null;
            return @bitCast(u);
        }
        return null;
    }

    fn readString(self: *Self, size: usize) ?[]const u8 {
        if (self.pos + size > self.data.len) return null;
        const result = self.data[self.pos..][0..size];
        self.pos += size;
        return result;
    }

    fn parse(self: *Self) !void {
        // Parse EBML header
        const ebml_id = self.readElementId() orelse return AudioError.InvalidFormat;
        if (ebml_id != EBML_ID) return AudioError.InvalidFormat;

        const ebml_size = self.readVint() orelse return AudioError.TruncatedData;
        const ebml_end = self.pos + @as(usize, @intCast(ebml_size));

        // Check DocType
        while (self.pos < ebml_end) {
            const id = self.readElementId() orelse break;
            const size = self.readVint() orelse break;

            if (id == 0x4282) { // DocType
                const doc_type = self.readString(@intCast(size)) orelse break;
                self.is_webm = std.mem.eql(u8, doc_type, "webm");
            } else {
                if (!self.skip(size)) break;
            }
        }
        self.pos = ebml_end;

        // Parse Segment
        const segment_id = self.readElementId() orelse return AudioError.TruncatedData;
        if (segment_id != SEGMENT_ID) return AudioError.InvalidFormat;

        _ = self.readVint(); // Segment size (often unknown)

        // Parse Segment children
        while (self.pos < self.data.len) {
            const start_pos = self.pos;
            const id = self.readElementId() orelse break;
            const size = self.readVint() orelse break;

            if (id == INFO_ID) {
                try self.parseInfo(@intCast(size));
            } else if (id == TRACKS_ID) {
                try self.parseTracks(@intCast(size));
            } else if (id == CLUSTER_ID) {
                self.cluster_offset = start_pos;
                break; // Stop at first cluster
            } else {
                if (!self.skip(size)) break;
            }
        }
    }

    fn parseInfo(self: *Self, size: usize) !void {
        const end_pos = self.pos + size;

        while (self.pos < end_pos) {
            const id = self.readElementId() orelse break;
            const elem_size = self.readVint() orelse break;

            if (id == TIMECODE_SCALE_ID) {
                self.timecode_scale = self.readU64(@intCast(elem_size)) orelse 1000000;
            } else if (id == DURATION_ID) {
                const dur = self.readF64(@intCast(elem_size)) orelse 0;
                self.duration_ns = @intFromFloat(dur * @as(f64, @floatFromInt(self.timecode_scale)));
            } else if (id == TITLE_ID) {
                const title_str = self.readString(@intCast(elem_size)) orelse continue;
                self.title = try self.allocator.dupe(u8, title_str);
            } else {
                if (!self.skip(elem_size)) break;
            }
        }

        self.pos = end_pos;
    }

    fn parseTracks(self: *Self, size: usize) !void {
        const end_pos = self.pos + size;

        while (self.pos < end_pos) {
            const id = self.readElementId() orelse break;
            const elem_size = self.readVint() orelse break;

            if (id == TRACK_ENTRY_ID) {
                try self.parseTrackEntry(@intCast(elem_size));
            } else {
                if (!self.skip(elem_size)) break;
            }
        }

        self.pos = end_pos;
    }

    fn parseTrackEntry(self: *Self, size: usize) !void {
        const end_pos = self.pos + size;
        var track_type: u8 = 0;

        while (self.pos < end_pos) {
            const id = self.readElementId() orelse break;
            const elem_size = self.readVint() orelse break;

            if (id == TRACK_TYPE_ID) {
                track_type = @intCast(self.readU64(@intCast(elem_size)) orelse 0);
            } else if (id == CODEC_ID_ID) {
                const codec_str = self.readString(@intCast(elem_size)) orelse continue;
                self.codec = MatroskaCodec.fromCodecId(codec_str);
                self.codec_id = try self.allocator.dupe(u8, codec_str);
            } else if (id == AUDIO_ID) {
                try self.parseAudio(@intCast(elem_size));
            } else {
                if (!self.skip(elem_size)) break;
            }
        }

        // Only care about audio tracks (type 2)
        // track_type == 2 means audio track
        if (track_type != 2) {
            // Non-audio track, but we still parsed it
            self.codec = .unknown;
        }
        self.pos = end_pos;
    }

    fn parseAudio(self: *Self, size: usize) !void {
        const end_pos = self.pos + size;

        while (self.pos < end_pos) {
            const id = self.readElementId() orelse break;
            const elem_size = self.readVint() orelse break;

            if (id == SAMPLING_FREQ_ID) {
                self.sample_rate = self.readF64(@intCast(elem_size)) orelse 44100;
            } else if (id == CHANNELS_ID) {
                self.channels = @intCast(self.readU64(@intCast(elem_size)) orelse 2);
            } else if (id == BIT_DEPTH_ID) {
                self.bit_depth = @intCast(self.readU64(@intCast(elem_size)) orelse 16);
            } else {
                if (!self.skip(elem_size)) break;
            }
        }

        self.pos = end_pos;
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(self.channels);
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        return Duration.fromMicroseconds(self.duration_ns / 1000);
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return @intFromFloat(self.sample_rate);
    }

    /// Get codec name
    pub fn getCodecName(self: *const Self) []const u8 {
        return self.codec.toString();
    }

    /// Check if this is WebM
    pub fn isWebM(self: *const Self) bool {
        return self.is_webm;
    }
};

/// Detect if data is Matroska/WebM format
pub fn isMatroska(data: []const u8) bool {
    if (data.len < 4) return false;
    // EBML header ID
    return data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3;
}

/// Detect if data is WebM specifically
pub fn isWebM(data: []const u8) bool {
    if (!isMatroska(data)) return false;
    // Quick check for "webm" DocType
    if (data.len < 40) return false;
    for (0..data.len - 4) |i| {
        if (std.mem.eql(u8, data[i..][0..4], "webm")) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "MatroskaCodec fromCodecId" {
    try std.testing.expectEqual(MatroskaCodec.opus, MatroskaCodec.fromCodecId("A_OPUS"));
    try std.testing.expectEqual(MatroskaCodec.vorbis, MatroskaCodec.fromCodecId("A_VORBIS"));
    try std.testing.expectEqual(MatroskaCodec.aac, MatroskaCodec.fromCodecId("A_AAC"));
    try std.testing.expectEqual(MatroskaCodec.flac, MatroskaCodec.fromCodecId("A_FLAC"));
}

test "Matroska detection" {
    const mkv_magic = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3 };
    try std.testing.expect(isMatroska(&mkv_magic));

    const not_mkv = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(!isMatroska(&not_mkv));
}
