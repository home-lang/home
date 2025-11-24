// Home Video Library - FLAC Muxer
// Free Lossless Audio Codec container with metadata blocks

const std = @import("std");

/// FLAC metadata block types
pub const MetadataBlockType = enum(u7) {
    streaminfo = 0,
    padding = 1,
    application = 2,
    seektable = 3,
    vorbis_comment = 4,
    cuesheet = 5,
    picture = 6,
    _,
};

/// FLAC stream info
pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u32,  // 24-bit, 0 = unknown
    max_frame_size: u32,  // 24-bit, 0 = unknown
    sample_rate: u32,     // 20-bit
    channels: u8,         // 3-bit (actual channels - 1)
    bits_per_sample: u8,  // 5-bit (actual bps - 1)
    total_samples: u64,   // 36-bit
    md5_signature: [16]u8,
};

/// Vorbis comment (metadata)
pub const VorbisComment = struct {
    vendor_string: []const u8,
    comments: std.StringHashMap([]const u8),
};

/// Seek point
pub const SeekPoint = struct {
    sample_number: u64,
    stream_offset: u64,
    frame_samples: u16,
};

/// Picture metadata
pub const Picture = struct {
    picture_type: PictureType,
    mime_type: []const u8,
    description: []const u8,
    width: u32,
    height: u32,
    color_depth: u32,
    colors_used: u32,
    data: []const u8,
};

pub const PictureType = enum(u32) {
    other = 0,
    file_icon_32x32 = 1,
    other_file_icon = 2,
    cover_front = 3,
    cover_back = 4,
    leaflet_page = 5,
    media = 6,
    lead_artist = 7,
    artist = 8,
    conductor = 9,
    band_orchestra = 10,
    composer = 11,
    lyricist = 12,
    recording_location = 13,
    during_recording = 14,
    during_performance = 15,
    video_screen_capture = 16,
    fish = 17,
    illustration = 18,
    band_logotype = 19,
    publisher_logotype = 20,
};

