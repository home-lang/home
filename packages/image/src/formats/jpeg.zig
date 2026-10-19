// JPEG Decoder/Encoder
// Implements JPEG/JFIF baseline and progressive
// Based on ITU-T T.81

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// JPEG Constants
// ============================================================================

const Marker = enum(u16) {
    SOI = 0xFFD8, // Start of image
    EOI = 0xFFD9, // End of image
    SOF0 = 0xFFC0, // Baseline DCT
    SOF1 = 0xFFC1, // Extended sequential DCT
    SOF2 = 0xFFC2, // Progressive DCT
    DHT = 0xFFC4, // Define Huffman table
    DQT = 0xFFDB, // Define quantization table
    DRI = 0xFFDD, // Define restart interval
    SOS = 0xFFDA, // Start of scan
    APP0 = 0xFFE0, // JFIF marker
    APP1 = 0xFFE1, // EXIF marker
    APP2 = 0xFFE2, // ICC profile
    COM = 0xFFFE, // Comment
    RST0 = 0xFFD0, // Restart markers
    RST1 = 0xFFD1,
    RST2 = 0xFFD2,
    RST3 = 0xFFD3,
    RST4 = 0xFFD4,
    RST5 = 0xFFD5,
    RST6 = 0xFFD6,
    RST7 = 0xFFD7,
    _,
};

// Zigzag order for DCT coefficients
const ZIGZAG = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// Default quantization tables (from JPEG standard)
const DEFAULT_LUMINANCE_QUANT = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const DEFAULT_CHROMINANCE_QUANT = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

// ============================================================================
// Huffman Tables
// ============================================================================

const HuffmanTable = struct {
    bits: [17]u8, // Number of codes of each length (1-16)
    values: [256]u8,
    num_values: usize,

    // Lookup tables for fast decoding
    maxcode: [18]i32,
    mincode: [17]i32,
    valptr: [17]i32,

    pub fn init() HuffmanTable {
        return HuffmanTable{
            .bits = @splat(0),
            .values = @splat(0),
            .num_values = 0,
            .maxcode = @splat(0),
            .mincode = @splat(0),
            .valptr = @splat(0),
        };
    }

    pub fn buildLookup(self: *HuffmanTable) void {
        var code: i32 = 0;
        var valptr: i32 = 0;

        for (1..17) |i| {
            self.mincode[i] = code;
            self.valptr[i] = valptr;

            const count = self.bits[i];
            code += count;
            valptr += count;

            self.maxcode[i] = code - 1;
            code <<= 1;
        }
        self.maxcode[17] = 0x7FFFFFFF;
    }
};

// ============================================================================
// JPEG Decoder State
// ============================================================================

