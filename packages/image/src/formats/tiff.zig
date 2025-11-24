// TIFF Decoder/Encoder
// Implements TIFF (Tagged Image File Format) based on TIFF 6.0 specification
// Supports: Bilevel, Grayscale, Palette-color, RGB, with various compression methods

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// TIFF Constants
// ============================================================================

// Byte order markers
const LITTLE_ENDIAN_MARKER: u16 = 0x4949; // "II"
const BIG_ENDIAN_MARKER: u16 = 0x4D4D; // "MM"
const TIFF_MAGIC: u16 = 42;

// Tag IDs
const TAG_IMAGE_WIDTH: u16 = 256;
const TAG_IMAGE_LENGTH: u16 = 257;
const TAG_BITS_PER_SAMPLE: u16 = 258;
const TAG_COMPRESSION: u16 = 259;
const TAG_PHOTOMETRIC: u16 = 262;
const TAG_STRIP_OFFSETS: u16 = 273;
const TAG_SAMPLES_PER_PIXEL: u16 = 277;
const TAG_ROWS_PER_STRIP: u16 = 278;
const TAG_STRIP_BYTE_COUNTS: u16 = 279;
const TAG_X_RESOLUTION: u16 = 282;
const TAG_Y_RESOLUTION: u16 = 283;
const TAG_PLANAR_CONFIG: u16 = 284;
const TAG_RESOLUTION_UNIT: u16 = 296;
const TAG_COLOR_MAP: u16 = 320;
const TAG_TILE_WIDTH: u16 = 322;
const TAG_TILE_LENGTH: u16 = 323;
const TAG_TILE_OFFSETS: u16 = 324;
const TAG_TILE_BYTE_COUNTS: u16 = 325;
const TAG_EXTRA_SAMPLES: u16 = 338;
const TAG_SAMPLE_FORMAT: u16 = 339;

// Compression types
const COMPRESSION_NONE: u16 = 1;
const COMPRESSION_CCITT_RLE: u16 = 2;
const COMPRESSION_CCITT_FAX3: u16 = 3;
const COMPRESSION_CCITT_FAX4: u16 = 4;
const COMPRESSION_LZW: u16 = 5;
const COMPRESSION_JPEG_OLD: u16 = 6;
const COMPRESSION_JPEG: u16 = 7;
const COMPRESSION_DEFLATE: u16 = 8;
const COMPRESSION_PACKBITS: u16 = 32773;

// Photometric interpretation
const PHOTOMETRIC_WHITE_IS_ZERO: u16 = 0;
const PHOTOMETRIC_BLACK_IS_ZERO: u16 = 1;
const PHOTOMETRIC_RGB: u16 = 2;
const PHOTOMETRIC_PALETTE: u16 = 3;
const PHOTOMETRIC_MASK: u16 = 4;
const PHOTOMETRIC_SEPARATED: u16 = 5; // CMYK
const PHOTOMETRIC_YCBCR: u16 = 6;

// Data types
const TYPE_BYTE: u16 = 1;
const TYPE_ASCII: u16 = 2;
const TYPE_SHORT: u16 = 3;
const TYPE_LONG: u16 = 4;
const TYPE_RATIONAL: u16 = 5;
const TYPE_SBYTE: u16 = 6;
const TYPE_UNDEFINED: u16 = 7;
const TYPE_SSHORT: u16 = 8;
const TYPE_SLONG: u16 = 9;
const TYPE_SRATIONAL: u16 = 10;
const TYPE_FLOAT: u16 = 11;
const TYPE_DOUBLE: u16 = 12;

// ============================================================================
// IFD Entry
// ============================================================================

const IFDEntry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_offset: u32,
};

