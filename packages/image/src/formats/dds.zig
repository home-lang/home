// DDS (DirectDraw Surface) Decoder/Encoder
// Implements Microsoft DDS format for GPU textures
// Supports: DXT1/BC1, DXT3/BC2, DXT5/BC3, uncompressed formats

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// DDS Constants
// ============================================================================

const DDS_MAGIC = "DDS ";
const DDS_HEADER_SIZE = 124;

// DDSD flags
const DDSD_CAPS: u32 = 0x1;
const DDSD_HEIGHT: u32 = 0x2;
const DDSD_WIDTH: u32 = 0x4;
const DDSD_PITCH: u32 = 0x8;
const DDSD_PIXELFORMAT: u32 = 0x1000;
const DDSD_MIPMAPCOUNT: u32 = 0x20000;
const DDSD_LINEARSIZE: u32 = 0x80000;

// DDPF flags
const DDPF_ALPHAPIXELS: u32 = 0x1;
const DDPF_FOURCC: u32 = 0x4;
const DDPF_RGB: u32 = 0x40;
const DDPF_LUMINANCE: u32 = 0x20000;

// FourCC codes
const FOURCC_DXT1: u32 = 0x31545844; // "DXT1"
const FOURCC_DXT3: u32 = 0x33545844; // "DXT3"
const FOURCC_DXT5: u32 = 0x35545844; // "DXT5"
const FOURCC_DX10: u32 = 0x30315844; // "DX10"
const FOURCC_BC4U: u32 = 0x55344342; // "BC4U"
const FOURCC_BC5U: u32 = 0x55354342; // "BC5U"

const DDSHeader = struct {
    size: u32,
    flags: u32,
    height: u32,
    width: u32,
    pitch_or_linear_size: u32,
    depth: u32,
    mipmap_count: u32,
    reserved1: [11]u32,
    pixel_format: DDSPixelFormat,
    caps: u32,
    caps2: u32,
    caps3: u32,
    caps4: u32,
    reserved2: u32,
};

const DDSPixelFormat = struct {
    size: u32,
    flags: u32,
    four_cc: u32,
    rgb_bit_count: u32,
    r_bit_mask: u32,
    g_bit_mask: u32,
    b_bit_mask: u32,
    a_bit_mask: u32,
};

// ============================================================================
// DDS Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 4 + DDS_HEADER_SIZE) return error.TruncatedData;

    // Check magic
    if (!std.mem.eql(u8, data[0..4], DDS_MAGIC)) {
        return error.InvalidFormat;
    }

    // Parse header
    const header = parseHeader(data[4..][0..DDS_HEADER_SIZE]);

    if (header.width == 0 or header.height == 0) {
        return error.InvalidDimensions;
    }

    var img = try Image.init(allocator, header.width, header.height, .rgba8);
    errdefer img.deinit();

    const pixel_data = data[4 + DDS_HEADER_SIZE ..];

    if ((header.pixel_format.flags & DDPF_FOURCC) != 0) {
        // Compressed format
        switch (header.pixel_format.four_cc) {
            FOURCC_DXT1 => try decodeDXT1(&img, pixel_data),
            FOURCC_DXT3 => try decodeDXT3(&img, pixel_data),
            FOURCC_DXT5 => try decodeDXT5(&img, pixel_data),
            else => return error.UnsupportedFormat,
        }
    } else if ((header.pixel_format.flags & DDPF_RGB) != 0) {
        // Uncompressed RGB
        try decodeRGB(&img, pixel_data, header.pixel_format);
    } else if ((header.pixel_format.flags & DDPF_LUMINANCE) != 0) {
        // Luminance
        try decodeLuminance(&img, pixel_data, header.pixel_format);
    } else {
        return error.UnsupportedFormat;
    }

    return img;
}

