// PNG Decoder/Encoder
// Implements PNG specification: https://www.w3.org/TR/PNG/

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// PNG Constants
// ============================================================================

const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

const ChunkType = enum(u32) {
    IHDR = 0x49484452,
    PLTE = 0x504C5445,
    IDAT = 0x49444154,
    IEND = 0x49454E44,
    tRNS = 0x74524E53,
    gAMA = 0x67414D41,
    cHRM = 0x6348524D,
    sRGB = 0x73524742,
    iCCP = 0x69434350,
    tEXt = 0x74455874,
    zTXt = 0x7A545874,
    iTXt = 0x69545874,
    bKGD = 0x624B4744,
    pHYs = 0x70485973,
    sBIT = 0x73424954,
    sPLT = 0x73504C54,
    hIST = 0x68495354,
    tIME = 0x74494D45,
    _,
};

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

// ============================================================================
// PNG Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8) return error.TruncatedData;

    // Verify PNG signature
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) {
        return error.InvalidFormat;
    }

    var reader = PngReader{ .data = data, .pos = 8 };

    // Read IHDR (must be first)
    const ihdr = try reader.readChunk();
    if (ihdr.chunk_type != @intFromEnum(ChunkType.IHDR)) {
        return error.InvalidFormat;
    }

    const header = try parseIHDR(ihdr.data);

    // Validate dimensions
    if (header.width == 0 or header.height == 0 or header.width > 0x7FFFFFFF or header.height > 0x7FFFFFFF) {
        return error.InvalidDimensions;
    }

    // Collect all IDAT chunks and palette
    var idat_data = std.ArrayList(u8).init(allocator);
    defer idat_data.deinit();

    var palette: ?[]Color = null;
    var transparency: ?[]u8 = null;
    defer if (transparency) |t| allocator.free(t);

    while (true) {
        const chunk = reader.readChunk() catch |err| {
            if (err == error.TruncatedData and idat_data.items.len > 0) break;
            return err;
        };

        const chunk_type: ChunkType = @enumFromInt(chunk.chunk_type);

        switch (chunk_type) {
            .IDAT => {
                try idat_data.appendSlice(chunk.data);
            },
            .PLTE => {
                if (chunk.data.len % 3 != 0) return error.InvalidFormat;
                const num_colors = chunk.data.len / 3;
                palette = try allocator.alloc(Color, num_colors);
                for (0..num_colors) |i| {
                    palette.?[i] = Color{
                        .r = chunk.data[i * 3],
                        .g = chunk.data[i * 3 + 1],
                        .b = chunk.data[i * 3 + 2],
                        .a = 255,
                    };
                }
            },
            .tRNS => {
                transparency = try allocator.alloc(u8, chunk.data.len);
                @memcpy(transparency.?, chunk.data);

                // Apply transparency to palette
                if (palette) |pal| {
                    for (0..@min(transparency.?.len, pal.len)) |i| {
                        pal[i].a = transparency.?[i];
                    }
                }
            },
            .IEND => break,
            else => {}, // Skip unknown/ancillary chunks
        }
    }

    // Decompress IDAT data using zlib
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();

    var stream = std.io.fixedBufferStream(idat_data.items);
    var decompressor = std.compress.zlib.decompressor(stream.reader());

    // Read all decompressed data
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = decompressor.read(&buf) catch |err| {
            if (err == error.EndOfStream) break;
            return error.DecompressionFailed;
        };
        if (n == 0) break;
        try decompressed.appendSlice(buf[0..n]);
    }

    // Determine output format
    const output_format: PixelFormat = switch (header.color_type) {
        .grayscale => .grayscale8,
        .rgb => .rgb8,
        .indexed => .indexed8,
        .grayscale_alpha, .rgba => .rgba8,
    };

    // Create output image
    var img = try Image.init(allocator, header.width, header.height, output_format);
    errdefer img.deinit();

    // Apply palette if indexed
    if (output_format == .indexed8 and palette != null) {
        img.palette = palette;
        palette = null; // Transfer ownership
    } else if (palette) |pal| {
        allocator.free(pal);
    }

    // Unfilter scanlines
    try unfilterImage(&img, decompressed.items, header);

    return img;
}

const PngHeader = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression: u8,
    filter: u8,
    interlace: u8,
};

fn parseIHDR(data: []const u8) !PngHeader {
    if (data.len < 13) return error.InvalidHeader;

    return PngHeader{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .bit_depth = data[8],
        .color_type = @enumFromInt(data[9]),
        .compression = data[10],
        .filter = data[11],
        .interlace = data[12],
    };
}

