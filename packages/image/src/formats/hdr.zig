// HDR (Radiance RGBE) Decoder/Encoder
// Implements Radiance HDR/RGBE format
// Based on: http://www.graphics.cornell.edu/~bjw/rgbe.html

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// HDR Constants
// ============================================================================

const HDR_MAGIC_RADIANCE = "#?RADIANCE";
const HDR_MAGIC_RGBE = "#?RGBE";

// RGBE format: 4 bytes per pixel (R, G, B mantissas + shared exponent)
const RGBE = struct {
    r: u8,
    g: u8,
    b: u8,
    e: u8,

    fn toRGB(self: RGBE) struct { r: f32, g: f32, b: f32 } {
        if (self.e == 0) {
            return .{ .r = 0, .g = 0, .b = 0 };
        }

        const exp = @as(f32, @floatFromInt(@as(i32, self.e) - 128 - 8));
        const scale = std.math.pow(f32, 2.0, exp);

        return .{
            .r = @as(f32, @floatFromInt(self.r)) * scale,
            .g = @as(f32, @floatFromInt(self.g)) * scale,
            .b = @as(f32, @floatFromInt(self.b)) * scale,
        };
    }

    fn fromRGB(r: f32, g: f32, b: f32) RGBE {
        const max_val = @max(r, @max(g, b));
        if (max_val < 1e-32) {
            return .{ .r = 0, .g = 0, .b = 0, .e = 0 };
        }

        var exp: i32 = 0;
        const mantissa = std.math.frexp(max_val);
        const v = mantissa.significand * 256.0 / max_val;
        exp = mantissa.exponent;

        return .{
            .r = @intFromFloat(@max(0, @min(255, r * v))),
            .g = @intFromFloat(@max(0, @min(255, g * v))),
            .b = @intFromFloat(@max(0, @min(255, b * v))),
            .e = @intCast(@max(0, @min(255, exp + 128))),
        };
    }
};

// ============================================================================
// HDR Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    var parser = Parser{ .data = data, .pos = 0 };

    // Check magic
    if (!parser.startsWith(HDR_MAGIC_RADIANCE) and !parser.startsWith(HDR_MAGIC_RGBE)) {
        return error.InvalidFormat;
    }

    // Parse header
    var width: u32 = 0;
    var height: u32 = 0;
    var y_flipped = false;
    var x_flipped = false;

    while (parser.pos < data.len) {
        parser.skipLine(); // Skip current line

        if (parser.startsWith("\n") or parser.startsWith("\r\n")) {
            parser.skipLine();
            break;
        }

        // Look for resolution string
        if (parser.startsWith("-Y ") or parser.startsWith("+Y ")) {
            y_flipped = data[parser.pos] == '-';
            parser.pos += 3;

            height = parser.readNumber() orelse return error.InvalidFormat;
            parser.skipWhitespace();

            if (parser.startsWith("-X ") or parser.startsWith("+X ")) {
                x_flipped = data[parser.pos] == '-';
                parser.pos += 3;
                width = parser.readNumber() orelse return error.InvalidFormat;
            }

            parser.skipLine();
            break;
        }
    }

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Allocate HDR buffer
    var hdr_data = try allocator.alloc(RGBE, @as(usize, width) * height);
    defer allocator.free(hdr_data);

    // Decode scanlines
    try decodeScanlines(&parser, hdr_data, width, height, allocator);

    // Convert to LDR image (tone mapping)
    var img = try Image.init(allocator, width, height, .rgb8);
    errdefer img.deinit();

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_x = if (x_flipped) width - 1 - x else x;
            const src_y = if (y_flipped) y else height - 1 - y;

            const rgbe = hdr_data[src_y * width + src_x];
            const rgb = rgbe.toRGB();

            // Simple Reinhard tone mapping
            const mapped = toneMap(rgb.r, rgb.g, rgb.b);

            img.setPixel(x, y, Color{
                .r = @intFromFloat(@max(0, @min(255, mapped.r * 255))),
                .g = @intFromFloat(@max(0, @min(255, mapped.g * 255))),
                .b = @intFromFloat(@max(0, @min(255, mapped.b * 255))),
                .a = 255,
            });
        }
    }

    return img;
}

fn decodeScanlines(parser: *Parser, hdr_data: []RGBE, width: u32, height: u32, allocator: std.mem.Allocator) !void {
    var scanline_buf = try allocator.alloc(u8, width * 4);
    defer allocator.free(scanline_buf);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = hdr_data[y * width ..][0..width];

        if (parser.pos + 4 > parser.data.len) return error.TruncatedData;

        // Check for new-style RLE
        if (parser.data[parser.pos] == 2 and parser.data[parser.pos + 1] == 2) {
            const scanline_width = (@as(u32, parser.data[parser.pos + 2]) << 8) | parser.data[parser.pos + 3];
            if (scanline_width != width) return error.InvalidFormat;

            parser.pos += 4;

            // Decode each channel separately
            for (0..4) |channel| {
                var x: u32 = 0;
                while (x < width) {
                    if (parser.pos >= parser.data.len) return error.TruncatedData;

                    const code = parser.data[parser.pos];
                    parser.pos += 1;

                    if (code > 128) {
                        // Run
                        const run_len = code - 128;
                        if (parser.pos >= parser.data.len) return error.TruncatedData;
                        const val = parser.data[parser.pos];
                        parser.pos += 1;

                        var i: u32 = 0;
                        while (i < run_len and x < width) : (i += 1) {
                            scanline_buf[x * 4 + channel] = val;
                            x += 1;
                        }
                    } else {
                        // Literal
                        var i: u8 = 0;
                        while (i < code and x < width) : (i += 1) {
                            if (parser.pos >= parser.data.len) return error.TruncatedData;
                            scanline_buf[x * 4 + channel] = parser.data[parser.pos];
                            parser.pos += 1;
                            x += 1;
                        }
                    }
                }
            }

            // Convert scanline buffer to RGBE
            for (0..width) |x| {
                row[x] = .{
                    .r = scanline_buf[x * 4],
                    .g = scanline_buf[x * 4 + 1],
                    .b = scanline_buf[x * 4 + 2],
                    .e = scanline_buf[x * 4 + 3],
                };
            }
        } else {
            // Old-style or uncompressed
            for (0..width) |x| {
                if (parser.pos + 4 > parser.data.len) return error.TruncatedData;
                row[x] = .{
                    .r = parser.data[parser.pos],
                    .g = parser.data[parser.pos + 1],
                    .b = parser.data[parser.pos + 2],
                    .e = parser.data[parser.pos + 3],
                };
                parser.pos += 4;
            }
        }
    }
}

