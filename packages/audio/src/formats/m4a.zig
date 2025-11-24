const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const AudioFormat = types.AudioFormat;
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// M4A/MP4 audio container reader
/// Supports AAC, ALAC (Apple Lossless), and other audio codecs in MP4 container
pub const M4aReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // File info
    duration_ns: u64,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    codec: AudioCodec,

    // Track info
    time_scale: u32,
    track_duration: u64,
    sample_count: u64,

    // Metadata
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,
    year: ?[]const u8,
    genre: ?[]const u8,
    comment: ?[]const u8,
    track_number: ?u16,

    // Atom positions
    mdat_offset: u64,
    mdat_size: u64,

    pub const AudioCodec = enum {
        aac_lc,
        aac_he,
        aac_he_v2,
        alac,
        mp3,
        ac3,
        eac3,
        opus,
        flac,
        unknown,

        pub fn toString(self: AudioCodec) []const u8 {
            return switch (self) {
                .aac_lc => "AAC-LC",
                .aac_he => "HE-AAC",
                .aac_he_v2 => "HE-AACv2",
                .alac => "Apple Lossless",
                .mp3 => "MP3",
                .ac3 => "AC-3",
                .eac3 => "E-AC-3",
                .opus => "Opus",
                .flac => "FLAC",
                .unknown => "Unknown",
            };
        }
    };

    const Self = @This();

    /// Box/Atom header
    const BoxHeader = struct {
        size: u64,
        box_type: [4]u8,
        header_size: u8, // 8 for regular, 16 for extended size
    };

    /// Common box types
    const BOX_FTYP: [4]u8 = "ftyp".*;
    const BOX_MOOV: [4]u8 = "moov".*;
    const BOX_MVHD: [4]u8 = "mvhd".*;
    const BOX_TRAK: [4]u8 = "trak".*;
    const BOX_MDIA: [4]u8 = "mdia".*;
    const BOX_MDHD: [4]u8 = "mdhd".*;
    const BOX_HDLR: [4]u8 = "hdlr".*;
    const BOX_MINF: [4]u8 = "minf".*;
    const BOX_STBL: [4]u8 = "stbl".*;
    const BOX_STSD: [4]u8 = "stsd".*;
    const BOX_STSZ: [4]u8 = "stsz".*;
    const BOX_UDTA: [4]u8 = "udta".*;
    const BOX_META: [4]u8 = "meta".*;
    const BOX_ILST: [4]u8 = "ilst".*;
    const BOX_ESDS: [4]u8 = "esds".*;
    const BOX_ALAC: [4]u8 = "alac".*;
    const BOX_MDAT: [4]u8 = "mdat".*;

    /// Audio sample entry types
    const SAMPLE_MP4A: [4]u8 = "mp4a".*;
    const SAMPLE_ALAC: [4]u8 = "alac".*;
    const SAMPLE_AC3: [4]u8 = "ac-3".*;
    const SAMPLE_EC3: [4]u8 = "ec-3".*;
    const SAMPLE_OPUS: [4]u8 = "Opus".*;
    const SAMPLE_FLAC: [4]u8 = "fLaC".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .duration_ns = 0,
            .sample_rate = 44100,
            .channels = 2,
            .bits_per_sample = 16,
            .codec = .unknown,
            .time_scale = 1000,
            .track_duration = 0,
            .sample_count = 0,
            .title = null,
            .artist = null,
            .album = null,
            .year = null,
            .genre = null,
            .comment = null,
            .track_number = null,
            .mdat_offset = 0,
            .mdat_size = 0,
        };

        try self.parseTopLevel();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.artist) |a| self.allocator.free(a);
        if (self.album) |a| self.allocator.free(a);
        if (self.year) |y| self.allocator.free(y);
        if (self.genre) |g| self.allocator.free(g);
        if (self.comment) |c| self.allocator.free(c);
    }

    /// Read bytes at position
    fn readBytes(self: *Self, comptime N: usize) ?*const [N]u8 {
        if (self.pos + N > self.data.len) return null;
        const result = self.data[self.pos..][0..N];
        self.pos += N;
        return result;
    }

    /// Read u32 big endian
    fn readU32(self: *Self) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes, .big);
    }

    /// Read u16 big endian
    fn readU16(self: *Self) ?u16 {
        const bytes = self.readBytes(2) orelse return null;
        return std.mem.readInt(u16, bytes, .big);
    }

    /// Skip bytes
    fn skip(self: *Self, count: u64) bool {
        if (self.pos + count > self.data.len) return false;
        self.pos += @intCast(count);
        return true;
    }

    /// Read box header
    fn readBoxHeader(self: *Self) ?BoxHeader {
        const size32 = self.readU32() orelse return null;
        const box_type = self.readBytes(4) orelse return null;

        if (size32 == 1) {
            // Extended size (64-bit)
            const ext_high = self.readU32() orelse return null;
            const ext_low = self.readU32() orelse return null;
            return .{
                .size = (@as(u64, ext_high) << 32) | ext_low,
                .box_type = box_type.*,
                .header_size = 16,
            };
        } else if (size32 == 0) {
            // Size extends to end of file
            return .{
                .size = self.data.len - self.pos + 8,
                .box_type = box_type.*,
                .header_size = 8,
            };
        }

        return .{
            .size = size32,
            .box_type = box_type.*,
            .header_size = 8,
        };
    }

    /// Parse top-level atoms
    fn parseTopLevel(self: *Self) !void {
        while (self.pos < self.data.len) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const content_size = header.size -| header.header_size;

            if (std.mem.eql(u8, &header.box_type, &BOX_MOOV)) {
                const end_pos = start_pos + header.size;
                try self.parseMoov(end_pos);
                self.pos = @intCast(end_pos);
            } else if (std.mem.eql(u8, &header.box_type, &BOX_MDAT)) {
                self.mdat_offset = self.pos;
                self.mdat_size = content_size;
                if (!self.skip(content_size)) break;
            } else {
                if (!self.skip(content_size)) break;
            }
        }
    }

    /// Parse moov atom (movie container)
    fn parseMoov(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_MVHD)) {
                try self.parseMvhd(header.size -| header.header_size);
            } else if (std.mem.eql(u8, &header.box_type, &BOX_TRAK)) {
                try self.parseTrak(box_end);
            } else if (std.mem.eql(u8, &header.box_type, &BOX_UDTA)) {
                try self.parseUdta(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse mvhd atom (movie header)
    fn parseMvhd(self: *Self, size: u64) !void {
        if (size < 20) return;

        const version = self.readBytes(1) orelse return;
        _ = self.readBytes(3); // flags

        if (version[0] == 0) {
            // 32-bit times
            if (!self.skip(8)) return; // creation/modification time
            self.time_scale = self.readU32() orelse return;
            const duration32 = self.readU32() orelse return;

            if (self.time_scale > 0) {
                self.duration_ns = @as(u64, duration32) * 1_000_000_000 / self.time_scale;
            }
        } else {
            // 64-bit times
            if (!self.skip(16)) return; // creation/modification time
            self.time_scale = self.readU32() orelse return;
            const dur_high = self.readU32() orelse return;
            const dur_low = self.readU32() orelse return;
            const duration64 = (@as(u64, dur_high) << 32) | dur_low;

            if (self.time_scale > 0) {
                self.duration_ns = duration64 * 1_000_000_000 / self.time_scale;
            }
        }
    }

    /// Parse trak atom (track container)
    fn parseTrak(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_MDIA)) {
                try self.parseMdia(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse mdia atom (media container)
    fn parseMdia(self: *Self, end_pos: u64) !void {
        var is_audio = false;

        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_MDHD)) {
                try self.parseMdhd(header.size -| header.header_size);
            } else if (std.mem.eql(u8, &header.box_type, &BOX_HDLR)) {
                is_audio = self.parseHdlr();
            } else if (std.mem.eql(u8, &header.box_type, &BOX_MINF)) {
                if (is_audio) {
                    try self.parseMinf(box_end);
                }
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse mdhd atom (media header)
    fn parseMdhd(self: *Self, size: u64) !void {
        if (size < 20) return;

        const version = self.readBytes(1) orelse return;
        _ = self.readBytes(3); // flags

        if (version[0] == 0) {
            if (!self.skip(8)) return; // times
            const track_timescale = self.readU32() orelse return;
            self.track_duration = self.readU32() orelse return;

            if (track_timescale > 1000) {
                self.sample_rate = track_timescale;
            }
        } else {
            if (!self.skip(16)) return; // times
            const track_timescale = self.readU32() orelse return;
            const dur_high = self.readU32() orelse return;
            const dur_low = self.readU32() orelse return;
            self.track_duration = (@as(u64, dur_high) << 32) | dur_low;

            if (track_timescale > 1000) {
                self.sample_rate = track_timescale;
            }
        }
    }

    /// Parse hdlr atom (handler reference)
    fn parseHdlr(self: *Self) bool {
        if (!self.skip(8)) return false; // version/flags + pre_defined

        const handler_type = self.readBytes(4) orelse return false;
        return std.mem.eql(u8, handler_type, "soun");
    }

    /// Parse minf atom (media info)
    fn parseMinf(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_STBL)) {
                try self.parseStbl(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse stbl atom (sample table)
    fn parseStbl(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_STSD)) {
                try self.parseStsd(box_end);
            } else if (std.mem.eql(u8, &header.box_type, &BOX_STSZ)) {
                self.parseStsz();
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse stsd atom (sample description)
    fn parseStsd(self: *Self, end_pos: u64) !void {
        _ = self.readBytes(4); // version/flags
        const entry_count = self.readU32() orelse return;

        for (0..entry_count) |_| {
            if (self.pos >= end_pos) break;

            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const entry_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &SAMPLE_MP4A)) {
                try self.parseMp4aEntry(entry_end);
            } else if (std.mem.eql(u8, &header.box_type, &SAMPLE_ALAC)) {
                self.codec = .alac;
                try self.parseAlacEntry(entry_end);
            } else if (std.mem.eql(u8, &header.box_type, &SAMPLE_AC3)) {
                self.codec = .ac3;
            } else if (std.mem.eql(u8, &header.box_type, &SAMPLE_EC3)) {
                self.codec = .eac3;
            } else if (std.mem.eql(u8, &header.box_type, &SAMPLE_OPUS)) {
                self.codec = .opus;
            } else if (std.mem.eql(u8, &header.box_type, &SAMPLE_FLAC)) {
                self.codec = .flac;
            }

            self.pos = @intCast(entry_end);
        }
    }

    /// Parse mp4a audio sample entry
    fn parseMp4aEntry(self: *Self, end_pos: u64) !void {
        // Skip reserved (6) + data_ref_index (2) + reserved (8) = 16
        if (!self.skip(16)) return;

        self.channels = @intCast(self.readU16() orelse return);
        self.bits_per_sample = @intCast(self.readU16() orelse return);

        if (!self.skip(4)) return; // reserved
        const sample_rate_fixed = self.readU32() orelse return;
        self.sample_rate = sample_rate_fixed >> 16; // Fixed point 16.16

        // Parse child boxes (esds for AAC codec info)
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_ESDS)) {
                self.parseEsds();
            } else if (std.mem.eql(u8, &header.box_type, &BOX_ALAC)) {
                self.codec = .alac;
                self.parseAlacBox();
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse esds box (elementary stream descriptor)
    fn parseEsds(self: *Self) void {
        if (!self.skip(4)) return; // version/flags

        // Simple parsing - look for DecoderConfigDescriptor and AudioSpecificConfig
        var remaining: usize = 64; // reasonable limit
        while (remaining > 2) {
            const tag = self.readBytes(1) orelse return;
            remaining -= 1;

            // Read length (variable length encoding)
            var length: u32 = 0;
            for (0..4) |_| {
                if (remaining == 0) break;
                const len_byte = self.readBytes(1) orelse return;
                remaining -= 1;
                length = (length << 7) | (len_byte[0] & 0x7F);
                if ((len_byte[0] & 0x80) == 0) break;
            }

            if (tag[0] == 0x03) {
                // ES_Descriptor - skip ES_ID + flags
                if (!self.skip(3)) return;
                remaining -|= 3;
            } else if (tag[0] == 0x04) {
                // DecoderConfigDescriptor
                const object_type = self.readBytes(1) orelse return;
                remaining -= 1;

                if (object_type[0] == 0x40) {
                    self.codec = .aac_lc;
                } else if (object_type[0] == 0x67) {
                    self.codec = .aac_he;
                } else if (object_type[0] == 0x69 or object_type[0] == 0x6B) {
                    self.codec = .mp3;
                }

                if (!self.skip(12)) return;
                remaining -|= 12;
            } else if (tag[0] == 0x05) {
                // DecoderSpecificInfo (AudioSpecificConfig for AAC)
                if (length >= 2) {
                    const asc = self.readBytes(2) orelse return;
                    remaining -= 2;

                    const audio_object_type = asc[0] >> 3;
                    if (audio_object_type == 2) {
                        self.codec = .aac_lc;
                    } else if (audio_object_type == 5) {
                        self.codec = .aac_he;
                    } else if (audio_object_type == 29) {
                        self.codec = .aac_he_v2;
                    }

                    if (length > 2) {
                        const to_skip = length - 2;
                        if (!self.skip(to_skip)) return;
                        remaining -|= to_skip;
                    }
                }
            } else {
                // Skip unknown descriptor
                if (length > 0) {
                    if (!self.skip(length)) return;
                    remaining -|= length;
                }
            }
        }
    }

    /// Parse ALAC sample entry
    fn parseAlacEntry(self: *Self, end_pos: u64) !void {
        // Skip reserved (6) + data_ref_index (2) + reserved (8) = 16
        if (!self.skip(16)) return;

        self.channels = @intCast(self.readU16() orelse return);
        self.bits_per_sample = @intCast(self.readU16() orelse return);

        if (!self.skip(4)) return; // reserved
        const sample_rate_fixed = self.readU32() orelse return;
        self.sample_rate = sample_rate_fixed >> 16;

        // Parse ALAC specific box
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_ALAC)) {
                self.parseAlacBox();
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse ALAC specific config box
    fn parseAlacBox(self: *Self) void {
        // Skip version (4), frameLength (4), compatibleVersion (1)
        if (!self.skip(9)) return;

        const bit_depth = self.readBytes(1) orelse return;
        self.bits_per_sample = bit_depth[0];

        // Skip pb (1), mb (1), kb (1)
        if (!self.skip(3)) return;

        const num_channels = self.readBytes(1) orelse return;
        self.channels = num_channels[0];

        // Skip maxRun (2), maxFrameBytes (4), avgBitRate (4)
        if (!self.skip(10)) return;

        self.sample_rate = self.readU32() orelse return;
    }

    /// Parse stsz atom (sample sizes)
    fn parseStsz(self: *Self) void {
        _ = self.readBytes(4); // version/flags
        _ = self.readU32(); // sample_size
        self.sample_count = self.readU32() orelse return;
    }

    /// Parse udta atom (user data)
    fn parseUdta(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_META)) {
                try self.parseMeta(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse meta atom
    fn parseMeta(self: *Self, end_pos: u64) !void {
        // Skip version/flags
        if (!self.skip(4)) return;

        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            if (std.mem.eql(u8, &header.box_type, &BOX_ILST)) {
                try self.parseIlst(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse ilst atom (iTunes metadata list)
    fn parseIlst(self: *Self, end_pos: u64) !void {
        while (self.pos < end_pos) {
            const start_pos = self.pos;
            const header = self.readBoxHeader() orelse break;
            const box_end = start_pos + header.size;

            // iTunes metadata keys
            if (std.mem.eql(u8, &header.box_type, "\xA9nam")) {
                self.title = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "\xA9ART")) {
                self.artist = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "\xA9alb")) {
                self.album = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "\xA9day")) {
                self.year = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "\xA9gen")) {
                self.genre = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "\xA9cmt")) {
                self.comment = try self.parseDataAtom(box_end);
            } else if (std.mem.eql(u8, &header.box_type, "trkn")) {
                self.track_number = self.parseTrackNumber(box_end);
            }

            self.pos = @intCast(box_end);
        }
    }

    /// Parse data atom inside metadata item
    fn parseDataAtom(self: *Self, end_pos: u64) !?[]const u8 {
        const header = self.readBoxHeader() orelse return null;
        if (!std.mem.eql(u8, &header.box_type, "data")) return null;

        const data_end = self.pos - header.header_size + header.size;
        if (data_end > end_pos) return null;

        // Skip type (4) and locale (4)
        if (!self.skip(8)) return null;

        const text_size = data_end - self.pos;
        if (text_size == 0 or text_size > 10000) return null;

        const text = try self.allocator.alloc(u8, @intCast(text_size));
        @memcpy(text, self.data[self.pos..][0..@intCast(text_size)]);
        return text;
    }

    /// Parse track number from trkn atom
    fn parseTrackNumber(self: *Self, end_pos: u64) ?u16 {
        const header = self.readBoxHeader() orelse return null;
        if (!std.mem.eql(u8, &header.box_type, "data")) return null;

        _ = end_pos;

        // Skip type (4), locale (4), padding (2)
        if (!self.skip(10)) return null;

        return self.readU16();
    }

    /// Get format info
    pub fn getFormat(_: *const Self) AudioFormat {
        return .m4a;
    }

    /// Get sample format
    pub fn getSampleFormat(self: *const Self) SampleFormat {
        if (self.codec == .alac) {
            // ALAC is integer samples
            if (self.bits_per_sample <= 16) return .s16le;
            if (self.bits_per_sample <= 24) return .s24le;
            return .s32le;
        }
        // AAC decoded to float
        return .f32le;
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return switch (self.channels) {
            1 => .mono,
            2 => .stereo,
            3 => .surround_30,
            4 => .quad,
            5 => .surround_50,
            6 => .surround_51,
            7 => .surround_61,
            8 => .surround_71,
            else => .stereo,
        };
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        return Duration.fromMicroseconds(self.duration_ns / 1000);
    }

    /// Get codec name
    pub fn getCodecName(self: *const Self) []const u8 {
        return self.codec.toString();
    }

    /// Check if format is Apple Lossless
    pub fn isLossless(self: *const Self) bool {
        return self.codec == .alac or self.codec == .flac;
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.sample_rate;
    }

    /// Get channel count
    pub fn getChannels(self: *const Self) u8 {
        return self.channels;
    }
};

