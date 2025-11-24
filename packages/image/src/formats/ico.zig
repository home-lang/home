// ICO/CUR Decoder/Encoder
// Implements Windows Icon (.ico) and Cursor (.cur) formats
// Based on: Microsoft ICO file format specification

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;
const png = @import("png.zig");

// ============================================================================
// ICO Constants
// ============================================================================

const ICO_TYPE: u16 = 1; // Icon
const CUR_TYPE: u16 = 2; // Cursor

const IconDirEntry = struct {
    width: u8, // 0 means 256
    height: u8, // 0 means 256
    color_count: u8, // 0 if >= 256 colors
    reserved: u8,
    planes: u16, // For ICO: color planes, for CUR: hotspot X
    bit_count: u16, // For ICO: bits per pixel, for CUR: hotspot Y
    bytes_in_res: u32,
    image_offset: u32,
};

// ============================================================================
// ICO Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    return decodeWithIndex(allocator, data, null);
}

pub fn decodeWithIndex(allocator: std.mem.Allocator, data: []const u8, index: ?usize) !Image {
    if (data.len < 6) return error.TruncatedData;

    // Parse header
    const reserved = std.mem.readInt(u16, data[0..2], .little);
    const image_type = std.mem.readInt(u16, data[2..4], .little);
    const image_count = std.mem.readInt(u16, data[4..6], .little);

    if (reserved != 0) return error.InvalidFormat;
    if (image_type != ICO_TYPE and image_type != CUR_TYPE) return error.InvalidFormat;
    if (image_count == 0) return error.InvalidFormat;

    // Parse directory entries
    const entries_size = @as(usize, image_count) * 16;
    if (6 + entries_size > data.len) return error.TruncatedData;

    // Find best image (largest) or use specified index
    var best_idx: usize = 0;
    var best_size: u32 = 0;

    if (index) |idx| {
        if (idx >= image_count) return error.InvalidFormat;
        best_idx = idx;
    } else {
        var i: usize = 0;
        while (i < image_count) : (i += 1) {
            const entry = parseEntry(data[6 + i * 16 ..][0..16]);
            const w: u32 = if (entry.width == 0) 256 else entry.width;
            const h: u32 = if (entry.height == 0) 256 else entry.height;
            const size = w * h;
            if (size > best_size) {
                best_size = size;
                best_idx = i;
            }
        }
    }

    const entry = parseEntry(data[6 + best_idx * 16 ..][0..16]);
    const img_data = data[entry.image_offset..][0..@min(entry.bytes_in_res, data.len - entry.image_offset)];

    // Check if it's a PNG
    if (img_data.len >= 8 and img_data[0] == 0x89 and img_data[1] == 'P' and img_data[2] == 'N' and img_data[3] == 'G') {
        return png.decode(allocator, img_data);
    }

    // Otherwise it's a BMP DIB
    return decodeDIB(allocator, img_data, entry);
}

fn parseEntry(data: *const [16]u8) IconDirEntry {
    return .{
        .width = data[0],
        .height = data[1],
        .color_count = data[2],
        .reserved = data[3],
        .planes = std.mem.readInt(u16, data[4..6], .little),
        .bit_count = std.mem.readInt(u16, data[6..8], .little),
        .bytes_in_res = std.mem.readInt(u32, data[8..12], .little),
        .image_offset = std.mem.readInt(u32, data[12..16], .little),
    };
}