// ============================================================================
// TIFF Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8) return error.TruncatedData;

    // Check byte order
    const byte_order = std.mem.readInt(u16, data[0..2], .little);
    const is_little_endian = byte_order == LITTLE_ENDIAN_MARKER;

    if (byte_order != LITTLE_ENDIAN_MARKER and byte_order != BIG_ENDIAN_MARKER) {
        return error.InvalidFormat;
    }

    // Check magic number
    const magic = readU16(data[2..4], is_little_endian);
    if (magic != TIFF_MAGIC) {
        return error.InvalidFormat;
    }

    // Get IFD offset
    const ifd_offset = readU32(data[4..8], is_little_endian);
    if (ifd_offset >= data.len) {
        return error.InvalidFormat;
    }

    // Parse IFD
    var width: u32 = 0;
    var height: u32 = 0;
    var bits_per_sample: u16 = 8;
    var samples_per_pixel: u16 = 1;
    var compression: u16 = COMPRESSION_NONE;
    var photometric: u16 = PHOTOMETRIC_BLACK_IS_ZERO;
    var rows_per_strip: u32 = 0xFFFFFFFF;
    var strip_offsets: ?[]u32 = null;
    var strip_byte_counts: ?[]u32 = null;
    var color_map: ?[]u16 = null;

    defer if (strip_offsets) |so| allocator.free(so);
    defer if (strip_byte_counts) |sbc| allocator.free(sbc);
    defer if (color_map) |cm| allocator.free(cm);

    const num_entries = readU16(data[ifd_offset..][0..2], is_little_endian);
    var entry_offset = ifd_offset + 2;

    var i: u16 = 0;
    while (i < num_entries) : (i += 1) {
        if (entry_offset + 12 > data.len) break;

        const entry = parseIFDEntry(data[entry_offset..][0..12], is_little_endian);
        entry_offset += 12;

        switch (entry.tag) {
            TAG_IMAGE_WIDTH => {
                width = getEntryValue(data, entry, is_little_endian);
            },
            TAG_IMAGE_LENGTH => {
                height = getEntryValue(data, entry, is_little_endian);
            },
            TAG_BITS_PER_SAMPLE => {
                bits_per_sample = @truncate(getEntryValue(data, entry, is_little_endian));
            },
            TAG_COMPRESSION => {
                compression = @truncate(getEntryValue(data, entry, is_little_endian));
            },
            TAG_PHOTOMETRIC => {
                photometric = @truncate(getEntryValue(data, entry, is_little_endian));
            },
            TAG_SAMPLES_PER_PIXEL => {
                samples_per_pixel = @truncate(getEntryValue(data, entry, is_little_endian));
            },
            TAG_ROWS_PER_STRIP => {
                rows_per_strip = getEntryValue(data, entry, is_little_endian);
            },
            TAG_STRIP_OFFSETS => {
                strip_offsets = try getEntryValues(allocator, data, entry, is_little_endian);
            },
            TAG_STRIP_BYTE_COUNTS => {
                strip_byte_counts = try getEntryValues(allocator, data, entry, is_little_endian);
            },
            TAG_COLOR_MAP => {
                color_map = try getColorMap(allocator, data, entry, is_little_endian);
            },
            else => {},
        }
    }

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Determine pixel format
    const format: PixelFormat = switch (photometric) {
        PHOTOMETRIC_WHITE_IS_ZERO, PHOTOMETRIC_BLACK_IS_ZERO => .grayscale8,
        PHOTOMETRIC_RGB => if (samples_per_pixel >= 4) .rgba8 else .rgb8,
        PHOTOMETRIC_PALETTE => .indexed8,
        else => .rgb8,
    };

    var img = try Image.init(allocator, width, height, format);
    errdefer img.deinit();

    // Set palette for indexed images
    if (photometric == PHOTOMETRIC_PALETTE and color_map != null) {
        const cm = color_map.?;
        const num_colors = cm.len / 3;
        img.palette = try allocator.alloc(Color, num_colors);
        var c: usize = 0;
        while (c < num_colors) : (c += 1) {
            img.palette.?[c] = Color{
                .r = @truncate(cm[c] >> 8),
                .g = @truncate(cm[c + num_colors] >> 8),
                .b = @truncate(cm[c + 2 * num_colors] >> 8),
                .a = 255,
            };
        }
    }

    // Decode strips
    if (strip_offsets) |offsets| {
        const byte_counts = strip_byte_counts orelse return error.InvalidFormat;
        try decodeStrips(&img, data, offsets, byte_counts, rows_per_strip, compression, photometric, bits_per_sample, samples_per_pixel, is_little_endian, allocator);
    } else {
        return error.InvalidFormat;
    }

    return img;
}

