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
        // Quantize RGB data to 256 color palette using median cut
        var quantizer = MedianCutQuantizer.init(self.allocator);
        defer quantizer.deinit();

        const pixel_count = @as(usize, self.width) * self.height;
        const indices = try self.allocator.alloc(u8, pixel_count);
        errdefer self.allocator.free(indices);

        // Build color histogram and quantize
        const palette = try quantizer.quantize(rgb_data, 256);
        defer self.allocator.free(palette);

        // Map pixels to palette indices
        for (0..pixel_count) |i| {
            const r = rgb_data[i * 3];
            const g = rgb_data[i * 3 + 1];
            const b = rgb_data[i * 3 + 2];
            indices[i] = quantizer.findNearestColor(r, g, b);
        }

        try self.frames.append(.{
            .indices = indices,
            .palette = try self.allocator.dupe(u8, palette),
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

        // Use local color table if frame has palette
        if (frame.palette != null) {
            const palette_size_code: u8 = 7; // 256 colors = 2^(7+1)
            const packed: u8 = 0x80 | palette_size_code; // Local color table flag
            try writer.writeByte(packed);

            // Write local color table
            if (frame.palette) |pal| {
                try writer.writeAll(pal);
                // Pad to 256 colors if needed
                const needed_size = 768; // 256 * 3
                if (pal.len < needed_size) {
                    var i: usize = pal.len;
                    while (i < needed_size) : (i += 1) {
                        try writer.writeByte(0);
                    }
                }
            }
        } else {
            try writer.writeByte(0); // No local color table
        }

        // LZW compress and write image data
        try self.writeLzwData(writer, frame.indices);
    }

    fn writeLzwData(self: *GifWriter, writer: anytype, indices: []const u8) !void {
        _ = self;
        const min_code_size: u8 = 8;
        try writer.writeByte(min_code_size);

        // Simple LZW compression
        var lzw = LzwEncoder.init(min_code_size);
        const compressed = try lzw.encode(indices);
        defer lzw.allocator.free(compressed);

        // Write in data sub-blocks (max 255 bytes each)
        var offset: usize = 0;
        while (offset < compressed.len) {
            const block_size = @min(255, compressed.len - offset);
            try writer.writeByte(@intCast(block_size));
            try writer.writeAll(compressed[offset .. offset + block_size]);
            offset += block_size;
        }

        // Block terminator
        try writer.writeByte(0);
    }

    const LzwEncoder = struct {
        min_code_size: u8,
        allocator: std.mem.Allocator,

        fn init(min_code_size: u8) LzwEncoder {
            return .{
                .min_code_size = min_code_size,
                .allocator = std.heap.page_allocator,
            };
        }

        fn encode(self: *LzwEncoder, data: []const u8) ![]u8 {
            // Simplified LZW: just write clear code, data, and end code
            var output = std.ArrayList(u8).init(self.allocator);
            errdefer output.deinit();

            const clear_code: u16 = @as(u16, 1) << @intCast(self.min_code_size);
            const end_code: u16 = clear_code + 1;
            var next_code: u16 = end_code + 1;

            var code_size: u8 = self.min_code_size + 1;
            var bit_buffer: u32 = 0;
            var bits_in_buffer: u8 = 0;

            // Write clear code
            try self.writeCode(&output, &bit_buffer, &bits_in_buffer, clear_code, code_size);

            // Write data codes
            for (data) |byte| {
                try self.writeCode(&output, &bit_buffer, &bits_in_buffer, byte, code_size);

                next_code += 1;
                if (next_code >= (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
                    code_size += 1;
                }
            }

            // Write end code
            try self.writeCode(&output, &bit_buffer, &bits_in_buffer, end_code, code_size);

            // Flush remaining bits
            if (bits_in_buffer > 0) {
                try output.append(@truncate(bit_buffer));
            }

            return output.toOwnedSlice();
        }

        fn writeCode(
            self: *LzwEncoder,
            output: *std.ArrayList(u8),
            bit_buffer: *u32,
            bits_in_buffer: *u8,
            code: u16,
            code_size: u8,
        ) !void {
            _ = self;

            // Add code to bit buffer
            bit_buffer.* |= @as(u32, code) << @intCast(bits_in_buffer.*);
            bits_in_buffer.* += code_size;

            // Output bytes
            while (bits_in_buffer.* >= 8) {
                try output.append(@truncate(bit_buffer.*));
                bit_buffer.* >>= 8;
                bits_in_buffer.* -= 8;
            }
        }
    };
};

/// Check if data is GIF
pub fn isGif(data: []const u8) bool {
    if (data.len < 6) return false;
    return std.mem.eql(u8, data[0..3], "GIF") and
        (std.mem.eql(u8, data[3..6], "87a") or std.mem.eql(u8, data[3..6], "89a"));
}

/// Color quantization using median cut algorithm
pub const MedianCutQuantizer = struct {
    allocator: std.mem.Allocator,
    palette: []u8,
    palette_size: usize,

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    const ColorBox = struct {
        colors: std.ArrayList(Color),
        min_r: u8,
        max_r: u8,
        min_g: u8,
        max_g: u8,
        min_b: u8,
        max_b: u8,

        fn init(allocator: std.mem.Allocator) ColorBox {
            return .{
                .colors = std.ArrayList(Color).init(allocator),
                .min_r = 255,
                .max_r = 0,
                .min_g = 255,
                .max_g = 0,
                .min_b = 255,
                .max_b = 0,
            };
        }

        fn deinit(self: *ColorBox) void {
            self.colors.deinit();
        }

        fn addColor(self: *ColorBox, c: Color) !void {
            try self.colors.append(c);
            if (c.r < self.min_r) self.min_r = c.r;
            if (c.r > self.max_r) self.max_r = c.r;
            if (c.g < self.min_g) self.min_g = c.g;
            if (c.g > self.max_g) self.max_g = c.g;
            if (c.b < self.min_b) self.min_b = c.b;
            if (c.b > self.max_b) self.max_b = c.b;
        }

        fn longestAxis(self: *const ColorBox) u8 {
            const r_range = self.max_r - self.min_r;
            const g_range = self.max_g - self.min_g;
            const b_range = self.max_b - self.min_b;

            if (r_range >= g_range and r_range >= b_range) return 0; // Red
            if (g_range >= b_range) return 1; // Green
            return 2; // Blue
        }

        fn split(self: *ColorBox, allocator: std.mem.Allocator) !struct { ColorBox, ColorBox } {
            const axis = self.longestAxis();
            const median_idx = self.colors.items.len / 2;

            // Sort colors by the longest axis
            if (axis == 0) {
                std.mem.sort(Color, self.colors.items, {}, struct {
                    fn lessThan(_: void, a: Color, b: Color) bool {
                        return a.r < b.r;
                    }
                }.lessThan);
            } else if (axis == 1) {
                std.mem.sort(Color, self.colors.items, {}, struct {
                    fn lessThan(_: void, a: Color, b: Color) bool {
                        return a.g < b.g;
                    }
                }.lessThan);
            } else {
                std.mem.sort(Color, self.colors.items, {}, struct {
                    fn lessThan(_: void, a: Color, b: Color) bool {
                        return a.b < b.b;
                    }
                }.lessThan);
            }

            // Create two new boxes
            var box1 = ColorBox.init(allocator);
            var box2 = ColorBox.init(allocator);

            for (self.colors.items, 0..) |c, i| {
                if (i < median_idx) {
                    try box1.addColor(c);
                } else {
                    try box2.addColor(c);
                }
            }

            return .{ box1, box2 };
        }

        fn averageColor(self: *const ColorBox) Color {
            if (self.colors.items.len == 0) {
                return .{ .r = 0, .g = 0, .b = 0 };
            }

            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;

            for (self.colors.items) |c| {
                sum_r += c.r;
                sum_g += c.g;
                sum_b += c.b;
            }

            const count: u32 = @intCast(self.colors.items.len);
            return .{
                .r = @intCast(sum_r / count),
                .g = @intCast(sum_g / count),
                .b = @intCast(sum_b / count),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) MedianCutQuantizer {
        return .{
            .allocator = allocator,
            .palette = &[_]u8{},
            .palette_size = 0,
        };
    }

    pub fn deinit(self: *MedianCutQuantizer) void {
        if (self.palette.len > 0) {
            self.allocator.free(self.palette);
        }
    }

    pub fn quantize(self: *MedianCutQuantizer, rgb_data: []const u8, max_colors: usize) ![]u8 {
        // Build initial color box
        var initial_box = ColorBox.init(self.allocator);
        defer initial_box.deinit();

        const pixel_count = rgb_data.len / 3;
        for (0..pixel_count) |i| {
            try initial_box.addColor(.{
                .r = rgb_data[i * 3],
                .g = rgb_data[i * 3 + 1],
                .b = rgb_data[i * 3 + 2],
            });
        }

        // Start with one box
        var boxes = std.ArrayList(ColorBox).init(self.allocator);
        defer {
            for (boxes.items) |*box| box.deinit();
            boxes.deinit();
        }

        try boxes.append(initial_box);

        // Split boxes until we have desired number of colors
        while (boxes.items.len < max_colors) {
            // Find box with most colors to split
            var largest_idx: usize = 0;
            var largest_size: usize = 0;

            for (boxes.items, 0..) |*box, i| {
                if (box.colors.items.len > largest_size) {
                    largest_size = box.colors.items.len;
                    largest_idx = i;
                }
            }

            // Stop if largest box has only one color
            if (largest_size <= 1) break;

            // Split the largest box
            const box_to_split = boxes.orderedRemove(largest_idx);
            const split_result = try box_to_split.split(self.allocator);

            // Note: box_to_split will be deinitialized by boxes.deinit
            // so we don't need to deinit it here

            try boxes.append(split_result[0]);
            try boxes.append(split_result[1]);
        }

        // Generate palette from boxes
        const palette = try self.allocator.alloc(u8, boxes.items.len * 3);
        for (boxes.items, 0..) |*box, i| {
            const avg = box.averageColor();
            palette[i * 3] = avg.r;
            palette[i * 3 + 1] = avg.g;
            palette[i * 3 + 2] = avg.b;
        }

        self.palette = palette;
        self.palette_size = boxes.items.len;

        return palette;
    }

    pub fn findNearestColor(self: *const MedianCutQuantizer, r: u8, g: u8, b: u8) u8 {
        if (self.palette_size == 0) return 0;

        var min_dist: u32 = std.math.maxInt(u32);
        var best_idx: u8 = 0;

        for (0..self.palette_size) |i| {
            const pr = self.palette[i * 3];
            const pg = self.palette[i * 3 + 1];
            const pb = self.palette[i * 3 + 2];

            const dr = @as(i32, r) - @as(i32, pr);
            const dg = @as(i32, g) - @as(i32, pg);
            const db = @as(i32, b) - @as(i32, pb);

            const dist: u32 = @intCast(dr * dr + dg * dg + db * db);

            if (dist < min_dist) {
                min_dist = dist;
                best_idx = @intCast(i);
            }
        }

        return best_idx;
    }
};