fn toneMap(r: f32, g: f32, b: f32) struct { r: f32, g: f32, b: f32 } {
    // Reinhard tone mapping with exposure adjustment
    const exposure: f32 = 1.0;
    const gamma: f32 = 2.2;

    const map = struct {
        fn f(v: f32, exp: f32, gam: f32) f32 {
            const exposed = v * exp;
            const mapped = exposed / (1.0 + exposed);
            return std.math.pow(f32, mapped, 1.0 / gam);
        }
    }.f;

    return .{
        .r = map(r, exposure, gamma),
        .g = map(g, exposure, gamma),
        .b = map(b, exposure, gamma),
    };
}

const Parser = struct {
    data: []const u8,
    pos: usize,

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.data.len) return false;
        return std.mem.eql(u8, self.data[self.pos..][0..prefix.len], prefix);
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.data.len and self.data[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.data.len and (self.data[self.pos] == ' ' or self.data[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn readNumber(self: *Parser) ?u32 {
        const start = self.pos;
        while (self.pos < self.data.len and std.ascii.isDigit(self.data[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(u32, self.data[start..self.pos], 10) catch null;
    }
};

// ============================================================================
// HDR Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Header
    try output.appendSlice("#?RADIANCE\n");
    try output.appendSlice("FORMAT=32-bit_rle_rgbe\n");
    try output.appendSlice("\n");

    // Resolution
    try output.appendSlice("-Y ");
    var buf: [32]u8 = undefined;
    var len = std.fmt.formatIntBuf(&buf, img.height, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.appendSlice(" +X ");
    len = std.fmt.formatIntBuf(&buf, img.width, 10, .lower, .{});
    try output.appendSlice(buf[0..len]);
    try output.append('\n');

    // Encode scanlines with RLE
    var scanline = try allocator.alloc(u8, img.width * 4);
    defer allocator.free(scanline);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        // New-style RLE header
        try output.append(2);
        try output.append(2);
        try output.append(@truncate(img.width >> 8));
        try output.append(@truncate(img.width));

        // Fill scanline buffer
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const src_y = img.height - 1 - y;
            const color = img.getPixel(x, src_y) orelse Color.BLACK;

            // Convert to HDR (assume sRGB input)
            const r = srgbToLinear(@as(f32, @floatFromInt(color.r)) / 255.0);
            const g = srgbToLinear(@as(f32, @floatFromInt(color.g)) / 255.0);
            const b = srgbToLinear(@as(f32, @floatFromInt(color.b)) / 255.0);

            const rgbe = RGBE.fromRGB(r, g, b);
            scanline[x] = rgbe.r;
            scanline[img.width + x] = rgbe.g;
            scanline[2 * img.width + x] = rgbe.b;
            scanline[3 * img.width + x] = rgbe.e;
        }

        // RLE encode each channel
        for (0..4) |channel| {
            const channel_data = scanline[channel * img.width ..][0..img.width];
            try encodeRLE(&output, channel_data);
        }
    }

    return output.toOwnedSlice();
}

fn encodeRLE(output: *std.ArrayList(u8), data: []const u8) !void {
    var i: usize = 0;

    while (i < data.len) {
        // Check for run
        var run_len: usize = 1;
        while (i + run_len < data.len and run_len < 127 and data[i + run_len] == data[i]) {
            run_len += 1;
        }

        if (run_len > 2) {
            // Encode as run
            try output.append(@as(u8, @truncate(run_len + 128)));
            try output.append(data[i]);
            i += run_len;
        } else {
            // Find literal run
            var lit_len: usize = 1;
            while (i + lit_len < data.len and lit_len < 127) {
                // Check if a run of 3+ starts
                if (i + lit_len + 2 < data.len and
                    data[i + lit_len] == data[i + lit_len + 1] and
                    data[i + lit_len] == data[i + lit_len + 2])
                {
                    break;
                }
                lit_len += 1;
            }

            try output.append(@truncate(lit_len));
            try output.appendSlice(data[i..][0..lit_len]);
            i += lit_len;
        }
    }
}

fn srgbToLinear(v: f32) f32 {
    if (v <= 0.04045) {
        return v / 12.92;
    }
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

// ============================================================================
// Tests
// ============================================================================

test "RGBE conversion" {
    const rgbe = RGBE.fromRGB(1.0, 0.5, 0.25);
    const rgb = rgbe.toRGB();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rgb.r, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rgb.g, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rgb.b, 0.02);
}

test "RGBE zero handling" {
    const rgbe = RGBE.fromRGB(0, 0, 0);
    try std.testing.expectEqual(@as(u8, 0), rgbe.e);

    const rgb = rgbe.toRGB();
    try std.testing.expectEqual(@as(f32, 0), rgb.r);
}

test "HDR magic detection" {
    try std.testing.expectEqualSlices(u8, "#?RADIANCE", HDR_MAGIC_RADIANCE);
}
