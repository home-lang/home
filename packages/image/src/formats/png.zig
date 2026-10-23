// PNG Decoder/Encoder
// Implements PNG specification: https://www.w3.org/TR/PNG/

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;
const raster = @import("raster_encoder.zig");
pub const AnimationEncoder = @import("apng_encoder.zig");

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
    // APNG chunks
    acTL = 0x6163544C, // Animation control
    fcTL = 0x6663544C, // Frame control
    fdAT = 0x66644154, // Frame data
    _,
};

// APNG frame dispose operations
const APNGDisposeOp = enum(u8) {
    none = 0,
    background = 1,
    previous = 2,
};

// APNG frame blend operations
const APNGBlendOp = enum(u8) {
    source = 0,
    over = 1,
};

// APNG animation control
const APNGAnimationControl = struct {
    num_frames: u32,
    num_plays: u32, // 0 = infinite
};

// APNG frame control
const APNGFrameControl = struct {
    sequence_number: u32,
    width: u32,
    height: u32,
    x_offset: u32,
    y_offset: u32,
    delay_num: u16,
    delay_den: u16,
    dispose_op: APNGDisposeOp,
    blend_op: APNGBlendOp,
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
    if (ihdr.chunk_type != @backingInt(ChunkType.IHDR)) {
        return error.InvalidFormat;
    }

    const header = try parseIHDR(ihdr.data);

    // Validate dimensions
    if (header.width == 0 or header.height == 0 or header.width > 0x7FFFFFFF or header.height > 0x7FFFFFFF) {
        return error.InvalidDimensions;
    }

    // Collect all IDAT chunks, palette, and APNG data
    var idat_data: std.ArrayList(u8) = .empty;
    defer idat_data.deinit(allocator);

    var palette: ?[]Color = null;
    defer if (palette) |pal| allocator.free(pal);
    var transparency: ?[]u8 = null;
    defer if (transparency) |t| allocator.free(t);

    // APNG support
    var anim_ctrl: ?APNGAnimationControl = null;
    var frame_controls: std.ArrayList(APNGFrameControl) = .empty;
    defer frame_controls.deinit(allocator);
    var frame_data_chunks: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (frame_data_chunks.items) |*fd| {
            fd.deinit(allocator);
        }
        frame_data_chunks.deinit(allocator);
    }
    var current_frame_data: ?*std.ArrayList(u8) = null;
    var first_frame_is_default = false;

    while (true) {
        const chunk = reader.readChunk() catch |err| {
            if (err == error.TruncatedData and idat_data.items.len > 0) break;
            return err;
        };

        const chunk_type: ChunkType = @enumFromInt(chunk.chunk_type);

        switch (chunk_type) {
            .IDAT => {
                try idat_data.appendSlice(allocator, chunk.data);
                // If first frame uses default image, add to first frame data too
                if (anim_ctrl != null and first_frame_is_default and current_frame_data != null) {
                    try current_frame_data.?.appendSlice(allocator, chunk.data);
                }
            },
            .PLTE => {
                if (palette != null) return error.InvalidFormat;
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
                if (transparency != null) return error.InvalidFormat;
                transparency = try allocator.alloc(u8, chunk.data.len);
                @memcpy(transparency.?, chunk.data);

                // Apply transparency to palette
                if (palette) |pal| {
                    for (0..@min(transparency.?.len, pal.len)) |i| {
                        pal[i].a = transparency.?[i];
                    }
                }
            },
            .acTL => {
                // APNG animation control
                if (chunk.data.len >= 8) {
                    anim_ctrl = APNGAnimationControl{
                        .num_frames = std.mem.readInt(u32, chunk.data[0..4], .big),
                        .num_plays = std.mem.readInt(u32, chunk.data[4..8], .big),
                    };
                }
            },
            .fcTL => {
                // APNG frame control
                if (chunk.data.len >= 26) {
                    const fc = APNGFrameControl{
                        .sequence_number = std.mem.readInt(u32, chunk.data[0..4], .big),
                        .width = std.mem.readInt(u32, chunk.data[4..8], .big),
                        .height = std.mem.readInt(u32, chunk.data[8..12], .big),
                        .x_offset = std.mem.readInt(u32, chunk.data[12..16], .big),
                        .y_offset = std.mem.readInt(u32, chunk.data[16..20], .big),
                        .delay_num = std.mem.readInt(u16, chunk.data[20..22], .big),
                        .delay_den = std.mem.readInt(u16, chunk.data[22..24], .big),
                        .dispose_op = @enumFromInt(chunk.data[24]),
                        .blend_op = @enumFromInt(chunk.data[25]),
                    };
                    try frame_controls.append(allocator, fc);

                    // Create new frame data buffer
                    try frame_data_chunks.append(allocator, .empty);
                    current_frame_data = &frame_data_chunks.items[frame_data_chunks.items.len - 1];

                    // Check if first frame uses default image
                    if (frame_controls.items.len == 1 and fc.sequence_number == 0) {
                        first_frame_is_default = true;
                    }
                }
            },
            .fdAT => {
                // APNG frame data (skip 4-byte sequence number)
                if (chunk.data.len > 4 and current_frame_data != null) {
                    try current_frame_data.?.appendSlice(allocator, chunk.data[4..]);
                }
            },
            .IEND => break,
            else => {}, // Skip unknown/ancillary chunks
        }
    }

    // Decompress IDAT data using zlib
    const decompressed = try decompressZlib(allocator, idat_data.items);
    defer allocator.free(decompressed);

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
    }

    // Unfilter scanlines
    try unfilterImage(&img, decompressed, header);

    // Handle APNG frames
    if (anim_ctrl != null and frame_controls.items.len > 0) {
        img.loop_count = anim_ctrl.?.num_plays;

        // Decode animation frames
        const frames = try allocator.alloc(Image.Frame, frame_controls.items.len);
        var initialized_frames: usize = 0;
        errdefer {
            for (frames[0..initialized_frames]) |f| {
                allocator.free(f.pixels);
            }
            allocator.free(frames);
        }

        for (frame_controls.items, 0..) |fc, i| {
            // Calculate delay in milliseconds
            var delay_ms: u32 = 100; // Default
            if (fc.delay_den != 0) {
                delay_ms = (@as(u32, fc.delay_num) * 1000) / @as(u32, fc.delay_den);
            } else if (fc.delay_num != 0) {
                delay_ms = @as(u32, fc.delay_num) * 10; // 1/100th second
            }

            // Allocate frame pixels
            const frame_size = @as(usize, fc.width) * @as(usize, fc.height) * output_format.bytesPerPixel();
            const frame_pixels = try allocator.alloc(u8, frame_size);
            errdefer allocator.free(frame_pixels);

            // Decompress frame data
            if (i < frame_data_chunks.items.len and frame_data_chunks.items[i].items.len > 0) {
                const frame_decompressed = try decompressZlib(allocator, frame_data_chunks.items[i].items);
                defer allocator.free(frame_decompressed);

                // Create temp image for unfiltering
                var temp_img = try Image.init(allocator, fc.width, fc.height, output_format);
                defer temp_img.deinit();

                const temp_header = PngHeader{
                    .width = fc.width,
                    .height = fc.height,
                    .bit_depth = header.bit_depth,
                    .color_type = header.color_type,
                    .compression = 0,
                    .filter = 0,
                    .interlace = 0,
                };

                try unfilterImage(&temp_img, frame_decompressed, temp_header);
                @memcpy(frame_pixels, temp_img.pixels);
            } else if (first_frame_is_default and i == 0) {
                // First frame uses default image
                @memcpy(frame_pixels, img.pixels);
            } else {
                @memset(frame_pixels, 0);
            }

            frames[i] = Image.Frame{
                .width = fc.width,
                .height = fc.height,
                .pixels = frame_pixels,
                .delay_ms = delay_ms,
                .x_offset = fc.x_offset,
                .y_offset = fc.y_offset,
                .dispose_op = switch (fc.dispose_op) {
                    .none => .none,
                    .background => .background,
                    .previous => .previous,
                },
                .blend_op = switch (fc.blend_op) {
                    .source => .source,
                    .over => .over,
                },
            };
            initialized_frames += 1;
        }

        img.frames = frames;
    }

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
        if (scanline_start + raw_scanline_width > raw_data.len) return error.TruncatedData;

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
    const sample_bytes: usize = if (header.bit_depth == 16) 2 else 1;

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
                const src_idx = @as(usize, x) * 3 * sample_bytes;
                img.pixels[out_idx] = scanline[src_idx];
                img.pixels[out_idx + 1] = scanline[src_idx + sample_bytes];
                img.pixels[out_idx + 2] = scanline[src_idx + 2 * sample_bytes];
            },
            .indexed => {
                img.pixels[out_idx] = scanline[x];
            },
            .grayscale_alpha => {
                const src_idx = @as(usize, x) * 2 * sample_bytes;
                const gray = scanline[src_idx];
                img.pixels[out_idx] = gray;
                img.pixels[out_idx + 1] = gray;
                img.pixels[out_idx + 2] = gray;
                img.pixels[out_idx + 3] = scanline[src_idx + sample_bytes];
            },
            .rgba => {
                const src_idx = @as(usize, x) * 4 * sample_bytes;
                img.pixels[out_idx] = scanline[src_idx];
                img.pixels[out_idx + 1] = scanline[src_idx + sample_bytes];
                img.pixels[out_idx + 2] = scanline[src_idx + 2 * sample_bytes];
                img.pixels[out_idx + 3] = scanline[src_idx + 3 * sample_bytes];
            },
        }
    }
}

