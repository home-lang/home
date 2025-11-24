// PSD (Photoshop Document) Decoder/Encoder
// Implements Adobe PSD format
// Supports: Flattened image, basic layer reading

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// PSD Constants
// ============================================================================

const PSD_SIGNATURE = "8BPS";
const PSD_VERSION_1 = 1; // PSD
const PSD_VERSION_2 = 2; // PSB (large document)

const ColorMode = enum(u16) {
    bitmap = 0,
    grayscale = 1,
    indexed = 2,
    rgb = 3,
    cmyk = 4,
    multichannel = 7,
    duotone = 8,
    lab = 9,
    _,
};

const CompressionMethod = enum(u16) {
    raw = 0,
    rle = 1,
    zip = 2,
    zip_prediction = 3,
    _,
};

const PSDHeader = struct {
    version: u16,
    channels: u16,
    height: u32,
    width: u32,
    depth: u16,
    color_mode: ColorMode,
};

// ============================================================================
// PSD Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 26) return error.TruncatedData;

    // Validate signature
    if (!std.mem.eql(u8, data[0..4], PSD_SIGNATURE)) {
        return error.InvalidFormat;
    }

    // Parse header
    const header = PSDHeader{
        .version = std.mem.readInt(u16, data[4..6], .big),
        .channels = std.mem.readInt(u16, data[12..14], .big),
        .height = std.mem.readInt(u32, data[14..18], .big),
        .width = std.mem.readInt(u32, data[18..22], .big),
        .depth = std.mem.readInt(u16, data[22..24], .big),
        .color_mode = @enumFromInt(std.mem.readInt(u16, data[24..26], .big)),
    };

    if (header.version != PSD_VERSION_1 and header.version != PSD_VERSION_2) {
        return error.UnsupportedFormat;
    }

    if (header.width == 0 or header.height == 0) {
        return error.InvalidDimensions;
    }

    var pos: usize = 26;

    // Skip color mode data
    if (pos + 4 > data.len) return error.TruncatedData;
    const color_mode_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4 + color_mode_len;

    // Skip image resources
    if (pos + 4 > data.len) return error.TruncatedData;
    const resources_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4 + resources_len;

    // Skip layer and mask info
    if (pos + 4 > data.len) return error.TruncatedData;
    const layer_info_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4 + layer_info_len;

    // Image data section
    if (pos + 2 > data.len) return error.TruncatedData;
    const compression: CompressionMethod = @enumFromInt(std.mem.readInt(u16, data[pos..][0..2], .big));
    pos += 2;

    // Determine output format
    const format: PixelFormat = switch (header.color_mode) {
        .grayscale => .grayscale8,
        .rgb => if (header.channels >= 4) .rgba8 else .rgb8,
        else => .rgb8,
    };

    var img = try Image.init(allocator, header.width, header.height, format);
    errdefer img.deinit();

    // Decode image data
    switch (compression) {
        .raw => try decodeRaw(&img, data[pos..], header, allocator),
        .rle => try decodeRLE(&img, data[pos..], header, allocator),
        else => return error.UnsupportedFormat,
    }

    return img;
}

fn decodeRaw(img: *Image, data: []const u8, header: PSDHeader, allocator: std.mem.Allocator) !void {
    const bytes_per_sample = header.depth / 8;
    const scanline_bytes = @as(usize, img.width) * bytes_per_sample;
    const channel_bytes = scanline_bytes * img.height;

    // Allocate channel buffers
    const num_channels = @min(header.channels, 4);
    var channels = try allocator.alloc([]const u8, num_channels);
    defer allocator.free(channels);

    for (0..num_channels) |c| {
        const offset = c * channel_bytes;
        if (offset + channel_bytes > data.len) {
            channels[c] = &[_]u8{};
        } else {
            channels[c] = data[offset..][0..channel_bytes];
        }
    }

    // Combine channels
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const idx = @as(usize, y) * img.width + x;

            const color = switch (header.color_mode) {
                .grayscale => blk: {
                    const v = if (channels[0].len > idx) channels[0][idx] else 0;
                    break :blk Color{ .r = v, .g = v, .b = v, .a = 255 };
                },
                .rgb => blk: {
                    const r = if (channels[0].len > idx) channels[0][idx] else 0;
                    const g = if (num_channels > 1 and channels[1].len > idx) channels[1][idx] else 0;
                    const b = if (num_channels > 2 and channels[2].len > idx) channels[2][idx] else 0;
                    const a = if (num_channels > 3 and channels[3].len > idx) channels[3][idx] else 255;
                    break :blk Color{ .r = r, .g = g, .b = b, .a = a };
                },
                .cmyk => blk: {
                    // Convert CMYK to RGB
                    const c = if (channels[0].len > idx) channels[0][idx] else 0;
                    const m = if (num_channels > 1 and channels[1].len > idx) channels[1][idx] else 0;
                    const yc = if (num_channels > 2 and channels[2].len > idx) channels[2][idx] else 0;
                    const k = if (num_channels > 3 and channels[3].len > idx) channels[3][idx] else 0;

                    const cf = 1.0 - @as(f32, @floatFromInt(c)) / 255.0;
                    const mf = 1.0 - @as(f32, @floatFromInt(m)) / 255.0;
                    const yf = 1.0 - @as(f32, @floatFromInt(yc)) / 255.0;
                    const kf = 1.0 - @as(f32, @floatFromInt(k)) / 255.0;

                    break :blk Color{
                        .r = @intFromFloat(cf * kf * 255),
                        .g = @intFromFloat(mf * kf * 255),
                        .b = @intFromFloat(yf * kf * 255),
                        .a = 255,
                    };
                },
                else => Color.BLACK,
            };

            img.setPixel(x, y, color);
        }
    }
}

