const std = @import("std");

/// GIF (Graphics Interchange Format) container
pub const Gif = struct {
    /// GIF version
    pub const Version = enum {
        gif87a,
        gif89a,
    };

    /// Disposal method
    pub const DisposalMethod = enum(u3) {
        none = 0,
        do_not_dispose = 1,
        restore_background = 2,
        restore_previous = 3,
    };

    /// GIF header
    pub const Header = struct {
        version: Version,
        width: u16,
        height: u16,
        global_color_table: bool,
        color_resolution: u3,
        sort_flag: bool,
        global_color_table_size: u8,
        background_color_index: u8,
        pixel_aspect_ratio: u8,
    };

    /// GIF frame/image
    pub const Frame = struct {
        left: u16,
        top: u16,
        width: u16,
        height: u16,
        local_color_table: bool,
        interlaced: bool,
        sort_flag: bool,
        local_color_table_size: u8,
        delay_centiseconds: u16, // 1/100th of a second
        disposal_method: DisposalMethod,
        transparent_color: bool,
        transparent_color_index: u8,
        color_table: ?[]u8, // RGB triplets
        indices: []u8, // Indexed pixel data
    };

    /// Application extension (for loop count)
    pub const ApplicationExtension = struct {
        identifier: [8]u8,
        auth_code: [3]u8,
        loop_count: u16,
    };
};

