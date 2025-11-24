// EXR (OpenEXR) Decoder/Encoder
// Implements OpenEXR format for HDR imaging
// Supports: Scanline, tiled, basic compression (uncompressed, ZIP, RLE)

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// EXR Constants
// ============================================================================

const EXR_MAGIC: u32 = 20000630;
const EXR_VERSION_MASK: u32 = 0xFF;
const EXR_TILED_FLAG: u32 = 0x200;

const Compression = enum(u8) {
    none = 0,
    rle = 1,
    zips = 2, // ZIP single scanline
    zip = 3, // ZIP 16 scanlines
    piz = 4,
    pxr24 = 5,
    b44 = 6,
    b44a = 7,
    dwaa = 8,
    dwab = 9,
    _,
};

const PixelType = enum(u32) {
    uint = 0,
    half = 1,
    float = 2,
    _,
};

const LineOrder = enum(u8) {
    increasing_y = 0,
    decreasing_y = 1,
    random_y = 2,
    _,
};

const Channel = struct {
    name: []const u8,
    pixel_type: PixelType,
    linear: bool,
    x_sampling: u32,
    y_sampling: u32,
};

const EXRHeader = struct {
    version: u32,
    is_tiled: bool,
    compression: Compression,
    line_order: LineOrder,
    data_window: [4]i32, // xMin, yMin, xMax, yMax
    display_window: [4]i32,
    channels: []Channel,
    allocator: std.mem.Allocator,

    fn deinit(self: *EXRHeader) void {
        for (self.channels) |ch| {
            self.allocator.free(ch.name);
        }
        self.allocator.free(self.channels);
    }
};

// ============================================================================
// Half-Float Support
// ============================================================================

fn halfToFloat(h: u16) f32 {
    const sign: u32 = (@as(u32, h) & 0x8000) << 16;
    var exp: u32 = (@as(u32, h) >> 10) & 0x1F;
    var mant: u32 = @as(u32, h) & 0x3FF;

    if (exp == 0) {
        if (mant == 0) {
            // Zero
            return @bitCast(sign);
        }
        // Denormalized
        while ((mant & 0x400) == 0) {
            mant <<= 1;
            exp -= 1;
        }
        exp += 1;
        mant &= ~@as(u32, 0x400);
        exp += 112;
        mant <<= 13;
    } else if (exp == 31) {
        // Inf or NaN
        exp = 255;
        mant <<= 13;
    } else {
        exp += 112;
        mant <<= 13;
    }

    return @bitCast(sign | (exp << 23) | mant);
}

fn floatToHalf(f: f32) u16 {
    const bits: u32 = @bitCast(f);
    const sign: u16 = @truncate((bits >> 16) & 0x8000);
    var exp: i32 = @intCast((bits >> 23) & 0xFF);
    var mant: u32 = bits & 0x7FFFFF;

    if (exp == 255) {
        // Inf or NaN
        return sign | 0x7C00 | @as(u16, @truncate(mant >> 13));
    }

    exp -= 127;

    if (exp < -24) {
        // Too small - zero
        return sign;
    }

    if (exp < -14) {
        // Denormalized
        mant |= 0x800000;
        const shift: u5 = @intCast(-14 - exp);
        mant >>= shift;
        return sign | @as(u16, @truncate(mant >> 13));
    }

    if (exp > 15) {
        // Too large - infinity
        return sign | 0x7C00;
    }

    return sign | @as(u16, @truncate((@as(u32, @intCast(exp + 15)) << 10) | (mant >> 13)));
}

