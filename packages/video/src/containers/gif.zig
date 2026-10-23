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
        global_color_table_size: u16,
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
        local_color_table_size: u16,
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
    pending_control: struct {
        delay: u16 = 0,
        disposal: Gif.DisposalMethod = .none,
        transparent: bool = false,
        index: u8 = 0,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !GifReader {
        if (data.len < 13) return error.InvalidGif;
        if (!isGif(data)) return error.InvalidSignature;

        var reader = GifReader{
            .allocator = allocator,
            .data = data,
            .offset = 0,
            .header = undefined,
            .global_color_table = null,
            .frames = .empty,
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
        self.frames.deinit(self.allocator);
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

        const packed_fields = self.data[self.offset + 4];
        self.header.global_color_table = (packed_fields & 0x80) != 0;
        self.header.color_resolution = @truncate((packed_fields >> 4) & 0x07);
        self.header.sort_flag = (packed_fields & 0x08) != 0;
        const gct_size_code: u3 = @truncate(packed_fields & 0x07);
        self.header.global_color_table_size = @as(u16, 1) << (@as(u4, gct_size_code) + 1);

        self.header.background_color_index = self.data[self.offset + 5];
        self.header.pixel_aspect_ratio = self.data[self.offset + 6];

        self.offset += 7;

        // Read global color table
        if (self.header.global_color_table) {
            const table_size = @as(usize, self.header.global_color_table_size) * 3;
            if (table_size > self.data.len - self.offset) return error.TruncatedGif;
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
        if (self.offset >= self.data.len) return error.TruncatedGif;
        const label = self.data[self.offset];
        self.offset += 1;

        switch (label) {
            0xF9 => try self.parseGraphicControlExtension(),
            0xFF => try self.parseApplicationExtension(),
            0xFE => try self.skipDataSubBlocks(), // Comment
            0x01 => { // Plain text consumes a preceding graphic control block.
                try self.skipDataSubBlocks();
                self.pending_control = .{};
            },
            else => try self.skipDataSubBlocks(),
        }
    }

    fn parseGraphicControlExtension(self: *GifReader) !void {
        if (self.offset >= self.data.len) return error.TruncatedGif;
        const block_size = self.data[self.offset];
        if (block_size != 4) return error.InvalidGraphicControl;
        if (self.data.len - self.offset < 6) return error.TruncatedGif;
        const fields = self.data[self.offset + 1];
        const disposal = (fields >> 2) & 7;
        if (disposal > 3 or self.data[self.offset + 5] != 0) return error.InvalidGraphicControl;
        self.pending_control = .{
            .delay = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little),
            .disposal = @enumFromInt(disposal),
            .transparent = fields & 1 != 0,
            .index = self.data[self.offset + 4],
        };
        self.offset += 6;
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
        if (self.data.len - self.offset < 9) return error.TruncatedGif;
        var frame: Gif.Frame = undefined;

        // Image descriptor (9 bytes)
        frame.left = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
        frame.top = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);
        frame.width = std.mem.readInt(u16, self.data[self.offset + 4 ..][0..2], .little);
        frame.height = std.mem.readInt(u16, self.data[self.offset + 6 ..][0..2], .little);

        const packed_fields = self.data[self.offset + 8];
        frame.local_color_table = (packed_fields & 0x80) != 0;
        frame.interlaced = (packed_fields & 0x40) != 0;
        frame.sort_flag = (packed_fields & 0x20) != 0;
        const lct_size_code: u3 = @truncate(packed_fields & 0x07);
        frame.local_color_table_size = @as(u16, 1) << (@as(u4, lct_size_code) + 1);
        if (frame.width == 0 or frame.height == 0) return error.InvalidDimensions;

        self.offset += 9;

        // Read local color table
        if (frame.local_color_table) {
            const table_size = @as(usize, frame.local_color_table_size) * 3;
            if (table_size > self.data.len - self.offset) return error.TruncatedGif;
            frame.color_table = try self.allocator.alloc(u8, table_size);
            errdefer self.allocator.free(frame.color_table.?);
            @memcpy(frame.color_table.?, self.data[self.offset .. self.offset + table_size]);
            self.offset += table_size;
        } else {
            frame.color_table = null;
        }

        frame.delay_centiseconds = self.pending_control.delay;
        frame.disposal_method = self.pending_control.disposal;
        frame.transparent_color = self.pending_control.transparent;
        frame.transparent_color_index = self.pending_control.index;

        // Read LZW compressed image data
        if (self.offset >= self.data.len) return error.TruncatedGif;
        const lzw_min_code_size = self.data[self.offset];
        self.offset += 1;

        // Decompress image data
        frame.indices = try self.decompressLzw(lzw_min_code_size, frame.width, frame.height);
        errdefer self.allocator.free(frame.indices);

        try self.frames.append(self.allocator, frame);
        self.pending_control = .{};
    }

    fn decompressLzw(self: *GifReader, min_code_size: u8, width: u16, height: u16) ![]u8 {
        if (min_code_size < 2 or min_code_size > 8) return error.InvalidLzwCodeSize;

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(self.allocator);

        while (true) {
            if (self.offset >= self.data.len) return error.TruncatedGifData;
            const block_size = self.data[self.offset];
            self.offset += 1;
            if (block_size == 0) break;

            const block_end = std.math.add(usize, self.offset, block_size) catch
                return error.TruncatedGifData;
            if (block_end > self.data.len) return error.TruncatedGifData;
            try compressed.appendSlice(self.allocator, self.data[self.offset..block_end]);
            self.offset = block_end;
        }

        const output_size = std.math.mul(usize, width, height) catch
            return error.InvalidImageDimensions;
        const output = try self.allocator.alloc(u8, output_size);
        errdefer self.allocator.free(output);

        const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
        const end_code = clear_code + 1;
        var next_code = end_code + 1;
        var code_size: u8 = min_code_size + 1;

        var prefixes: [4096]u16 = undefined;
        var suffixes: [4096]u8 = undefined;
        var stack: [4096]u8 = undefined;
        for (0..clear_code) |code| suffixes[code] = @intCast(code);

        var byte_index: usize = 0;
        var bit_buffer: u32 = 0;
        var bits_in_buffer: u8 = 0;
        var output_index: usize = 0;
        var previous_code: ?u16 = null;
        var first_byte: u8 = 0;
        var saw_end_code = false;

        while (true) {
            while (bits_in_buffer < code_size) {
                if (byte_index >= compressed.items.len) return error.TruncatedLzwData;
                bit_buffer |= @as(u32, compressed.items[byte_index]) << @intCast(bits_in_buffer);
                bits_in_buffer += 8;
                byte_index += 1;
            }

            const code_mask = (@as(u32, 1) << @intCast(code_size)) - 1;
            const code: u16 = @intCast(bit_buffer & code_mask);
            bit_buffer >>= @intCast(code_size);
            bits_in_buffer -= code_size;

            if (code == clear_code) {
                next_code = end_code + 1;
                code_size = min_code_size + 1;
                previous_code = null;
                continue;
            }
            if (code == end_code) {
                saw_end_code = true;
                break;
            }
            if (code > next_code or (code == next_code and previous_code == null)) {
                return error.InvalidLzwCode;
            }

            const input_code = code;
            var expanded_code = code;
            var stack_len: usize = 0;

            if (expanded_code == next_code) {
                stack[stack_len] = first_byte;
                stack_len += 1;
                expanded_code = previous_code.?;
            }

            while (expanded_code >= clear_code) {
                if (expanded_code >= next_code or stack_len >= stack.len) {
                    return error.InvalidLzwCode;
                }
                stack[stack_len] = suffixes[expanded_code];
                stack_len += 1;
                expanded_code = prefixes[expanded_code];
            }

            first_byte = @intCast(expanded_code);
            if (stack_len >= stack.len) return error.InvalidLzwCode;
            stack[stack_len] = first_byte;
            stack_len += 1;

            if (output_index + stack_len > output.len) return error.InvalidLzwOutput;
            while (stack_len > 0) {
                stack_len -= 1;
                output[output_index] = stack[stack_len];
                output_index += 1;
            }

            if (previous_code) |previous| {
                if (next_code < 4096) {
                    prefixes[next_code] = previous;
                    suffixes[next_code] = first_byte;
                    next_code += 1;
                    if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
                        code_size += 1;
                    }
                }
            }
            previous_code = input_code;
        }

        if (!saw_end_code or output_index != output.len) return error.InvalidLzwOutput;

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
            .frames = .empty,
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
        self.frames.deinit(self.allocator);
        if (self.global_palette) |pal| {
            self.allocator.free(pal);
        }
    }

    pub fn addFrame(self: *GifWriter, rgb_data: []const u8, delay_centiseconds: u16) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidDimensions;
        const required = try std.math.mul(usize, try std.math.mul(usize, self.width, self.height), 3);
        if (rgb_data.len != required) return error.InvalidPixels;
        // Quantize RGB data to 256 color palette using median cut
        var quantizer = MedianCutQuantizer.init(self.allocator);
        defer quantizer.deinit();

        const pixel_count = @as(usize, self.width) * self.height;
        const indices = try self.allocator.alloc(u8, pixel_count);
        errdefer self.allocator.free(indices);

        // Build color histogram and quantize
        // Borrowed until quantizer.deinit; the frame retains its own copy below.
        const palette = try quantizer.quantize(rgb_data, 256);

        // Map pixels to palette indices
        for (0..pixel_count) |i| {
            const r = rgb_data[i * 3];
            const g = rgb_data[i * 3 + 1];
            const b = rgb_data[i * 3 + 2];
            indices[i] = quantizer.findNearestColor(r, g, b);
        }

        const owned_palette = try self.allocator.dupe(u8, palette);
        errdefer self.allocator.free(owned_palette);
        try self.frames.append(self.allocator, .{
            .indices = indices,
            .palette = owned_palette,
            .delay_centiseconds = delay_centiseconds,
            .disposal_method = .restore_background,
        });
    }

    pub fn write(self: *GifWriter) ![]u8 {
        if (self.width == 0 or self.height == 0) return error.InvalidDimensions;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        const Writer = struct {
            allocator: std.mem.Allocator,
            bytes: *std.ArrayList(u8),
            pub fn writeAll(sink: @This(), bytes: []const u8) !void {
                try sink.bytes.appendSlice(sink.allocator, bytes);
            }
            pub fn writeByte(sink: @This(), value: u8) !void {
                try sink.bytes.append(sink.allocator, value);
            }
            pub fn writeInt(sink: @This(), comptime T: type, value: T, endian: std.builtin.Endian) !void {
                var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, endian);
                try sink.writeAll(&bytes);
            }
        };
        const writer = Writer{ .allocator = self.allocator, .bytes = &output };

        // Header
        try writer.writeAll("GIF89a");

        // Logical screen descriptor
        try writer.writeInt(u16, self.width, .little);
        try writer.writeInt(u16, self.height, .little);

        const packed_fields: u8 = 0xF7; // Global color table, 256 colors
        try writer.writeByte(packed_fields);
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

        return output.toOwnedSlice(self.allocator);
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
            const packed_fields: u8 = 0x80 | palette_size_code; // Local color table flag
            try writer.writeByte(packed_fields);

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
        const min_code_size: u8 = 8;
        try writer.writeByte(min_code_size);

        // Simple LZW compression
        var lzw = LzwEncoder.init(min_code_size);
        lzw.allocator = self.allocator;
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
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(self.allocator);

            const clear_code: u16 = @as(u16, 1) << @intCast(self.min_code_size);
            const end_code: u16 = clear_code + 1;
            var next_code: u16 = end_code + 1;

            var code_size: u8 = self.min_code_size + 1;
            var bit_buffer: u32 = 0;
            var bits_in_buffer: u8 = 0;

            // Write clear code
            try self.writeCode(&output, &bit_buffer, &bits_in_buffer, clear_code, code_size);

            var has_previous = false;
            for (data) |byte| {
                try self.writeCode(&output, &bit_buffer, &bits_in_buffer, byte, code_size);

                if (has_previous) {
                    next_code += 1;
                    if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
                        code_size += 1;
                    }
                    if (next_code == 4096) {
                        try self.writeCode(&output, &bit_buffer, &bits_in_buffer, clear_code, code_size);
                        next_code = end_code + 1;
                        code_size = self.min_code_size + 1;
                        has_previous = false;
                        continue;
                    }
                }
                has_previous = true;
            }

            // Write end code
            try self.writeCode(&output, &bit_buffer, &bits_in_buffer, end_code, code_size);

            // Flush remaining bits
            if (bits_in_buffer > 0) {
                try output.append(self.allocator, @truncate(bit_buffer));
            }

            return output.toOwnedSlice(self.allocator);
        }

        fn writeCode(
            self: *LzwEncoder,
            output: *std.ArrayList(u8),
            bit_buffer: *u32,
            bits_in_buffer: *u8,
            code: u16,
            code_size: u8,
        ) !void {
            // Add code to bit buffer
            bit_buffer.* |= @as(u32, code) << @intCast(bits_in_buffer.*);
            bits_in_buffer.* += code_size;

            // Output bytes
            while (bits_in_buffer.* >= 8) {
                try output.append(self.allocator, @truncate(bit_buffer.*));
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

test "GIF LZW encoder and decoder preserve indexed pixels" {
    const allocator = std.testing.allocator;
    const indices = [_]u8{
        0, 1, 2, 3,
        3, 2, 1, 0,
        0, 0, 1, 1,
        2, 2, 3, 3,
    };

    var encoder = GifWriter.LzwEncoder.init(2);
    encoder.allocator = allocator;
    const compressed = try encoder.encode(&indices);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len <= 255);

    const sub_blocks = try allocator.alloc(u8, compressed.len + 2);
    defer allocator.free(sub_blocks);
    sub_blocks[0] = @intCast(compressed.len);
    @memcpy(sub_blocks[1 .. compressed.len + 1], compressed);
    sub_blocks[sub_blocks.len - 1] = 0;

    var reader = GifReader{
        .allocator = allocator,
        .data = sub_blocks,
        .offset = 0,
        .header = undefined,
        .global_color_table = null,
        .frames = .empty,
        .loop_count = 0,
    };
    defer reader.frames.deinit(allocator);

    const decoded = try reader.decompressLzw(2, 4, 4);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &indices, decoded);
    try std.testing.expectEqual(sub_blocks.len, reader.offset);
}

