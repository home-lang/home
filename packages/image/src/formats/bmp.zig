// BMP Decoder/Encoder
// Implements Windows Bitmap format

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// BMP Constants
// ============================================================================

const BMP_SIGNATURE = [_]u8{ 'B', 'M' };

const CompressionMethod = enum(u32) {
    BI_RGB = 0,
    BI_RLE8 = 1,
    BI_RLE4 = 2,
    BI_BITFIELDS = 3,
    BI_JPEG = 4,
    BI_PNG = 5,
    BI_ALPHABITFIELDS = 6,
    _,
};

// ============================================================================
// BMP Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 54) return error.TruncatedData;

    // Check signature
    if (!std.mem.eql(u8, data[0..2], &BMP_SIGNATURE)) {
        return error.InvalidFormat;
    }

    // Parse file header
    const data_offset = std.mem.readInt(u32, data[10..14], .little);

    // Parse DIB header
    const header_size = std.mem.readInt(u32, data[14..18], .little);
    if (header_size < 40) return error.InvalidHeader; // Require at least BITMAPINFOHEADER

    const width_signed = std.mem.readInt(i32, data[18..22], .little);
    const height_signed = std.mem.readInt(i32, data[22..26], .little);

    const width: u32 = @intCast(@as(i64, @abs(width_signed)));
    const height: u32 = @intCast(@as(i64, @abs(height_signed)));
    const top_down = height_signed < 0;

    if (width == 0 or height == 0) return error.InvalidDimensions;

    const planes = std.mem.readInt(u16, data[26..28], .little);
    if (planes != 1) return error.InvalidFormat;

    const bit_depth = std.mem.readInt(u16, data[28..30], .little);
    const compression: CompressionMethod = @enumFromInt(std.mem.readInt(u32, data[30..34], .little));

    // Determine output format
    const output_format: PixelFormat = switch (bit_depth) {
        1, 4, 8 => .indexed8,
        24 => .rgb8,
        32 => .rgba8,
        else => return error.InvalidBitDepth,
    };

    // Create image
    var img = try Image.init(allocator, width, height, output_format);
    errdefer img.deinit();

    // Read color palette for indexed formats
    if (bit_depth <= 8) {
        const num_colors: usize = @as(usize, 1) << @intCast(bit_depth);
        const palette_offset: usize = 14 + header_size;

        img.palette = try allocator.alloc(Color, num_colors);

        for (0..num_colors) |i| {
            const pal_idx = palette_offset + i * 4;
            if (pal_idx + 3 >= data.len) break;
            img.palette.?[i] = Color{
                .b = data[pal_idx],
                .g = data[pal_idx + 1],
                .r = data[pal_idx + 2],
                .a = 255,
            };
        }
    }

    // Calculate row stride (rows are padded to 4-byte boundaries)
    const bits_per_row = @as(usize, width) * @as(usize, bit_depth);
    const bytes_per_row = (bits_per_row + 7) / 8;
    const row_stride = (bytes_per_row + 3) & ~@as(usize, 3);

    // Decode based on compression
    switch (compression) {
        .BI_RGB => {
            try decodeUncompressed(&img, data[data_offset..], bit_depth, row_stride, top_down);
        },
        .BI_BITFIELDS => {
            // Read bit masks
            var r_mask: u32 = 0x00FF0000;
            var g_mask: u32 = 0x0000FF00;
            var b_mask: u32 = 0x000000FF;
            var a_mask: u32 = 0xFF000000;

            if (header_size >= 56) {
                r_mask = std.mem.readInt(u32, data[54..58], .little);
                g_mask = std.mem.readInt(u32, data[58..62], .little);
                b_mask = std.mem.readInt(u32, data[62..66], .little);
                if (header_size >= 60) {
                    a_mask = std.mem.readInt(u32, data[66..70], .little);
                }
            }

            try decodeBitfields(&img, data[data_offset..], bit_depth, row_stride, top_down, r_mask, g_mask, b_mask, a_mask);
        },
        .BI_RLE8 => {
            try decodeRLE8(&img, data[data_offset..], top_down);
        },
        else => return error.UnsupportedFormat,
    }

    return img;
}

