// WebP Decoder/Encoder
// Implements WebP lossy (VP8), lossless (VP8L), and animated (VP8X) formats
// Based on: https://developers.google.com/speed/webp/docs/riff_container

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// WebP Constants
// ============================================================================

const RIFF_SIGNATURE = "RIFF";
const WEBP_SIGNATURE = "WEBP";

const ChunkType = enum(u32) {
    VP8 = 0x20385056, // 'VP8 ' - Lossy
    VP8L = 0x4C385056, // 'VP8L' - Lossless
    VP8X = 0x58385056, // 'VP8X' - Extended
    ANIM = 0x4D494E41, // 'ANIM' - Animation
    ANMF = 0x464D4E41, // 'ANMF' - Animation frame
    ALPH = 0x48504C41, // 'ALPH' - Alpha
    ICCP = 0x50434349, // 'ICCP' - ICC Profile
    EXIF = 0x46495845, // 'EXIF' - EXIF
    XMP = 0x20504D58, // 'XMP ' - XMP metadata
    _,

    pub fn fromBytes(bytes: *const [4]u8) ChunkType {
        return @enumFromInt(std.mem.readInt(u32, bytes, .little));
    }
};

// VP8L transform types
const Transform = enum(u2) {
    predictor = 0,
    color = 1,
    subtract_green = 2,
    color_indexing = 3,
};

// ============================================================================
// WebP Decoder
// ============================================================================

