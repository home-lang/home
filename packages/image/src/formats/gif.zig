// GIF Decoder/Encoder
// GIF87a/GIF89a raster decode/encode. See image/docs/gif-codec.md for scope.
// Based on: https://www.w3.org/Graphics/GIF/spec-gif89a.txt

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// GIF Constants
// ============================================================================

const GIF87A_SIGNATURE = "GIF87a";
const GIF89A_SIGNATURE = "GIF89a";

const BlockType = enum(u8) {
    extension = 0x21,
    image_descriptor = 0x2C,
    trailer = 0x3B,
};

const ExtensionType = enum(u8) {
    graphics_control = 0xF9,
    comment = 0xFE,
    plain_text = 0x01,
    application = 0xFF,
};

const DisposalMethod = enum(u3) {
    none = 0,
    keep = 1,
    restore_background = 2,
    restore_previous = 3,
    _,
};

// ============================================================================
// LZW Decoder
// ============================================================================

const LzwDecoder = struct {
    data: []const u8,
    pos: usize,
    min_code_size: u8,
    clear_code: u16,
    end_code: u16,
    next_code: u16,
    code_size: u8,
    bit_buffer: u32,
    bits_in_buffer: u8,

    // Code table
    table: [4096]Entry,

    const Entry = struct {
        prefix: u16,
        suffix: u8,
        length: u16,
    };

    pub fn init(data: []const u8, min_code_size: u8) LzwDecoder {
        const clear_code = @as(u16, 1) << @intCast(min_code_size);
        const end_code = clear_code + 1;

        var decoder = LzwDecoder{
            .data = data,
            .pos = 0,
            .min_code_size = min_code_size,
            .clear_code = clear_code,
            .end_code = end_code,
            .next_code = end_code + 1,
            .code_size = min_code_size + 1,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
            .table = undefined,
        };

        decoder.resetTable();
        return decoder;
    }

    fn resetTable(self: *LzwDecoder) void {
        // Initialize with literal codes
        for (0..@as(usize, self.clear_code)) |i| {
            self.table[i] = Entry{
                .prefix = 0xFFFF,
                .suffix = @intCast(i),
                .length = 1,
            };
        }
        self.next_code = self.end_code + 1;
        self.code_size = self.min_code_size + 1;
    }

    fn readCode(self: *LzwDecoder) ?u16 {
        // Fill bit buffer
        while (self.bits_in_buffer < self.code_size and self.pos < self.data.len) {
            self.bit_buffer |= @as(u32, self.data[self.pos]) << @intCast(self.bits_in_buffer);
            self.bits_in_buffer += 8;
            self.pos += 1;
        }

        if (self.bits_in_buffer < self.code_size) {
            return null;
        }

        const mask = (@as(u32, 1) << @intCast(self.code_size)) - 1;
        const code: u16 = @intCast(self.bit_buffer & mask);
        self.bit_buffer >>= @intCast(self.code_size);
        self.bits_in_buffer -= self.code_size;

        return code;
    }

    fn outputCode(self: *LzwDecoder, allocator: std.mem.Allocator, code: u16, output: *std.ArrayList(u8)) !void {
        if (code >= 4096) return;

        // Build output string (in reverse order first)
        var stack: [4096]u8 = undefined;
        var stack_pos: usize = 0;
        var current = code;

        while (current != 0xFFFF and stack_pos < 4096) {
            if (current >= 4096) break;
            stack[stack_pos] = self.table[current].suffix;
            stack_pos += 1;
            current = self.table[current].prefix;
        }

        // Output in correct order
        while (stack_pos > 0) {
            stack_pos -= 1;
            try output.append(allocator, stack[stack_pos]);
        }
    }

    fn getFirstChar(self: *LzwDecoder, code: u16) u8 {
        var current = code;
        while (current < 4096 and self.table[current].prefix != 0xFFFF) {
            current = self.table[current].prefix;
        }
        if (current >= 4096) return 0;
        return self.table[current].suffix;
    }

    pub fn decode(self: *LzwDecoder, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        var prev_code: ?u16 = null;

        while (true) {
            const code = self.readCode() orelse break;

            if (code == self.end_code) {
                break;
            }

            if (code == self.clear_code) {
                self.resetTable();
                prev_code = null;
                continue;
            }

            if (prev_code == null) {
                try self.outputCode(allocator, code, output);
                prev_code = code;
                continue;
            }

            if (code < self.next_code) {
                try self.outputCode(allocator, code, output);

                // Add new code to table
                if (self.next_code < 4096) {
                    self.table[self.next_code] = Entry{
                        .prefix = prev_code.?,
                        .suffix = self.getFirstChar(code),
                        .length = self.table[prev_code.?].length + 1,
                    };
                    self.next_code += 1;
                }
            } else {
                // Code not in table yet (special case)
                const first_char = self.getFirstChar(prev_code.?);

                if (self.next_code < 4096) {
                    self.table[self.next_code] = Entry{
                        .prefix = prev_code.?,
                        .suffix = first_char,
                        .length = self.table[prev_code.?].length + 1,
                    };
                    self.next_code += 1;
                }

                try self.outputCode(allocator, self.next_code - 1, output);
            }

            prev_code = code;

            // Increase code size if needed
            if (self.next_code >= (@as(u16, 1) << @intCast(self.code_size)) and self.code_size < 12) {
                self.code_size += 1;
            }
        }
    }
};