fn parseHeader(data: *const [DDS_HEADER_SIZE]u8) DDSHeader {
    return .{
        .size = std.mem.readInt(u32, data[0..4], .little),
        .flags = std.mem.readInt(u32, data[4..8], .little),
        .height = std.mem.readInt(u32, data[8..12], .little),
        .width = std.mem.readInt(u32, data[12..16], .little),
        .pitch_or_linear_size = std.mem.readInt(u32, data[16..20], .little),
        .depth = std.mem.readInt(u32, data[20..24], .little),
        .mipmap_count = std.mem.readInt(u32, data[24..28], .little),
        .reserved1 = undefined,
        .pixel_format = .{
            .size = std.mem.readInt(u32, data[72..76], .little),
            .flags = std.mem.readInt(u32, data[76..80], .little),
            .four_cc = std.mem.readInt(u32, data[80..84], .little),
            .rgb_bit_count = std.mem.readInt(u32, data[84..88], .little),
            .r_bit_mask = std.mem.readInt(u32, data[88..92], .little),
            .g_bit_mask = std.mem.readInt(u32, data[92..96], .little),
            .b_bit_mask = std.mem.readInt(u32, data[96..100], .little),
            .a_bit_mask = std.mem.readInt(u32, data[100..104], .little),
        },
        .caps = std.mem.readInt(u32, data[104..108], .little),
        .caps2 = std.mem.readInt(u32, data[108..112], .little),
        .caps3 = std.mem.readInt(u32, data[112..116], .little),
        .caps4 = std.mem.readInt(u32, data[116..120], .little),
        .reserved2 = std.mem.readInt(u32, data[120..124], .little),
    };
}

fn decodeDXT1(img: *Image, data: []const u8) !void {
    const blocks_x = (img.width + 3) / 4;
    const blocks_y = (img.height + 3) / 4;

    var by: u32 = 0;
    while (by < blocks_y) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_x) : (bx += 1) {
            const block_idx = (by * blocks_x + bx) * 8;
            if (block_idx + 8 > data.len) break;

            const block = data[block_idx..][0..8];
            decodeBlockDXT1(img, bx * 4, by * 4, block);
        }
    }
}

fn decodeBlockDXT1(img: *Image, bx: u32, by: u32, block: *const [8]u8) void {
    const c0 = std.mem.readInt(u16, block[0..2], .little);
    const c1 = std.mem.readInt(u16, block[2..4], .little);

    var colors: [4]Color = undefined;
    colors[0] = rgb565ToColor(c0);
    colors[1] = rgb565ToColor(c1);

    if (c0 > c1) {
        colors[2] = interpolateColor(colors[0], colors[1], 2, 1);
        colors[3] = interpolateColor(colors[0], colors[1], 1, 2);
    } else {
        colors[2] = interpolateColor(colors[0], colors[1], 1, 1);
        colors[3] = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    const indices = std.mem.readInt(u32, block[4..8], .little);

    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const px = bx + x;
            const py = by + y;
            if (px < img.width and py < img.height) {
                const idx = (y * 4 + x) * 2;
                const color_idx = (indices >> @intCast(idx)) & 0x3;
                img.setPixel(px, py, colors[color_idx]);
            }
        }
    }
}

fn decodeDXT3(img: *Image, data: []const u8) !void {
    const blocks_x = (img.width + 3) / 4;
    const blocks_y = (img.height + 3) / 4;

    var by: u32 = 0;
    while (by < blocks_y) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_x) : (bx += 1) {
            const block_idx = (by * blocks_x + bx) * 16;
            if (block_idx + 16 > data.len) break;

            const alpha_block = data[block_idx..][0..8];
            const color_block = data[block_idx + 8 ..][0..8];

            decodeBlockDXT3(img, bx * 4, by * 4, alpha_block, color_block);
        }
    }
}

fn decodeBlockDXT3(img: *Image, bx: u32, by: u32, alpha_block: *const [8]u8, color_block: *const [8]u8) void {
    const c0 = std.mem.readInt(u16, color_block[0..2], .little);
    const c1 = std.mem.readInt(u16, color_block[2..4], .little);

    var colors: [4]Color = undefined;
    colors[0] = rgb565ToColor(c0);
    colors[1] = rgb565ToColor(c1);
    colors[2] = interpolateColor(colors[0], colors[1], 2, 1);
    colors[3] = interpolateColor(colors[0], colors[1], 1, 2);

    const indices = std.mem.readInt(u32, color_block[4..8], .little);

    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const px = bx + x;
            const py = by + y;
            if (px < img.width and py < img.height) {
                const idx = (y * 4 + x) * 2;
                const color_idx = (indices >> @intCast(idx)) & 0x3;
                var color = colors[color_idx];

                // Get explicit alpha
                const alpha_idx = y * 4 + x;
                const alpha_byte = alpha_block[alpha_idx / 2];
                const alpha_val: u8 = if (alpha_idx % 2 == 0) (alpha_byte & 0x0F) * 17 else (alpha_byte >> 4) * 17;
                color.a = alpha_val;

                img.setPixel(px, py, color);
            }
        }
    }
}

