// TGA (Targa) Decoder/Encoder
// Implements Truevision TGA format
// Supports: Uncompressed and RLE compressed, color-mapped and true-color

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// TGA Constants
// ============================================================================

const ImageType = enum(u8) {
    no_image = 0,
    color_mapped = 1,
    true_color = 2,
    grayscale = 3,
    color_mapped_rle = 9,
    true_color_rle = 10,
    grayscale_rle = 11,
    _,
};

const TgaHeader = struct {
    id_length: u8,
    color_map_type: u8,
    image_type: ImageType,
    color_map_origin: u16,
    color_map_length: u16,
    color_map_depth: u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    pixel_depth: u8,
    image_descriptor: u8,

    fn isRLE(self: TgaHeader) bool {
        return @intFromEnum(self.image_type) >= 9;
    }

    fn isTopToBottom(self: TgaHeader) bool {
        return (self.image_descriptor & 0x20) != 0;
    }

    fn isRightToLeft(self: TgaHeader) bool {
        return (self.image_descriptor & 0x10) != 0;
    }

    fn alphaDepth(self: TgaHeader) u8 {
        return self.image_descriptor & 0x0F;
    }
};

// ============================================================================
// TGA Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 18) return error.TruncatedData;

    const header = parseHeader(data[0..18]);

    if (header.width == 0 or header.height == 0) {
        return error.InvalidDimensions;
    }

    // Skip image ID
    var pos: usize = 18 + header.id_length;

    // Parse color map if present
    var color_map: ?[]Color = null;
    defer if (color_map) |cm| allocator.free(cm);

    if (header.color_map_type == 1 and header.color_map_length > 0) {
        const cm_bytes = (@as(usize, header.color_map_depth) + 7) / 8;
        const cm_size = @as(usize, header.color_map_length) * cm_bytes;
        if (pos + cm_size > data.len) return error.TruncatedData;

        color_map = try allocator.alloc(Color, header.color_map_length);
        const cm_data = data[pos..][0..cm_size];

        for (0..header.color_map_length) |i| {
            color_map.?[i] = readColor(cm_data[i * cm_bytes ..], header.color_map_depth);
        }
        pos += cm_size;
    }

    // Determine pixel format
    const format: PixelFormat = switch (header.image_type) {
        .grayscale, .grayscale_rle => .grayscale8,
        else => if (header.pixel_depth == 32 or header.alphaDepth() > 0) .rgba8 else .rgb8,
    };

    var img = try Image.init(allocator, header.width, header.height, format);
    errdefer img.deinit();

    // Decode pixels
    const pixel_data = data[pos..];
    if (header.isRLE()) {
        try decodeRLE(&img, pixel_data, header, color_map);
    } else {
        try decodeRaw(&img, pixel_data, header, color_map);
    }

    return img;
}

fn parseHeader(data: *const [18]u8) TgaHeader {
    return .{
        .id_length = data[0],
        .color_map_type = data[1],
        .image_type = @enumFromInt(data[2]),
        .color_map_origin = std.mem.readInt(u16, data[3..5], .little),
        .color_map_length = std.mem.readInt(u16, data[5..7], .little),
        .color_map_depth = data[7],
        .x_origin = std.mem.readInt(u16, data[8..10], .little),
        .y_origin = std.mem.readInt(u16, data[10..12], .little),
        .width = std.mem.readInt(u16, data[12..14], .little),
        .height = std.mem.readInt(u16, data[14..16], .little),
        .pixel_depth = data[16],
        .image_descriptor = data[17],
    };
}

fn readColor(data: []const u8, depth: u8) Color {
    return switch (depth) {
        8 => .{ .r = data[0], .g = data[0], .b = data[0], .a = 255 },
        15, 16 => blk: {
            const val = std.mem.readInt(u16, data[0..2], .little);
            const r: u8 = @truncate(((val >> 10) & 0x1F) * 255 / 31);
            const g: u8 = @truncate(((val >> 5) & 0x1F) * 255 / 31);
            const b: u8 = @truncate((val & 0x1F) * 255 / 31);
            const a: u8 = if (depth == 16 and (val & 0x8000) == 0) 0 else 255;
            break :blk .{ .r = r, .g = g, .b = b, .a = a };
        },
        24 => .{ .r = data[2], .g = data[1], .b = data[0], .a = 255 },
        32 => .{ .r = data[2], .g = data[1], .b = data[0], .a = data[3] },
        else => Color.BLACK,
    };
}

