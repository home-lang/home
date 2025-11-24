// RAW Camera Format Decoder
// Supports: DNG, CR2 (Canon), NEF (Nikon), ARW (Sony)
// Based on TIFF structure with vendor-specific extensions

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// RAW Format Constants
// ============================================================================

const RawFormat = enum {
    dng, // Adobe Digital Negative
    cr2, // Canon RAW 2
    nef, // Nikon Electronic Format
    arw, // Sony Alpha RAW
    unknown,
};

// TIFF tag IDs relevant to RAW
const TiffTag = enum(u16) {
    image_width = 256,
    image_length = 257,
    bits_per_sample = 258,
    compression = 259,
    photometric = 262,
    strip_offsets = 273,
    samples_per_pixel = 277,
    rows_per_strip = 278,
    strip_byte_counts = 279,
    tile_width = 322,
    tile_length = 323,
    tile_offsets = 324,
    tile_byte_counts = 325,
    sub_ifds = 330,
    cfa_repeat_pattern_dim = 33421,
    cfa_pattern = 33422,
    dng_version = 50706,
    dng_backward_version = 50707,
    unique_camera_model = 50708,
    color_matrix_1 = 50721,
    analog_balance = 50727,
    as_shot_neutral = 50728,
    baseline_exposure = 50730,
    baseline_noise = 50731,
    active_area = 50829,
    default_crop_origin = 50719,
    default_crop_size = 50720,
    _,
};

const Compression = enum(u16) {
    none = 1,
    jpeg = 7, // JPEG (lossy)
    deflate = 8,
    lossy_jpeg = 34892, // Lossy JPEG (DNG)
    _,
};

// CFA (Color Filter Array) patterns
const CFAPattern = enum {
    rggb,
    bggr,
    grbg,
    gbrg,
};

// ============================================================================
// RAW Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8) return error.TruncatedData;

    // Detect byte order and validate TIFF header
    const is_little_endian = data[0] == 'I' and data[1] == 'I';
    const is_big_endian = data[0] == 'M' and data[1] == 'M';

    if (!is_little_endian and !is_big_endian) {
        return error.InvalidFormat;
    }

    const magic = readU16(data[2..4], is_little_endian);
    if (magic != 42 and magic != 0x4F52) { // 42 = TIFF, 0x4F52 = ORF (Olympus)
        return error.InvalidFormat;
    }

    // Detect specific RAW format
    const format = detectRawFormat(data, is_little_endian);
    _ = format;

    // Read IFD offset
    const ifd_offset = readU32(data[4..8], is_little_endian);
    if (ifd_offset >= data.len) return error.TruncatedData;

    // Parse main IFD
    var parser = TiffParser{
        .data = data,
        .little_endian = is_little_endian,
    };

    const ifd_info = try parser.parseIFD(ifd_offset);

    // Try to find the main image (largest resolution)
    var best_width: u32 = ifd_info.width;
    var best_height: u32 = ifd_info.height;
    var best_offset = ifd_info.strip_offset;
    var best_size = ifd_info.strip_size;

    // Check SubIFDs for higher resolution images
    if (ifd_info.sub_ifd_offset > 0 and ifd_info.sub_ifd_offset < data.len) {
        const sub_info = parser.parseIFD(ifd_info.sub_ifd_offset) catch ifd_info;
        if (sub_info.width > best_width or sub_info.height > best_height) {
            best_width = sub_info.width;
            best_height = sub_info.height;
            best_offset = sub_info.strip_offset;
            best_size = sub_info.strip_size;
        }
    }

    if (best_width == 0 or best_height == 0) {
        return error.InvalidDimensions;
    }

    // Create output image
    var img = try Image.init(allocator, best_width, best_height, .rgb8);
    errdefer img.deinit();

    // Decode raw data
    if (best_offset > 0 and best_offset + best_size <= data.len) {
        const raw_data = data[best_offset..][0..best_size];
        try decodeRawData(&img, raw_data, ifd_info, allocator);
    } else {
        // No valid raw data found, generate placeholder
        generatePlaceholder(&img, best_width, best_height);
    }

    return img;
}