fn decodeDIB(allocator: std.mem.Allocator, data: []const u8, entry: IconDirEntry) !Image {
    if (data.len < 40) return error.TruncatedData;

    // Parse BITMAPINFOHEADER
    const header_size = std.mem.readInt(u32, data[0..4], .little);
    if (header_size < 40) return error.InvalidFormat;

    const bmp_width: u32 = @bitCast(std.mem.readInt(i32, data[4..8], .little));
    const bmp_height_raw: i32 = std.mem.readInt(i32, data[8..12], .little);
    // Height is doubled in ICO (includes AND mask)
    const bmp_height: u32 = @intCast(@divTrunc(@abs(bmp_height_raw), 2));
    const bit_count = std.mem.readInt(u16, data[14..16], .little);
    const compression = std.mem.readInt(u32, data[16..20], .little);

    if (compression != 0 and compression != 3) return error.UnsupportedFormat;

    const width: u32 = if (entry.width == 0) 256 else entry.width;
    const height: u32 = if (entry.height == 0) 256 else entry.height;

    _ = bmp_width;
    _ = bmp_height;

    var img = try Image.init(allocator, width, height, .rgba8);
    errdefer img.deinit();

    // Calculate color table size
    var color_table_size: usize = 0;
    if (bit_count <= 8) {
        const num_colors: usize = if (entry.color_count == 0) @as(usize, 1) << @intCast(bit_count) else entry.color_count;
        color_table_size = num_colors * 4;
    }

    const pixel_offset = header_size + color_table_size;
    if (pixel_offset >= data.len) return error.TruncatedData;

    // Parse color table if needed
    var color_table: [256]Color = undefined;
    if (bit_count <= 8) {
        const table_data = data[header_size..][0..color_table_size];
        var i: usize = 0;
        while (i < color_table_size / 4) : (i += 1) {
            color_table[i] = .{
                .b = table_data[i * 4],
                .g = table_data[i * 4 + 1],
                .r = table_data[i * 4 + 2],
                .a = 255,
            };
        }
    }

    // Calculate row stride (rows are padded to 4-byte boundaries)
    const bits_per_row = @as(usize, width) * bit_count;
    const row_stride = ((bits_per_row + 31) / 32) * 4;

    // XOR mask (color data)
    const xor_size = row_stride * height;
    const xor_data = data[pixel_offset..][0..@min(xor_size, data.len - pixel_offset)];

    // AND mask (transparency)
    const and_row_stride = ((width + 31) / 32) * 4;
    const and_offset = pixel_offset + xor_size;
    const and_data = if (and_offset < data.len) data[and_offset..] else &[_]u8{};

    // Decode pixels (bottom-up)
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = height - 1 - y;
        const row_offset = src_y * row_stride;

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            var color: Color = undefined;

            switch (bit_count) {
                1 => {
                    const byte_idx = row_offset + x / 8;
                    if (byte_idx < xor_data.len) {
                        const bit: u3 = @intCast(7 - (x % 8));
                        const idx = (xor_data[byte_idx] >> bit) & 1;
                        color = color_table[idx];
                    } else {
                        color = Color.BLACK;
                    }
                },
                4 => {
                    const byte_idx = row_offset + x / 2;
                    if (byte_idx < xor_data.len) {
                        const shift: u2 = if (x % 2 == 0) 4 else 0;
                        const idx = (xor_data[byte_idx] >> shift) & 0x0F;
                        color = color_table[idx];
                    } else {
                        color = Color.BLACK;
                    }
                },
                8 => {
                    const byte_idx = row_offset + x;
                    if (byte_idx < xor_data.len) {
                        color = color_table[xor_data[byte_idx]];
                    } else {
                        color = Color.BLACK;
                    }
                },
                24 => {
                    const byte_idx = row_offset + x * 3;
                    if (byte_idx + 2 < xor_data.len) {
                        color = .{
                            .b = xor_data[byte_idx],
                            .g = xor_data[byte_idx + 1],
                            .r = xor_data[byte_idx + 2],
                            .a = 255,
                        };
                    } else {
                        color = Color.BLACK;
                    }
                },
                32 => {
                    const byte_idx = row_offset + x * 4;
                    if (byte_idx + 3 < xor_data.len) {
                        color = .{
                            .b = xor_data[byte_idx],
                            .g = xor_data[byte_idx + 1],
                            .r = xor_data[byte_idx + 2],
                            .a = xor_data[byte_idx + 3],
                        };
                    } else {
                        color = Color.BLACK;
                    }
                },
                else => {
                    color = Color.BLACK;
                },
            }

            // Apply AND mask for transparency (if not 32-bit with alpha)
            if (bit_count != 32 and and_data.len > 0) {
                const and_row_offset = src_y * and_row_stride;
                const and_byte_idx = and_row_offset + x / 8;
                if (and_byte_idx < and_data.len) {
                    const bit: u3 = @intCast(7 - (x % 8));
                    const transparent = ((and_data[and_byte_idx] >> bit) & 1) != 0;
                    if (transparent) {
                        color.a = 0;
                    }
                }
            }

            img.setPixel(x, y, color);
        }
    }

    return img;
}