fn decodeRLE(img: *Image, data: []const u8, header: PSDHeader, allocator: std.mem.Allocator) !void {
    const num_channels = @min(header.channels, 4);
    const total_scanlines = @as(usize, img.height) * num_channels;

    // Read scanline byte counts
    var pos: usize = 0;
    var scanline_sizes = try allocator.alloc(u16, total_scanlines);
    defer allocator.free(scanline_sizes);

    for (0..total_scanlines) |i| {
        if (pos + 2 > data.len) {
            scanline_sizes[i] = 0;
            continue;
        }
        scanline_sizes[i] = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    }

    // Allocate channel buffers
    const scanline_pixels = img.width;
    var channels = try allocator.alloc([]u8, num_channels);
    defer {
        for (channels) |ch| {
            allocator.free(ch);
        }
        allocator.free(channels);
    }

    for (0..num_channels) |c| {
        channels[c] = try allocator.alloc(u8, @as(usize, img.height) * scanline_pixels);
    }

    // Decode each channel
    for (0..num_channels) |c| {
        var y: u32 = 0;
        while (y < img.height) : (y += 1) {
            const scanline_idx = c * img.height + y;
            const scanline_size = scanline_sizes[scanline_idx];

            if (pos + scanline_size > data.len) break;

            const rle_data = data[pos..][0..scanline_size];
            const dest = channels[c][y * scanline_pixels ..][0..scanline_pixels];

            try decodePackBits(rle_data, dest);
            pos += scanline_size;
        }
    }

    // Combine channels
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const idx = @as(usize, y) * img.width + x;

            const color = switch (header.color_mode) {
                .grayscale => blk: {
                    const v = channels[0][idx];
                    break :blk Color{ .r = v, .g = v, .b = v, .a = 255 };
                },
                .rgb => blk: {
                    break :blk Color{
                        .r = channels[0][idx],
                        .g = if (num_channels > 1) channels[1][idx] else 0,
                        .b = if (num_channels > 2) channels[2][idx] else 0,
                        .a = if (num_channels > 3) channels[3][idx] else 255,
                    };
                },
                else => Color.BLACK,
            };

            img.setPixel(x, y, color);
        }
    }
}

fn decodePackBits(src: []const u8, dest: []u8) !void {
    var src_pos: usize = 0;
    var dest_pos: usize = 0;

    while (src_pos < src.len and dest_pos < dest.len) {
        const n: i8 = @bitCast(src[src_pos]);
        src_pos += 1;

        if (n >= 0) {
            // Literal run
            const count: usize = @intCast(@as(i16, n) + 1);
            const to_copy = @min(count, @min(src.len - src_pos, dest.len - dest_pos));
            @memcpy(dest[dest_pos..][0..to_copy], src[src_pos..][0..to_copy]);
            src_pos += to_copy;
            dest_pos += to_copy;
        } else if (n > -128) {
            // Repeat
            if (src_pos >= src.len) break;
            const count: usize = @intCast(1 - @as(i16, n));
            const val = src[src_pos];
            src_pos += 1;
            const to_fill = @min(count, dest.len - dest_pos);
            @memset(dest[dest_pos..][0..to_fill], val);
            dest_pos += to_fill;
        }
        // n == -128: no-op
    }
}

// ============================================================================
// PSD Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const channels: u16 = if (img.format.hasAlpha()) 4 else 3;
    const color_mode: u16 = @intFromEnum(ColorMode.rgb);

    // Signature
    try output.appendSlice(PSD_SIGNATURE);

    // Version
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, PSD_VERSION_1)));

    // Reserved (6 bytes)
    try output.appendNTimes(0, 6);

    // Channels
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, channels)));

    // Height and width
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.height)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.width)));

    // Depth (8-bit)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, 8)));

    // Color mode (RGB)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, color_mode)));

    // Color mode data (empty for RGB)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    // Image resources (empty)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    // Layer and mask info (empty)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    // Image data - raw compression
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, 0)));

    // Write channel data (planar format)
    for (0..channels) |c| {
        var y: u32 = 0;
        while (y < img.height) : (y += 1) {
            var x: u32 = 0;
            while (x < img.width) : (x += 1) {
                const color = img.getPixel(x, y) orelse Color.BLACK;
                const val = switch (c) {
                    0 => color.r,
                    1 => color.g,
                    2 => color.b,
                    3 => color.a,
                    else => 0,
                };
                try output.append(val);
            }
        }
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "PSD signature detection" {
    try std.testing.expectEqualSlices(u8, "8BPS", PSD_SIGNATURE);
}

test "PackBits decoding" {
    var dest: [10]u8 = undefined;

    // Literal: 0x01 means copy next 2 bytes
    const literal = [_]u8{ 0x01, 0xAA, 0xBB };
    try decodePackBits(&literal, &dest);
    try std.testing.expectEqual(@as(u8, 0xAA), dest[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dest[1]);

    // Repeat: 0xFE (-2) means repeat next byte 3 times
    const repeat = [_]u8{ 0xFE, 0xCC };
    try decodePackBits(&repeat, &dest);
    try std.testing.expectEqual(@as(u8, 0xCC), dest[0]);
    try std.testing.expectEqual(@as(u8, 0xCC), dest[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), dest[2]);
}

test "ColorMode enum" {
    try std.testing.expectEqual(@as(u16, 3), @intFromEnum(ColorMode.rgb));
    try std.testing.expectEqual(@as(u16, 4), @intFromEnum(ColorMode.cmyk));
}