fn decodeUncompressed(img: *Image, pixel_data: []const u8, bit_depth: u16, row_stride: usize, top_down: bool) !void {
    const output_bpp = img.format.bytesPerPixel();

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const src_y = if (top_down) y else img.height - 1 - y;
        const row_offset = @as(usize, src_y) * row_stride;

        if (row_offset >= pixel_data.len) continue;
        const row_data = pixel_data[row_offset..];

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const out_idx = (@as(usize, y) * @as(usize, img.width) + @as(usize, x)) * output_bpp;

            switch (bit_depth) {
                8 => {
                    if (x < row_data.len) {
                        img.pixels[out_idx] = row_data[x];
                    }
                },
                24 => {
                    const src_idx = @as(usize, x) * 3;
                    if (src_idx + 2 < row_data.len) {
                        img.pixels[out_idx] = row_data[src_idx + 2]; // R
                        img.pixels[out_idx + 1] = row_data[src_idx + 1]; // G
                        img.pixels[out_idx + 2] = row_data[src_idx]; // B
                    }
                },
                32 => {
                    const src_idx = @as(usize, x) * 4;
                    if (src_idx + 3 < row_data.len) {
                        img.pixels[out_idx] = row_data[src_idx + 2]; // R
                        img.pixels[out_idx + 1] = row_data[src_idx + 1]; // G
                        img.pixels[out_idx + 2] = row_data[src_idx]; // B
                        img.pixels[out_idx + 3] = row_data[src_idx + 3]; // A
                    }
                },
                1, 4 => {
                    // Packed pixels
                    const byte_idx = (@as(usize, x) * bit_depth) / 8;
                    const bit_offset: u3 = @intCast(7 - ((@as(usize, x) * bit_depth) % 8));
                    const mask: u8 = @as(u8, (@as(u8, 1) << @intCast(bit_depth)) - 1);

                    if (byte_idx < row_data.len) {
                        const pixel_value = (row_data[byte_idx] >> bit_offset) & mask;
                        img.pixels[out_idx] = pixel_value;
                    }
                },
                else => {},
            }
        }
    }
}

fn decodeBitfields(img: *Image, pixel_data: []const u8, bit_depth: u16, row_stride: usize, top_down: bool, r_mask: u32, g_mask: u32, b_mask: u32, a_mask: u32) !void {
    const r_shift = @ctz(r_mask);
    const g_shift = @ctz(g_mask);
    const b_shift = @ctz(b_mask);
    const a_shift = @ctz(a_mask);

    const r_max = r_mask >> r_shift;
    const g_max = g_mask >> g_shift;
    const b_max = b_mask >> b_shift;
    const a_max = if (a_mask > 0) a_mask >> a_shift else 1;

    const output_bpp = img.format.bytesPerPixel();
    const bytes_per_pixel: usize = @as(usize, bit_depth) / 8;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const src_y = if (top_down) y else img.height - 1 - y;
        const row_offset = @as(usize, src_y) * row_stride;

        if (row_offset >= pixel_data.len) continue;

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const src_idx = row_offset + @as(usize, x) * bytes_per_pixel;
            const out_idx = (@as(usize, y) * @as(usize, img.width) + @as(usize, x)) * output_bpp;

            if (src_idx + bytes_per_pixel > pixel_data.len) continue;

            const pixel: u32 = switch (bit_depth) {
                16 => std.mem.readInt(u16, pixel_data[src_idx..][0..2], .little),
                32 => std.mem.readInt(u32, pixel_data[src_idx..][0..4], .little),
                else => 0,
            };

            const r: u8 = if (r_max > 0) @intCast(((pixel & r_mask) >> r_shift) * 255 / r_max) else 0;
            const g: u8 = if (g_max > 0) @intCast(((pixel & g_mask) >> g_shift) * 255 / g_max) else 0;
            const b: u8 = if (b_max > 0) @intCast(((pixel & b_mask) >> b_shift) * 255 / b_max) else 0;
            const a: u8 = if (a_mask > 0 and a_max > 0) @intCast(((pixel & a_mask) >> a_shift) * 255 / a_max) else 255;

            img.pixels[out_idx] = r;
            img.pixels[out_idx + 1] = g;
            img.pixels[out_idx + 2] = b;
            if (output_bpp >= 4) {
                img.pixels[out_idx + 3] = a;
            }
        }
    }
}

fn decodeRLE8(img: *Image, pixel_data: []const u8, top_down: bool) !void {
    var x: u32 = 0;
    var y: u32 = 0;
    var pos: usize = 0;

    while (pos < pixel_data.len and y < img.height) {
        const count = pixel_data[pos];
        pos += 1;
        if (pos >= pixel_data.len) break;

        const value = pixel_data[pos];
        pos += 1;

        if (count == 0) {
            // Escape sequence
            switch (value) {
                0 => { // End of line
                    x = 0;
                    y += 1;
                },
                1 => { // End of bitmap
                    break;
                },
                2 => { // Delta
                    if (pos + 1 >= pixel_data.len) break;
                    x += pixel_data[pos];
                    y += pixel_data[pos + 1];
                    pos += 2;
                },
                else => { // Absolute mode
                    var i: u8 = 0;
                    while (i < value and pos < pixel_data.len) : (i += 1) {
                        if (x < img.width and y < img.height) {
                            const out_y = if (top_down) y else img.height - 1 - y;
                            const out_idx = @as(usize, out_y) * @as(usize, img.width) + @as(usize, x);
                            img.pixels[out_idx] = pixel_data[pos];
                        }
                        x += 1;
                        pos += 1;
                    }
                    // Pad to word boundary
                    if (value % 2 != 0) pos += 1;
                },
            }
        } else {
            // Encoded mode: repeat value count times
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (x < img.width and y < img.height) {
                    const out_y = if (top_down) y else img.height - 1 - y;
                    const out_idx = @as(usize, out_y) * @as(usize, img.width) + @as(usize, x);
                    img.pixels[out_idx] = value;
                }
                x += 1;
            }
        }
    }
}