/// Shared bounded weighted median-cut quantizer; preserves the public owner API.
pub const MedianCutQuantizer = @import("palette_quantizer.zig").Quantizer;

fn gifWriterAllocationFailures(allocator: std.mem.Allocator) !void {
    var writer = GifWriter.init(allocator, 2, 2);
    defer writer.deinit();
    try writer.addFrame(&.{ 255, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0, 255 }, 10);
    try writer.addFrame(&.{ 0, 255, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0 }, 20);
    const bytes = try writer.write();
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 20);
}
test "GIF writer owns each frame palette once and unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, gifWriterAllocationFailures, .{});
    var writer = GifWriter.init(std.testing.allocator, 2, 2);
    defer writer.deinit();
    try std.testing.expectError(error.InvalidPixels, writer.addFrame(&.{ 0, 1, 2 }, 10));
    try std.testing.expectEqual(@as(usize, 0), writer.frames.items.len);
    var empty = GifWriter.init(std.testing.failing_allocator, 0, 2);
    defer empty.deinit();
    try std.testing.expectError(error.InvalidDimensions, empty.addFrame(&.{}, 0));
    try std.testing.expectError(error.InvalidDimensions, empty.write());
}
test "GIF quantizer replacement retains owned palette on failure and releases previous success" {
    const t = std.testing;
    var q = MedianCutQuantizer.init(t.allocator);
    defer q.deinit();
    const first = try q.quantize(&.{ 255, 0, 0, 0, 0, 255 }, 2);
    const address = first.ptr;
    try t.expectEqual(@as(usize, 6), first.len);
    try t.expectError(error.InvalidColors, q.quantize(&.{ 0, 0, 0 }, 0));
    try t.expectError(error.InvalidColors, q.quantize(&.{ 0, 0, 0 }, 257));
    try t.expectError(error.InvalidPixels, q.quantize(&.{ 0, 0 }, 2));
    try t.expectError(error.InvalidPixels, q.quantize(&.{}, 2));
    try t.expect(q.palette.ptr == address);
    try t.expectEqual(@as(usize, 2), q.palette_size);
    const second = try q.quantize(&.{ 0, 255, 0 }, 1);
    try t.expectEqualSlices(u8, &.{ 0, 255, 0 }, second);
    try t.expect(second.ptr != address);
    try t.expectEqual(@as(usize, 1), q.palette_size);
}
test "GIF public writer emits two independent frames with retained delays and RGB palettes" {
    const t = std.testing;
    var writer = GifWriter.init(t.allocator, 2, 1);
    defer writer.deinit();
    try writer.addFrame(&.{ 255, 0, 0, 0, 0, 255 }, 10);
    try writer.addFrame(&.{ 0, 255, 0, 0, 0, 0 }, 20);
    const bytes = try writer.write();
    defer t.allocator.free(bytes);
    var reader = try GifReader.init(t.allocator, bytes);
    defer reader.deinit();
    try reader.readFrames();
    try t.expectEqual(@as(usize, 2), reader.frames.items.len);
    try t.expectEqual(@as(u16, 256), reader.header.global_color_table_size);
    for (reader.frames.items, 0..) |frame, i| {
        try t.expectEqual(@as(u16, if (i == 0) 10 else 20), frame.delay_centiseconds);
        try t.expectEqual(@as(u16, 256), frame.local_color_table_size);
        const palette = frame.color_table orelse return error.MissingPalette;
        const expected = if (i == 0) [_]u8{ 255, 0, 0, 0, 0, 255 } else [_]u8{ 0, 255, 0, 0, 0, 0 };
        for (frame.indices, 0..) |index, x| try t.expectEqualSlices(u8, expected[x * 3 ..][0..3], palette[@as(usize, index) * 3 ..][0..3]);
    }
}