fn unfilterImage(img: *Image, raw_data: []const u8, header: PngHeader) !void {
    const samples_per_pixel: u8 = switch (header.color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };

    const bits_per_pixel = @as(u16, samples_per_pixel) * @as(u16, header.bit_depth);
    const bytes_per_pixel: u8 = @max(1, @as(u8, @intCast(bits_per_pixel / 8)));
    const scanline_width = @as(usize, header.width) * bytes_per_pixel;
    const raw_scanline_width = scanline_width + 1; // +1 for filter byte

    var prev_scanline: ?[]u8 = null;
    const current_scanline = try img.allocator.alloc(u8, scanline_width);
    defer img.allocator.free(current_scanline);

    var prev_alloc: ?[]u8 = null;
    defer if (prev_alloc) |p| img.allocator.free(p);

    var y: u32 = 0;
    while (y < header.height) : (y += 1) {
        const scanline_start = @as(usize, y) * raw_scanline_width;
        if (scanline_start >= raw_data.len) return error.TruncatedData;

        const filter_type: FilterType = @enumFromInt(raw_data[scanline_start]);
        const raw_scanline = raw_data[scanline_start + 1 ..][0..scanline_width];

        // Apply filter
        applyFilter(current_scanline, raw_scanline, prev_scanline, filter_type, bytes_per_pixel);

        // Convert to output format
        convertScanline(img, y, current_scanline, header);

        // Save for next iteration
        if (prev_alloc) |p| {
            prev_scanline = p;
        } else {
            prev_alloc = try img.allocator.alloc(u8, scanline_width);
            prev_scanline = prev_alloc;
        }
        @memcpy(prev_scanline.?, current_scanline);
    }
}

fn applyFilter(output: []u8, input: []const u8, prev: ?[]const u8, filter: FilterType, bpp: u8) void {
    for (0..output.len) |i| {
        const a: u8 = if (i >= bpp) output[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev) |p| (if (i >= bpp) p[i - bpp] else 0) else 0;

        output[i] = switch (filter) {
            .none => input[i],
            .sub => input[i] +% a,
            .up => input[i] +% b,
            .average => input[i] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
            .paeth => input[i] +% paethPredictor(a, b, c),
        };
    }
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const pa = @as(i16, @intCast(b)) - @as(i16, @intCast(c));
    const pb = @as(i16, @intCast(a)) - @as(i16, @intCast(c));
    const pc = pa + pb;

    const abs_pa = if (pa < 0) -pa else pa;
    const abs_pb = if (pb < 0) -pb else pb;
    const abs_pc = if (pc < 0) -pc else pc;

    if (abs_pa <= abs_pb and abs_pa <= abs_pc) {
        return a;
    } else if (abs_pb <= abs_pc) {
        return b;
    } else {
        return c;
    }
}

fn convertScanline(img: *Image, y: u32, scanline: []const u8, header: PngHeader) void {
    const output_bpp = img.format.bytesPerPixel();

    var x: u32 = 0;
    while (x < header.width) : (x += 1) {
        const out_idx = (@as(usize, y) * @as(usize, img.width) + @as(usize, x)) * output_bpp;

        switch (header.color_type) {
            .grayscale => {
                if (header.bit_depth == 8) {
                    img.pixels[out_idx] = scanline[x];
                } else if (header.bit_depth == 16) {
                    img.pixels[out_idx] = scanline[x * 2]; // Take high byte
                }
            },
            .rgb => {
                const src_idx = @as(usize, x) * 3;
                img.pixels[out_idx] = scanline[src_idx];
                img.pixels[out_idx + 1] = scanline[src_idx + 1];
                img.pixels[out_idx + 2] = scanline[src_idx + 2];
            },
            .indexed => {
                img.pixels[out_idx] = scanline[x];
            },
            .grayscale_alpha => {
                const src_idx = @as(usize, x) * 2;
                const gray = scanline[src_idx];
                img.pixels[out_idx] = gray;
                img.pixels[out_idx + 1] = gray;
                img.pixels[out_idx + 2] = gray;
                img.pixels[out_idx + 3] = scanline[src_idx + 1];
            },
            .rgba => {
                const src_idx = @as(usize, x) * 4;
                img.pixels[out_idx] = scanline[src_idx];
                img.pixels[out_idx + 1] = scanline[src_idx + 1];
                img.pixels[out_idx + 2] = scanline[src_idx + 2];
                img.pixels[out_idx + 3] = scanline[src_idx + 3];
            },
        }
    }
}