// ============================================================================
// BMP Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Determine output bit depth
    const bit_depth: u16 = switch (img.format) {
        .indexed8 => 8,
        .grayscale8 => 8,
        .rgb8 => 24,
        .rgba8 => 32,
        else => 24,
    };

    const bytes_per_pixel: usize = @as(usize, bit_depth) / 8;
    const row_stride = ((@as(usize, img.width) * bytes_per_pixel) + 3) & ~@as(usize, 3);
    const pixel_data_size = row_stride * @as(usize, img.height);

    const palette_size: usize = if (bit_depth <= 8) 256 * 4 else 0;
    const data_offset: u32 = 14 + 40 + @as(u32, @intCast(palette_size));
    const file_size: u32 = data_offset + @as(u32, @intCast(pixel_data_size));

    // File header (14 bytes)
    try output.appendSlice(&BMP_SIGNATURE);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, file_size)));
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // Reserved
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, data_offset)));

    // DIB header (BITMAPINFOHEADER - 40 bytes)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 40))); // Header size
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(img.width))));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(img.height)))); // Positive = bottom-up
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 1))); // Planes
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, bit_depth)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0))); // Compression (BI_RGB)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(pixel_data_size))));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(i32, 2835))); // X pixels per meter (~72 DPI)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(i32, 2835))); // Y pixels per meter
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, if (bit_depth <= 8) 256 else 0))); // Colors used
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0))); // Important colors

    // Color palette for 8-bit images
    if (bit_depth <= 8) {
        if (img.palette) |pal| {
            for (pal) |color| {
                try output.append(color.b);
                try output.append(color.g);
                try output.append(color.r);
                try output.append(0); // Reserved
            }
            // Pad to 256 colors
            for (pal.len..256) |_| {
                try output.appendSlice(&[_]u8{ 0, 0, 0, 0 });
            }
        } else {
            // Generate grayscale palette
            for (0..256) |i| {
                const v: u8 = @intCast(i);
                try output.appendSlice(&[_]u8{ v, v, v, 0 });
            }
        }
    }

    // Pixel data (bottom-up)
    var y: u32 = img.height;
    while (y > 0) {
        y -= 1;
        var row_bytes: usize = 0;

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const src_idx = (@as(usize, y) * @as(usize, img.width) + @as(usize, x)) * img.format.bytesPerPixel();

            switch (bit_depth) {
                8 => {
                    if (img.format == .indexed8 or img.format == .grayscale8) {
                        try output.append(img.pixels[src_idx]);
                    } else {
                        // Convert to grayscale
                        const color = img.getPixel(x, y) orelse Color.BLACK;
                        try output.append(color.toGrayscale());
                    }
                    row_bytes += 1;
                },
                24 => {
                    const color = img.getPixel(x, y) orelse Color.BLACK;
                    try output.append(color.b);
                    try output.append(color.g);
                    try output.append(color.r);
                    row_bytes += 3;
                },
                32 => {
                    const color = img.getPixel(x, y) orelse Color.BLACK;
                    try output.append(color.b);
                    try output.append(color.g);
                    try output.append(color.r);
                    try output.append(color.a);
                    row_bytes += 4;
                },
                else => {},
            }
        }

        // Pad row to 4-byte boundary
        while (row_bytes % 4 != 0) : (row_bytes += 1) {
            try output.append(0);
        }
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "BMP signature" {
    try std.testing.expectEqual(@as(u8, 'B'), BMP_SIGNATURE[0]);
    try std.testing.expectEqual(@as(u8, 'M'), BMP_SIGNATURE[1]);
}

test "BMP encode/decode roundtrip" {
    var img = try Image.init(std.testing.allocator, 4, 4, .rgb8);
    defer img.deinit();

    // Set some pixels
    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 1, Color.GREEN);
    img.setPixel(2, 2, Color.BLUE);

    // Encode
    const encoded = try encode(std.testing.allocator, &img);
    defer std.testing.allocator.free(encoded);

    // Decode
    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);

    // Check pixels
    const red = decoded.getPixel(0, 0);
    try std.testing.expect(red != null);
    try std.testing.expectEqual(@as(u8, 255), red.?.r);
}