/// GIF reader
pub const GifReader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize,
    header: Gif.Header,
    global_color_table: ?[]u8,
    frames: std.ArrayList(Gif.Frame),
    loop_count: u16,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !GifReader {
        if (data.len < 13) return error.InvalidGif;
        if (!isGif(data)) return error.InvalidSignature;

        var reader = GifReader{
            .allocator = allocator,
            .data = data,
            .offset = 0,
            .header = undefined,
            .global_color_table = null,
            .frames = std.ArrayList(Gif.Frame).init(allocator),
            .loop_count = 0,
        };

        try reader.parseHeader();
        return reader;
    }

    pub fn deinit(self: *GifReader) void {
        if (self.global_color_table) |table| {
            self.allocator.free(table);
        }
        for (self.frames.items) |*frame| {
            if (frame.color_table) |table| {
                self.allocator.free(table);
            }
            self.allocator.free(frame.indices);
        }
        self.frames.deinit();
    }

    fn parseHeader(self: *GifReader) !void {
        // Signature + version (6 bytes)
        const sig = self.data[0..6];
        self.header.version = if (std.mem.eql(u8, sig, "GIF87a"))
            .gif87a
        else
            .gif89a;

        self.offset = 6;

        // Logical screen descriptor (7 bytes)
        self.header.width = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
        self.header.height = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);

        const packed = self.data[self.offset + 4];
        self.header.global_color_table = (packed & 0x80) != 0;
        self.header.color_resolution = @truncate((packed >> 4) & 0x07);
        self.header.sort_flag = (packed & 0x08) != 0;
        const gct_size_code: u3 = @truncate(packed & 0x07);
        self.header.global_color_table_size = @as(u8, 1) << (@as(u8, gct_size_code) + 1);

        self.header.background_color_index = self.data[self.offset + 5];
        self.header.pixel_aspect_ratio = self.data[self.offset + 6];

        self.offset += 7;

        // Read global color table
        if (self.header.global_color_table) {
            const table_size = @as(usize, self.header.global_color_table_size) * 3;
            self.global_color_table = try self.allocator.alloc(u8, table_size);
            @memcpy(self.global_color_table.?, self.data[self.offset .. self.offset + table_size]);
            self.offset += table_size;
        }
    }

    pub fn readFrames(self: *GifReader) !void {
        while (self.offset < self.data.len) {
            const separator = self.data[self.offset];
            self.offset += 1;

            switch (separator) {
                0x21 => try self.parseExtension(), // Extension
                0x2C => try self.parseImage(), // Image
                0x3B => break, // Trailer
                else => return error.InvalidGifBlock,
            }
        }
    }

    fn parseExtension(self: *GifReader) !void {
        const label = self.data[self.offset];
        self.offset += 1;

        switch (label) {
            0xF9 => try self.parseGraphicControlExtension(),
            0xFF => try self.parseApplicationExtension(),
            0xFE => try self.skipDataSubBlocks(), // Comment
            0x01 => try self.skipDataSubBlocks(), // Plain text
            else => try self.skipDataSubBlocks(),
        }
    }

    fn parseGraphicControlExtension(self: *GifReader) !void {
        const block_size = self.data[self.offset];
        self.offset += 1;

        if (block_size != 4) return error.InvalidGraphicControl;

        // Store for next frame
        // This is simplified - should be associated with next image
        self.offset += block_size + 1; // +1 for block terminator
    }

    fn parseApplicationExtension(self: *GifReader) !void {
        const block_size = self.data[self.offset];
        self.offset += 1;

        if (block_size == 11) {
            const identifier = self.data[self.offset .. self.offset + 8];
            if (std.mem.eql(u8, identifier, "NETSCAPE")) {
                self.offset += 11;
                // Read loop count from data sub-block
                const sub_block_size = self.data[self.offset];
                if (sub_block_size == 3) {
                    self.loop_count = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);
                }
                self.offset += sub_block_size + 1;
            } else {
                self.offset += block_size;
                try self.skipDataSubBlocks();
            }
        } else {
            self.offset += block_size;
            try self.skipDataSubBlocks();
        }

        // Skip block terminator
        if (self.offset < self.data.len and self.data[self.offset] == 0) {
            self.offset += 1;
        }
    }

    fn parseImage(self: *GifReader) !void {
        var frame: Gif.Frame = undefined;

        // Image descriptor (9 bytes)
        frame.left = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
        frame.top = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);
        frame.width = std.mem.readInt(u16, self.data[self.offset + 4 ..][0..2], .little);
        frame.height = std.mem.readInt(u16, self.data[self.offset + 6 ..][0..2], .little);

        const packed = self.data[self.offset + 8];
        frame.local_color_table = (packed & 0x80) != 0;
        frame.interlaced = (packed & 0x40) != 0;
        frame.sort_flag = (packed & 0x20) != 0;
        const lct_size_code: u3 = @truncate(packed & 0x07);
        frame.local_color_table_size = @as(u8, 1) << (@as(u8, lct_size_code) + 1);

        self.offset += 9;

        // Read local color table
        if (frame.local_color_table) {
            const table_size = @as(usize, frame.local_color_table_size) * 3;
            frame.color_table = try self.allocator.alloc(u8, table_size);
            @memcpy(frame.color_table.?, self.data[self.offset .. self.offset + table_size]);
            self.offset += table_size;
        } else {
            frame.color_table = null;
        }

        // Default values (would be set by graphic control extension)
        frame.delay_centiseconds = 0;
        frame.disposal_method = .none;
        frame.transparent_color = false;
        frame.transparent_color_index = 0;

        // Read LZW compressed image data
        const lzw_min_code_size = self.data[self.offset];
        self.offset += 1;

        // Decompress image data
        frame.indices = try self.decompressLzw(lzw_min_code_size, frame.width, frame.height);

        try self.frames.append(frame);
    }

    fn decompressLzw(self: *GifReader, min_code_size: u8, width: u16, height: u16) ![]u8 {
        const output_size = @as(usize, width) * @as(usize, height);
        const output = try self.allocator.alloc(u8, output_size);

        // Simplified LZW decompression (would need full implementation)
        // For now, skip the data blocks
        try self.skipDataSubBlocks();

        // Fill with placeholder data
        @memset(output, 0);

        return output;
    }

    fn skipDataSubBlocks(self: *GifReader) !void {
        while (self.offset < self.data.len) {
            const block_size = self.data[self.offset];
            self.offset += 1;
            if (block_size == 0) break;
            self.offset += block_size;
        }
    }
};

