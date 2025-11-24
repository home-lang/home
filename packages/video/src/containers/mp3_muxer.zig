// Home Video Library - MP3 Muxer
// MPEG Audio Layer III with ID3v1/ID3v2 tags and Xing/VBRI headers

const std = @import("std");

/// ID3v2 frame IDs
pub const ID3v2Frame = enum {
    title, // TIT2
    artist, // TPE1
    album, // TALB
    year, // TYER/TDRC
    comment, // COMM
    track, // TRCK
    genre, // TCON
    album_artist, // TPE2
    composer, // TCOM
    publisher, // TPUB
    copyright, // TCOP
    url, // WXXX
    picture, // APIC
};

/// ID3v1 tag
pub const ID3v1Tag = struct {
    title: [30]u8 = [_]u8{0} ** 30,
    artist: [30]u8 = [_]u8{0} ** 30,
    album: [30]u8 = [_]u8{0} ** 30,
    year: [4]u8 = [_]u8{0} ** 4,
    comment: [30]u8 = [_]u8{0} ** 30,
    genre: u8 = 255, // Unknown
};

/// ID3v2 tag
pub const ID3v2Tag = struct {
    major_version: u8 = 4,
    minor_version: u8 = 0,
    frames: std.StringHashMap([]const u8),
};

/// Xing VBR header info
pub const XingHeader = struct {
    frames: u32,
    bytes: u32,
    quality: u8 = 0,
    toc: ?[100]u8 = null, // Table of contents for seeking
};

/// VBRI VBR header info (Fraunhofer)
pub const VBRIHeader = struct {
    version: u16 = 1,
    delay: u16 = 0,
    quality: u16 = 0,
    bytes: u32,
    frames: u32,
    toc_entries: u16 = 0,
    toc_scale: u16 = 1,
    toc_entry_size: u16 = 2,
    toc_frames_per_entry: u16 = 1,
};

/// MP3 muxer
pub const MP3Muxer = struct {
    allocator: std.mem.Allocator,

    // Tags
    id3v1_tag: ?ID3v1Tag = null,
    id3v2_tag: ?ID3v2Tag = null,

    // VBR header
    xing_header: ?XingHeader = null,
    vbri_header: ?VBRIHeader = null,

    // Audio frames
    frames: std.ArrayList([]const u8),

    // Options
    enable_id3v1: bool = true,
    enable_id3v2: bool = true,
    enable_xing: bool = true, // For VBR files

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .frames = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.id3v2_tag) |*tag| {
            tag.frames.deinit();
        }
        self.frames.deinit();
    }

    pub fn setID3v1Tag(self: *Self, tag: ID3v1Tag) void {
        self.id3v1_tag = tag;
    }

    pub fn setID3v2Tag(self: *Self, tag: ID3v2Tag) void {
        self.id3v2_tag = tag;
    }

    pub fn setXingHeader(self: *Self, header: XingHeader) void {
        self.xing_header = header;
    }

    pub fn addFrame(self: *Self, frame_data: []const u8) !void {
        try self.frames.append(frame_data);
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // ID3v2 tag (at beginning)
        if (self.enable_id3v2 and self.id3v2_tag != null) {
            const id3v2_data = try self.buildID3v2Tag();
            defer self.allocator.free(id3v2_data);
            try output.appendSlice(id3v2_data);
        }

        // Xing VBR header (in first frame)
        if (self.enable_xing and self.xing_header != null and self.frames.items.len > 0) {
            const xing_frame = try self.buildXingFrame();
            defer self.allocator.free(xing_frame);
            try output.appendSlice(xing_frame);

            // Add remaining frames (skip first as Xing replaced it)
            for (self.frames.items[1..]) |frame| {
                try output.appendSlice(frame);
            }
        } else {
            // Add all frames
            for (self.frames.items) |frame| {
                try output.appendSlice(frame);
            }
        }

        // ID3v1 tag (at end)
        if (self.enable_id3v1 and self.id3v1_tag != null) {
            try self.writeID3v1Tag(&output);
        }

        return output.toOwnedSlice();
    }

    fn buildID3v2Tag(self: *Self) ![]u8 {
        if (self.id3v2_tag) |tag| {
            var tag_data = std.ArrayList(u8).init(self.allocator);
            defer tag_data.deinit();

            // Write frames
            var iter = tag.frames.iterator();
            while (iter.next()) |entry| {
                try self.writeID3v2Frame(&tag_data, entry.key_ptr.*, entry.value_ptr.*);
            }

            // Build header
            var output = std.ArrayList(u8).init(self.allocator);
            errdefer output.deinit();

            // ID3v2 identifier
            try output.appendSlice("ID3");

            // Version
            try output.writer().writeByte(tag.major_version);
            try output.writer().writeByte(tag.minor_version);

            // Flags (no unsync, no extended header, no experimental)
            try output.writer().writeByte(0);

            // Size (synchsafe integer)
            const size: u32 = @intCast(tag_data.items.len);
            try self.writeSynchsafeInt(&output, size);

            // Frames
            try output.appendSlice(tag_data.items);

            return output.toOwnedSlice();
        }

        return error.NoID3v2Tag;
    }

    fn writeID3v2Frame(self: *Self, output: *std.ArrayList(u8), frame_id: []const u8, content: []const u8) !void {
        // Frame ID (4 chars)
        try output.appendSlice(frame_id);

        // Size (synchsafe for v2.4, normal for v2.3)
        const size: u32 = @intCast(content.len + 1); // +1 for text encoding
        if (self.id3v2_tag.?.major_version >= 4) {
            try self.writeSynchsafeInt(output, size);
        } else {
            try output.writer().writeInt(u32, size, .big);
        }

        // Flags
        try output.writer().writeInt(u16, 0, .big);

        // Text encoding (0 = ISO-8859-1, 3 = UTF-8)
        try output.writer().writeByte(3);

        // Content
        try output.appendSlice(content);
    }

    fn writeSynchsafeInt(self: *Self, output: *std.ArrayList(u8), value: u32) !void {
        _ = self;

        // Synchsafe integer: 7 bits per byte, MSB is always 0
        try output.writer().writeByte(@intCast((value >> 21) & 0x7F));
        try output.writer().writeByte(@intCast((value >> 14) & 0x7F));
        try output.writer().writeByte(@intCast((value >> 7) & 0x7F));
        try output.writer().writeByte(@intCast(value & 0x7F));
    }

    fn buildXingFrame(self: *Self) ![]u8 {
        if (self.xing_header) |xing| {
            // Use first frame as template
            const first_frame = self.frames.items[0];

            // Allocate new frame with Xing header
            var frame = std.ArrayList(u8).init(self.allocator);
            errdefer frame.deinit();

            // Copy MP3 header (4 bytes)
            try frame.appendSlice(first_frame[0..4]);

            // Calculate Xing header offset (depends on MPEG version and channel mode)
            // Simplified: assume MPEG1, stereo
            const xing_offset: usize = 36;

            // Pad to Xing header position
            try frame.appendNTimes(0, xing_offset - 4);

            // Xing header ID
            try frame.appendSlice("Xing");

            // Flags (frames + bytes + TOC + quality)
            var flags: u32 = 0x0001 | 0x0002; // frames + bytes
            if (xing.toc != null) flags |= 0x0004;
            if (xing.quality > 0) flags |= 0x0008;

            try frame.writer().writeInt(u32, flags, .big);

            // Number of frames
            try frame.writer().writeInt(u32, xing.frames, .big);

            // Number of bytes
            try frame.writer().writeInt(u32, xing.bytes, .big);

            // TOC (if present)
            if (xing.toc) |toc| {
                try frame.appendSlice(&toc);
            }

            // Quality
            if (xing.quality > 0) {
                try frame.writer().writeInt(u32, xing.quality, .big);
            }

            // Pad to standard frame size (typically 417 bytes for 128kbps CBR)
            const target_size: usize = 417;
            if (frame.items.len < target_size) {
                try frame.appendNTimes(0, target_size - frame.items.len);
            }

            return frame.toOwnedSlice();
        }

        return error.NoXingHeader;
    }

    fn writeID3v1Tag(self: *Self, output: *std.ArrayList(u8)) !void {
        if (self.id3v1_tag) |tag| {
            // TAG identifier
            try output.appendSlice("TAG");

            // Title (30 bytes)
            try output.appendSlice(&tag.title);

            // Artist (30 bytes)
            try output.appendSlice(&tag.artist);

            // Album (30 bytes)
            try output.appendSlice(&tag.album);

            // Year (4 bytes)
            try output.appendSlice(&tag.year);

            // Comment (30 bytes)
            try output.appendSlice(&tag.comment);

            // Genre
            try output.writer().writeByte(tag.genre);
        }
    }
};