fn decodeDXT5(img: *Image, data: []const u8) !void {
    const blocks_x = (img.width + 3) / 4;
    const blocks_y = (img.height + 3) / 4;

    var by: u32 = 0;
    while (by < blocks_y) : (by += 1) {
        var bx: u32 = 0;
        while (bx < blocks_x) : (bx += 1) {
            const block_idx = (by * blocks_x + bx) * 16;
            if (block_idx + 16 > data.len) break;

            const alpha_block = data[block_idx..][0..8];
            const color_block = data[block_idx + 8 ..][0..8];

            decodeBlockDXT5(img, bx * 4, by * 4, alpha_block, color_block);
        }
    }
}

fn decodeBlockDXT5(img: *Image, bx: u32, by: u32, alpha_block: *const [8]u8, color_block: *const [8]u8) void {
    // Decode alpha
    const a0 = alpha_block[0];
    const a1 = alpha_block[1];

    var alphas: [8]u8 = undefined;
    alphas[0] = a0;
    alphas[1] = a1;

    if (a0 > a1) {
        alphas[2] = @truncate((@as(u16, a0) * 6 + @as(u16, a1) * 1) / 7);
        alphas[3] = @truncate((@as(u16, a0) * 5 + @as(u16, a1) * 2) / 7);
        alphas[4] = @truncate((@as(u16, a0) * 4 + @as(u16, a1) * 3) / 7);
        alphas[5] = @truncate((@as(u16, a0) * 3 + @as(u16, a1) * 4) / 7);
        alphas[6] = @truncate((@as(u16, a0) * 2 + @as(u16, a1) * 5) / 7);
        alphas[7] = @truncate((@as(u16, a0) * 1 + @as(u16, a1) * 6) / 7);
    } else {
        alphas[2] = @truncate((@as(u16, a0) * 4 + @as(u16, a1) * 1) / 5);
        alphas[3] = @truncate((@as(u16, a0) * 3 + @as(u16, a1) * 2) / 5);
        alphas[4] = @truncate((@as(u16, a0) * 2 + @as(u16, a1) * 3) / 5);
        alphas[5] = @truncate((@as(u16, a0) * 1 + @as(u16, a1) * 4) / 5);
        alphas[6] = 0;
        alphas[7] = 255;
    }

    // Decode color
    const c0 = std.mem.readInt(u16, color_block[0..2], .little);
    const c1 = std.mem.readInt(u16, color_block[2..4], .little);

    var colors: [4]Color = undefined;
    colors[0] = rgb565ToColor(c0);
    colors[1] = rgb565ToColor(c1);
    colors[2] = interpolateColor(colors[0], colors[1], 2, 1);
    colors[3] = interpolateColor(colors[0], colors[1], 1, 2);

    const color_indices = std.mem.readInt(u32, color_block[4..8], .little);

    // Alpha indices are packed in 48 bits (6 bytes)
    const alpha_bits: u48 = @as(u48, alpha_block[2]) |
        (@as(u48, alpha_block[3]) << 8) |
        (@as(u48, alpha_block[4]) << 16) |
        (@as(u48, alpha_block[5]) << 24) |
        (@as(u48, alpha_block[6]) << 32) |
        (@as(u48, alpha_block[7]) << 40);

    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const px = bx + x;
            const py = by + y;
            if (px < img.width and py < img.height) {
                const color_idx_shift = (y * 4 + x) * 2;
                const color_idx = (color_indices >> @intCast(color_idx_shift)) & 0x3;

                const alpha_idx_shift: u6 = @intCast((y * 4 + x) * 3);
                const alpha_idx: u3 = @truncate((alpha_bits >> alpha_idx_shift) & 0x7);

                var color = colors[color_idx];
                color.a = alphas[alpha_idx];

                img.setPixel(px, py, color);
            }
        }
    }
}

