// PPM/PGM/PBM (Netpbm) Decoder/Encoder
// Implements Portable Pixmap/Graymap/Bitmap formats
// Supports both ASCII (P1-P3) and binary (P4-P6) variants

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// Netpbm Format Types
// ============================================================================

const NetpbmFormat = enum {
    pbm_ascii, // P1 - Bitmap ASCII
    pgm_ascii, // P2 - Graymap ASCII
    ppm_ascii, // P3 - Pixmap ASCII
    pbm_binary, // P4 - Bitmap binary
    pgm_binary, // P5 - Graymap binary
    ppm_binary, // P6 - Pixmap binary
    pam, // P7 - Portable Arbitrary Map

    fn fromMagic(magic: []const u8) ?NetpbmFormat {
        if (magic.len < 2) return null;
        if (magic[0] != 'P') return null;

        return switch (magic[1]) {
            '1' => .pbm_ascii,
            '2' => .pgm_ascii,
            '3' => .ppm_ascii,
            '4' => .pbm_binary,
            '5' => .pgm_binary,
            '6' => .ppm_binary,
            '7' => .pam,
            else => null,
        };
    }

    fn isAscii(self: NetpbmFormat) bool {
        return self == .pbm_ascii or self == .pgm_ascii or self == .ppm_ascii;
    }

    fn isBitmap(self: NetpbmFormat) bool {
        return self == .pbm_ascii or self == .pbm_binary;
    }

    fn isGraymap(self: NetpbmFormat) bool {
        return self == .pgm_ascii or self == .pgm_binary;
    }
};

// ============================================================================
// Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 3) return error.TruncatedData;

    const format = NetpbmFormat.fromMagic(data[0..2]) orelse return error.InvalidFormat;

    if (format == .pam) {
        return decodePAM(allocator, data);
    }

    var parser = Parser{ .data = data, .pos = 2 };

    // Skip whitespace and comments after magic
    parser.skipWhitespaceAndComments();

    // Read width
    const width = parser.readNumber() orelse return error.InvalidFormat;
    parser.skipWhitespaceAndComments();

    // Read height
    const height = parser.readNumber() orelse return error.InvalidFormat;
    parser.skipWhitespaceAndComments();

    // Read max value (except for bitmap)
    var max_val: u32 = 1;
    if (!format.isBitmap()) {
        max_val = parser.readNumber() orelse return error.InvalidFormat;
        parser.skipWhitespaceAndComments();
    }

    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (max_val == 0 or max_val > 65535) return error.InvalidFormat;

    // Determine pixel format
    const pixel_format: PixelFormat = if (format.isGraymap() or format.isBitmap()) .grayscale8 else .rgb8;

    var img = try Image.init(allocator, width, height, pixel_format);
    errdefer img.deinit();

    // Decode pixels
    if (format.isAscii()) {
        try decodeAscii(&img, &parser, format, max_val);
    } else {
        try decodeBinary(&img, parser.data[parser.pos..], format, max_val);
    }

    return img;
}

fn decodeAscii(img: *Image, parser: *Parser, format: NetpbmFormat, max_val: u32) !void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            parser.skipWhitespaceAndComments();

            const color = switch (format) {
                .pbm_ascii => blk: {
                    const bit = parser.readNumber() orelse return error.TruncatedData;
                    const val: u8 = if (bit == 0) 255 else 0;
                    break :blk Color{ .r = val, .g = val, .b = val, .a = 255 };
                },
                .pgm_ascii => blk: {
                    const gray = parser.readNumber() orelse return error.TruncatedData;
                    const val: u8 = @truncate((gray * 255) / max_val);
                    break :blk Color{ .r = val, .g = val, .b = val, .a = 255 };
                },
                .ppm_ascii => blk: {
                    const r = parser.readNumber() orelse return error.TruncatedData;
                    parser.skipWhitespaceAndComments();
                    const g = parser.readNumber() orelse return error.TruncatedData;
                    parser.skipWhitespaceAndComments();
                    const b = parser.readNumber() orelse return error.TruncatedData;

                    break :blk Color{
                        .r = @truncate((r * 255) / max_val),
                        .g = @truncate((g * 255) / max_val),
                        .b = @truncate((b * 255) / max_val),
                        .a = 255,
                    };
                },
                else => unreachable,
            };

            img.setPixel(x, y, color);
        }
    }
}