/// FLAC muxer
pub const FLACMuxer = struct {
    allocator: std.mem.Allocator,
    stream_info: StreamInfo,
    vorbis_comment: ?VorbisComment = null,
    seek_table: std.ArrayList(SeekPoint),
    pictures: std.ArrayList(Picture),

    // Frame data
    frames: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stream_info: StreamInfo) Self {
        return .{
            .allocator = allocator,
            .stream_info = stream_info,
            .seek_table = std.ArrayList(SeekPoint).init(allocator),
            .pictures = std.ArrayList(Picture).init(allocator),
            .frames = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.vorbis_comment) |*vc| {
            vc.comments.deinit();
        }
        self.seek_table.deinit();
        self.pictures.deinit();
        self.frames.deinit();
    }

    pub fn setVorbisComment(self: *Self, comment: VorbisComment) void {
        self.vorbis_comment = comment;
    }

    pub fn addSeekPoint(self: *Self, point: SeekPoint) !void {
        try self.seek_table.append(point);
    }

    pub fn addPicture(self: *Self, picture: Picture) !void {
        try self.pictures.append(picture);
    }

    pub fn addFrame(self: *Self, frame_data: []const u8) !void {
        try self.frames.append(frame_data);
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // FLAC stream marker
        try output.appendSlice("fLaC");

        // STREAMINFO block (mandatory, must be first)
        try self.writeStreamInfoBlock(&output);

        // VORBIS_COMMENT block
        if (self.vorbis_comment != null) {
            try self.writeVorbisCommentBlock(&output, false);
        }

        // SEEKTABLE block
        if (self.seek_table.items.len > 0) {
            try self.writeSeekTableBlock(&output, false);
        }

        // PICTURE blocks
        for (self.pictures.items, 0..) |picture, idx| {
            const is_last = (idx == self.pictures.items.len - 1) and self.frames.items.len == 0;
            try self.writePictureBlock(&output, &picture, is_last);
        }

        // PADDING block (optional, marks end of metadata if no frames)
        if (self.frames.items.len > 0) {
            try self.writePaddingBlock(&output, true, 4096);
        }

        // Audio frames
        for (self.frames.items) |frame| {
            try output.appendSlice(frame);
        }

        return output.toOwnedSlice();
    }

    fn writeStreamInfoBlock(self: *Self, output: *std.ArrayList(u8)) !void {
        const is_last: u8 = if (self.vorbis_comment == null and
            self.seek_table.items.len == 0 and
            self.pictures.items.len == 0) 1 else 0;

        // Block header
        const header: u8 = (is_last << 7) | @intFromEnum(MetadataBlockType.streaminfo);
        try output.writer().writeByte(header);

        // Block length (always 34 for STREAMINFO)
        try output.writer().writeInt(u24, 34, .big);

        // Min/max block size
        try output.writer().writeInt(u16, self.stream_info.min_block_size, .big);
        try output.writer().writeInt(u16, self.stream_info.max_block_size, .big);

        // Min/max frame size (24-bit each)
        try output.writer().writeInt(u24, @intCast(self.stream_info.min_frame_size & 0xFFFFFF), .big);
        try output.writer().writeInt(u24, @intCast(self.stream_info.max_frame_size & 0xFFFFFF), .big);

        // Sample rate (20 bits), channels (3 bits), bps (5 bits), total samples (36 bits)
        // This is a 64-bit packed field
        var packed: u64 = 0;
        packed |= @as(u64, self.stream_info.sample_rate & 0xFFFFF) << 44;
        packed |= @as(u64, self.stream_info.channels) << 41;
        packed |= @as(u64, self.stream_info.bits_per_sample) << 36;
        packed |= self.stream_info.total_samples & 0xFFFFFFFFF;

        try output.writer().writeInt(u64, packed, .big);

        // MD5 signature
        try output.appendSlice(&self.stream_info.md5_signature);
    }

    fn writeVorbisCommentBlock(self: *Self, output: *std.ArrayList(u8), is_last: bool) !void {
        if (self.vorbis_comment) |vc| {
            var block_data = std.ArrayList(u8).init(self.allocator);
            defer block_data.deinit();

            // Vendor string length + data
            try block_data.writer().writeInt(u32, @intCast(vc.vendor_string.len), .little);
            try block_data.appendSlice(vc.vendor_string);

            // User comment list length
            const num_comments: u32 = @intCast(vc.comments.count());
            try block_data.writer().writeInt(u32, num_comments, .little);

            // User comments
            var iter = vc.comments.iterator();
            while (iter.next()) |entry| {
                const comment = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}={s}",
                    .{ entry.key_ptr.*, entry.value_ptr.* },
                );
                defer self.allocator.free(comment);

                try block_data.writer().writeInt(u32, @intCast(comment.len), .little);
                try block_data.appendSlice(comment);
            }

            // Block header
            const header: u8 = (@as(u8, if (is_last) 1 else 0) << 7) |
                @intFromEnum(MetadataBlockType.vorbis_comment);
            try output.writer().writeByte(header);

            // Block length
            try output.writer().writeInt(u24, @intCast(block_data.items.len), .big);
            try output.appendSlice(block_data.items);
        }
    }

    fn writeSeekTableBlock(self: *Self, output: *std.ArrayList(u8), is_last: bool) !void {
        const num_points = self.seek_table.items.len;
        const block_size = num_points * 18; // 18 bytes per seek point

        // Block header
        const header: u8 = (@as(u8, if (is_last) 1 else 0) << 7) |
            @intFromEnum(MetadataBlockType.seektable);
        try output.writer().writeByte(header);

        // Block length
        try output.writer().writeInt(u24, @intCast(block_size), .big);

        // Seek points
        for (self.seek_table.items) |point| {
            try output.writer().writeInt(u64, point.sample_number, .big);
            try output.writer().writeInt(u64, point.stream_offset, .big);
            try output.writer().writeInt(u16, point.frame_samples, .big);
        }
    }

    fn writePictureBlock(self: *Self, output: *std.ArrayList(u8), picture: *const Picture, is_last: bool) !void {
        var block_data = std.ArrayList(u8).init(self.allocator);
        defer block_data.deinit();

        // Picture type
        try block_data.writer().writeInt(u32, @intFromEnum(picture.picture_type), .big);

        // MIME type length + data
        try block_data.writer().writeInt(u32, @intCast(picture.mime_type.len), .big);
        try block_data.appendSlice(picture.mime_type);

        // Description length + data
        try block_data.writer().writeInt(u32, @intCast(picture.description.len), .big);
        try block_data.appendSlice(picture.description);

        // Picture dimensions
        try block_data.writer().writeInt(u32, picture.width, .big);
        try block_data.writer().writeInt(u32, picture.height, .big);
        try block_data.writer().writeInt(u32, picture.color_depth, .big);
        try block_data.writer().writeInt(u32, picture.colors_used, .big);

        // Picture data length + data
        try block_data.writer().writeInt(u32, @intCast(picture.data.len), .big);
        try block_data.appendSlice(picture.data);

        // Block header
        const header: u8 = (@as(u8, if (is_last) 1 else 0) << 7) |
            @intFromEnum(MetadataBlockType.picture);
        try output.writer().writeByte(header);

        // Block length
        try output.writer().writeInt(u24, @intCast(block_data.items.len), .big);
        try output.appendSlice(block_data.items);
    }

    fn writePaddingBlock(self: *Self, output: *std.ArrayList(u8), is_last: bool, size: u24) !void {
        _ = self;

        // Block header
        const header: u8 = (@as(u8, if (is_last) 1 else 0) << 7) |
            @intFromEnum(MetadataBlockType.padding);
        try output.writer().writeByte(header);

        // Block length
        try output.writer().writeInt(u24, size, .big);

        // Padding (zeros)
        try output.appendNTimes(0, size);
    }
};