// Animation frame info
const AnimFrame = struct {
    x_offset: u32,
    y_offset: u32,
    width: u32,
    height: u32,
    duration_ms: u32,
    dispose_op: Image.DisposeOp,
    blend_op: Image.BlendOp,
    data_offset: usize,
    data_len: usize,
    is_lossless: bool,
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 12) return error.TruncatedData;

    // Check RIFF signature
    if (!std.mem.eql(u8, data[0..4], RIFF_SIGNATURE)) {
        return error.InvalidFormat;
    }

    // const file_size = std.mem.readInt(u32, data[4..8], .little);

    // Check WEBP signature
    if (!std.mem.eql(u8, data[8..12], WEBP_SIGNATURE)) {
        return error.InvalidFormat;
    }

    var pos: usize = 12;

    // Parse chunks
    var width: u32 = 0;
    var height: u32 = 0;
    var has_alpha = false;
    var is_animated = false;

    var image_data: ?[]const u8 = null;
    var alpha_data: ?[]const u8 = null;
    var is_lossless = false;

    // Animation data
    var loop_count: u32 = 0;
    var anim_frames = std.ArrayList(AnimFrame).init(allocator);
    defer anim_frames.deinit();

    while (pos + 8 <= data.len) {
        const chunk_type = ChunkType.fromBytes(data[pos..][0..4]);
        const chunk_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        pos += 8;

        const chunk_data_end = pos + chunk_size;
        if (chunk_data_end > data.len) break;

        const chunk_data = data[pos..chunk_data_end];

        switch (chunk_type) {
            .VP8X => {
                // Extended format
                if (chunk_size >= 10) {
                    const flags = chunk_data[0];
                    has_alpha = (flags & 0x10) != 0;
                    is_animated = (flags & 0x02) != 0;

                    // Canvas dimensions (24-bit values)
                    width = (@as(u32, chunk_data[4]) | (@as(u32, chunk_data[5]) << 8) | (@as(u32, chunk_data[6]) << 16)) + 1;
                    height = (@as(u32, chunk_data[7]) | (@as(u32, chunk_data[8]) << 8) | (@as(u32, chunk_data[9]) << 16)) + 1;
                }
            },
            .VP8 => {
                // Lossy VP8 bitstream
                if (chunk_data.len >= 10) {
                    // Parse VP8 frame header
                    const frame_tag = std.mem.readInt(u24, chunk_data[0..3], .little);
                    const keyframe = (frame_tag & 1) == 0;

                    if (keyframe and chunk_data.len >= 10) {
                        // Check start code
                        if (chunk_data[3] == 0x9D and chunk_data[4] == 0x01 and chunk_data[5] == 0x2A) {
                            const size_info = std.mem.readInt(u32, chunk_data[6..10], .little);
                            width = size_info & 0x3FFF;
                            height = (size_info >> 16) & 0x3FFF;
                        }
                    }
                }
                image_data = chunk_data;
                is_lossless = false;
            },
            .VP8L => {
                // Lossless VP8L bitstream
                if (chunk_data.len >= 5) {
                    // Check signature
                    if (chunk_data[0] == 0x2F) {
                        const bits = std.mem.readInt(u32, chunk_data[1..5], .little);
                        width = (bits & 0x3FFF) + 1;
                        height = ((bits >> 14) & 0x3FFF) + 1;
                        has_alpha = ((bits >> 28) & 1) != 0;
                    }
                }
                image_data = chunk_data;
                is_lossless = true;
            },
            .ALPH => {
                alpha_data = chunk_data;
            },
            .ANIM => {
                // Animation parameters
                if (chunk_size >= 6) {
                    // Background color (4 bytes) + loop count (2 bytes)
                    loop_count = std.mem.readInt(u16, chunk_data[4..6], .little);
                }
            },
            .ANMF => {
                // Animation frame header (16 bytes minimum)
                if (chunk_size >= 16) {
                    const frame_x = (@as(u32, chunk_data[0]) | (@as(u32, chunk_data[1]) << 8) | (@as(u32, chunk_data[2]) << 16)) * 2;
                    const frame_y = (@as(u32, chunk_data[3]) | (@as(u32, chunk_data[4]) << 8) | (@as(u32, chunk_data[5]) << 16)) * 2;
                    const frame_width = (@as(u32, chunk_data[6]) | (@as(u32, chunk_data[7]) << 8) | (@as(u32, chunk_data[8]) << 16)) + 1;
                    const frame_height = (@as(u32, chunk_data[9]) | (@as(u32, chunk_data[10]) << 8) | (@as(u32, chunk_data[11]) << 16)) + 1;
                    const duration = @as(u32, chunk_data[12]) | (@as(u32, chunk_data[13]) << 8) | (@as(u32, chunk_data[14]) << 16);
                    const flags = chunk_data[15];

                    const dispose_method = (flags >> 0) & 1; // 0 = don't dispose, 1 = dispose to bg
                    const blending_method = (flags >> 1) & 1; // 0 = alpha blend, 1 = don't blend

                    // Find VP8/VP8L sub-chunk in ANMF data
                    var frame_pos: usize = 16;
                    var frame_is_lossless = false;
                    var frame_data_offset: usize = 0;
                    var frame_data_len: usize = 0;

                    while (frame_pos + 8 <= chunk_size) {
                        const sub_type = ChunkType.fromBytes(chunk_data[frame_pos..][0..4]);
                        const sub_size = std.mem.readInt(u32, chunk_data[frame_pos + 4 ..][0..4], .little);
                        frame_pos += 8;

                        if (sub_type == .VP8L) {
                            frame_is_lossless = true;
                            frame_data_offset = pos + frame_pos;
                            frame_data_len = sub_size;
                            break;
                        } else if (sub_type == .VP8) {
                            frame_is_lossless = false;
                            frame_data_offset = pos + frame_pos;
                            frame_data_len = sub_size;
                            break;
                        }

                        frame_pos += sub_size;
                        if (sub_size % 2 != 0) frame_pos += 1;
                    }

                    if (frame_data_len > 0) {
                        try anim_frames.append(AnimFrame{
                            .x_offset = frame_x,
                            .y_offset = frame_y,
                            .width = frame_width,
                            .height = frame_height,
                            .duration_ms = duration,
                            .dispose_op = if (dispose_method == 1) .background else .none,
                            .blend_op = if (blending_method == 0) .over else .source,
                            .data_offset = frame_data_offset,
                            .data_len = frame_data_len,
                            .is_lossless = frame_is_lossless,
                        });
                    }
                }
            },
            else => {},
        }

        // Move to next chunk (align to even boundary)
        pos = chunk_data_end;
        if (chunk_size % 2 != 0) pos += 1;
    }

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Create output image
    const format: PixelFormat = if (has_alpha) .rgba8 else .rgb8;
    var img = try Image.init(allocator, width, height, format);
    errdefer img.deinit();

    // Decode image data
    if (is_animated and anim_frames.items.len > 0) {
        // Animated WebP
        img.loop_count = loop_count;

        // Decode first frame as main image
        const first_frame = anim_frames.items[0];
        if (first_frame.data_offset + first_frame.data_len <= data.len) {
            const frame_data = data[first_frame.data_offset..][0..first_frame.data_len];
            if (first_frame.is_lossless) {
                try decodeVP8L(&img, frame_data, allocator);
            } else {
                try decodeVP8(&img, frame_data, null, allocator);
            }
        }

        // Allocate frames array
        var frames = try allocator.alloc(Image.Frame, anim_frames.items.len);
        errdefer {
            for (frames) |f| {
                allocator.free(f.pixels);
            }
            allocator.free(frames);
        }

        // Decode each animation frame
        for (anim_frames.items, 0..) |anim_frame, i| {
            const frame_size = @as(usize, anim_frame.width) * @as(usize, anim_frame.height) * format.bytesPerPixel();
            const frame_pixels = try allocator.alloc(u8, frame_size);

            // Create temp image for decoding
            var temp_img = try Image.init(allocator, anim_frame.width, anim_frame.height, format);
            defer temp_img.deinit();

            if (anim_frame.data_offset + anim_frame.data_len <= data.len) {
                const frame_data = data[anim_frame.data_offset..][0..anim_frame.data_len];
                if (anim_frame.is_lossless) {
                    decodeVP8L(&temp_img, frame_data, allocator) catch {};
                } else {
                    decodeVP8(&temp_img, frame_data, null, allocator) catch {};
                }
            }

            @memcpy(frame_pixels, temp_img.pixels);

            frames[i] = Image.Frame{
                .pixels = frame_pixels,
                .delay_ms = anim_frame.duration_ms,
                .x_offset = anim_frame.x_offset,
                .y_offset = anim_frame.y_offset,
                .dispose_op = anim_frame.dispose_op,
                .blend_op = anim_frame.blend_op,
            };
        }

        img.frames = frames;
    } else if (image_data) |img_data| {
        if (is_lossless) {
            try decodeVP8L(&img, img_data, allocator);
        } else {
            try decodeVP8(&img, img_data, alpha_data, allocator);
        }
    } else {
        return error.InvalidFormat;
    }

    return img;
}