fn decodeBinary(img: *Image, data: []const u8, format: NetpbmFormat, max_val: u32) !void {
    const bytes_per_sample: usize = if (max_val > 255) 2 else 1;
    var pos: usize = 0;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        if (format.isBitmap()) {
            // PBM binary - packed bits
            const row_bytes = (img.width + 7) / 8;
            if (pos + row_bytes > data.len) return error.TruncatedData;

            var x: u32 = 0;
            while (x < img.width) : (x += 1) {
                const byte_idx = x / 8;
                const bit_idx: u3 = @intCast(7 - (x % 8));
                const bit = (data[pos + byte_idx] >> bit_idx) & 1;
                const val: u8 = if (bit == 0) 255 else 0;
                img.setPixel(x, y, Color{ .r = val, .g = val, .b = val, .a = 255 });
            }
            pos += row_bytes;
        } else {
            var x: u32 = 0;
            while (x < img.width) : (x += 1) {
                const color = switch (format) {
                    .pgm_binary => blk: {
                        if (pos + bytes_per_sample > data.len) return error.TruncatedData;
                        const gray = readSample(data[pos..], bytes_per_sample, max_val);
                        pos += bytes_per_sample;
                        break :blk Color{ .r = gray, .g = gray, .b = gray, .a = 255 };
                    },
                    .ppm_binary => blk: {
                        if (pos + 3 * bytes_per_sample > data.len) return error.TruncatedData;
                        const r = readSample(data[pos..], bytes_per_sample, max_val);
                        pos += bytes_per_sample;
                        const g = readSample(data[pos..], bytes_per_sample, max_val);
                        pos += bytes_per_sample;
                        const b = readSample(data[pos..], bytes_per_sample, max_val);
                        pos += bytes_per_sample;
                        break :blk Color{ .r = r, .g = g, .b = b, .a = 255 };
                    },
                    else => unreachable,
                };

                img.setPixel(x, y, color);
            }
        }
    }
}

fn readSample(data: []const u8, bytes: usize, max_val: u32) u8 {
    const val: u32 = if (bytes == 2)
        std.mem.readInt(u16, data[0..2], .big)
    else
        data[0];

    return @truncate((val * 255) / max_val);
}

fn decodePAM(allocator: std.mem.Allocator, data: []const u8) !Image {
    var parser = Parser{ .data = data, .pos = 3 }; // Skip "P7\n"

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u32 = 0;
    var max_val: u32 = 255;

    // Parse header lines
    while (parser.pos < data.len) {
        parser.skipWhitespace();

        if (parser.startsWith("ENDHDR")) {
            parser.pos += 6;
            parser.skipWhitespace();
            break;
        }

        if (parser.startsWith("#")) {
            parser.skipLine();
            continue;
        }

        if (parser.startsWith("WIDTH")) {
            parser.pos += 5;
            parser.skipWhitespace();
            width = parser.readNumber() orelse return error.InvalidFormat;
        } else if (parser.startsWith("HEIGHT")) {
            parser.pos += 6;
            parser.skipWhitespace();
            height = parser.readNumber() orelse return error.InvalidFormat;
        } else if (parser.startsWith("DEPTH")) {
            parser.pos += 5;
            parser.skipWhitespace();
            depth = parser.readNumber() orelse return error.InvalidFormat;
        } else if (parser.startsWith("MAXVAL")) {
            parser.pos += 6;
            parser.skipWhitespace();
            max_val = parser.readNumber() orelse return error.InvalidFormat;
        } else if (parser.startsWith("TUPLTYPE")) {
            parser.skipLine();
        } else {
            parser.skipLine();
        }
    }

    if (width == 0 or height == 0 or depth == 0) return error.InvalidDimensions;

    const format: PixelFormat = switch (depth) {
        1 => .grayscale8,
        3 => .rgb8,
        4 => .rgba8,
        else => .rgba8,
    };

    var img = try Image.init(allocator, width, height, format);
    errdefer img.deinit();

    const bytes_per_sample: usize = if (max_val > 255) 2 else 1;
    const pixel_bytes = depth * bytes_per_sample;
    const pixel_data = data[parser.pos..];

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const pos = (@as(usize, y) * width + x) * pixel_bytes;
            if (pos + pixel_bytes > pixel_data.len) break;

            const color = switch (depth) {
                1 => blk: {
                    const v = readSample(pixel_data[pos..], bytes_per_sample, max_val);
                    break :blk Color{ .r = v, .g = v, .b = v, .a = 255 };
                },
                3 => blk: {
                    const r = readSample(pixel_data[pos..], bytes_per_sample, max_val);
                    const g = readSample(pixel_data[pos + bytes_per_sample ..], bytes_per_sample, max_val);
                    const b = readSample(pixel_data[pos + 2 * bytes_per_sample ..], bytes_per_sample, max_val);
                    break :blk Color{ .r = r, .g = g, .b = b, .a = 255 };
                },
                4 => blk: {
                    const r = readSample(pixel_data[pos..], bytes_per_sample, max_val);
                    const g = readSample(pixel_data[pos + bytes_per_sample ..], bytes_per_sample, max_val);
                    const b = readSample(pixel_data[pos + 2 * bytes_per_sample ..], bytes_per_sample, max_val);
                    const a = readSample(pixel_data[pos + 3 * bytes_per_sample ..], bytes_per_sample, max_val);
                    break :blk Color{ .r = r, .g = g, .b = b, .a = a };
                },
                else => Color.BLACK,
            };

            img.setPixel(x, y, color);
        }
    }

    return img;
}

