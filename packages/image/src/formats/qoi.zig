// QOI (Quite OK Image) Decoder/Encoder
// Implements the QOI lossless image format
// Based on: https://qoiformat.org/qoi-specification.pdf

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// QOI Constants
// ============================================================================

const QOI_MAGIC = "qoif";
const QOI_END_MARKER = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

const QOI_OP_RGB: u8 = 0xFE;
const QOI_OP_RGBA: u8 = 0xFF;
const QOI_OP_INDEX: u8 = 0x00; // 00xxxxxx
const QOI_OP_DIFF: u8 = 0x40; // 01xxxxxx
const QOI_OP_LUMA: u8 = 0x80; // 10xxxxxx
const QOI_OP_RUN: u8 = 0xC0; // 11xxxxxx

const QOI_MASK_2: u8 = 0xC0;

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

// ============================================================================
// QOI Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 14) return error.TruncatedData;

    // Validate magic
    if (!std.mem.eql(u8, data[0..4], QOI_MAGIC)) {
        return error.InvalidFormat;
    }

    // Parse header
    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);
    const channels: Channels = @enumFromInt(data[12]);
    const colorspace: Colorspace = @enumFromInt(data[13]);
    _ = colorspace;

    if (width == 0 or height == 0) return error.InvalidDimensions;

    const format: PixelFormat = if (channels == .rgba) .rgba8 else .rgb8;
    var img = try Image.init(allocator, width, height, format);
    errdefer img.deinit();

    // Initialize index array
    var index: [64]Color = .{Color{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64;

    var prev = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var pos: usize = 14;
    var pixel_idx: usize = 0;
    const total_pixels = @as(usize, width) * @as(usize, height);

    while (pixel_idx < total_pixels and pos < data.len - 8) {
        const b1 = data[pos];

        var color: Color = undefined;
        var run: usize = 1;

        if (b1 == QOI_OP_RGB) {
            pos += 1;
            if (pos + 3 > data.len) break;
            color = Color{ .r = data[pos], .g = data[pos + 1], .b = data[pos + 2], .a = prev.a };
            pos += 3;
        } else if (b1 == QOI_OP_RGBA) {
            pos += 1;
            if (pos + 4 > data.len) break;
            color = Color{ .r = data[pos], .g = data[pos + 1], .b = data[pos + 2], .a = data[pos + 3] };
            pos += 4;
        } else if ((b1 & QOI_MASK_2) == QOI_OP_INDEX) {
            color = index[b1 & 0x3F];
            pos += 1;
        } else if ((b1 & QOI_MASK_2) == QOI_OP_DIFF) {
            const dr: i8 = @as(i8, @intCast((b1 >> 4) & 0x03)) - 2;
            const dg: i8 = @as(i8, @intCast((b1 >> 2) & 0x03)) - 2;
            const db: i8 = @as(i8, @intCast(b1 & 0x03)) - 2;

            color = Color{
                .r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr),
                .g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg),
                .b = @bitCast(@as(i8, @bitCast(prev.b)) +% db),
                .a = prev.a,
            };
            pos += 1;
        } else if ((b1 & QOI_MASK_2) == QOI_OP_LUMA) {
            pos += 1;
            if (pos >= data.len) break;
            const b2 = data[pos];
            pos += 1;

            const dg: i8 = @as(i8, @intCast(b1 & 0x3F)) - 32;
            const dr_dg: i8 = @as(i8, @intCast((b2 >> 4) & 0x0F)) - 8;
            const db_dg: i8 = @as(i8, @intCast(b2 & 0x0F)) - 8;

            color = Color{
                .r = @bitCast(@as(i8, @bitCast(prev.r)) +% dg +% dr_dg),
                .g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg),
                .b = @bitCast(@as(i8, @bitCast(prev.b)) +% dg +% db_dg),
                .a = prev.a,
            };
        } else if ((b1 & QOI_MASK_2) == QOI_OP_RUN) {
            run = (b1 & 0x3F) + 1;
            color = prev;
            pos += 1;
        } else {
            pos += 1;
            continue;
        }

        // Store in index
        index[colorHash(color)] = color;
        prev = color;

        // Write pixels
        for (0..run) |_| {
            if (pixel_idx >= total_pixels) break;
            const x: u32 = @intCast(pixel_idx % width);
            const y: u32 = @intCast(pixel_idx / width);
            img.setPixel(x, y, color);
            pixel_idx += 1;
        }
    }

    return img;
}