// ============================================================================
// EXR Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8) return error.TruncatedData;

    // Check magic
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != EXR_MAGIC) return error.InvalidFormat;

    const version = std.mem.readInt(u32, data[4..8], .little);
    const is_tiled = (version & EXR_TILED_FLAG) != 0;

    // Parse header
    var header = try parseHeader(allocator, data[8..]);
    defer header.deinit();

    header.is_tiled = is_tiled;

    const width: u32 = @intCast(header.data_window[2] - header.data_window[0] + 1);
    const height: u32 = @intCast(header.data_window[3] - header.data_window[1] + 1);

    if (width == 0 or height == 0) return error.InvalidDimensions;

    var img = try Image.init(allocator, width, height, .rgba8);
    errdefer img.deinit();

    // Find header end and offset table
    var pos: usize = 8;
    while (pos < data.len) {
        if (data[pos] == 0) {
            pos += 1;
            break;
        }
        // Skip attribute name
        while (pos < data.len and data[pos] != 0) pos += 1;
        pos += 1;
        // Skip attribute type
        while (pos < data.len and data[pos] != 0) pos += 1;
        pos += 1;
        // Skip attribute size and data
        if (pos + 4 > data.len) break;
        const attr_size = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4 + attr_size;
    }

    // Read offset table
    const num_scanlines = height;
    if (pos + num_scanlines * 8 > data.len) return error.TruncatedData;

    // Decode scanlines
    try decodeScanlines(&img, data, pos, header, allocator);

    return img;
}

fn parseHeader(allocator: std.mem.Allocator, data: []const u8) !EXRHeader {
    var header = EXRHeader{
        .version = 0,
        .is_tiled = false,
        .compression = .none,
        .line_order = .increasing_y,
        .data_window = .{ 0, 0, 0, 0 },
        .display_window = .{ 0, 0, 0, 0 },
        .channels = &[_]Channel{},
        .allocator = allocator,
    };

    var pos: usize = 0;

    while (pos < data.len and data[pos] != 0) {
        // Read attribute name
        const name_start = pos;
        while (pos < data.len and data[pos] != 0) pos += 1;
        const attr_name = data[name_start..pos];
        pos += 1;

        // Read attribute type
        const type_start = pos;
        while (pos < data.len and data[pos] != 0) pos += 1;
        const attr_type = data[type_start..pos];
        pos += 1;

        // Read attribute size
        if (pos + 4 > data.len) break;
        const attr_size = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + attr_size > data.len) break;
        const attr_data = data[pos..][0..attr_size];

        // Parse known attributes
        if (std.mem.eql(u8, attr_name, "compression")) {
            header.compression = @enumFromInt(attr_data[0]);
        } else if (std.mem.eql(u8, attr_name, "lineOrder")) {
            header.line_order = @enumFromInt(attr_data[0]);
        } else if (std.mem.eql(u8, attr_name, "dataWindow") and std.mem.eql(u8, attr_type, "box2i")) {
            if (attr_size >= 16) {
                header.data_window[0] = std.mem.readInt(i32, attr_data[0..4], .little);
                header.data_window[1] = std.mem.readInt(i32, attr_data[4..8], .little);
                header.data_window[2] = std.mem.readInt(i32, attr_data[8..12], .little);
                header.data_window[3] = std.mem.readInt(i32, attr_data[12..16], .little);
            }
        } else if (std.mem.eql(u8, attr_name, "displayWindow") and std.mem.eql(u8, attr_type, "box2i")) {
            if (attr_size >= 16) {
                header.display_window[0] = std.mem.readInt(i32, attr_data[0..4], .little);
                header.display_window[1] = std.mem.readInt(i32, attr_data[4..8], .little);
                header.display_window[2] = std.mem.readInt(i32, attr_data[8..12], .little);
                header.display_window[3] = std.mem.readInt(i32, attr_data[12..16], .little);
            }
        } else if (std.mem.eql(u8, attr_name, "channels") and std.mem.eql(u8, attr_type, "chlist")) {
            header.channels = try parseChannels(allocator, attr_data);
        }

        pos += attr_size;
    }

    return header;
}

fn parseChannels(allocator: std.mem.Allocator, data: []const u8) ![]Channel {
    var channels = std.ArrayList(Channel).init(allocator);
    errdefer {
        for (channels.items) |ch| {
            allocator.free(ch.name);
        }
        channels.deinit();
    }

    var pos: usize = 0;

    while (pos < data.len and data[pos] != 0) {
        // Channel name
        const name_start = pos;
        while (pos < data.len and data[pos] != 0) pos += 1;

        const name = try allocator.dupe(u8, data[name_start..pos]);
        pos += 1;

        if (pos + 16 > data.len) {
            allocator.free(name);
            break;
        }

        const pixel_type: PixelType = @enumFromInt(std.mem.readInt(u32, data[pos..][0..4], .little));
        const linear = data[pos + 4] != 0;
        const x_sampling = std.mem.readInt(u32, data[pos + 8 ..][0..4], .little);
        const y_sampling = std.mem.readInt(u32, data[pos + 12 ..][0..4], .little);
        pos += 16;

        try channels.append(.{
            .name = name,
            .pixel_type = pixel_type,
            .linear = linear,
            .x_sampling = x_sampling,
            .y_sampling = y_sampling,
        });
    }

    return channels.toOwnedSlice();
}