const JpegDecoder = struct {
    data: []const u8,
    pos: usize,
    width: u32,
    height: u32,
    num_components: u8,
    components: [4]Component,
    quant_tables: [4][64]u16,
    dc_tables: [4]HuffmanTable,
    ac_tables: [4]HuffmanTable,
    restart_interval: u16,
    progressive: bool,
    allocator: std.mem.Allocator,

    // Bit reader state
    bit_buffer: u32,
    bits_in_buffer: u8,

    const Component = struct {
        id: u8,
        h_sample: u8,
        v_sample: u8,
        quant_table: u8,
        dc_table: u8,
        ac_table: u8,
        dc_pred: i32,
    };

    pub fn init(allocator: std.mem.Allocator, data: []const u8) JpegDecoder {
        return JpegDecoder{
            .data = data,
            .pos = 0,
            .width = 0,
            .height = 0,
            .num_components = 0,
            .components = @splat(Component{
                .id = 0,
                .h_sample = 1,
                .v_sample = 1,
                .quant_table = 0,
                .dc_table = 0,
                .ac_table = 0,
                .dc_pred = 0,
            }),
            .quant_tables = @splat(@as([64]u16, @splat(16))),
            .dc_tables = @splat(HuffmanTable.init()),
            .ac_tables = @splat(HuffmanTable.init()),
            .restart_interval = 0,
            .progressive = false,
            .allocator = allocator,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    fn readByte(self: *JpegDecoder) !u8 {
        if (self.pos >= self.data.len) return error.TruncatedData;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16(self: *JpegDecoder) !u16 {
        const high = try self.readByte();
        const low = try self.readByte();
        return (@as(u16, high) << 8) | low;
    }

    fn readMarker(self: *JpegDecoder) !Marker {
        const b1 = try self.readByte();
        if (b1 != 0xFF) return error.InvalidFormat;

        var b2 = try self.readByte();
        // Skip padding bytes
        while (b2 == 0xFF) {
            b2 = try self.readByte();
        }

        return @fromBackingInt(@intCast((@as(u16, 0xFF) << 8) | b2));
    }

    fn skipMarker(self: *JpegDecoder) !void {
        const length = try self.readU16();
        if (length < 2) return error.InvalidFormat;
        self.pos += length - 2;
    }

    fn parseSOF(self: *JpegDecoder) !void {
        const length = try self.readU16();
        if (length < 8) return error.InvalidFormat;

        const precision = try self.readByte();
        if (precision != 8) return error.UnsupportedFormat; // Only 8-bit supported

        self.height = try self.readU16();
        self.width = try self.readU16();
        self.num_components = try self.readByte();

        if (self.num_components > 4) return error.InvalidFormat;

        for (0..self.num_components) |i| {
            self.components[i].id = try self.readByte();
            const sampling = try self.readByte();
            self.components[i].h_sample = sampling >> 4;
            self.components[i].v_sample = sampling & 0x0F;
            self.components[i].quant_table = try self.readByte();
        }
    }

    fn parseDQT(self: *JpegDecoder) !void {
        var length = try self.readU16();
        length -= 2;

        while (length > 0) {
            const info = try self.readByte();
            length -= 1;

            const precision = info >> 4;
            const table_id = info & 0x0F;

            if (table_id > 3) return error.InvalidFormat;

            if (precision == 0) {
                // 8-bit values
                for (0..64) |i| {
                    self.quant_tables[table_id][ZIGZAG[i]] = try self.readByte();
                }
                length -= 64;
            } else {
                // 16-bit values
                for (0..64) |i| {
                    self.quant_tables[table_id][ZIGZAG[i]] = try self.readU16();
                }
                length -= 128;
            }
        }
    }

    fn parseDHT(self: *JpegDecoder) !void {
        var length = try self.readU16();
        length -= 2;

        while (length > 0) {
            const info = try self.readByte();
            length -= 1;

            const table_class = info >> 4; // 0 = DC, 1 = AC
            const table_id = info & 0x0F;

            if (table_id > 3) return error.InvalidFormat;

            const table = if (table_class == 0)
                &self.dc_tables[table_id]
            else
                &self.ac_tables[table_id];

            // Read code lengths
            var total_codes: usize = 0;
            for (1..17) |i| {
                table.bits[i] = try self.readByte();
                total_codes += table.bits[i];
            }
            length -= 16;

            // Read values
            table.num_values = total_codes;
            for (0..total_codes) |i| {
                table.values[i] = try self.readByte();
            }
            length -= @intCast(total_codes);

            table.buildLookup();
        }
    }

    fn parseDRI(self: *JpegDecoder) !void {
        _ = try self.readU16(); // Length (always 4)
        self.restart_interval = try self.readU16();
    }

    fn parseSOS(self: *JpegDecoder) !void {
        const length = try self.readU16();
        const num_components = try self.readByte();

        for (0..num_components) |_| {
            const id = try self.readByte();
            const tables = try self.readByte();

            // Find component and set tables
            for (0..self.num_components) |j| {
                if (self.components[j].id == id) {
                    self.components[j].dc_table = tables >> 4;
                    self.components[j].ac_table = tables & 0x0F;
                    break;
                }
            }
        }

        // Skip spectral selection and successive approximation bytes
        self.pos += length - 3 - num_components * 2;
    }

    // Bit reading for entropy decoding
    fn fillBitBuffer(self: *JpegDecoder) !void {
        while (self.bits_in_buffer <= 24 and self.pos < self.data.len) {
            const byte = self.data[self.pos];
            self.pos += 1;

            // Handle byte stuffing (0xFF00 -> 0xFF)
            if (byte == 0xFF) {
                if (self.pos < self.data.len) {
                    const next = self.data[self.pos];
                    if (next == 0x00) {
                        self.pos += 1;
                    } else if (next >= 0xD0 and next <= 0xD7) {
                        // Restart marker - skip it
                        self.pos += 1;
                        continue;
                    } else {
                        // End of scan
                        self.pos -= 1;
                        return;
                    }
                }
            }

            self.bit_buffer = (self.bit_buffer << 8) | byte;
            self.bits_in_buffer += 8;
        }
    }

    fn getBits(self: *JpegDecoder, count: u5) !u32 {
        try self.fillBitBuffer();

        if (self.bits_in_buffer < count) {
            return 0;
        }

        const shift: u5 = @intCast(self.bits_in_buffer - count);
        const result = (self.bit_buffer >> shift) & ((@as(u32, 1) << count) - 1);
        self.bits_in_buffer -= count;

        return result;
    }

    fn decodeHuffman(self: *JpegDecoder, table: *const HuffmanTable) !u8 {
        try self.fillBitBuffer();

        var code: i32 = 0;
        var i: u5 = 1;

        while (i <= 16) : (i += 1) {
            if (self.bits_in_buffer == 0) {
                try self.fillBitBuffer();
            }

            const shift: u5 = @intCast(self.bits_in_buffer - 1);
            code = (code << 1) | @as(i32, @intCast((self.bit_buffer >> shift) & 1));
            self.bits_in_buffer -= 1;

            if (code <= table.maxcode[i]) {
                const idx = table.valptr[i] + code - table.mincode[i];
                if (idx >= 0 and idx < @as(i32, @intCast(table.num_values))) {
                    return table.values[@intCast(idx)];
                }
            }
        }

        return error.DecompressionFailed;
    }

    fn decodeNumber(self: *JpegDecoder, bits: u4) !i32 {
        if (bits == 0) return 0;

        const value = try self.getBits(bits);
        const threshold: u32 = @as(u32, 1) << (bits - 1);

        if (value < threshold) {
            // Negative number
            return @as(i32, @intCast(value)) - @as(i32, @intCast((@as(u32, 1) << bits) - 1));
        }
        return @intCast(value);
    }

    fn decodeMCU(self: *JpegDecoder, component: *Component) ![64]i32 {
        var block: [64]i32 = @splat(0);

        // Decode DC coefficient
        const dc_table = &self.dc_tables[component.dc_table];
        const dc_bits = try self.decodeHuffman(dc_table);
        const dc_diff = try self.decodeNumber(@intCast(dc_bits));
        component.dc_pred += dc_diff;
        block[0] = component.dc_pred;

        // Decode AC coefficients
        const ac_table = &self.ac_tables[component.ac_table];
        var k: usize = 1;

        while (k < 64) {
            const symbol = try self.decodeHuffman(ac_table);

            if (symbol == 0) {
                // End of block
                break;
            }

            const zeros = symbol >> 4;
            const bits: u4 = @intCast(symbol & 0x0F);

            if (bits == 0) {
                if (zeros == 15) {
                    // Skip 16 zeros
                    k += 16;
                } else {
                    // EOB
                    break;
                }
            } else {
                k += zeros;
                if (k < 64) {
                    block[ZIGZAG[k]] = try self.decodeNumber(bits);
                    k += 1;
                }
            }
        }

        return block;
    }
};

// ============================================================================
// IDCT (Inverse Discrete Cosine Transform)
// ============================================================================

fn idct(block: *[64]i32, quant: *const [64]u16) void {
    @import("../jpeg_dct.zig").inverse(block, quant);
}

fn clamp(value: i32) i32 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return value;
}

// ============================================================================
// YCbCr to RGB Conversion
// ============================================================================

fn ycbcrToRgb(y: i32, cb: i32, cr: i32) Color {
    // Full-range YCbCr to RGB
    const r = y + @divTrunc((cr - 128) * 359, 256);
    const g = y - @divTrunc((cb - 128) * 88 + (cr - 128) * 183, 256);
    const b = y + @divTrunc((cb - 128) * 454, 256);

    return Color{
        .r = @intCast(std.math.clamp(r, 0, 255)),
        .g = @intCast(std.math.clamp(g, 0, 255)),
        .b = @intCast(std.math.clamp(b, 0, 255)),
        .a = 255,
    };
}

// ============================================================================
// Public Decode Function
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 4) return error.TruncatedData;

    // Check JPEG signature
    if (data[0] != 0xFF or data[1] != 0xD8) {
        return error.InvalidFormat;
    }

    var decoder = JpegDecoder.init(allocator, data);
    decoder.pos = 2; // Skip SOI

    // Parse headers
    while (decoder.pos < data.len) {
        const marker = try decoder.readMarker();

        switch (marker) {
            .SOF0 => {
                decoder.progressive = false;
                try decoder.parseSOF();
            },
            .SOF2 => {
                decoder.progressive = true;
                try decoder.parseSOF();
            },
            .DHT => try decoder.parseDHT(),
            .DQT => try decoder.parseDQT(),
            .DRI => try decoder.parseDRI(),
            .SOS => {
                try decoder.parseSOS();
                break; // Start decoding
            },
            .EOI => break,
            else => {
                // Skip unknown markers
                if (@backingInt(marker) >= 0xFFC0) {
                    try decoder.skipMarker();
                }
            },
        }
    }

    if (decoder.width == 0 or decoder.height == 0) {
        return error.InvalidDimensions;
    }

    // Create output image
    const format: PixelFormat = if (decoder.num_components == 1) .grayscale8 else .rgb8;
    var img = try Image.init(allocator, decoder.width, decoder.height, format);
    errdefer img.deinit();

    // Decode MCUs
    const mcu_width: u32 = 8;
    const mcu_height: u32 = 8;
    const mcus_x = (decoder.width + mcu_width - 1) / mcu_width;
    const mcus_y = (decoder.height + mcu_height - 1) / mcu_height;

    // Reset DC predictors
    for (0..decoder.num_components) |i| {
        decoder.components[i].dc_pred = 0;
    }

    var mcu_y: u32 = 0;
    while (mcu_y < mcus_y) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcus_x) : (mcu_x += 1) {
            // Decode each component's block (max 4 components: Y, Cb, Cr, A)
            var blocks: [4][64]i32 = undefined;

            if (decoder.num_components > 4) return error.InvalidComponent;
            for (0..decoder.num_components) |c| {
                blocks[c] = try decoder.decodeMCU(&decoder.components[c]);
                const qt_idx = decoder.components[c].quant_table;
                if (qt_idx >= decoder.quant_tables.len) return error.InvalidQuantTable;
                idct(&blocks[c], &decoder.quant_tables[qt_idx]);
            }

            // Convert to RGB and store
            var by: u32 = 0;
            while (by < 8) : (by += 1) {
                const py = mcu_y * mcu_height + by;
                if (py >= decoder.height) continue;

                var bx: u32 = 0;
                while (bx < 8) : (bx += 1) {
                    const px = mcu_x * mcu_width + bx;
                    if (px >= decoder.width) continue;

                    const block_idx = by * 8 + bx;

                    const color = if (decoder.num_components == 1)
                        Color{
                            .r = @intCast(std.math.clamp(blocks[0][block_idx], 0, 255)),
                            .g = @intCast(std.math.clamp(blocks[0][block_idx], 0, 255)),
                            .b = @intCast(std.math.clamp(blocks[0][block_idx], 0, 255)),
                            .a = 255,
                        }
                    else
                        ycbcrToRgb(
                            blocks[0][block_idx],
                            blocks[1][block_idx],
                            blocks[2][block_idx],
                        );

                    img.setPixel(px, py, color);
                }
            }
        }
    }

    return img;
}