/// MP3 frame header parser
pub const MP3FrameHeader = struct {
    sync_word: u16,
    mpeg_version: u8,
    layer: u8,
    protection: bool,
    bitrate: u32,
    sample_rate: u32,
    padding: bool,
    private_bit: bool,
    channel_mode: u8,
    frame_size: u32,

    pub fn parse(header_bytes: [4]u8) !MP3FrameHeader {
        const sync = (@as(u16, header_bytes[0]) << 4) | (@as(u16, header_bytes[1]) >> 4);
        if (sync != 0xFFE) return error.InvalidSync;

        const mpeg_version = (header_bytes[1] >> 3) & 0x3;
        const layer = (header_bytes[1] >> 1) & 0x3;
        const protection = (header_bytes[1] & 0x1) == 0;

        const bitrate_index = (header_bytes[2] >> 4) & 0xF;
        const sample_rate_index = (header_bytes[2] >> 2) & 0x3;
        const padding = ((header_bytes[2] >> 1) & 0x1) == 1;
        const private_bit = (header_bytes[2] & 0x1) == 1;

        const channel_mode = (header_bytes[3] >> 6) & 0x3;

        // Lookup tables (simplified)
        const bitrate = switch (layer) {
            1 => @as(u32, bitrate_index) * 32000, // Layer III
            else => @as(u32, bitrate_index) * 8000,
        };

        const sample_rate: u32 = switch (sample_rate_index) {
            0 => 44100,
            1 => 48000,
            2 => 32000,
            else => return error.InvalidSampleRate,
        };

        // Calculate frame size
        const frame_size = if (layer == 1) // Layer III
            (144 * bitrate) / sample_rate + (if (padding) 1 else 0)
        else
            (144 * bitrate) / sample_rate + (if (padding) 4 else 0);

        return .{
            .sync_word = sync,
            .mpeg_version = mpeg_version,
            .layer = layer,
            .protection = protection,
            .bitrate = bitrate,
            .sample_rate = sample_rate,
            .padding = padding,
            .private_bit = private_bit,
            .channel_mode = channel_mode,
            .frame_size = frame_size,
        };
    }
};