fn parseIFDEntry(data: *const [12]u8, is_little_endian: bool) IFDEntry {
    return IFDEntry{
        .tag = readU16(data[0..2], is_little_endian),
        .field_type = readU16(data[2..4], is_little_endian),
        .count = readU32(data[4..8], is_little_endian),
        .value_offset = readU32(data[8..12], is_little_endian),
    };
}

fn getEntryValue(data: []const u8, entry: IFDEntry, is_little_endian: bool) u32 {
    const type_size = getTypeSize(entry.field_type);
    if (type_size * entry.count <= 4) {
        // Value fits in offset field
        if (entry.field_type == TYPE_SHORT) {
            return readU16(@as(*const [2]u8, @ptrCast(&@as([4]u8, @bitCast(entry.value_offset)))), is_little_endian);
        }
        return entry.value_offset;
    } else {
        // Value is at offset
        if (entry.value_offset >= data.len) return 0;
        if (entry.field_type == TYPE_SHORT) {
            return readU16(data[entry.value_offset..][0..2], is_little_endian);
        }
        return readU32(data[entry.value_offset..][0..4], is_little_endian);
    }
}

fn getEntryValues(allocator: std.mem.Allocator, data: []const u8, entry: IFDEntry, is_little_endian: bool) ![]u32 {
    const values = try allocator.alloc(u32, entry.count);
    errdefer allocator.free(values);

    const type_size = getTypeSize(entry.field_type);

    if (type_size * entry.count <= 4) {
        // Values fit in offset field
        const bytes: [4]u8 = @bitCast(entry.value_offset);
        var idx: u32 = 0;
        while (idx < entry.count) : (idx += 1) {
            if (entry.field_type == TYPE_SHORT) {
                const offset = idx * 2;
                values[idx] = readU16(bytes[offset..][0..2], is_little_endian);
            } else {
                values[idx] = bytes[idx];
            }
        }
    } else {
        // Values at offset
        var offset = entry.value_offset;
        var idx: u32 = 0;
        while (idx < entry.count) : (idx += 1) {
            if (offset + type_size > data.len) break;
            if (entry.field_type == TYPE_SHORT) {
                values[idx] = readU16(data[offset..][0..2], is_little_endian);
                offset += 2;
            } else {
                values[idx] = readU32(data[offset..][0..4], is_little_endian);
                offset += 4;
            }
        }
    }

    return values;
}

fn getColorMap(allocator: std.mem.Allocator, data: []const u8, entry: IFDEntry, is_little_endian: bool) ![]u16 {
    const values = try allocator.alloc(u16, entry.count);
    errdefer allocator.free(values);

    var offset = entry.value_offset;
    var idx: u32 = 0;
    while (idx < entry.count) : (idx += 1) {
        if (offset + 2 > data.len) break;
        values[idx] = readU16(data[offset..][0..2], is_little_endian);
        offset += 2;
    }

    return values;
}

fn getTypeSize(field_type: u16) u32 {
    return switch (field_type) {
        TYPE_BYTE, TYPE_ASCII, TYPE_SBYTE, TYPE_UNDEFINED => 1,
        TYPE_SHORT, TYPE_SSHORT => 2,
        TYPE_LONG, TYPE_SLONG, TYPE_FLOAT => 4,
        TYPE_RATIONAL, TYPE_SRATIONAL, TYPE_DOUBLE => 8,
        else => 1,
    };
}

fn decodeStrips(
    img: *Image,
    data: []const u8,
    strip_offsets: []u32,
    strip_byte_counts: []u32,
    rows_per_strip: u32,
    compression: u16,
    photometric: u16,
    bits_per_sample: u16,
    samples_per_pixel: u16,
    is_little_endian: bool,
    allocator: std.mem.Allocator,
) !void {
    _ = is_little_endian;

    var y: u32 = 0;

    for (strip_offsets, 0..) |offset, strip_idx| {
        if (offset >= data.len) continue;

        const byte_count = if (strip_idx < strip_byte_counts.len) strip_byte_counts[strip_idx] else 0;
        if (byte_count == 0) continue;

        const strip_data = data[offset..][0..@min(byte_count, data.len - offset)];

        // Decompress if needed
        const decompressed = switch (compression) {
            COMPRESSION_NONE => strip_data,
            COMPRESSION_PACKBITS => blk: {
                const dec = try decompressPackBits(allocator, strip_data);
                break :blk dec;
            },
            COMPRESSION_LZW => blk: {
                const dec = try decompressLZW(allocator, strip_data);
                break :blk dec;
            },
            else => strip_data,
        };
        defer if (compression != COMPRESSION_NONE) allocator.free(decompressed);

        // Decode pixels
        const strip_rows = @min(rows_per_strip, img.height - y);
        try decodePixels(img, decompressed, y, strip_rows, photometric, bits_per_sample, samples_per_pixel);

        y += strip_rows;
        if (y >= img.height) break;
    }
}