fn decodeRaw(img: *Image, data: []const u8, header: TgaHeader, color_map: ?[]Color) !void {
    const bytes_per_pixel = (header.pixel_depth + 7) / 8;
    const row_size = @as(usize, img.width) * bytes_per_pixel;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const actual_y = if (header.isTopToBottom()) y else img.height - 1 - y;
        const row_offset = y * row_size;

        if (row_offset + row_size > data.len) break;

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const actual_x = if (header.isRightToLeft()) img.width - 1 - x else x;
            const pixel_offset = row_offset + @as(usize, x) * bytes_per_pixel;

            const color = getPixelColor(data[pixel_offset..], header, color_map);
            img.setPixel(actual_x, actual_y, color);
        }
    }
}

fn decodeRLE(img: *Image, data: []const u8, header: TgaHeader, color_map: ?[]Color) !void {
    const bytes_per_pixel = (header.pixel_depth + 7) / 8;
    var pos: usize = 0;
    var pixel_idx: usize = 0;
    const total_pixels = @as(usize, img.width) * @as(usize, img.height);

    while (pixel_idx < total_pixels and pos < data.len) {
        const packet = data[pos];
        pos += 1;

        const count = (packet & 0x7F) + 1;
        const is_rle = (packet & 0x80) != 0;

        if (is_rle) {
            // RLE packet - one pixel repeated
            if (pos + bytes_per_pixel > data.len) break;
            const color = getPixelColor(data[pos..], header, color_map);
            pos += bytes_per_pixel;

            for (0..count) |_| {
                if (pixel_idx >= total_pixels) break;
                const coords = getPixelCoords(pixel_idx, img.width, img.height, header);
                img.setPixel(coords.x, coords.y, color);
                pixel_idx += 1;
            }
        } else {
            // Raw packet - count literal pixels
            for (0..count) |_| {
                if (pixel_idx >= total_pixels) break;
                if (pos + bytes_per_pixel > data.len) break;

                const color = getPixelColor(data[pos..], header, color_map);
                pos += bytes_per_pixel;

                const coords = getPixelCoords(pixel_idx, img.width, img.height, header);
                img.setPixel(coords.x, coords.y, color);
                pixel_idx += 1;
            }
        }
    }
}

fn getPixelColor(data: []const u8, header: TgaHeader, color_map: ?[]Color) Color {
    return switch (header.image_type) {
        .color_mapped, .color_mapped_rle => blk: {
            if (color_map) |cm| {
                const idx = data[0];
                if (idx < cm.len) {
                    break :blk cm[idx];
                }
            }
            break :blk Color.BLACK;
        },
        .grayscale, .grayscale_rle => .{ .r = data[0], .g = data[0], .b = data[0], .a = 255 },
        else => readColor(data, header.pixel_depth),
    };
}

fn getPixelCoords(idx: usize, width: u32, height: u32, header: TgaHeader) struct { x: u32, y: u32 } {
    const raw_x: u32 = @intCast(idx % width);
    const raw_y: u32 = @intCast(idx / width);

    const x = if (header.isRightToLeft()) width - 1 - raw_x else raw_x;
    const y = if (header.isTopToBottom()) raw_y else height - 1 - raw_y;

    return .{ .x = x, .y = y };
}

// ============================================================================
// TGA Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    return encodeWithOptions(allocator, img, .{});
}

pub const EncodeOptions = struct {
    rle: bool = true,
    include_footer: bool = true,
};

pub fn encodeWithOptions(allocator: std.mem.Allocator, img: *const Image, options: EncodeOptions) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const is_grayscale = img.format == .grayscale8 or img.format == .grayscale16;
    const has_alpha = img.format.hasAlpha();
    const pixel_depth: u8 = if (is_grayscale) 8 else if (has_alpha) 32 else 24;

    const image_type: u8 = if (is_grayscale)
        (if (options.rle) 11 else 3)
    else
        (if (options.rle) 10 else 2);

    // Header
    try output.append(0); // ID length
    try output.append(0); // No color map
    try output.append(image_type);
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0, 0 }); // Color map spec
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 0))); // X origin
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, 0))); // Y origin
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(img.width))));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(img.height))));
    try output.append(pixel_depth);
    try output.append(if (has_alpha) 0x28 else 0x20); // Top-to-bottom, alpha bits

    // Pixel data
    if (options.rle) {
        try encodeRLE(&output, img, is_grayscale, has_alpha);
    } else {
        try encodeRaw(&output, img, is_grayscale, has_alpha);
    }

    // Footer (TGA 2.0)
    if (options.include_footer) {
        try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // Extension offset
        try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // Developer offset
        try output.appendSlice("TRUEVISION-XFILE.");
        try output.append(0);
    }

    return output.toOwnedSlice();
}