fn colorHash(c: Color) usize {
    return @intCast((@as(usize, c.r) * 3 + @as(usize, c.g) * 5 + @as(usize, c.b) * 7 + @as(usize, c.a) * 11) % 64);
}

// ============================================================================
// QOI Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const channels: u8 = if (img.format.hasAlpha()) 4 else 3;

    // Header
    try output.appendSlice(QOI_MAGIC);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.width)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.height)));
    try output.append(channels);
    try output.append(0); // sRGB colorspace

    // Initialize state
    var index: [64]Color = .{Color{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 64;
    var prev = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var run: u8 = 0;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;

            if (colorsEqual(color, prev)) {
                run += 1;
                if (run == 62 or (y == img.height - 1 and x == img.width - 1)) {
                    try output.append(QOI_OP_RUN | (run - 1));
                    run = 0;
                }
            } else {
                if (run > 0) {
                    try output.append(QOI_OP_RUN | (run - 1));
                    run = 0;
                }

                const idx = colorHash(color);

                if (colorsEqual(index[idx], color)) {
                    try output.append(QOI_OP_INDEX | @as(u8, @intCast(idx)));
                } else {
                    index[idx] = color;

                    if (color.a == prev.a) {
                        const dr: i8 = @as(i8, @bitCast(color.r)) -% @as(i8, @bitCast(prev.r));
                        const dg: i8 = @as(i8, @bitCast(color.g)) -% @as(i8, @bitCast(prev.g));
                        const db: i8 = @as(i8, @bitCast(color.b)) -% @as(i8, @bitCast(prev.b));

                        const dr_dg = dr -% dg;
                        const db_dg = db -% dg;

                        if (dr >= -2 and dr <= 1 and dg >= -2 and dg <= 1 and db >= -2 and db <= 1) {
                            try output.append(QOI_OP_DIFF | @as(u8, @bitCast(@as(i8, dr + 2) << 4 | @as(i8, dg + 2) << 2 | @as(i8, db + 2))));
                        } else if (dr_dg >= -8 and dr_dg <= 7 and dg >= -32 and dg <= 31 and db_dg >= -8 and db_dg <= 7) {
                            try output.append(QOI_OP_LUMA | @as(u8, @bitCast(@as(i8, dg + 32))));
                            try output.append(@as(u8, @bitCast(@as(i8, dr_dg + 8) << 4 | @as(i8, db_dg + 8))));
                        } else {
                            try output.append(QOI_OP_RGB);
                            try output.appendSlice(&[_]u8{ color.r, color.g, color.b });
                        }
                    } else {
                        try output.append(QOI_OP_RGBA);
                        try output.appendSlice(&[_]u8{ color.r, color.g, color.b, color.a });
                    }
                }

                prev = color;
            }
        }
    }

    // Flush remaining run
    if (run > 0) {
        try output.append(QOI_OP_RUN | (run - 1));
    }

    // End marker
    try output.appendSlice(&QOI_END_MARKER);

    return output.toOwnedSlice();
}

fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

// ============================================================================
// Tests
// ============================================================================

test "QOI magic detection" {
    const valid_header = "qoif" ++ "\x00\x00\x00\x10" ++ "\x00\x00\x00\x10" ++ "\x04\x00";
    try std.testing.expect(std.mem.eql(u8, valid_header[0..4], QOI_MAGIC));
}

test "Color hash" {
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

    try std.testing.expect(colorHash(black) != colorHash(white));
    try std.testing.expect(colorHash(black) < 64);
    try std.testing.expect(colorHash(white) < 64);
}

test "QOI roundtrip" {
    const allocator = std.testing.allocator;

    // Create test image
    var img = try Image.init(allocator, 4, 4, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.RED); // Same - should trigger run
    img.setPixel(2, 0, Color.GREEN);
    img.setPixel(3, 0, Color.BLUE);

    // Encode
    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);

    // Verify header
    try std.testing.expectEqualSlices(u8, "qoif", encoded[0..4]);

    // Decode
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
}