// ============================================================================
// PNG Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write PNG signature
    try output.appendSlice(&PNG_SIGNATURE);

    // Determine color type and bit depth based on image format
    const color_type: ColorType = switch (img.format) {
        .grayscale8, .grayscale16 => .grayscale,
        .rgb8, .rgb16 => .rgb,
        .rgba8, .rgba16 => .rgba,
        .indexed8 => .indexed,
    };

    const bit_depth: u8 = switch (img.format) {
        .grayscale16, .rgb16, .rgba16 => 16,
        else => 8,
    };

    // Write IHDR chunk
    var ihdr_data: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], img.height, .big);
    ihdr_data[8] = bit_depth;
    ihdr_data[9] = @intFromEnum(color_type);
    ihdr_data[10] = 0; // Compression
    ihdr_data[11] = 0; // Filter
    ihdr_data[12] = 0; // Interlace
    try writeChunk(&output, .IHDR, &ihdr_data);

    // Write PLTE chunk for indexed images
    if (color_type == .indexed and img.palette != null) {
        var plte_data = try allocator.alloc(u8, img.palette.?.len * 3);
        defer allocator.free(plte_data);

        for (img.palette.?, 0..) |color, i| {
            plte_data[i * 3] = color.r;
            plte_data[i * 3 + 1] = color.g;
            plte_data[i * 3 + 2] = color.b;
        }
        try writeChunk(&output, .PLTE, plte_data);
    }

    // Prepare filtered data
    const samples_per_pixel: u8 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };
    const bytes_per_pixel = samples_per_pixel * (bit_depth / 8);
    const scanline_width = @as(usize, img.width) * bytes_per_pixel;
    const raw_size = @as(usize, img.height) * (scanline_width + 1);

    var raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    // Apply filters and copy data
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        const out_idx = @as(usize, y) * (scanline_width + 1);
        raw_data[out_idx] = 0; // No filter (simplest encoder)

        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const src_idx = (@as(usize, y) * @as(usize, img.width) + @as(usize, x)) * img.format.bytesPerPixel();
            const dst_idx = out_idx + 1 + @as(usize, x) * bytes_per_pixel;

            // Copy pixel data
            for (0..bytes_per_pixel) |b| {
                if (src_idx + b < img.pixels.len) {
                    raw_data[dst_idx + b] = img.pixels[src_idx + b];
                }
            }
        }
    }

    // Compress with zlib
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();

    var fbs = std.io.fixedBufferStream(raw_data);
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    const reader = fbs.reader();

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = try reader.read(&buf);
        if (n == 0) break;
        _ = try compressor.write(buf[0..n]);
    }
    try compressor.finish();

    // Write IDAT chunk(s)
    try writeChunk(&output, .IDAT, compressed.items);

    // Write IEND chunk
    try writeChunk(&output, .IEND, &[_]u8{});

    return output.toOwnedSlice();
}

fn writeChunk(output: *std.ArrayList(u8), chunk_type: ChunkType, data: []const u8) !void {
    // Length
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try output.appendSlice(&len_buf);

    // Type
    var type_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &type_buf, @intFromEnum(chunk_type), .big);
    try output.appendSlice(&type_buf);

    // Data
    try output.appendSlice(data);

    // CRC (over type + data)
    var crc_data = try output.allocator.alloc(u8, 4 + data.len);
    defer output.allocator.free(crc_data);
    @memcpy(crc_data[0..4], &type_buf);
    @memcpy(crc_data[4..], data);

    const crc = std.hash.Crc32.hash(crc_data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc, .big);
    try output.appendSlice(&crc_buf);
}

// ============================================================================
// PNG Reader Helper
// ============================================================================

const PngReader = struct {
    data: []const u8,
    pos: usize,

    const Chunk = struct {
        length: u32,
        chunk_type: u32,
        data: []const u8,
        crc: u32,
    };

    fn readChunk(self: *PngReader) !Chunk {
        if (self.pos + 12 > self.data.len) return error.TruncatedData;

        const length = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        const chunk_type = std.mem.readInt(u32, self.data[self.pos + 4 ..][0..4], .big);

        if (self.pos + 12 + length > self.data.len) return error.TruncatedData;

        const chunk_data = self.data[self.pos + 8 ..][0..length];
        const crc = std.mem.readInt(u32, self.data[self.pos + 8 + length ..][0..4], .big);

        self.pos += 12 + length;

        return Chunk{
            .length = length,
            .chunk_type = chunk_type,
            .data = chunk_data,
            .crc = crc,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PNG magic bytes" {
    try std.testing.expectEqual(
        @as(u8, 0x89),
        PNG_SIGNATURE[0],
    );
}

test "Paeth predictor" {
    // Test the Paeth predictor function
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 10, 10));
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
}
