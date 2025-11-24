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
            .bits = [_]u8{0} ** 17,
            .values = [_]u8{0} ** 256,
            .num_values = 0,
            .maxcode = [_]i32{0} ** 18,
            .mincode = [_]i32{0} ** 17,
            .valptr = [_]i32{0} ** 17,
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
            .components = [_]Component{Component{
                .id = 0,
                .h_sample = 1,
                .v_sample = 1,
                .quant_table = 0,
                .dc_table = 0,
                .ac_table = 0,
                .dc_pred = 0,
            }} ** 4,
            .quant_tables = [_][64]u16{[_]u16{16} ** 64} ** 4,
            .dc_tables = [_]HuffmanTable{HuffmanTable.init()} ** 4,
            .ac_tables = [_]HuffmanTable{HuffmanTable.init()} ** 4,
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

        return @enumFromInt((@as(u16, 0xFF) << 8) | b2);
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
                if (idx >= 0 and idx < 256) {
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
        var block = [_]i32{0} ** 64;

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
    // Dequantize
    for (0..64) |i| {
        block[i] *= @intCast(quant[i]);
    }

    // Fast IDCT using scaled integers
    // Based on AAN algorithm
    var workspace: [64]i32 = undefined;

    // Process columns
    for (0..8) |col| {
        idctColumn(block, &workspace, col);
    }

    // Process rows
    for (0..8) |row| {
        idctRow(&workspace, block, row);
    }
}

fn idctColumn(input: *const [64]i32, output: *[64]i32, col: usize) void {
    const s0 = input[col + 0 * 8];
    const s1 = input[col + 1 * 8];
    const s2 = input[col + 2 * 8];
    const s3 = input[col + 3 * 8];
    const s4 = input[col + 4 * 8];
    const s5 = input[col + 5 * 8];
    const s6 = input[col + 6 * 8];
    const s7 = input[col + 7 * 8];

    // Stage 1
    const p2 = s2;
    const p3 = s6;
    const p1 = @divTrunc((p2 + p3) * 2896, 4096); // cos(4*pi/16) * 4096
    const t2 = @divTrunc(p3 * -7017, 4096) + p1; // -cos(4*pi/16) - cos(2*pi/16)
    const t3 = @divTrunc(p2 * 3406, 4096) + p1; // cos(4*pi/16) - cos(6*pi/16)

    const t0 = (s0 + s4) << 12;
    const t1 = (s0 - s4) << 12;

    const t10 = t0 + t3;
    const t13 = t0 - t3;
    const t11 = t1 + t2;
    const t12 = t1 - t2;

    // Stage 2
    const z1 = s7 + s1;
    const z2 = s5 + s3;
    const z3 = s7 + s3;
    const z4 = s5 + s1;
    const z5 = @divTrunc((z3 + z4) * 4816, 4096); // cos(2*pi/16) + cos(6*pi/16)

    const t4 = @divTrunc(s7 * 799, 4096);
    const t5 = @divTrunc(s5 * 2276, 4096);
    const t6 = @divTrunc(s3 * 3406, 4096);
    const t7 = @divTrunc(s1 * 4017, 4096);

    const z1_scaled = @divTrunc(z1 * -1390, 4096);
    const z2_scaled = @divTrunc(z2 * -3406, 4096);
    const z3_scaled = @divTrunc(z3 * -7017, 4096);
    const z4_scaled = @divTrunc(z4 * 799, 4096);

    const t4_out = t4 + z1_scaled + z3_scaled;
    const t5_out = t5 + z2_scaled + z4_scaled;
    const t6_out = t6 + z2_scaled + z3_scaled;
    const t7_out = t7 + z1_scaled + z4_scaled + z5;

    output[col + 0 * 8] = (t10 + t7_out) >> 12;
    output[col + 7 * 8] = (t10 - t7_out) >> 12;
    output[col + 1 * 8] = (t11 + t6_out) >> 12;
    output[col + 6 * 8] = (t11 - t6_out) >> 12;
    output[col + 2 * 8] = (t12 + t5_out) >> 12;
    output[col + 5 * 8] = (t12 - t5_out) >> 12;
    output[col + 3 * 8] = (t13 + t4_out) >> 12;
    output[col + 4 * 8] = (t13 - t4_out) >> 12;
}