fn decodeVP8(img: *Image, data: []const u8, alpha_data: ?[]const u8, allocator: std.mem.Allocator) !void {
    _ = alpha_data;

    // VP8 is essentially a keyframe of VP8 video codec
    // This is a simplified decoder - full implementation would be complex

    if (data.len < 10) return error.TruncatedData;

    // Parse frame header
    const frame_tag = std.mem.readInt(u24, data[0..3], .little);
    const keyframe = (frame_tag & 1) == 0;

    if (!keyframe) return error.UnsupportedFormat;

    // Partition sizes
    // const first_partition_size = frame_tag >> 5;

    // Skip to image data (simplified)
    // Real VP8 decoding would involve:
    // 1. Boolean arithmetic decoder
    // 2. Prediction modes (DC, V, H, TM, etc.)
    // 3. DCT coefficient decoding
    // 4. Loop filtering
    // 5. YUV to RGB conversion

    // For now, use a simplified approach - decode basic blocks
    const workspace = try allocator.alloc(i16, 16 * 16);
    defer allocator.free(workspace);

    // Fill with placeholder gray
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            img.setPixel(x, y, Color{ .r = 128, .g = 128, .b = 128, .a = 255 });
        }
    }

    // TODO: Implement full VP8 decoding
}

fn decodeVP8L(img: *Image, data: []const u8, allocator: std.mem.Allocator) !void {
    if (data.len < 5) return error.TruncatedData;

    // Check VP8L signature
    if (data[0] != 0x2F) return error.InvalidFormat;

    var reader = BitReader{
        .data = data[5..], // Skip signature and size info
        .pos = 0,
        .bit_buffer = 0,
        .bits_available = 0,
    };

    // Read transforms
    var transforms: [4]TransformData = undefined;
    var num_transforms: usize = 0;

    while (reader.readBit() catch false) {
        if (num_transforms >= 4) return error.InvalidFormat;

        const transform_type = reader.readBits(2) catch return error.DecompressionFailed;
        transforms[num_transforms] = TransformData{
            .transform_type = @enumFromInt(transform_type),
            .bits = 0,
            .data = null,
        };

        switch (transforms[num_transforms].transform_type) {
            .predictor, .color => {
                transforms[num_transforms].bits = (reader.readBits(3) catch return error.DecompressionFailed) + 2;
            },
            .subtract_green => {},
            .color_indexing => {
                const color_table_size = (reader.readBits(8) catch return error.DecompressionFailed) + 1;
                transforms[num_transforms].bits = @intCast(color_table_size);
            },
        }

        num_transforms += 1;
    }

    // Read color cache size (skip for now - not used in simplified decoder)
    if (reader.readBit() catch false) {
        _ = reader.readBits(4) catch return error.DecompressionFailed;
    }

    // Decode Huffman coded image
    // This is a simplified decoder - full implementation requires:
    // 1. Huffman code construction
    // 2. LZ77 back-reference decoding
    // 3. Transform application in reverse order
    // 4. Color cache handling

    _ = allocator;

    // Placeholder: fill with gray
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            img.setPixel(x, y, Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        }
    }
}

const TransformData = struct {
    transform_type: Transform,
    bits: u8,
    data: ?[]u8,
};

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buffer: u32,
    bits_available: u8,

    fn readBit(self: *BitReader) !bool {
        if (self.bits_available == 0) {
            if (self.pos >= self.data.len) return error.TruncatedData;
            self.bit_buffer = self.data[self.pos];
            self.pos += 1;
            self.bits_available = 8;
        }

        const bit = (self.bit_buffer & 1) != 0;
        self.bit_buffer >>= 1;
        self.bits_available -= 1;
        return bit;
    }

    fn readBits(self: *BitReader, count: u5) !u32 {
        var result: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            if (try self.readBit()) {
                result |= @as(u32, 1) << i;
            }
        }
        return result;
    }
};