fn decodePixels(
    img: *Image,
    strip_data: []const u8,
    start_y: u32,
    num_rows: u32,
    photometric: u16,
    bits_per_sample: u16,
    samples_per_pixel: u16,
) !void {
    const bytes_per_sample = (bits_per_sample + 7) / 8;
    const bytes_per_pixel = bytes_per_sample * samples_per_pixel;
    const row_bytes = img.width * bytes_per_pixel;

    var y: u32 = 0;
    while (y < num_rows) : (y += 1) {
        const row_offset = y * row_bytes;
        if (row_offset >= strip_data.len) break;

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const pixel_offset = row_offset + x * bytes_per_pixel;
            if (pixel_offset >= strip_data.len) break;

            const color = switch (photometric) {
                PHOTOMETRIC_WHITE_IS_ZERO => blk: {
                    const val = 255 - strip_data[pixel_offset];
                    break :blk Color{ .r = val, .g = val, .b = val, .a = 255 };
                },
                PHOTOMETRIC_BLACK_IS_ZERO => blk: {
                    const val = strip_data[pixel_offset];
                    break :blk Color{ .r = val, .g = val, .b = val, .a = 255 };
                },
                PHOTOMETRIC_RGB => blk: {
                    if (pixel_offset + 2 >= strip_data.len) break :blk Color.BLACK;
                    const a: u8 = if (samples_per_pixel >= 4 and pixel_offset + 3 < strip_data.len)
                        strip_data[pixel_offset + 3]
                    else
                        255;
                    break :blk Color{
                        .r = strip_data[pixel_offset],
                        .g = strip_data[pixel_offset + 1],
                        .b = strip_data[pixel_offset + 2],
                        .a = a,
                    };
                },
                PHOTOMETRIC_PALETTE => blk: {
                    const idx = strip_data[pixel_offset];
                    if (img.palette) |pal| {
                        if (idx < pal.len) {
                            break :blk pal[idx];
                        }
                    }
                    break :blk Color.BLACK;
                },
                else => Color.BLACK,
            };

            img.setPixel(x, start_y + y, color);
        }
    }
}

fn decompressPackBits(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var i: usize = 0;
    while (i < data.len) {
        const n: i8 = @bitCast(data[i]);
        i += 1;

        if (n >= 0) {
            // Copy next n+1 bytes literally
            const count: usize = @intCast(@as(i16, n) + 1);
            if (i + count > data.len) break;
            try output.appendSlice(data[i..][0..count]);
            i += count;
        } else if (n > -128) {
            // Repeat next byte 1-n times
            const count: usize = @intCast(1 - @as(i16, n));
            if (i >= data.len) break;
            const byte = data[i];
            i += 1;
            try output.appendNTimes(byte, count);
        }
        // n == -128: no-op
    }

    return output.toOwnedSlice();
}