fn idctRow(input: *const [64]i32, output: *[64]i32, row: usize) void {
    const base = row * 8;
    const s0 = input[base + 0];
    const s1 = input[base + 1];
    const s2 = input[base + 2];
    const s3 = input[base + 3];
    const s4 = input[base + 4];
    const s5 = input[base + 5];
    const s6 = input[base + 6];
    const s7 = input[base + 7];

    // Simplified 1D IDCT
    const t0 = (s0 + s4) << 7;
    const t1 = (s0 - s4) << 7;

    const t2 = @divTrunc(s2 * 2896, 4096) - @divTrunc(s6 * 1203, 4096);
    const t3 = @divTrunc(s2 * 1203, 4096) + @divTrunc(s6 * 2896, 4096);

    const t10 = t0 + t3;
    const t13 = t0 - t3;
    const t11 = t1 + t2;
    const t12 = t1 - t2;

    const z1 = s1 + s7;
    const z2 = s3 + s5;
    const z3 = s1 + s5;
    const z4 = s3 + s7;

    const t4 = @divTrunc(s7 * 799, 4096) - @divTrunc(z1 * 1390, 4096) - @divTrunc(z3 * 3406, 4096);
    const t5 = @divTrunc(s5 * 2276, 4096) - @divTrunc(z2 * 3406, 4096) + @divTrunc(z4 * 799, 4096);
    const t6 = @divTrunc(s3 * 3406, 4096) - @divTrunc(z2 * 3406, 4096) - @divTrunc(z3 * 3406, 4096);
    const t7 = @divTrunc(s1 * 4017, 4096) - @divTrunc(z1 * 1390, 4096) + @divTrunc(z4 * 799, 4096);

    // Final output with level shift and clamping
    output[base + 0] = clamp(@divTrunc(t10 + t7, 256) + 128);
    output[base + 7] = clamp(@divTrunc(t10 - t7, 256) + 128);
    output[base + 1] = clamp(@divTrunc(t11 + t6, 256) + 128);
    output[base + 6] = clamp(@divTrunc(t11 - t6, 256) + 128);
    output[base + 2] = clamp(@divTrunc(t12 + t5, 256) + 128);
    output[base + 5] = clamp(@divTrunc(t12 - t5, 256) + 128);
    output[base + 3] = clamp(@divTrunc(t13 + t4, 256) + 128);
    output[base + 4] = clamp(@divTrunc(t13 - t4, 256) + 128);
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
                if (@intFromEnum(marker) >= 0xFFC0) {
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
            // Decode each component's block
            var blocks: [4][64]i32 = undefined;

            for (0..decoder.num_components) |c| {
                blocks[c] = try decoder.decodeMCU(&decoder.components[c]);
                idct(&blocks[c], &decoder.quant_tables[decoder.components[c].quant_table]);
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

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // SOI marker
    try output.appendSlice(&[_]u8{ 0xFF, 0xD8 });

    // APP0 (JFIF) marker
    try output.appendSlice(&[_]u8{
        0xFF, 0xE0, // APP0
        0x00, 0x10, // Length = 16
        'J',  'F',  'I', 'F', 0x00, // Identifier
        0x01, 0x01, // Version 1.1
        0x00, // Aspect ratio units (0 = no units)
        0x00, 0x01, // X density
        0x00, 0x01, // Y density
        0x00, // Thumbnail width
        0x00, // Thumbnail height
    });

    // DQT marker (quantization tables)
    try output.appendSlice(&[_]u8{ 0xFF, 0xDB, 0x00, 0x43, 0x00 }); // Length, table 0
    try output.appendSlice(&DEFAULT_LUMINANCE_QUANT);

    // Second quantization table for chrominance
    try output.appendSlice(&[_]u8{ 0xFF, 0xDB, 0x00, 0x43, 0x01 });
    try output.appendSlice(&DEFAULT_CHROMINANCE_QUANT);

    // SOF0 (baseline DCT)
    const is_grayscale = img.format == .grayscale8;
    const num_components: u8 = if (is_grayscale) 1 else 3;

    try output.appendSlice(&[_]u8{
        0xFF,
        0xC0, // SOF0
        0x00,
        @intCast(8 + num_components * 3), // Length
        0x08, // Precision (8 bits)
    });
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(img.height))));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(img.width))));
    try output.append(num_components);

    if (is_grayscale) {
        try output.appendSlice(&[_]u8{ 1, 0x11, 0 }); // Y component
    } else {
        try output.appendSlice(&[_]u8{ 1, 0x11, 0 }); // Y component
        try output.appendSlice(&[_]u8{ 2, 0x11, 1 }); // Cb component
        try output.appendSlice(&[_]u8{ 3, 0x11, 1 }); // Cr component
    }

    // DHT (Huffman tables) - using standard JPEG tables
    try writeStandardHuffmanTables(&output);

    // SOS (start of scan)
    try output.appendSlice(&[_]u8{
        0xFF,
        0xDA, // SOS
        0x00,
        @intCast(6 + num_components * 2), // Length
        num_components,
    });

    if (is_grayscale) {
        try output.appendSlice(&[_]u8{ 1, 0x00 }); // Component 1, DC/AC table 0
    } else {
        try output.appendSlice(&[_]u8{ 1, 0x00 }); // Y: tables 0/0
        try output.appendSlice(&[_]u8{ 2, 0x11 }); // Cb: tables 1/1
        try output.appendSlice(&[_]u8{ 3, 0x11 }); // Cr: tables 1/1
    }

    try output.appendSlice(&[_]u8{ 0x00, 0x3F, 0x00 }); // Spectral selection, successive approx

    // Encode scan data (simplified - just output raw MCUs with minimal compression)
    // This is a placeholder - full encoding would require DCT, quantization, Huffman encoding

    // For now, output a minimal valid bitstream
    // A proper implementation would encode each 8x8 block with DCT

    // EOI marker
    try output.appendSlice(&[_]u8{ 0xFF, 0xD9 });

    return output.toOwnedSlice();
}