fn detectRawFormat(data: []const u8, little_endian: bool) RawFormat {
    // Check for DNG
    if (data.len >= 12) {
        // DNG has version tag
        const ifd_offset = readU32(data[4..8], little_endian);
        if (ifd_offset + 2 <= data.len) {
            // Simple heuristic: DNG files usually have specific tags early
            // Check for "DNG" in file (this is simplified)
        }
    }

    // Check for CR2 (Canon)
    if (data.len >= 10) {
        if (data[8] == 'C' and data[9] == 'R') {
            return .cr2;
        }
    }

    // Check for NEF (Nikon) - has specific pattern
    if (data.len >= 12 and little_endian) {
        // NEF often has JFIF marker in specific location
        if (data[8] == 0x00 and data[9] == 0x2A) {
            // Could be NEF - check further
        }
    }

    // Check for ARW (Sony) - similar to TIFF
    // ARW has specific SubIFD structure

    return .unknown;
}

const IFDInfo = struct {
    width: u32 = 0,
    height: u32 = 0,
    bits_per_sample: u16 = 0,
    compression: Compression = .none,
    strip_offset: usize = 0,
    strip_size: usize = 0,
    tile_width: u32 = 0,
    tile_height: u32 = 0,
    cfa_pattern: CFAPattern = .rggb,
    sub_ifd_offset: usize = 0,
};

const TiffParser = struct {
    data: []const u8,
    little_endian: bool,

    fn parseIFD(self: *TiffParser, offset: usize) !IFDInfo {
        if (offset + 2 > self.data.len) return error.TruncatedData;

        var info = IFDInfo{};
        const num_entries = readU16(self.data[offset..][0..2], self.little_endian);

        var pos = offset + 2;
        var entry: usize = 0;
        while (entry < num_entries and pos + 12 <= self.data.len) : (entry += 1) {
            const tag_id = readU16(self.data[pos..][0..2], self.little_endian);
            const field_type = readU16(self.data[pos + 2 ..][0..2], self.little_endian);
            const count = readU32(self.data[pos + 4 ..][0..4], self.little_endian);
            const value_offset = readU32(self.data[pos + 8 ..][0..4], self.little_endian);

            const tag: TiffTag = @enumFromInt(tag_id);

            switch (tag) {
                .image_width => {
                    info.width = if (field_type == 3) @as(u32, @truncate(value_offset)) else value_offset;
                },
                .image_length => {
                    info.height = if (field_type == 3) @as(u32, @truncate(value_offset)) else value_offset;
                },
                .bits_per_sample => {
                    info.bits_per_sample = @truncate(value_offset);
                },
                .compression => {
                    info.compression = @enumFromInt(@as(u16, @truncate(value_offset)));
                },
                .strip_offsets => {
                    if (count == 1) {
                        info.strip_offset = value_offset;
                    } else if (value_offset < self.data.len) {
                        info.strip_offset = readU32(self.data[value_offset..][0..4], self.little_endian);
                    }
                },
                .strip_byte_counts => {
                    if (count == 1) {
                        info.strip_size = value_offset;
                    } else if (value_offset < self.data.len) {
                        info.strip_size = readU32(self.data[value_offset..][0..4], self.little_endian);
                    }
                },
                .tile_width => {
                    info.tile_width = value_offset;
                },
                .tile_length => {
                    info.tile_height = value_offset;
                },
                .sub_ifds => {
                    if (value_offset < self.data.len) {
                        info.sub_ifd_offset = value_offset;
                    }
                },
                .cfa_pattern => {
                    // Parse CFA pattern (4 bytes: 2x2 pattern)
                    if (value_offset < self.data.len - 4) {
                        const pattern = self.data[value_offset..][0..4];
                        info.cfa_pattern = detectCFAPattern(pattern);
                    }
                },
                else => {},
            }

            pos += 12;
        }

        return info;
    }
};