fn quantizerReplacementFailures(a: std.mem.Allocator) !void {
    var q = MedianCutQuantizer.init(a);
    defer q.deinit();
    const original = try q.quantize(&.{ 255, 0, 0, 0, 0, 255 }, 2);
    var expected: [6]u8 = undefined;
    @memcpy(&expected, original);
    const pointer = original.ptr;
    const replacement = q.quantize(&.{ 0, 255, 0 }, 1) catch |err| {
        try std.testing.expect(q.palette.ptr == pointer);
        try std.testing.expectEqualSlices(u8, &expected, q.palette);
        return err;
    };
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, replacement);
}
test "GIF failed quantizer reallocation retains the previously borrowed palette" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, quantizerReplacementFailures, .{});
}
test "GIF graphic control belongs only to its next image and truncated control/table data rejects" {
    const t = std.testing;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(t.allocator);
    try data.appendSlice(t.allocator, "GIF89a");
    try data.appendSlice(t.allocator, &.{ 1, 0, 1, 0, 0x81, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 });
    try data.appendSlice(t.allocator, &.{ 0x21, 0xf9, 4, 0x0d, 0x34, 0x12, 2, 0 });
    try data.appendSlice(t.allocator, &.{ 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0 });
    try data.appendSlice(t.allocator, &.{ 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4c, 1, 0, 0x3b });
    var reader = try GifReader.init(t.allocator, data.items);
    defer reader.deinit();
    try reader.readFrames();
    try t.expectEqual(@as(usize, 2), reader.frames.items.len);
    const first = reader.frames.items[0];
    const second = reader.frames.items[1];
    try t.expectEqual(@as(u16, 0x1234), first.delay_centiseconds);
    try t.expectEqual(Gif.DisposalMethod.restore_previous, first.disposal_method);
    try t.expect(first.transparent_color);
    try t.expectEqual(@as(u8, 2), first.transparent_color_index);
    try t.expectEqual(@as(u16, 0), second.delay_centiseconds);
    try t.expectEqual(Gif.DisposalMethod.none, second.disposal_method);
    try t.expect(!second.transparent_color);
    const header = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0, 0, 0 };
    const control = [_]u8{ 0x21, 0xf9, 4, 0x0d, 0x34, 0x12, 2, 0 };
    var short: [21]u8 = undefined;
    @memcpy(short[0..13], &header);
    @memcpy(short[13..], &control);
    for (1..control.len) |n| {
        var truncated = try GifReader.init(t.allocator, short[0 .. 13 + n]);
        defer truncated.deinit();
        try t.expectError(error.TruncatedGif, truncated.readFrames());
    }
    var palette_header = header;
    palette_header[10] = 0x87;
    try t.expectError(error.TruncatedGif, GifReader.init(std.testing.failing_allocator, &palette_header));
}