// ============================================================================
// GIF Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 13) return error.TruncatedData;

    // Check signature
    if (!std.mem.eql(u8, data[0..6], GIF87A_SIGNATURE) and
        !std.mem.eql(u8, data[0..6], GIF89A_SIGNATURE))
    {
        return error.InvalidFormat;
    }

    // Logical screen descriptor
    const width = std.mem.readInt(u16, data[6..8], .little);
    const height = std.mem.readInt(u16, data[8..10], .little);
    const packed_byte = data[10];
    const bg_color_index = data[11];
    _ = bg_color_index;
    // const pixel_aspect = data[12];

    const has_global_color_table = (packed_byte & 0x80) != 0;
    const color_resolution = ((packed_byte >> 4) & 0x07) + 1;
    _ = color_resolution;
    const global_color_table_size: usize = if (has_global_color_table)
        @as(usize, 1) << @as(u4, @intCast((packed_byte & 0x07) + 1))
    else
        0;

    var pos: usize = 13;

    // Read global color table
    var global_palette: ?[]Color = null;
    defer if (global_palette) |p| allocator.free(p);

    if (has_global_color_table) {
        if (global_color_table_size > (data.len - pos) / 3) return error.TruncatedData;
        global_palette = try allocator.alloc(Color, global_color_table_size);
        for (0..global_color_table_size) |i| {
            global_palette.?[i] = Color{
                .r = data[pos],
                .g = data[pos + 1],
                .b = data[pos + 2],
                .a = 255,
            };
            pos += 3;
        }
    }

    // Create output image
    var img = try Image.init(allocator, width, height, .rgba8);
    errdefer img.deinit();

    // Initialize to transparent
    @memset(img.pixels, 0);

    // Animation frames storage
    var frames: std.ArrayList(Image.Frame) = .empty;
    defer {
        for (frames.items) |frame| {
            allocator.free(frame.pixels);
        }
        frames.deinit(allocator);
    }

    // Graphics control extension data
    var transparent_index: ?u8 = null;
    var delay_time: u16 = 0;
    var disposal_method: DisposalMethod = .none;

    // Parse blocks
    while (pos < data.len) {
        const block_type: BlockType = @enumFromInt(data[pos]);
        pos += 1;

        switch (block_type) {
            .extension => {
                if (pos >= data.len) break;
                const ext_type: ExtensionType = @enumFromInt(data[pos]);
                pos += 1;

                switch (ext_type) {
                    .graphics_control => {
                        if (pos + 5 >= data.len) break;
                        // const block_size = data[pos];
                        pos += 1;
                        const gce_packed = data[pos];
                        pos += 1;
                        delay_time = std.mem.readInt(u16, data[pos..][0..2], .little);
                        pos += 2;
                        const trans_idx = data[pos];
                        pos += 1;
                        pos += 1; // Block terminator

                        disposal_method = @enumFromInt((gce_packed >> 2) & 0x07);
                        if ((gce_packed & 0x01) != 0) {
                            transparent_index = trans_idx;
                        } else {
                            transparent_index = null;
                        }
                    },
                    .application => {
                        // Skip application extension
                        pos = skipSubBlocks(data, pos);
                    },
                    .comment => {
                        // Skip comment
                        pos = skipSubBlocks(data, pos);
                    },
                    else => {
                        pos = skipSubBlocks(data, pos);
                    },
                }
            },
            .image_descriptor => {
                if (pos + 9 >= data.len) break;

                const img_left = std.mem.readInt(u16, data[pos..][0..2], .little);
                const img_top = std.mem.readInt(u16, data[pos + 2 ..][0..2], .little);
                const img_width = std.mem.readInt(u16, data[pos + 4 ..][0..2], .little);
                const img_height = std.mem.readInt(u16, data[pos + 6 ..][0..2], .little);
                const img_packed = data[pos + 8];
                pos += 9;

                const has_local_color_table = (img_packed & 0x80) != 0;
                const is_interlaced = (img_packed & 0x40) != 0;
                const local_color_table_size: usize = if (has_local_color_table)
                    @as(usize, 1) << @as(u4, @intCast((img_packed & 0x07) + 1))
                else
                    0;

                // Read local color table
                var local_palette: ?[]Color = null;
                defer if (local_palette) |p| allocator.free(p);

                if (has_local_color_table) {
                    if (local_color_table_size > (data.len - pos) / 3) return error.TruncatedData;
                    local_palette = try allocator.alloc(Color, local_color_table_size);
                    for (0..local_color_table_size) |i| {
                        local_palette.?[i] = Color{
                            .r = data[pos],
                            .g = data[pos + 1],
                            .b = data[pos + 2],
                            .a = 255,
                        };
                        pos += 3;
                    }
                }

                const palette = local_palette orelse global_palette orelse {
                    return error.InvalidFormat; // Need a palette
                };

                // Read image data
                if (pos >= data.len) break;
                const lzw_min_code_size = data[pos];
                pos += 1;

                // Collect sub-blocks
                var lzw_data: std.ArrayList(u8) = .empty;
                defer lzw_data.deinit(allocator);

                while (pos < data.len) {
                    const block_size = data[pos];
                    pos += 1;
                    if (block_size == 0) break;

                    if (pos + block_size > data.len) break;
                    try lzw_data.appendSlice(allocator, data[pos..][0..block_size]);
                    pos += block_size;
                }

                // Decode LZW
                var decoded_pixels: std.ArrayList(u8) = .empty;
                defer decoded_pixels.deinit(allocator);

                var decoder = LzwDecoder.init(lzw_data.items, lzw_min_code_size);
                try decoder.decode(allocator, &decoded_pixels);

                // Apply pixels to image
                applyFrame(&img, decoded_pixels.items, palette, img_left, img_top, img_width, img_height, transparent_index, is_interlaced, disposal_method);

                // Store frame if animated
                if (delay_time > 0 or frames.items.len > 0) {
                    const frame_pixels = try allocator.alloc(u8, img.pixels.len);
                    @memcpy(frame_pixels, img.pixels);

                    frames.append(allocator, Image.Frame{
                        .pixels = frame_pixels,
                        .delay_ms = @as(u32, delay_time) * 10, // GIF delays are in centiseconds
                        .x_offset = img_left,
                        .y_offset = img_top,
                        .dispose_op = switch (disposal_method) {
                            .none, .keep => .none,
                            .restore_background => .background,
                            .restore_previous => .previous,
                            _ => .none,
                        },
                        .blend_op = .source,
                    }) catch |err| {
                        allocator.free(frame_pixels);
                        return err;
                    };
                }

                // Reset for next frame
                transparent_index = null;
                delay_time = 0;
                disposal_method = .none;
            },
            .trailer => break,
        }
    }

    // Store animation frames if we have multiple
    if (frames.items.len > 1) {
        img.frames = try frames.toOwnedSlice(allocator);
    }

    return img;
}