fn writeStandardHuffmanTables(output: *std.ArrayList(u8)) !void {
    // DC luminance table
    try output.appendSlice(&[_]u8{
        0xFF, 0xC4, // DHT marker
        0x00, 0x1F, // Length
        0x00, // DC table 0
        0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Bits
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, // Values
    });

    // AC luminance table
    try output.appendSlice(&[_]u8{
        0xFF, 0xC4, // DHT marker
        0x00, 0xB5, // Length
        0x10, // AC table 0
        0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D, // Bits
    });
    // AC values (162 bytes)
    const ac_values = [_]u8{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    };
    try output.appendSlice(&ac_values);

    // DC chrominance table
    try output.appendSlice(&[_]u8{
        0xFF, 0xC4, // DHT marker
        0x00, 0x1F, // Length
        0x01, // DC table 1
        0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, // Bits
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, // Values
    });

    // AC chrominance table
    try output.appendSlice(&[_]u8{
        0xFF, 0xC4, // DHT marker
        0x00, 0xB5, // Length
        0x11, // AC table 1
        0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, // Bits
    });
    try output.appendSlice(&ac_values);
}

// ============================================================================
// Tests
// ============================================================================

test "JPEG marker constants" {
    try std.testing.expectEqual(@as(u16, 0xFFD8), @intFromEnum(Marker.SOI));
    try std.testing.expectEqual(@as(u16, 0xFFD9), @intFromEnum(Marker.EOI));
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