/// GIF writer
pub const GifWriter = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    frames: std.ArrayList(FrameData),
    global_palette: ?[]u8,
    loop_count: u16,

    const FrameData = struct {
        indices: []u8,
        palette: ?[]u8,
        delay_centiseconds: u16,
        disposal_method: Gif.DisposalMethod,
    };

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) GifWriter {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .frames = std.ArrayList(FrameData).init(allocator),
            .global_palette = null,
            .loop_count = 0,
        };
    }

    pub fn deinit(self: *GifWriter) void {
        for (self.frames.items) |frame| {
            self.allocator.free(frame.indices);
            if (frame.palette) |pal| {
                self.allocator.free(pal);
            }
        }
        self.frames.deinit();
        if (self.global_palette) |pal| {
            self.allocator.free(pal);
        }
    }

    pub fn addFrame(self: *GifWriter, rgb_data: []const u8, delay_centiseconds: u16) !void {
        // Quantize to palette (simplified - would use octree or median cut)
        const indices = try self.allocator.alloc(u8, @as(usize, self.width) * self.height);
        @memset(indices, 0); // Placeholder

        try self.frames.append(.{
            .indices = indices,
            .palette = null,
            .delay_centiseconds = delay_centiseconds,
            .disposal_method = .restore_background,
        });
    }

    pub fn write(self: *GifWriter) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        // Header
        try writer.writeAll("GIF89a");

        // Logical screen descriptor
        try writer.writeInt(u16, self.width, .little);
        try writer.writeInt(u16, self.height, .little);

        const packed: u8 = 0xF7; // Global color table, 256 colors
        try writer.writeByte(packed);
        try writer.writeByte(0); // Background color
        try writer.writeByte(0); // Pixel aspect ratio

        // Global color table (256 colors)
        if (self.global_palette) |pal| {
            try writer.writeAll(pal);
        } else {
            // Default grayscale palette
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                const gray: u8 = @truncate(i);
                try writer.writeByte(gray);
                try writer.writeByte(gray);
                try writer.writeByte(gray);
            }
        }

        // Application extension (loop count)
        try writer.writeByte(0x21); // Extension
        try writer.writeByte(0xFF); // Application
        try writer.writeByte(11); // Block size
        try writer.writeAll("NETSCAPE2.0");
        try writer.writeByte(3); // Sub-block size
        try writer.writeByte(1); // Loop sub-block ID
        try writer.writeInt(u16, self.loop_count, .little);
        try writer.writeByte(0); // Block terminator

        // Write frames
        for (self.frames.items) |frame| {
            try self.writeFrame(writer, &frame);
        }

        // Trailer
        try writer.writeByte(0x3B);

        return output.toOwnedSlice();
    }

    fn writeFrame(self: *GifWriter, writer: anytype, frame: *const FrameData) !void {
        _ = self;

        // Graphic control extension
        try writer.writeByte(0x21); // Extension
        try writer.writeByte(0xF9); // Graphic control
        try writer.writeByte(4); // Block size
        const disposal: u8 = @as(u8, @intFromEnum(frame.disposal_method)) << 2;
        try writer.writeByte(disposal);
        try writer.writeInt(u16, frame.delay_centiseconds, .little);
        try writer.writeByte(0); // Transparent color index
        try writer.writeByte(0); // Block terminator

        // Image descriptor
        try writer.writeByte(0x2C); // Image separator
        try writer.writeInt(u16, 0, .little); // Left
        try writer.writeInt(u16, 0, .little); // Top
        try writer.writeInt(u16, self.width, .little);
        try writer.writeInt(u16, self.height, .little);
        try writer.writeByte(0); // No local color table

        // Image data (LZW compressed)
        try writer.writeByte(8); // LZW minimum code size
        // Simplified - would need LZW compression
        try writer.writeByte(0); // Empty data block
    }
};

/// Check if data is GIF
pub fn isGif(data: []const u8) bool {
    if (data.len < 6) return false;
    return std.mem.eql(u8, data[0..3], "GIF") and
        (std.mem.eql(u8, data[3..6], "87a") or std.mem.eql(u8, data[3..6], "89a"));
}

/// Color quantization using octree
pub const OctreeQuantizer = struct {
    const MAX_COLORS = 256;

    root: ?*Node,
    allocator: std.mem.Allocator,
    leaf_count: u32,

    const Node = struct {
        red_sum: u32,
        green_sum: u32,
        blue_sum: u32,
        pixel_count: u32,
        palette_index: u8,
        children: [8]?*Node,
        level: u8,
        is_leaf: bool,
    };

    pub fn init(allocator: std.mem.Allocator) OctreeQuantizer {
        return .{
            .root = null,
            .allocator = allocator,
            .leaf_count = 0,
        };
    }

    pub fn addColor(self: *OctreeQuantizer, r: u8, g: u8, b: u8) !void {
        _ = self;
        _ = r;
        _ = g;
        _ = b;
        // Would build octree
    }

    pub fn getPalette(self: *OctreeQuantizer) ![]u8 {
        return try self.allocator.alloc(u8, MAX_COLORS * 3);
    }
};