/// Detect if data is M4A/MP4 format
pub fn detect(data: []const u8) bool {
    if (data.len < 12) return false;

    // Check for ftyp box
    const size = std.mem.readInt(u32, data[0..4], .big);
    if (size < 8 or size > data.len) return false;

    if (!std.mem.eql(u8, data[4..8], "ftyp")) return false;

    // Check brand - common M4A/MP4 brands
    const brand = data[8..12];
    return std.mem.eql(u8, brand, "M4A ") or
        std.mem.eql(u8, brand, "M4B ") or
        std.mem.eql(u8, brand, "M4P ") or
        std.mem.eql(u8, brand, "M4V ") or
        std.mem.eql(u8, brand, "mp41") or
        std.mem.eql(u8, brand, "mp42") or
        std.mem.eql(u8, brand, "isom") or
        std.mem.eql(u8, brand, "iso2") or
        std.mem.eql(u8, brand, "avc1") or
        std.mem.eql(u8, brand, "qt  ");
}

test "M4A detection" {
    // Valid M4A with M4A brand (size 0x0c = 12 bytes which equals the array length)
    const valid_m4a = [_]u8{ 0, 0, 0, 0x0c, 'f', 't', 'y', 'p', 'M', '4', 'A', ' ' };
    try std.testing.expect(detect(&valid_m4a));

    // Valid MP4 with isom brand
    const valid_mp4 = [_]u8{ 0, 0, 0, 0x0c, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm' };
    try std.testing.expect(detect(&valid_mp4));

    // Invalid - not ftyp
    const invalid = [_]u8{ 0, 0, 0, 0x0c, 'm', 'o', 'o', 'v', 0, 0, 0, 0 };
    try std.testing.expect(!detect(&invalid));

    // Too short
    try std.testing.expect(!detect("short"));
}

test "AudioCodec toString" {
    try std.testing.expectEqualStrings("AAC-LC", M4aReader.AudioCodec.aac_lc.toString());
    try std.testing.expectEqualStrings("Apple Lossless", M4aReader.AudioCodec.alac.toString());
    try std.testing.expectEqualStrings("HE-AAC", M4aReader.AudioCodec.aac_he.toString());
}