fn rgb565ToColor(rgb565: u16) Color {
    const r: u8 = @truncate(((rgb565 >> 11) & 0x1F) * 255 / 31);
    const g: u8 = @truncate(((rgb565 >> 5) & 0x3F) * 255 / 63);
    const b: u8 = @truncate((rgb565 & 0x1F) * 255 / 31);
    return Color{ .r = r, .g = g, .b = b, .a = 255 };
}

fn interpolateColor(c0: Color, c1: Color, w0: u32, w1: u32) Color {
    const total = w0 + w1;
    return Color{
        .r = @truncate((@as(u32, c0.r) * w0 + @as(u32, c1.r) * w1) / total),
        .g = @truncate((@as(u32, c0.g) * w0 + @as(u32, c1.g) * w1) / total),
        .b = @truncate((@as(u32, c0.b) * w0 + @as(u32, c1.b) * w1) / total),
        .a = 255,
    };
}

fn decodeRGB(img: *Image, data: []const u8, pf: DDSPixelFormat) !void {
    const bpp = pf.rgb_bit_count / 8;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const offset = (@as(usize, y) * img.width + x) * bpp;
            if (offset + bpp > data.len) break;

            const pixel = readPixelValue(data[offset..], bpp);
            const color = extractColor(pixel, pf);
            img.setPixel(x, y, color);
        }
    }
}

fn decodeLuminance(img: *Image, data: []const u8, pf: DDSPixelFormat) !void {
    const bpp = pf.rgb_bit_count / 8;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const offset = (@as(usize, y) * img.width + x) * bpp;
            if (offset + bpp > data.len) break;

            const pixel = readPixelValue(data[offset..], bpp);
            const lum: u8 = extractChannel(pixel, pf.r_bit_mask);
            img.setPixel(x, y, Color{ .r = lum, .g = lum, .b = lum, .a = 255 });
        }
    }
}

fn readPixelValue(data: []const u8, bpp: u32) u32 {
    return switch (bpp) {
        1 => data[0],
        2 => std.mem.readInt(u16, data[0..2], .little),
        3 => @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16),
        4 => std.mem.readInt(u32, data[0..4], .little),
        else => 0,
    };
}

fn extractColor(pixel: u32, pf: DDSPixelFormat) Color {
    return Color{
        .r = extractChannel(pixel, pf.r_bit_mask),
        .g = extractChannel(pixel, pf.g_bit_mask),
        .b = extractChannel(pixel, pf.b_bit_mask),
        .a = if (pf.a_bit_mask != 0) extractChannel(pixel, pf.a_bit_mask) else 255,
    };
}

fn extractChannel(pixel: u32, mask: u32) u8 {
    if (mask == 0) return 0;

    const shift = @ctz(mask);
    const bits = @popCount(mask);
    const max_val = (@as(u32, 1) << @intCast(bits)) - 1;
    const val = (pixel & mask) >> @intCast(shift);

    return @truncate((val * 255) / max_val);
}

// ============================================================================
// DDS Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    // Encode as uncompressed BGRA
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Magic
    try output.appendSlice(DDS_MAGIC);

    // Header
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, DDS_HEADER_SIZE)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_PITCH)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, img.height)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, img.width)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, img.width * 4))); // pitch

    // Depth, mipmap count, reserved
    try output.appendNTimes(0, 4 + 4 + 44);

    // Pixel format
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 32))); // size
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, DDPF_RGB | DDPF_ALPHAPIXELS))); // flags
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // fourCC
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 32))); // bit count
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0x00FF0000))); // R mask
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0x0000FF00))); // G mask
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0x000000FF))); // B mask
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0xFF000000))); // A mask

    // Caps
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 0x1000))); // DDSCAPS_TEXTURE
    try output.appendNTimes(0, 16); // caps2-4, reserved2

    // Pixel data (BGRA)
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            try output.appendSlice(&[_]u8{ c.b, c.g, c.r, c.a });
        }
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "DDS magic detection" {
    try std.testing.expectEqualSlices(u8, "DDS ", DDS_MAGIC);
}

test "RGB565 to Color" {
    const white = rgb565ToColor(0xFFFF);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);

    const black = rgb565ToColor(0x0000);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);
}

test "Color interpolation" {
    const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const mid = interpolateColor(white, black, 1, 1);
    try std.testing.expectEqual(@as(u8, 127), mid.r);
}