fn decompressLZW(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const CLEAR_CODE: u16 = 256;
    const EOI_CODE: u16 = 257;

    var bit_reader = BitReader{ .data = data, .pos = 0, .bit_pos = 0 };
    var code_size: u4 = 9;
    var next_code: u16 = 258;

    // String table
    var table: [4096][]u8 = undefined;
    var table_alloc: [4096]bool = .{false} ** 4096;
    defer {
        for (&table, 0..) |*entry, idx| {
            if (table_alloc[idx]) {
                allocator.free(entry.*);
            }
        }
    }

    // Initialize table with single-byte entries
    var idx: u16 = 0;
    while (idx < 256) : (idx += 1) {
        table[idx] = try allocator.alloc(u8, 1);
        table[idx][0] = @truncate(idx);
        table_alloc[idx] = true;
    }

    var old_code: ?u16 = null;

    while (true) {
        const code = bit_reader.readBits(code_size) catch break;

        if (code == EOI_CODE) break;

        if (code == CLEAR_CODE) {
            // Reset table
            idx = 258;
            while (idx < next_code) : (idx += 1) {
                if (table_alloc[idx]) {
                    allocator.free(table[idx]);
                    table_alloc[idx] = false;
                }
            }
            next_code = 258;
            code_size = 9;
            old_code = null;
            continue;
        }

        var string: []const u8 = undefined;

        if (code < next_code) {
            string = table[code];
        } else if (code == next_code and old_code != null) {
            // Special case: code not in table yet
            const old_string = table[old_code.?];
            const new_string = try allocator.alloc(u8, old_string.len + 1);
            @memcpy(new_string[0..old_string.len], old_string);
            new_string[old_string.len] = old_string[0];
            table[next_code] = new_string;
            table_alloc[next_code] = true;
            string = new_string;
            next_code += 1;
        } else {
            break; // Invalid code
        }

        try output.appendSlice(string);

        if (old_code != null and next_code < 4096) {
            const old_string = table[old_code.?];
            const new_entry = try allocator.alloc(u8, old_string.len + 1);
            @memcpy(new_entry[0..old_string.len], old_string);
            new_entry[old_string.len] = string[0];
            table[next_code] = new_entry;
            table_alloc[next_code] = true;
            next_code += 1;

            if (next_code == (@as(u16, 1) << code_size) and code_size < 12) {
                code_size += 1;
            }
        }

        old_code = code;
    }

    return output.toOwnedSlice();
}

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_pos: u3,

    fn readBits(self: *BitReader, count: u4) !u16 {
        var result: u16 = 0;
        var bits_read: u4 = 0;

        while (bits_read < count) {
            if (self.pos >= self.data.len) return error.TruncatedData;

            const bits_available: u4 = @intCast(8 - @as(u4, self.bit_pos));
            const bits_to_read = @min(count - bits_read, bits_available);

            const shift = 8 - self.bit_pos - bits_to_read;
            const mask: u8 = @as(u8, 0xFF) >> @as(u3, @intCast(8 - bits_to_read));
            const bits: u16 = (self.data[self.pos] >> @as(u3, @intCast(shift))) & mask;

            result = (result << @intCast(bits_to_read)) | bits;
            bits_read += bits_to_read;

            self.bit_pos += @as(u3, @intCast(bits_to_read));
            if (self.bit_pos == 0) {
                self.pos += 1;
            }
        }

        return result;
    }
};

fn readU16(data: *const [2]u8, is_little_endian: bool) u16 {
    return if (is_little_endian)
        std.mem.readInt(u16, data, .little)
    else
        std.mem.readInt(u16, data, .big);
}

fn readU32(data: *const [4]u8, is_little_endian: bool) u32 {
    return if (is_little_endian)
        std.mem.readInt(u32, data, .little)
    else
        std.mem.readInt(u32, data, .big);
}