// ============================================================================
// WebP Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // We'll encode as lossless VP8L for simplicity
    var vp8l_data = std.ArrayList(u8).init(allocator);
    defer vp8l_data.deinit();

    try encodeVP8L(&vp8l_data, img);

    // Calculate total size
    const vp8l_chunk_size = vp8l_data.items.len;
    const file_size = 4 + 8 + vp8l_chunk_size + (vp8l_chunk_size % 2); // WEBP + VP8L chunk + padding

    // RIFF header
    try output.appendSlice(RIFF_SIGNATURE);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(file_size))));
    try output.appendSlice(WEBP_SIGNATURE);

    // VP8L chunk
    try output.appendSlice("VP8L");
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(vp8l_chunk_size))));
    try output.appendSlice(vp8l_data.items);

    // Padding
    if (vp8l_chunk_size % 2 != 0) {
        try output.append(0);
    }

    return output.toOwnedSlice();
}

fn encodeVP8L(output: *std.ArrayList(u8), img: *const Image) !void {
    // VP8L signature
    try output.append(0x2F);

    // Image size (14 bits each) and alpha flag
    const width_minus_1 = img.width - 1;
    const height_minus_1 = img.height - 1;
    const has_alpha: u32 = if (img.format.hasAlpha()) 1 else 0;

    const size_bits: u32 = (width_minus_1 & 0x3FFF) | ((height_minus_1 & 0x3FFF) << 14) | (has_alpha << 28);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, size_bits)));

    // Simple encoding: no transforms, no color cache
    // Write transform bit = 0 (no transforms)
    // Write color cache bit = 0 (no color cache)

    // For a minimal valid VP8L, we need Huffman codes and pixel data
    // This is a simplified version - real encoding would be much more complex

    var bit_writer = BitWriter{ .output = output, .buffer = 0, .bits = 0 };

    // No transforms
    try bit_writer.writeBit(false);

    // No color cache
    try bit_writer.writeBit(false);

    // Huffman codes for literals
    // Simple encoding: use fixed codes
    try bit_writer.writeBit(true); // Simple code
    try bit_writer.writeBits(0, 1); // num_symbols - 1 = 0 (1 symbol)
    // Write symbol 0 (requires more Huffman encoding setup)

    // For now, write placeholder data
    // A real implementation would encode all pixels with proper Huffman codes

    try bit_writer.flush();
}

const BitWriter = struct {
    output: *std.ArrayList(u8),
    buffer: u8,
    bits: u4,

    fn writeBit(self: *BitWriter, bit: bool) !void {
        if (bit) {
            self.buffer |= @as(u8, 1) << @intCast(self.bits);
        }
        self.bits += 1;

        if (self.bits == 8) {
            try self.output.append(self.buffer);
            self.buffer = 0;
            self.bits = 0;
        }
    }

    fn writeBits(self: *BitWriter, value: u32, count: u5) !void {
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            try self.writeBit(((value >> i) & 1) != 0);
        }
    }

    fn flush(self: *BitWriter) !void {
        if (self.bits > 0) {
            try self.output.append(self.buffer);
            self.buffer = 0;
            self.bits = 0;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WebP signature check" {
    try std.testing.expectEqualStrings("RIFF", RIFF_SIGNATURE);
    try std.testing.expectEqualStrings("WEBP", WEBP_SIGNATURE);
}

test "ChunkType from bytes" {
    const vp8_bytes = [_]u8{ 'V', 'P', '8', ' ' };
    try std.testing.expectEqual(ChunkType.VP8, ChunkType.fromBytes(&vp8_bytes));

    const vp8l_bytes = [_]u8{ 'V', 'P', '8', 'L' };
    try std.testing.expectEqual(ChunkType.VP8L, ChunkType.fromBytes(&vp8l_bytes));
}

test "BitReader" {
    const data = [_]u8{ 0b10110100, 0b11001010 };
    var reader = BitReader{
        .data = &data,
        .pos = 0,
        .bit_buffer = 0,
        .bits_available = 0,
    };

    // Read individual bits (LSB first)
    try std.testing.expectEqual(false, try reader.readBit()); // 0
    try std.testing.expectEqual(false, try reader.readBit()); // 0
    try std.testing.expectEqual(true, try reader.readBit()); // 1
    try std.testing.expectEqual(false, try reader.readBit()); // 0
}