fn encodeRaw(output: *std.ArrayList(u8), img: *const Image, is_grayscale: bool, has_alpha: bool) !void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;
            try writePixel(output, color, is_grayscale, has_alpha);
        }
    }
}

fn encodeRLE(output: *std.ArrayList(u8), img: *const Image, is_grayscale: bool, has_alpha: bool) !void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) {
            const start_x = x;
            const start_color = img.getPixel(x, y) orelse Color.BLACK;

            // Count run length
            var run_length: u32 = 1;
            x += 1;

            while (x < img.width and run_length < 128) {
                const color = img.getPixel(x, y) orelse Color.BLACK;
                if (!colorsEqual(color, start_color)) break;
                run_length += 1;
                x += 1;
            }

            if (run_length > 1) {
                // RLE packet
                try output.append(@as(u8, 0x80) | @as(u8, @truncate(run_length - 1)));
                try writePixel(output, start_color, is_grayscale, has_alpha);
            } else {
                // Check for raw run
                var raw_start = start_x;
                var raw_len: u32 = 1;

                while (x < img.width and raw_len < 128) {
                    const next_color = img.getPixel(x, y) orelse Color.BLACK;

                    // Check if a run starts
                    if (x + 1 < img.width) {
                        const after = img.getPixel(x + 1, y) orelse Color.BLACK;
                        if (colorsEqual(next_color, after)) break;
                    }

                    raw_len += 1;
                    x += 1;
                }

                // Raw packet
                try output.append(@as(u8, @truncate(raw_len - 1)));
                var i: u32 = 0;
                while (i < raw_len) : (i += 1) {
                    const color = img.getPixel(raw_start + i, y) orelse Color.BLACK;
                    try writePixel(output, color, is_grayscale, has_alpha);
                }
            }
        }
    }
}

fn writePixel(output: *std.ArrayList(u8), color: Color, is_grayscale: bool, has_alpha: bool) !void {
    if (is_grayscale) {
        try output.append(color.toGrayscale());
    } else {
        try output.appendSlice(&[_]u8{ color.b, color.g, color.r });
        if (has_alpha) {
            try output.append(color.a);
        }
    }
}

fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

// ============================================================================
// Tests
// ============================================================================

test "TGA header parsing" {
    const header_data = [_]u8{
        0, // ID length
        0, // No color map
        2, // True color
        0, 0, 0, 0, 0, // Color map spec
        0, 0, // X origin
        0, 0, // Y origin
        0x80, 0x00, // Width = 128
        0x60, 0x00, // Height = 96
        24, // 24-bit
        0x20, // Top-to-bottom
    };

    const header = parseHeader(&header_data);
    try std.testing.expectEqual(@as(u16, 128), header.width);
    try std.testing.expectEqual(@as(u16, 96), header.height);
    try std.testing.expectEqual(@as(u8, 24), header.pixel_depth);
    try std.testing.expect(header.isTopToBottom());
    try std.testing.expect(!header.isRightToLeft());
}

test "Color reading" {
    // 24-bit BGR
    const bgr = [_]u8{ 0x00, 0x80, 0xFF };
    const color24 = readColor(&bgr, 24);
    try std.testing.expectEqual(@as(u8, 255), color24.r);
    try std.testing.expectEqual(@as(u8, 128), color24.g);
    try std.testing.expectEqual(@as(u8, 0), color24.b);

    // 32-bit BGRA
    const bgra = [_]u8{ 0x00, 0x80, 0xFF, 0x40 };
    const color32 = readColor(&bgra, 32);
    try std.testing.expectEqual(@as(u8, 64), color32.a);
}

test "RLE flag detection" {
    const header = TgaHeader{
        .id_length = 0,
        .color_map_type = 0,
        .image_type = .true_color_rle,
        .color_map_origin = 0,
        .color_map_length = 0,
        .color_map_depth = 0,
        .x_origin = 0,
        .y_origin = 0,
        .width = 100,
        .height = 100,
        .pixel_depth = 24,
        .image_descriptor = 0,
    };

    try std.testing.expect(header.isRLE());
}