// ============================================================================
// PNG Encoder
// ============================================================================

fn decompressZlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(data);
    var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    _ = decompressor.reader.streamRemaining(&output.writer) catch return error.DecompressionFailed;
    return output.toOwnedSlice();
}

/// Image.frames[0] is the default image when animation frames are present.
/// Its pixels, rather than Image.pixels, supply the first animation frame.
/// Indexed pixels expand to RGBA to retain the complete palette alpha channel.
pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    const source_frames = img.frames orelse &.{};
    if (source_frames.len == 0) {
        if (img.format != .indexed8) return raster.png(allocator, try raster.fromImage(img), .{});
        const view = try indexedView(img.pixels, img.width, img.height);
        try validateIndices(img, view);
        const rgba = try expandIndices(allocator, img, view);
        defer allocator.free(rgba.data);
        return raster.png(allocator, rgba, .{});
    }
    if (source_frames.len > std.math.maxInt(u31)) return error.InvalidAnimation;
    const frames = try allocator.alloc(AnimationEncoder.Frame, source_frames.len);
    defer allocator.free(frames);
    var expanded: usize = 0;
    defer for (frames[0..expanded]) |frame| allocator.free(frame.view.data);
    for (source_frames, frames) |frame, *out| {
        const width = frame.width orelse img.width;
        const height = frame.height orelse img.height;
        var source = img.*;
        source.width = width;
        source.height = height;
        source.pixels = frame.pixels;
        out.* = .{
            .view = if (img.format == .indexed8) try indexedView(frame.pixels, width, height) else try raster.fromImage(&source),
            .x = frame.x_offset,
            .y = frame.y_offset,
            .delay = try AnimationEncoder.Delay.fromMilliseconds(frame.delay_ms),
            .dispose = switch (frame.dispose_op) {
                .none => .none,
                .background => .background,
                .previous => .previous,
            },
            .blend = switch (frame.blend_op) {
                .source => .source,
                .over => .over,
            },
        };
    }
    const animation = AnimationEncoder.Animation{ .width = img.width, .height = img.height, .frames = frames, .plays = img.loop_count };
    try animation.validate();
    if (img.format == .indexed8) {
        for (frames) |frame| try validateIndices(img, frame.view);
        for (frames) |*frame| {
            frame.view = try expandIndices(allocator, img, frame.view);
            expanded += 1;
        }
    }
    return AnimationEncoder.encode(allocator, animation);
}
const indexedView = @import("indexed_raster.zig").indexedView;
const validateIndices = @import("indexed_raster.zig").validateIndices;
const expandIndices = @import("indexed_raster.zig").expandIndices;

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
test "PNG public image encoding preserves sixteen-bit little-endian input in network byte order" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 1, 1, .rgb16);
    defer img.deinit();
    @memcpy(img.pixels, &[_]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a });
    const bytes = try encode(a, &img);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x56, 0x9a }, decoded.pixels);
}