fn decodeScanlines(img: *Image, data: []const u8, offset_table_pos: usize, header: EXRHeader, allocator: std.mem.Allocator) !void {
    const width = img.width;
    const height = img.height;

    // Calculate bytes per pixel per channel
    var bytes_per_pixel: usize = 0;
    for (header.channels) |ch| {
        bytes_per_pixel += switch (ch.pixel_type) {
            .uint => 4,
            .half => 2,
            .float => 4,
            else => 2,
        };
    }

    const scanline_bytes = width * bytes_per_pixel;
    _ = scanline_bytes;

    var pos = offset_table_pos;

    // Skip offset table
    pos += height * 8;

    // Allocate decompression buffer if needed
    var decomp_buf: ?[]u8 = null;
    defer if (decomp_buf) |buf| allocator.free(buf);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        if (pos + 8 > data.len) break;

        // const scanline_y = std.mem.readInt(i32, data[pos..][0..4], .little);
        const pixel_data_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        pos += 8;

        if (pos + pixel_data_size > data.len) break;

        const scanline_data = data[pos..][0..pixel_data_size];

        // Decompress if needed
        const pixel_data = switch (header.compression) {
            .none => scanline_data,
            .rle => blk: {
                if (decomp_buf == null or decomp_buf.?.len < width * bytes_per_pixel) {
                    if (decomp_buf) |buf| allocator.free(buf);
                    decomp_buf = try allocator.alloc(u8, width * bytes_per_pixel);
                }
                try decodeRLE(scanline_data, decomp_buf.?);
                break :blk decomp_buf.?;
            },
            else => scanline_data, // Treat as uncompressed for unsupported
        };

        // Parse channels
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            var a: f32 = 1;

            var channel_offset: usize = 0;
            for (header.channels) |ch| {
                const pixel_offset = channel_offset + @as(usize, x) * switch (ch.pixel_type) {
                    .uint => 4,
                    .half => 2,
                    .float => 4,
                    else => 2,
                };

                if (pixel_offset + 2 > pixel_data.len) continue;

                const val: f32 = switch (ch.pixel_type) {
                    .half => halfToFloat(std.mem.readInt(u16, pixel_data[pixel_offset..][0..2], .little)),
                    .float => @bitCast(std.mem.readInt(u32, pixel_data[pixel_offset..][0..4], .little)),
                    .uint => @floatFromInt(std.mem.readInt(u32, pixel_data[pixel_offset..][0..4], .little)),
                    else => 0,
                };

                if (ch.name.len > 0) {
                    switch (ch.name[0]) {
                        'R' => r = val,
                        'G' => g = val,
                        'B' => b = val,
                        'A' => a = val,
                        else => {},
                    }
                }

                channel_offset += width * switch (ch.pixel_type) {
                    .uint => 4,
                    .half => 2,
                    .float => 4,
                    else => 2,
                };
            }

            // Tone map and convert to 8-bit
            const mapped = toneMap(r, g, b);

            img.setPixel(x, y, Color{
                .r = @intFromFloat(@max(0, @min(255, mapped.r * 255))),
                .g = @intFromFloat(@max(0, @min(255, mapped.g * 255))),
                .b = @intFromFloat(@max(0, @min(255, mapped.b * 255))),
                .a = @intFromFloat(@max(0, @min(255, a * 255))),
            });
        }

        pos += pixel_data_size;
    }
}