fn skipSubBlocks(data: []const u8, start_pos: usize) usize {
    var pos = start_pos;
    while (pos < data.len) {
        const size = data[pos];
        pos += 1;
        if (size == 0) break;
        pos += size;
    }
    return pos;
}

fn applyFrame(img: *Image, pixels: []const u8, palette: []const Color, left: u16, top: u16, frame_width: u16, frame_height: u16, transparent_index: ?u8, is_interlaced: bool, disposal: DisposalMethod) void {
    _ = disposal;

    const pass_starts = [_]u16{ 0, 4, 2, 1 };
    const pass_increments = [_]u16{ 8, 8, 4, 2 };

    var src_y: u16 = 0;
    var pixel_idx: usize = 0;

    if (is_interlaced) {
        for (0..4) |pass| {
            var y: u32 = pass_starts[pass];
            while (y < frame_height) {
                var x: u16 = 0;
                while (x < frame_width) : (x += 1) {
                    if (pixel_idx >= pixels.len) return;

                    const color_index = pixels[pixel_idx];
                    pixel_idx += 1;

                    if (transparent_index) |ti| {
                        if (color_index == ti) continue;
                    }

                    const px = left + x;
                    const py = top + y;

                    if (px < img.width and py < img.height and color_index < palette.len) {
                        img.setPixel(px, py, palette[color_index]);
                    }
                }
                y += pass_increments[pass];
            }
        }
    } else {
        while (src_y < frame_height) : (src_y += 1) {
            var x: u16 = 0;
            while (x < frame_width) : (x += 1) {
                if (pixel_idx >= pixels.len) return;

                const color_index = pixels[pixel_idx];
                pixel_idx += 1;

                if (transparent_index) |ti| {
                    if (color_index == ti) continue;
                }

                const px = left + x;
                const py = top + src_y;

                if (px < img.width and py < img.height and color_index < palette.len) {
                    img.setPixel(px, py, palette[color_index]);
                }
            }
        }
    }
}