test "Paeth predictor" {
    // Test the Paeth predictor function
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 10, 10));
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
}

test "PNG encoder round trips RGBA pixels" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 2, 2, .rgba8);
    defer img.deinit();
    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.GREEN);
    img.setPixel(0, 1, Color.BLUE);
    img.setPixel(1, 1, Color{ .r = 12, .g = 34, .b = 56, .a = 78 });

    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(Color.RED, decoded.getPixel(0, 0).?);
    try std.testing.expectEqual(Color.GREEN, decoded.getPixel(1, 0).?);
    try std.testing.expectEqual(Color.BLUE, decoded.getPixel(0, 1).?);
    try std.testing.expectEqual(Color{ .r = 12, .g = 34, .b = 56, .a = 78 }, decoded.getPixel(1, 1).?);
}

test "Image APNG uses frame zero pixels, explicit rectangles and exact long delays" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 2, 1, .rgb16);
    defer img.deinit();
    const frames = try a.alloc(Image.Frame, 2);
    @memset(frames, .{ .pixels = &.{}, .delay_ms = 0 });
    img.frames = frames;
    frames[0].pixels = try a.dupe(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde, 0x22, 0x11, 0x44, 0x33 });
    frames[0].delay_ms = 20;
    frames[1] = .{ .pixels = try a.dupe(u8, &.{ 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef }), .width = 1, .height = 1, .x_offset = 1, .delay_ms = 65536, .dispose_op = .previous, .blend_op = .over };
    img.loop_count = 3;
    const encoded = try img.encode(.png);
    defer a.free(encoded);
    var decoded = try decode(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x56, 0x9a, 0xde, 0x11, 0x33 }, decoded.pixels);
    const result = decoded.frames.?;
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 3), decoded.loop_count);
    try std.testing.expectEqual(@as(?u32, 1), result[1].width);
    try std.testing.expectEqual(@as(?u32, 1), result[1].height);
    try std.testing.expectEqual(@as(u32, 1), result[1].x_offset);
    try std.testing.expectEqual(@as(u32, 65536), result[1].delay_ms);
    try std.testing.expectEqual(Image.DisposeOp.previous, result[1].dispose_op);
    try std.testing.expectEqual(Image.BlendOp.over, result[1].blend_op);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xab, 0xef }, result[1].pixels);
    frames[1].width = 2;
    try std.testing.expectError(error.BufferTooSmall, img.encode(.png));
}
test "indexed PNG expands palette alpha and rejects missing or out of range palette entries" {
    const a = std.testing.allocator;
    var img = try Image.init(a, 2, 1, .indexed8);
    defer img.deinit();
    img.palette = try a.dupe(Color, &.{ .{ .r = 255, .g = 0, .b = 0, .a = 0 }, .{ .r = 0, .g = 0, .b = 255, .a = 91 } });
    @memcpy(img.pixels, &[_]u8{ 0, 1 });
    const bytes = try img.encode(.png);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0, 255, 91 }, decoded.pixels);
    img.pixels[1] = 2;
    try std.testing.expectError(error.InvalidPalette, img.encode(.png));
}
fn indexedAnimationAllocationCase(a: std.mem.Allocator) !void {
    var img = try Image.init(a, 2, 1, .indexed8);
    defer img.deinit();
    img.palette = try a.dupe(Color, &.{Color.RED});
    const frames = try a.alloc(Image.Frame, 2);
    @memset(frames, .{ .pixels = &.{}, .delay_ms = 10 });
    img.frames = frames;
    frames[0].pixels = try a.dupe(u8, &.{ 0, 0 });
    frames[1].pixels = try a.dupe(u8, &.{ 0, 0 });
    const bytes = try img.encode(.png);
    defer a.free(bytes);
}
test "indexed APNG adapter unwinds frame descriptors expansions and PNG data on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, indexedAnimationAllocationCase, .{});
}