const Parser = struct {
    data: []const u8,
    pos: usize,

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.data.len and std.ascii.isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.data.len) {
            if (std.ascii.isWhitespace(self.data[self.pos])) {
                self.pos += 1;
            } else if (self.data[self.pos] == '#') {
                self.skipLine();
            } else {
                break;
            }
        }
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.data.len and self.data[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1;
    }

    fn readNumber(self: *Parser) ?u32 {
        const start = self.pos;
        while (self.pos < self.data.len and std.ascii.isDigit(self.data[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(u32, self.data[start..self.pos], 10) catch null;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.data.len) return false;
        return std.mem.eql(u8, self.data[self.pos..][0..prefix.len], prefix);
    }
};

// ============================================================================
// Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    return encodePPM(allocator, img);
}

pub fn encodePPM(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Header
    try output.appendSlice("P6\n");

    var buf: [32]u8 = undefined;
    var len = std.fmt.formatIntBuf(&buf, img.width, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append(' ');
    len = std.fmt.formatIntBuf(&buf, img.height, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append('\n');
    try output.appendSlice("255\n");

    // Pixel data
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            try output.appendSlice(&[_]u8{ c.r, c.g, c.b });
        }
    }

    return output.toOwnedSlice();
}

pub fn encodePGM(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    try output.appendSlice("P5\n");

    var buf: [32]u8 = undefined;
    var len = std.fmt.formatIntBuf(&buf, img.width, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append(' ');
    len = std.fmt.formatIntBuf(&buf, img.height, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append('\n');
    try output.appendSlice("255\n");

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            try output.append(c.toGrayscale());
        }
    }

    return output.toOwnedSlice();
}

pub fn encodePBM(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    try output.appendSlice("P4\n");

    var buf: [32]u8 = undefined;
    var len = std.fmt.formatIntBuf(&buf, img.width, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append(' ');
    len = std.fmt.formatIntBuf(&buf, img.height, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append('\n');

    const row_bytes = (img.width + 7) / 8;

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var byte_idx: u32 = 0;
        while (byte_idx < row_bytes) : (byte_idx += 1) {
            var byte: u8 = 0;
            var bit: u3 = 7;
            while (true) {
                const x = byte_idx * 8 + (7 - @as(u32, bit));
                if (x < img.width) {
                    const c = img.getPixel(x, y) orelse Color.BLACK;
                    const gray = c.toGrayscale();
                    if (gray < 128) {
                        byte |= @as(u8, 1) << bit;
                    }
                }
                if (bit == 0) break;
                bit -= 1;
            }
            try output.append(byte);
        }
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "PPM format detection" {
    try std.testing.expectEqual(NetpbmFormat.ppm_binary, NetpbmFormat.fromMagic("P6").?);
    try std.testing.expectEqual(NetpbmFormat.pgm_binary, NetpbmFormat.fromMagic("P5").?);
    try std.testing.expectEqual(NetpbmFormat.pbm_binary, NetpbmFormat.fromMagic("P4").?);
    try std.testing.expectEqual(NetpbmFormat.ppm_ascii, NetpbmFormat.fromMagic("P3").?);
}

test "Simple PPM decode" {
    const ppm_data = "P6\n2 2\n255\n" ++ "\xFF\x00\x00" ++ "\x00\xFF\x00" ++ "\x00\x00\xFF" ++ "\xFF\xFF\xFF";

    var img = try decode(std.testing.allocator, ppm_data);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);

    const p00 = img.getPixel(0, 0).?;
    try std.testing.expectEqual(@as(u8, 255), p00.r);
    try std.testing.expectEqual(@as(u8, 0), p00.g);
}

test "PPM with comments" {
    const ppm_data = "P6\n# This is a comment\n2 2\n# Another comment\n255\n" ++ "\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\xFF";

    var img = try decode(std.testing.allocator, ppm_data);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
}