// ============================================================================
// GIF Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    if (img.frames) |frames| if (frames.len != 0) return error.UnsupportedAnimation;
    const encoder = @import("gif_encoder.zig");
    if (img.format != .indexed8) return encoder.encode(allocator, try encoder.raster.fromImage(img), .{});
    const indexed = @import("indexed_raster.zig");
    const view = try indexed.indexedView(img.pixels, img.width, img.height);
    try indexed.validateIndices(img, view);
    const rgba = try indexed.expandIndices(allocator, img, view);
    defer allocator.free(rgba.data);
    return encoder.encode(allocator, rgba, .{});
}

// ============================================================================
// Tests
// ============================================================================

test "GIF signature" {
    try std.testing.expectEqualStrings("GIF89a", GIF89A_SIGNATURE);
}

test "LZW decoder initialization" {
    const data = [_]u8{ 0x04, 0x01, 0x00 };
    const decoder = LzwDecoder.init(&data, 2);
    try std.testing.expectEqual(@as(u16, 4), decoder.clear_code);
    try std.testing.expectEqual(@as(u16, 5), decoder.end_code);
}

test "GIF encoder round trips basic palette colors" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 1, .rgba8);
    defer img.deinit();
    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.BLUE);

    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqual(Color.RED, decoded.getPixel(0, 0).?);
    try std.testing.expectEqual(Color.BLUE, decoded.getPixel(1, 0).?);
}
test "GIF public adapter preserves equal-luminance hues sixteen-bit high bytes and binary alpha" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 4, 1, .rgba16);
    defer img.deinit();
    const words = [_]u16{ 65535, 0, 0, 65535, 0, 65535, 0, 32768, 0, 0, 65535, 32767, 0x1234, 0x5678, 0x9abc, 65535 };
    for (words, 0..) |word, i| std.mem.writeInt(u16, img.pixels[i * 2 ..][0..2], word, .little);
    const bytes = try img.encode(.gif);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0x12, 0x56, 0x9a, 255 }, decoded.pixels);
}
test "GIF indexed adapter shares validated alpha expansion and rejects missing palette entries" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 2, 1, .indexed8);
    defer img.deinit();
    try std.testing.expectError(error.InvalidPalette, img.encode(.gif));
    img.palette = try a.dupe(Color, &.{ Color.RED, .{ .r = 0, .g = 255, .b = 0, .a = 127 } });
    img.pixels[1] = 1;
    const bytes = try img.encode(.gif);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 0 }, decoded.pixels);
    img.pixels[1] = 2;
    try std.testing.expectError(error.InvalidPalette, img.encode(.gif));
}

test "GIF image encoder preserves a large grayscale pattern through dictionary width changes" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 128, 64, .rgb8);
    defer img.deinit();
    const values = [_]u8{ 0, 64, 128, 255 };
    for (0..img.height) |y| for (0..img.width) |x| {
        const v = values[(x + y) % 4];
        img.setPixel(@intCast(x), @intCast(y), .{ .r = v, .g = v, .b = v, .a = 255 });
    };
    const bytes = try encode(a, &img);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    for (0..img.height) |y| for (0..img.width) |x| {
        const c = decoded.getPixel(@intCast(x), @intCast(y)) orelse return error.MissingPixel;
        const v = values[(x + y) % 4];
        try std.testing.expectEqual([3]u8{ v, v, v }, [3]u8{ c.r, c.g, c.b });
    };
}