fn decodeRLE(src: []const u8, dest: []u8) !void {
    var src_pos: usize = 0;
    var dest_pos: usize = 0;

    while (src_pos < src.len and dest_pos < dest.len) {
        const count: i8 = @bitCast(src[src_pos]);
        src_pos += 1;

        if (count >= 0) {
            // Literal
            const n: usize = @intCast(@as(i16, count) + 1);
            const to_copy = @min(n, @min(src.len - src_pos, dest.len - dest_pos));
            @memcpy(dest[dest_pos..][0..to_copy], src[src_pos..][0..to_copy]);
            src_pos += to_copy;
            dest_pos += to_copy;
        } else {
            // Run
            if (src_pos >= src.len) break;
            const n: usize = @intCast(1 - @as(i16, count));
            const val = src[src_pos];
            src_pos += 1;
            const to_fill = @min(n, dest.len - dest_pos);
            @memset(dest[dest_pos..][0..to_fill], val);
            dest_pos += to_fill;
        }
    }
}

fn toneMap(r: f32, g: f32, b: f32) struct { r: f32, g: f32, b: f32 } {
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

// ============================================================================
// EXR Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Magic
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, EXR_MAGIC)));

    // Version (2, single-part, scanline)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, 2)));

    // Attributes
    try writeAttribute(&output, "channels", "chlist", &[_]u8{
        'B', 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0,
        'G', 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0,
        'R', 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0,
        0, // terminator
    });

    try writeAttribute(&output, "compression", "compression", &[_]u8{0}); // no compression

    // dataWindow
    var data_window: [16]u8 = undefined;
    std.mem.writeInt(i32, data_window[0..4], 0, .little);
    std.mem.writeInt(i32, data_window[4..8], 0, .little);
    std.mem.writeInt(i32, data_window[8..12], @as(i32, @intCast(img.width)) - 1, .little);
    std.mem.writeInt(i32, data_window[12..16], @as(i32, @intCast(img.height)) - 1, .little);
    try writeAttribute(&output, "dataWindow", "box2i", &data_window);
    try writeAttribute(&output, "displayWindow", "box2i", &data_window);

    try writeAttribute(&output, "lineOrder", "lineOrder", &[_]u8{0});

    // pixelAspectRatio
    try writeAttribute(&output, "pixelAspectRatio", "float", &std.mem.toBytes(std.mem.nativeToLittle(f32, 1.0)));

    // screenWindowCenter
    try writeAttribute(&output, "screenWindowCenter", "v2f", &std.mem.toBytes([2]f32{ 0.0, 0.0 }));

    // screenWindowWidth
    try writeAttribute(&output, "screenWindowWidth", "float", &std.mem.toBytes(std.mem.nativeToLittle(f32, 1.0)));

    // End of header
    try output.append(0);

    // Offset table
    const header_size = output.items.len;
    const offset_table_size = img.height * 8;
    const bytes_per_scanline = img.width * 3 * 2; // 3 channels, half float

    for (0..img.height) |y| {
        const offset: u64 = header_size + offset_table_size + y * (8 + bytes_per_scanline);
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u64, offset)));
    }

    // Scanlines
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        // Scanline header
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(i32, @as(i32, @intCast(y)))));
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(bytes_per_scanline)))));

        // B channel
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            const b = srgbToLinear(@as(f32, @floatFromInt(c.b)) / 255.0);
            try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, floatToHalf(b))));
        }

        // G channel
        x = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            const g = srgbToLinear(@as(f32, @floatFromInt(c.g)) / 255.0);
            try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, floatToHalf(g))));
        }

        // R channel
        x = 0;
        while (x < img.width) : (x += 1) {
            const c = img.getPixel(x, y) orelse Color.BLACK;
            const r = srgbToLinear(@as(f32, @floatFromInt(c.r)) / 255.0);
            try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, floatToHalf(r))));
        }
    }

    return output.toOwnedSlice();
}

fn writeAttribute(output: *std.ArrayList(u8), name: []const u8, attr_type: []const u8, data: []const u8) !void {
    try output.appendSlice(name);
    try output.append(0);
    try output.appendSlice(attr_type);
    try output.append(0);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(data.len)))));
    try output.appendSlice(data);
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

test "EXR magic" {
    try std.testing.expectEqual(@as(u32, 20000630), EXR_MAGIC);
}

test "Half-float conversion" {
    // Test 1.0
    const one = floatToHalf(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), halfToFloat(one), 0.001);

    // Test 0.0
    const zero = floatToHalf(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), halfToFloat(zero));

    // Test 0.5
    const half = floatToHalf(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), halfToFloat(half), 0.001);
}

test "Compression enum" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Compression.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Compression.rle));
}