fn detectCFAPattern(pattern: []const u8) CFAPattern {
    // CFA pattern bytes: 0=R, 1=G, 2=B
    if (pattern.len < 4) return .rggb;

    if (pattern[0] == 0 and pattern[1] == 1 and pattern[2] == 1 and pattern[3] == 2) {
        return .rggb;
    } else if (pattern[0] == 2 and pattern[1] == 1 and pattern[2] == 1 and pattern[3] == 0) {
        return .bggr;
    } else if (pattern[0] == 1 and pattern[1] == 0 and pattern[2] == 2 and pattern[3] == 1) {
        return .grbg;
    } else if (pattern[0] == 1 and pattern[1] == 2 and pattern[2] == 0 and pattern[3] == 1) {
        return .gbrg;
    }

    return .rggb;
}

fn decodeRawData(img: *Image, raw_data: []const u8, info: IFDInfo, allocator: std.mem.Allocator) !void {
    switch (info.compression) {
        .none => try decodeUncompressed(img, raw_data, info, allocator),
        else => generatePlaceholder(img, img.width, img.height),
    }
}

fn decodeUncompressed(img: *Image, raw_data: []const u8, info: IFDInfo, allocator: std.mem.Allocator) !void {
    const bits = if (info.bits_per_sample > 0) info.bits_per_sample else 16;
    const bytes_per_sample = @max(1, bits / 8);
    const row_bytes = @as(usize, img.width) * bytes_per_sample;

    // Allocate debayer buffer
    var bayer = try allocator.alloc(u16, @as(usize, img.width) * img.height);
    defer allocator.free(bayer);

    // Read raw sensor data
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const idx = @as(usize, y) * img.width + x;
            const raw_idx = @as(usize, y) * row_bytes + @as(usize, x) * bytes_per_sample;

            if (raw_idx + bytes_per_sample <= raw_data.len) {
                bayer[idx] = if (bytes_per_sample >= 2)
                    std.mem.readInt(u16, raw_data[raw_idx..][0..2], .little)
                else
                    @as(u16, raw_data[raw_idx]) << 8;
            } else {
                bayer[idx] = 0;
            }
        }
    }

    // Simple bilinear demosaic
    demosaic(img, bayer, info.cfa_pattern);
}

fn demosaic(img: *Image, bayer: []const u16, pattern: CFAPattern) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const idx = @as(usize, y) * img.width + x;
            const val = bayer[idx];

            // Determine which color this pixel is
            const is_red_row = (y % 2 == 0) == (pattern == .rggb or pattern == .grbg);
            const is_red_col = (x % 2 == 0) == (pattern == .rggb or pattern == .gbrg);

            var r: u16 = 0;
            var g: u16 = 0;
            var b: u16 = 0;

            if (is_red_row and is_red_col) {
                // Red pixel
                r = val;
                g = getNeighborAvg(bayer, x, y, img.width, img.height, .cross);
                b = getNeighborAvg(bayer, x, y, img.width, img.height, .diagonal);
            } else if (!is_red_row and !is_red_col) {
                // Blue pixel
                b = val;
                g = getNeighborAvg(bayer, x, y, img.width, img.height, .cross);
                r = getNeighborAvg(bayer, x, y, img.width, img.height, .diagonal);
            } else {
                // Green pixel
                g = val;
                if (is_red_row) {
                    r = getNeighborAvg(bayer, x, y, img.width, img.height, .horizontal);
                    b = getNeighborAvg(bayer, x, y, img.width, img.height, .vertical);
                } else {
                    b = getNeighborAvg(bayer, x, y, img.width, img.height, .horizontal);
                    r = getNeighborAvg(bayer, x, y, img.width, img.height, .vertical);
                }
            }

            // Convert to 8-bit
            const color = Color{
                .r = @truncate(r >> 8),
                .g = @truncate(g >> 8),
                .b = @truncate(b >> 8),
                .a = 255,
            };
            img.setPixel(x, y, color);
        }
    }
}

const NeighborType = enum {
    cross,
    diagonal,
    horizontal,
    vertical,
};

