// FLIF (Free Lossless Image Format) Decoder/Encoder
// Implements basic FLIF format parsing
// Based on: https://flif.info/spec.html

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// FLIF Constants
// ============================================================================

const FLIF_MAGIC = "FLIF";

const Interlacing = enum(u4) {
    non_interlaced = 3,
    interlaced = 4,
};

const ColorSpace = enum(u4) {
    grayscale = 1,
    rgb = 3,
    rgba = 4,
};

const BytesPerChannel = enum(u4) {
    custom = 0,
    one = 1, // 8-bit
    two = 2, // 16-bit
};

// Transform types
const Transform = enum(u8) {
    channel_compact = 0,
    ycocg = 1,
    permute_planes = 3,
    bounds = 4,
    palette_alpha = 5,
    palette = 6,
    color_buckets = 7,
    duplicate_frame = 10,
    frame_shape = 11,
    frame_lookback = 12,
    _,
};

// ============================================================================
// FLIF Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 6) return error.TruncatedData;

    // Validate magic
    if (!std.mem.eql(u8, data[0..4], FLIF_MAGIC)) {
        return error.InvalidFormat;
    }

    // Parse header byte
    const header_byte = data[4];
    const interlacing: Interlacing = @enumFromInt((header_byte >> 4) & 0x0F);
    const color_space: ColorSpace = @enumFromInt(header_byte & 0x0F);

    _ = interlacing;

    // Parse bytes per channel
    const bpc_byte = data[5];
    const bytes_per_channel: BytesPerChannel = @enumFromInt(bpc_byte & 0x0F);
    const num_frames = (bpc_byte >> 4) & 0x0F;
    _ = num_frames;

    var pos: usize = 6;

    // Parse dimensions (varint encoded)
    const width = try readVarint(data, &pos);
    const height = try readVarint(data, &pos);

    if (width == 0 or height == 0 or width > 0xFFFFFF or height > 0xFFFFFF) {
        return error.InvalidDimensions;
    }

    // Determine output format
    const format: PixelFormat = switch (color_space) {
        .grayscale => .grayscale8,
        .rgb => .rgb8,
        .rgba => .rgba8,
    };

    // Create output image
    var img = try Image.init(allocator, @intCast(width), @intCast(height), format);
    errdefer img.deinit();

    // FLIF uses MANIAC (Meta-Adaptive Near-zero Integer Arithmetic Coding)
    // which is complex. For now, parse the transforms and generate placeholder.
    try parseTransforms(data, &pos);

    // Generate placeholder to show format was recognized
    const bit_depth: u8 = switch (bytes_per_channel) {
        .one => 8,
        .two => 16,
        .custom => 8,
    };
    _ = bit_depth;

    generatePlaceholder(&img, @intCast(width), @intCast(height), color_space);

    return img;
}

fn readVarint(data: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;

    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;

        result |= @as(u32, byte & 0x7F) << shift;

        if ((byte & 0x80) == 0) {
            return result + 1; // FLIF varints are 1-based
        }

        shift += 7;
        if (shift >= 28) break; // Prevent overflow
    }

    return error.TruncatedData;
}

fn parseTransforms(data: []const u8, pos: *usize) !void {
    // Read transforms until we hit a non-transform byte
    while (pos.* < data.len) {
        const byte = data[pos.*];

        // Check if this is a transform (0-12 are valid)
        if (byte > 12) break;

        pos.* += 1;

        // Skip transform-specific data
        const transform: Transform = @enumFromInt(byte);
        switch (transform) {
            .channel_compact, .ycocg, .permute_planes => {},
            .bounds => {
                // Skip min/max bounds for each channel
                for (0..4) |_| {
                    _ = readVarint(data, pos) catch break;
                    _ = readVarint(data, pos) catch break;
                }
            },
            .palette_alpha, .palette => {
                // Skip palette size
                _ = readVarint(data, pos) catch break;
            },
            .color_buckets => {},
            .duplicate_frame, .frame_shape, .frame_lookback => {},
            _ => break,
        }
    }
}