// ============================================================================
// JPEG Encoder (basic quality encoding)
// ============================================================================

/// Encode baseline JPEG with a real DCT/quantization/Huffman scan. The standalone
/// encoder also accepts borrowed, padded rows and can reuse its output capacity.
pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    return encodeWithQuality(allocator, img, 90);
}
pub fn encodeWithQuality(allocator: std.mem.Allocator, img: *const Image, quality: u8) ![]u8 {
    const channels: u8 = switch (img.format) {
        .grayscale8 => 1,
        .rgb8 => 3,
        .rgba8 => 4,
        else => return error.UnsupportedFormat,
    };
    var encoder = @import("../jpeg_encoder.zig").Encoder.init(allocator);
    defer encoder.deinit();
    _ = try encoder.encode(img.pixels, img.width, img.height, @as(usize, img.width) * channels, channels, quality);
    return encoder.output.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "JPEG marker constants" {
    try std.testing.expectEqual(@as(u16, 0xFFD8), @backingInt(Marker.SOI));
    try std.testing.expectEqual(@as(u16, 0xFFD9), @backingInt(Marker.EOI));
}

test "YCbCr to RGB conversion" {
    // White (Y=255, Cb=128, Cr=128 should give RGB ~255,255,255)
    const white = ycbcrToRgb(255, 128, 128);
    try std.testing.expect(white.r > 250);
    try std.testing.expect(white.g > 250);
    try std.testing.expect(white.b > 250);

    // Black (Y=0, Cb=128, Cr=128 should give RGB ~0,0,0)
    const black = ycbcrToRgb(0, 128, 128);
    try std.testing.expect(black.r < 5);
    try std.testing.expect(black.g < 5);
    try std.testing.expect(black.b < 5);
}

test "Clamp function" {
    try std.testing.expectEqual(@as(i32, 0), clamp(-100));
    try std.testing.expectEqual(@as(i32, 255), clamp(300));
    try std.testing.expectEqual(@as(i32, 128), clamp(128));
}

test "JPEG encoder writes bounded baseline dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 3, 2, .rgb8);
    defer img.deinit();

    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, encoded[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, encoded[encoded.len - 2 ..]);

    const sof = std.mem.indexOf(u8, encoded, &.{ 0xFF, 0xC0 }) orelse return error.MissingStartOfFrame;
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, encoded[sof + 5 ..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, encoded[sof + 7 ..][0..2], .big));

    var empty = try Image.init(allocator, 0, 1, .rgb8);
    defer empty.deinit();
    try std.testing.expectError(error.InvalidDimensions, encode(allocator, &empty));

    var unsupported = try Image.init(allocator, 1, 1, .rgb16);
    defer unsupported.deinit();
    try std.testing.expectError(error.UnsupportedFormat, encode(allocator, &unsupported));
}