// ============================================================================
// ICO Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    return encodeMultiple(allocator, &[_]*const Image{img});
}

pub fn encodeMultiple(allocator: std.mem.Allocator, images: []const *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const image_count: u16 = @intCast(images.len);

    // Header
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 0))); // Reserved
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, ICO_TYPE)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, image_count)));

    // Encode each image as PNG
    var png_datas = try allocator.alloc([]u8, images.len);
    defer {
        for (png_datas) |pd| {
            allocator.free(pd);
        }
        allocator.free(png_datas);
    }

    for (images, 0..) |img, i| {
        png_datas[i] = try png.encode(allocator, img);
    }

    // Calculate offsets
    var current_offset: u32 = 6 + @as(u32, @intCast(images.len)) * 16;

    // Write directory entries
    for (images, 0..) |img, i| {
        const w: u8 = if (img.width >= 256) 0 else @truncate(img.width);
        const h: u8 = if (img.height >= 256) 0 else @truncate(img.height);

        try output.append(w);
        try output.append(h);
        try output.append(0); // color count
        try output.append(0); // reserved
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 1))); // planes
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 32))); // bit count
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(png_datas[i].len))));
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, current_offset)));

        current_offset += @intCast(png_datas[i].len);
    }

    // Write image data
    for (png_datas) |pd| {
        try output.appendSlice(pd);
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Utility Functions
// ============================================================================

pub fn getImageCount(data: []const u8) !u16 {
    if (data.len < 6) return error.TruncatedData;
    return std.mem.readInt(u16, data[4..6], .little);
}

pub fn getImageInfo(data: []const u8, index: usize) !struct { width: u32, height: u32, bit_depth: u16 } {
    if (data.len < 6) return error.TruncatedData;

    const count = std.mem.readInt(u16, data[4..6], .little);
    if (index >= count) return error.InvalidFormat;

    const entry = parseEntry(data[6 + index * 16 ..][0..16]);

    return .{
        .width = if (entry.width == 0) 256 else entry.width,
        .height = if (entry.height == 0) 256 else entry.height,
        .bit_depth = entry.bit_count,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ICO header validation" {
    // Valid ICO header
    const valid_ico = [_]u8{
        0, 0, // reserved
        1, 0, // type = 1 (icon)
        1, 0, // count = 1
        // Entry would follow...
    };
    const reserved = std.mem.readInt(u16, valid_ico[0..2], .little);
    const img_type = std.mem.readInt(u16, valid_ico[2..4], .little);
    try std.testing.expectEqual(@as(u16, 0), reserved);
    try std.testing.expectEqual(@as(u16, 1), img_type);
}

test "CUR header validation" {
    const valid_cur = [_]u8{
        0, 0, // reserved
        2, 0, // type = 2 (cursor)
        1, 0, // count = 1
    };
    const img_type = std.mem.readInt(u16, valid_cur[2..4], .little);
    try std.testing.expectEqual(@as(u16, 2), img_type);
}

test "Entry parsing" {
    const entry_data = [_]u8{
        32,   // width
        32,   // height
        0,    // color count
        0,    // reserved
        1, 0, // planes
        32, 0, // bit count
        0x00, 0x10, 0x00, 0x00, // bytes = 4096
        0x16, 0x00, 0x00, 0x00, // offset = 22
    };

    const entry = parseEntry(&entry_data);
    try std.testing.expectEqual(@as(u8, 32), entry.width);
    try std.testing.expectEqual(@as(u8, 32), entry.height);
    try std.testing.expectEqual(@as(u16, 32), entry.bit_count);
    try std.testing.expectEqual(@as(u32, 4096), entry.bytes_in_res);
    try std.testing.expectEqual(@as(u32, 22), entry.image_offset);
}