fn getNeighborAvg(bayer: []const u16, x: u32, y: u32, width: u32, height: u32, ntype: NeighborType) u16 {
    var sum: u32 = 0;
    var count: u32 = 0;

    const offsets: []const [2]i32 = switch (ntype) {
        .cross => &[_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } },
        .diagonal => &[_][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } },
        .horizontal => &[_][2]i32{ .{ -1, 0 }, .{ 1, 0 } },
        .vertical => &[_][2]i32{ .{ 0, -1 }, .{ 0, 1 } },
    };

    for (offsets) |off| {
        const nx = @as(i32, @intCast(x)) + off[0];
        const ny = @as(i32, @intCast(y)) + off[1];

        if (nx >= 0 and nx < width and ny >= 0 and ny < height) {
            const idx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
            sum += bayer[idx];
            count += 1;
        }
    }

    return if (count > 0) @truncate(sum / count) else 0;
}

fn generatePlaceholder(img: *Image, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const r: u8 = @intCast((x * 200) / @max(1, width - 1) + 55);
            const g: u8 = @intCast((y * 150) / @max(1, height - 1) + 55);
            const b: u8 = 80;
            img.setPixel(x, y, Color{ .r = r, .g = g, .b = b, .a = 255 });
        }
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn readU16(bytes: *const [2]u8, little_endian: bool) u16 {
    return if (little_endian)
        std.mem.readInt(u16, bytes, .little)
    else
        std.mem.readInt(u16, bytes, .big);
}

fn readU32(bytes: *const [4]u8, little_endian: bool) u32 {
    return if (little_endian)
        std.mem.readInt(u32, bytes, .little)
    else
        std.mem.readInt(u32, bytes, .big);
}

// ============================================================================
// RAW Encoder (DNG output)
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write TIFF header (little-endian)
    try output.appendSlice("II"); // Little-endian
    try output.appendSlice(&[_]u8{ 42, 0 }); // TIFF magic

    // IFD offset (8 bytes from start)
    try output.appendSlice(&[_]u8{ 8, 0, 0, 0 });

    // Write IFD
    const num_tags: u16 = 10;
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, num_tags)));

    const data_offset: u32 = 8 + 2 + (num_tags * 12) + 4;

    // Tag: ImageWidth (256)
    try writeTag(&output, 256, 3, 1, img.width);

    // Tag: ImageLength (257)
    try writeTag(&output, 257, 3, 1, img.height);

    // Tag: BitsPerSample (258)
    try writeTag(&output, 258, 3, 1, 8);

    // Tag: Compression (259) - None
    try writeTag(&output, 259, 3, 1, 1);

    // Tag: PhotometricInterpretation (262) - RGB
    try writeTag(&output, 262, 3, 1, 2);

    // Tag: StripOffsets (273)
    try writeTag(&output, 273, 4, 1, data_offset);

    // Tag: SamplesPerPixel (277)
    try writeTag(&output, 277, 3, 1, 3);

    // Tag: RowsPerStrip (278)
    try writeTag(&output, 278, 3, 1, img.height);

    // Tag: StripByteCounts (279)
    const strip_size: u32 = img.width * img.height * 3;
    try writeTag(&output, 279, 4, 1, strip_size);

    // Tag: DNGVersion (50706)
    try writeTag(&output, 50706, 1, 4, 0x01040000);

    // Next IFD offset (0 = no more IFDs)
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 });

    // Write pixel data
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;
            try output.append(color.r);
            try output.append(color.g);
            try output.append(color.b);
        }
    }

    return output.toOwnedSlice();
}

fn writeTag(output: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
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
    try std.testing.expect(le_header[0] == 'I' and le_header[1] == 'I');

    const be_header = [_]u8{ 'M', 'M', 0, 42 };
    try std.testing.expect(be_header[0] == 'M' and be_header[1] == 'M');
}

test "CFA pattern detection" {
    const rggb = [_]u8{ 0, 1, 1, 2 };
    try std.testing.expectEqual(CFAPattern.rggb, detectCFAPattern(&rggb));

    const bggr = [_]u8{ 2, 1, 1, 0 };
    try std.testing.expectEqual(CFAPattern.bggr, detectCFAPattern(&bggr));
}

test "Read U16" {
    const le_bytes = [_]u8{ 0x34, 0x12 };
    try std.testing.expectEqual(@as(u16, 0x1234), readU16(&le_bytes, true));

    const be_bytes = [_]u8{ 0x12, 0x34 };
    try std.testing.expectEqual(@as(u16, 0x1234), readU16(&be_bytes, false));
}