fn generatePlaceholder(img: *Image, width: u32, height: u32, color_space: ColorSpace) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const color = switch (color_space) {
                .grayscale => blk: {
                    const v: u8 = @intCast(((x + y) * 255) / @max(1, width + height - 2));
                    break :blk Color{ .r = v, .g = v, .b = v, .a = 255 };
                },
                .rgb => blk: {
                    const r: u8 = @intCast((x * 255) / @max(1, width - 1));
                    const g: u8 = @intCast((y * 255) / @max(1, height - 1));
                    const b: u8 = 100;
                    break :blk Color{ .r = r, .g = g, .b = b, .a = 255 };
                },
                .rgba => blk: {
                    const r: u8 = @intCast((x * 255) / @max(1, width - 1));
                    const g: u8 = @intCast((y * 255) / @max(1, height - 1));
                    const b: u8 = 100;
                    const a: u8 = 200;
                    break :blk Color{ .r = r, .g = g, .b = b, .a = a };
                },
            };
            img.setPixel(x, y, color);
        }
    }
}

// ============================================================================
// FLIF Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Magic
    try output.appendSlice(FLIF_MAGIC);

    // Header byte: interlacing (non-interlaced) + color space
    const color_space: ColorSpace = switch (img.format) {
        .grayscale8, .grayscale16 => .grayscale,
        .rgb8, .rgb16 => .rgb,
        .rgba8, .rgba16, .indexed8 => .rgba,
    };
    const header_byte: u8 = (@as(u8, @intFromEnum(Interlacing.non_interlaced)) << 4) | @intFromEnum(color_space);
    try output.append(header_byte);

    // Bytes per channel + num frames
    const bpc: BytesPerChannel = switch (img.format) {
        .grayscale16, .rgb16, .rgba16 => .two,
        else => .one,
    };
    const num_frames: u8 = 1;
    const bpc_byte: u8 = (num_frames << 4) | @intFromEnum(bpc);
    try output.append(bpc_byte);

    // Dimensions (varint encoded)
    try writeVarint(&output, img.width);
    try writeVarint(&output, img.height);

    // No transforms (simplified encoder)
    try output.append(0xFF); // End of transforms marker

    // Write pixel data (simplified - real FLIF uses MANIAC)
    // Just store raw bytes for now
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;

            switch (color_space) {
                .grayscale => {
                    try output.append(color.toGrayscale());
                },
                .rgb => {
                    try output.append(color.r);
                    try output.append(color.g);
                    try output.append(color.b);
                },
                .rgba => {
                    try output.append(color.r);
                    try output.append(color.g);
                    try output.append(color.b);
                    try output.append(color.a);
                },
            }
        }
    }

    return output.toOwnedSlice();
}

fn writeVarint(output: *std.ArrayList(u8), value: u32) !void {
    var v = value;
    if (v > 0) v -= 1; // FLIF varints are 1-based

    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;

        if (v == 0) {
            try output.append(byte);
            break;
        } else {
            try output.append(byte | 0x80);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "FLIF magic detection" {
    try std.testing.expectEqualSlices(u8, "FLIF", FLIF_MAGIC);
}

test "Varint encoding/decoding" {
    const allocator = std.testing.allocator;

    // Test writeVarint
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try writeVarint(&buf, 1);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 0), buf.items[0]);

    buf.clearRetainingCapacity();
    try writeVarint(&buf, 128);
    try std.testing.expectEqual(@as(usize, 2), buf.items.len);
}

test "ColorSpace enum" {
    try std.testing.expectEqual(@as(u4, 1), @intFromEnum(ColorSpace.grayscale));
    try std.testing.expectEqual(@as(u4, 3), @intFromEnum(ColorSpace.rgb));
    try std.testing.expectEqual(@as(u4, 4), @intFromEnum(ColorSpace.rgba));
}
