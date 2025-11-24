const std = @import("std");

/// Vorbis audio codec (in Ogg container)
pub const Vorbis = struct {
    /// Vorbis packet types
    pub const PacketType = enum(u8) {
        audio = 0,
        identification = 1,
        comment = 3,
        setup = 5,
    };

    /// Identification header
    pub const IdentificationHeader = struct {
        version: u32,
        channels: u8,
        sample_rate: u32,
        bitrate_maximum: i32,
        bitrate_nominal: i32,
        bitrate_minimum: i32,
        blocksize_0: u8, // Exponent (actual size = 2^blocksize_0)
        blocksize_1: u8,
        framing_flag: bool,
    };

    /// Comment header (Vorbis Comments)
    pub const CommentHeader = struct {
        vendor: []const u8,
        comments: []Comment,
    };

    pub const Comment = struct {
        tag: []const u8,
        value: []const u8,
    };

    /// Audio modes
    pub const Mode = struct {
        blockflag: bool,
        windowtype: u16,
        transformtype: u16,
        mapping: u8,
    };
};

/// Vorbis header parser
pub const VorbisParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VorbisParser {
        return .{ .allocator = allocator };
    }

    pub fn parseIdentificationHeader(self: *VorbisParser, data: []const u8) !Vorbis.IdentificationHeader {
        _ = self;

        if (data.len < 30) return error.InsufficientData;

        // Check packet type and vorbis signature
        if (data[0] != 1) return error.InvalidPacketType;
        if (!std.mem.eql(u8, data[1..7], "vorbis")) return error.InvalidSignature;

        var header: Vorbis.IdentificationHeader = undefined;

        header.version = std.mem.readInt(u32, data[7..11], .little);
        if (header.version != 0) return error.UnsupportedVersion;

        header.channels = data[11];
        if (header.channels == 0) return error.InvalidChannelCount;

        header.sample_rate = std.mem.readInt(u32, data[12..16], .little);
        if (header.sample_rate == 0) return error.InvalidSampleRate;

        header.bitrate_maximum = @bitCast(std.mem.readInt(u32, data[16..20], .little));
        header.bitrate_nominal = @bitCast(std.mem.readInt(u32, data[20..24], .little));
        header.bitrate_minimum = @bitCast(std.mem.readInt(u32, data[24..28], .little));

        const blocksizes = data[28];
        header.blocksize_0 = @truncate(blocksizes & 0x0F);
        header.blocksize_1 = @truncate((blocksizes >> 4) & 0x0F);

        if (header.blocksize_0 > header.blocksize_1) {
            return error.InvalidBlocksize;
        }
        if (header.blocksize_0 < 6 or header.blocksize_0 > 13) {
            return error.InvalidBlocksize;
        }
        if (header.blocksize_1 < 6 or header.blocksize_1 > 13) {
            return error.InvalidBlocksize;
        }

        header.framing_flag = (data[29] & 0x01) != 0;
        if (!header.framing_flag) return error.InvalidFramingFlag;

        return header;
    }

    pub fn parseCommentHeader(self: *VorbisParser, data: []const u8) !Vorbis.CommentHeader {
        if (data.len < 15) return error.InsufficientData;

        // Check packet type and vorbis signature
        if (data[0] != 3) return error.InvalidPacketType;
        if (!std.mem.eql(u8, data[1..7], "vorbis")) return error.InvalidSignature;

        var offset: usize = 7;

        // Vendor string length
        const vendor_length = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + vendor_length > data.len) return error.InsufficientData;

        // Vendor string
        const vendor = data[offset .. offset + vendor_length];
        offset += vendor_length;

        // Number of comments
        if (offset + 4 > data.len) return error.InsufficientData;
        const comment_count = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        // Parse comments
        var comments = try self.allocator.alloc(Vorbis.Comment, comment_count);
        errdefer self.allocator.free(comments);

        for (comments) |*comment| {
            if (offset + 4 > data.len) return error.InsufficientData;

            const comment_length = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            if (offset + comment_length > data.len) return error.InsufficientData;

            const comment_string = data[offset .. offset + comment_length];
            offset += comment_length;

            // Split on '='
            if (std.mem.indexOf(u8, comment_string, "=")) |split_pos| {
                comment.tag = comment_string[0..split_pos];
                comment.value = comment_string[split_pos + 1 ..];
            } else {
                comment.tag = comment_string;
                comment.value = "";
            }
        }

        return Vorbis.CommentHeader{
            .vendor = vendor,
            .comments = comments,
        };
    }

    pub fn isVorbisPacket(data: []const u8) bool {
        if (data.len < 7) return false;
        return std.mem.eql(u8, data[1..7], "vorbis");
    }

    pub fn getPacketType(data: []const u8) ?Vorbis.PacketType {
        if (data.len < 1) return null;

        return switch (data[0]) {
            0 => .audio,
            1 => .identification,
            3 => .comment,
            5 => .setup,
            else => null,
        };
    }
};