// ============================================================================
// TIFF Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write header (little endian)
    try output.appendSlice(&[_]u8{ 'I', 'I' }); // Little endian
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, TIFF_MAGIC)));

    // IFD offset (will be at offset 8)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 8)));

    // Build IFD entries
    const samples_per_pixel: u16 = switch (img.format) {
        .grayscale8, .grayscale16, .indexed8 => 1,
        .rgb8, .rgb16 => 3,
        .rgba8, .rgba16 => 4,
    };

    const photometric: u16 = switch (img.format) {
        .grayscale8, .grayscale16 => PHOTOMETRIC_BLACK_IS_ZERO,
        .indexed8 => PHOTOMETRIC_PALETTE,
        else => PHOTOMETRIC_RGB,
    };

    // Calculate strip data size
    const bytes_per_pixel = img.format.bytesPerPixel();
    const strip_size = @as(u32, @intCast(img.width)) * img.height * bytes_per_pixel;

    // Number of IFD entries
    const num_entries: u16 = 11;
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, num_entries)));

    // Calculate offsets
    const ifd_size = 2 + num_entries * 12 + 4; // count + entries + next IFD offset
    const strip_offset: u32 = 8 + ifd_size;

    // Write IFD entries
    try writeIFDEntry(&output, TAG_IMAGE_WIDTH, TYPE_LONG, 1, img.width);
    try writeIFDEntry(&output, TAG_IMAGE_LENGTH, TYPE_LONG, 1, img.height);
    try writeIFDEntry(&output, TAG_BITS_PER_SAMPLE, TYPE_SHORT, 1, 8);
    try writeIFDEntry(&output, TAG_COMPRESSION, TYPE_SHORT, 1, COMPRESSION_NONE);
    try writeIFDEntry(&output, TAG_PHOTOMETRIC, TYPE_SHORT, 1, photometric);
    try writeIFDEntry(&output, TAG_STRIP_OFFSETS, TYPE_LONG, 1, strip_offset);
    try writeIFDEntry(&output, TAG_SAMPLES_PER_PIXEL, TYPE_SHORT, 1, samples_per_pixel);
    try writeIFDEntry(&output, TAG_ROWS_PER_STRIP, TYPE_LONG, 1, img.height);
    try writeIFDEntry(&output, TAG_STRIP_BYTE_COUNTS, TYPE_LONG, 1, strip_size);
    try writeIFDEntry(&output, TAG_X_RESOLUTION, TYPE_RATIONAL, 1, strip_offset + strip_size);
    try writeIFDEntry(&output, TAG_Y_RESOLUTION, TYPE_RATIONAL, 1, strip_offset + strip_size + 8);

    // Next IFD offset (0 = no more IFDs)
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 });

    // Write strip data
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;
            switch (img.format) {
                .grayscale8 => {
                    try output.append(color.toGrayscale());
                },
                .rgb8 => {
                    try output.appendSlice(&[_]u8{ color.r, color.g, color.b });
                },
                .rgba8 => {
                    try output.appendSlice(&[_]u8{ color.r, color.g, color.b, color.a });
                },
                else => {
                    try output.appendSlice(&[_]u8{ color.r, color.g, color.b });
                },
            }
        }
    }

    // Write resolution values (72 DPI)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 72))); // numerator
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 1))); // denominator
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 72))); // numerator
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 1))); // denominator

    return output.toOwnedSlice();
}

fn writeIFDEntry(output: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, tag)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, field_type)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, count)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
}

// ============================================================================
// Tests
// ============================================================================

test "TIFF header detection" {
    const le_header = [_]u8{ 'I', 'I', 42, 0 };
    try std.testing.expectEqual(@as(u16, LITTLE_ENDIAN_MARKER), std.mem.readInt(u16, le_header[0..2], .little));
    try std.testing.expectEqual(@as(u16, TIFF_MAGIC), std.mem.readInt(u16, le_header[2..4], .little));

    const be_header = [_]u8{ 'M', 'M', 0, 42 };
    try std.testing.expectEqual(@as(u16, BIG_ENDIAN_MARKER), std.mem.readInt(u16, be_header[0..2], .big));
    try std.testing.expectEqual(@as(u16, TIFF_MAGIC), std.mem.readInt(u16, be_header[2..4], .big));
}

test "PackBits decompression" {
    const allocator = std.testing.allocator;

    // Test literal run: 0x01 means copy next 2 bytes
    const packed1 = [_]u8{ 0x01, 0xAA, 0xBB };
    const unpacked1 = try decompressPackBits(allocator, &packed1);
    defer allocator.free(unpacked1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, unpacked1);

    // Test repeat run: 0xFE (-2) means repeat next byte 3 times
    const packed2 = [_]u8{ 0xFE, 0xCC };
    const unpacked2 = try decompressPackBits(allocator, &packed2);
    defer allocator.free(unpacked2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xCC, 0xCC, 0xCC }, unpacked2);
}

test "IFD entry parsing" {
    const entry_data = [_]u8{
        0x00, 0x01, // tag = 256 (IMAGE_WIDTH)
        0x03, 0x00, // type = SHORT
        0x01, 0x00, 0x00, 0x00, // count = 1
        0x80, 0x02, 0x00, 0x00, // value = 640
    };

    const entry = parseIFDEntry(&entry_data, true);
    try std.testing.expectEqual(@as(u16, TAG_IMAGE_WIDTH), entry.tag);
    try std.testing.expectEqual(@as(u16, TYPE_SHORT), entry.field_type);
    try std.testing.expectEqual(@as(u32, 1), entry.count);
}