/// Vorbis decoder
pub const VorbisDecoder = struct {
    allocator: std.mem.Allocator,
    identification: ?Vorbis.IdentificationHeader,
    comments: ?Vorbis.CommentHeader,
    setup_complete: bool,

    pub fn init(allocator: std.mem.Allocator) VorbisDecoder {
        return .{
            .allocator = allocator,
            .identification = null,
            .comments = null,
            .setup_complete = false,
        };
    }

    pub fn deinit(self: *VorbisDecoder) void {
        if (self.comments) |comments| {
            self.allocator.free(comments.comments);
        }
    }

    pub fn submitPacket(self: *VorbisDecoder, packet: []const u8) !void {
        var parser = VorbisParser.init(self.allocator);

        if (packet.len < 1) return error.EmptyPacket;

        switch (packet[0]) {
            1 => {
                // Identification header
                self.identification = try parser.parseIdentificationHeader(packet);
            },
            3 => {
                // Comment header
                self.comments = try parser.parseCommentHeader(packet);
            },
            5 => {
                // Setup header (complex, simplified here)
                self.setup_complete = true;
            },
            else => {
                // Audio packet
                if (!self.setup_complete) return error.NotInitialized;
                // Would decode audio here
            },
        }
    }

    pub fn decodeAudio(self: *VorbisDecoder, packet: []const u8) ![]f32 {
        // Use full decoder implementation
        const vorbis_full = @import("vorbis_decoder.zig");
        var full_decoder = vorbis_full.VorbisFullDecoder.init(self.allocator);
        defer full_decoder.deinit();

        // Set up headers if available
        if (self.identification) |id| {
            full_decoder.identification = id;
            full_decoder.sample_rate = id.sample_rate;
            full_decoder.channels = id.channels;
        }

        return try full_decoder.decodePacket(packet);
    }

    pub fn getSampleRate(self: *const VorbisDecoder) ?u32 {
        if (self.identification) |id| {
            return id.sample_rate;
        }
        return null;
    }

    pub fn getChannelCount(self: *const VorbisDecoder) ?u8 {
        if (self.identification) |id| {
            return id.channels;
        }
        return null;
    }

    pub fn getComment(self: *const VorbisDecoder, tag: []const u8) ?[]const u8 {
        if (self.comments) |comments| {
            for (comments.comments) |comment| {
                if (std.ascii.eqlIgnoreCase(comment.tag, tag)) {
                    return comment.value;
                }
            }
        }
        return null;
    }
};

/// Vorbis encoder (simplified)
pub const VorbisEncoder = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    quality: f32, // -0.1 to 1.0

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, quality: f32) VorbisEncoder {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .quality = @max(-0.1, @min(1.0, quality)),
        };
    }

    pub fn generateIdentificationHeader(self: *VorbisEncoder) ![]u8 {
        var header = try self.allocator.alloc(u8, 30);

        header[0] = 1; // Packet type
        @memcpy(header[1..7], "vorbis");

        std.mem.writeInt(u32, header[7..11], 0, .little); // Version
        header[11] = self.channels;
        std.mem.writeInt(u32, header[12..16], self.sample_rate, .little);

        // Bitrate fields (0 for VBR)
        std.mem.writeInt(u32, header[16..20], 0, .little); // Max
        std.mem.writeInt(u32, header[20..24], 0, .little); // Nominal
        std.mem.writeInt(u32, header[24..28], 0, .little); // Min

        // Blocksizes (typically 8 and 11)
        header[28] = (11 << 4) | 8;

        // Framing flag
        header[29] = 0x01;

        return header;
    }

    pub fn generateCommentHeader(self: *VorbisEncoder, vendor: []const u8, comments: []const Vorbis.Comment) ![]u8 {
        var size: usize = 7 + 4 + vendor.len + 4; // Type + signature + vendor_length + vendor + comment_count

        for (comments) |comment| {
            size += 4 + comment.tag.len + 1 + comment.value.len; // length + tag + '=' + value
        }
        size += 1; // Framing bit

        var header = try self.allocator.alloc(u8, size);
        var offset: usize = 0;

        header[0] = 3; // Packet type
        @memcpy(header[1..7], "vorbis");
        offset = 7;

        // Vendor
        std.mem.writeInt(u32, header[offset..][0..4], @intCast(vendor.len), .little);
        offset += 4;
        @memcpy(header[offset .. offset + vendor.len], vendor);
        offset += vendor.len;

        // Comment count
        std.mem.writeInt(u32, header[offset..][0..4], @intCast(comments.len), .little);
        offset += 4;

        // Comments
        for (comments) |comment| {
            const comment_len = comment.tag.len + 1 + comment.value.len;
            std.mem.writeInt(u32, header[offset..][0..4], @intCast(comment_len), .little);
            offset += 4;

            @memcpy(header[offset .. offset + comment.tag.len], comment.tag);
            offset += comment.tag.len;

            header[offset] = '=';
            offset += 1;

            @memcpy(header[offset .. offset + comment.value.len], comment.value);
            offset += comment.value.len;
        }

        // Framing bit
        header[offset] = 0x01;

        return header;
    }

    pub fn encodeAudio(self: *VorbisEncoder, samples: []const f32) ![]u8 {
        // Use full encoder implementation
        const vorbis_full = @import("vorbis_encoder.zig");
        var full_encoder = vorbis_full.VorbisFullEncoder.init(
            self.allocator,
            self.sample_rate,
            self.channels,
            self.quality,
        );
        defer full_encoder.deinit();

        return try full_encoder.encodeAudio(samples);
    }
};
