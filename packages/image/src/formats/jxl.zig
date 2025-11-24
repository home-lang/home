// JPEG XL (JXL) Decoder/Encoder
// Implements basic JPEG XL container format
// Based on: https://jpeg.org/jpegxl/

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// JXL Constants
// ============================================================================

// JXL container signature
const JXL_CONTAINER_SIGNATURE = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };

// JXL naked codestream signature
const JXL_CODESTREAM_SIGNATURE = [_]u8{ 0xFF, 0x0A };

// Box types
const BOX_JXLC = "jxlc"; // Codestream box
const BOX_JXLP = "jxlp"; // Partial codestream
const BOX_EXIF = "Exif"; // EXIF metadata
const BOX_XML = "xml "; // XML metadata
const BOX_JUMB = "jumb"; // JUMBF metadata
const BOX_BROB = "brob"; // Brotli-compressed box

// Frame header flags
const FrameType = enum(u2) {
    regular_frame = 0,
    lf_frame = 1,
    reference_only = 2,
    skip_progressive = 3,
};

// ============================================================================
// JXL Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 2) return error.TruncatedData;

    // Detect format: container or naked codestream
    const is_container = data.len >= 12 and std.mem.eql(u8, data[0..12], &JXL_CONTAINER_SIGNATURE);
    const is_codestream = data[0] == 0xFF and data[1] == 0x0A;

    if (!is_container and !is_codestream) {
        return error.InvalidFormat;
    }

    if (is_container) {
        return decodeContainer(allocator, data);
    } else {
        return decodeCodestream(allocator, data);
    }
}

fn decodeContainer(allocator: std.mem.Allocator, data: []const u8) !Image {
    var pos: usize = 12; // Skip container signature

    // Collect codestream fragments
    var codestream_data = std.ArrayList(u8).init(allocator);
    defer codestream_data.deinit();

    while (pos + 8 <= data.len) {
        // Read box header
        var box_size = std.mem.readInt(u32, data[pos..][0..4], .big);
        const box_type = data[pos + 4 ..][0..4];
        pos += 8;

        var data_start = pos;
        var data_size: usize = 0;

        if (box_size == 1) {
            // Extended size (64-bit)
            if (pos + 8 > data.len) break;
            const extended_size = std.mem.readInt(u64, data[pos..][0..8], .big);
            pos += 8;
            data_start = pos;
            if (extended_size < 16) break;
            data_size = @intCast(extended_size - 16);
        } else if (box_size == 0) {
            // Box extends to end of file
            data_size = data.len - pos;
        } else {
            if (box_size < 8) break;
            data_size = box_size - 8;
        }

        if (data_start + data_size > data.len) {
            data_size = data.len - data_start;
        }

        // Handle box types
        if (std.mem.eql(u8, box_type, BOX_JXLC)) {
            // Complete codestream
            try codestream_data.appendSlice(data[data_start..][0..data_size]);
        } else if (std.mem.eql(u8, box_type, BOX_JXLP)) {
            // Partial codestream - skip 4-byte index
            if (data_size > 4) {
                try codestream_data.appendSlice(data[data_start + 4 ..][0 .. data_size - 4]);
            }
        }

        pos = data_start + data_size;
    }

    if (codestream_data.items.len == 0) {
        return error.InvalidFormat;
    }

    return decodeCodestream(allocator, codestream_data.items);
}

fn decodeCodestream(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 2) return error.TruncatedData;

    // Verify codestream signature
    if (data[0] != 0xFF or data[1] != 0x0A) {
        return error.InvalidFormat;
    }

    var reader = BitReader{ .data = data, .pos = 16 }; // Skip signature

    // Parse SizeHeader
    const size_header = try parseSizeHeader(&reader);

    // Validate dimensions
    if (size_header.width == 0 or size_header.height == 0) {
        return error.InvalidDimensions;
    }

    // Parse ImageMetadata
    const metadata = try parseImageMetadata(&reader);

    // Create output image
    const format: PixelFormat = if (metadata.has_alpha) .rgba8 else .rgb8;
    var img = try Image.init(allocator, size_header.width, size_header.height, format);
    errdefer img.deinit();

    // JXL uses complex entropy coding (ANS) and transforms
    // For now, create placeholder with gradient to show parsing worked
    // Full implementation would require ANS decoder and inverse transforms
    generatePlaceholder(&img, size_header.width, size_header.height);

    return img;
}

const SizeHeader = struct {
    width: u32,
    height: u32,
    is_small: bool,
};

fn parseSizeHeader(reader: *BitReader) !SizeHeader {
    // SizeHeader format (variable length)
    const div8 = reader.readBit() orelse return error.TruncatedData;

    var height: u32 = 0;
    var width: u32 = 0;

    if (div8) {
        // Small image: dimensions in 8-pixel units
        height = ((reader.readBits(5) orelse return error.TruncatedData) + 1) * 8;

        const ratio = reader.readBits(3) orelse return error.TruncatedData;
        if (ratio == 0) {
            width = ((reader.readBits(5) orelse return error.TruncatedData) + 1) * 8;
        } else {
            width = getWidthFromRatio(height, ratio);
        }
    } else {
        // Full size header
        height = (reader.readU32() orelse return error.TruncatedData) + 1;

        const ratio = reader.readBits(3) orelse return error.TruncatedData;
        if (ratio == 0) {
            width = (reader.readU32() orelse return error.TruncatedData) + 1;
        } else {
            width = getWidthFromRatio(height, ratio);
        }
    }

    return SizeHeader{
        .width = width,
        .height = height,
        .is_small = div8,
    };
}

fn getWidthFromRatio(height: u32, ratio: u32) u32 {
    return switch (ratio) {
        1 => height, // 1:1
        2 => (height * 12) / 10, // 1.2:1
        3 => (height * 4) / 3, // 4:3
        4 => (height * 3) / 2, // 3:2
        5 => (height * 16) / 9, // 16:9
        6 => (height * 5) / 4, // 5:4
        7 => (height * 2) / 1, // 2:1
        else => height,
    };
}

const ImageMetadata = struct {
    has_alpha: bool,
    bit_depth: u8,
    color_space: u8,
};

fn parseImageMetadata(reader: *BitReader) !ImageMetadata {
    // Default metadata
    var metadata = ImageMetadata{
        .has_alpha = false,
        .bit_depth = 8,
        .color_space = 0, // sRGB
    };

    // Check for non-default metadata
    const all_default = reader.readBit() orelse return metadata;
    if (all_default) {
        return metadata;
    }

    // Parse extra channels
    const extra_fields = reader.readBit() orelse return metadata;
    if (extra_fields) {
        // Has extra fields - check for alpha
        _ = reader.readBits(2); // orientation
        const has_intrinsic_size = reader.readBit() orelse return metadata;
        if (has_intrinsic_size) {
            _ = reader.readU32(); // intrinsic width
            _ = reader.readU32(); // intrinsic height
        }

        const has_preview = reader.readBit() orelse return metadata;
        if (has_preview) {
            _ = reader.readBit(); // div8
            _ = reader.readU32(); // preview width
            _ = reader.readU32(); // preview height
        }

        const has_animation = reader.readBit() orelse return metadata;
        if (has_animation) {
            _ = reader.readU32(); // ticks per second numerator
            _ = reader.readU32(); // denominator
            _ = reader.readU32(); // num loops
            _ = reader.readBit(); // have timecodes
        }
    }

    // Check for alpha
    const have_default_bit_depth = reader.readBit() orelse return metadata;
    if (!have_default_bit_depth) {
        // Custom bit depth
        const exp_bits = reader.readBits(4) orelse return metadata;
        _ = exp_bits;
        metadata.bit_depth = @intCast((reader.readBits(4) orelse return metadata) + 1);
    }

    // Check for extra channels (alpha)
    const num_extra = reader.readU32() orelse return metadata;
    if (num_extra > 0) {
        metadata.has_alpha = true;
    }

    return metadata;
}

fn generatePlaceholder(img: *Image, width: u32, height: u32) void {
    // Generate a gradient placeholder to indicate the format was recognized
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const r: u8 = @intCast((x * 255) / @max(1, width - 1));
            const g: u8 = @intCast((y * 255) / @max(1, height - 1));
            const b: u8 = 128;
            img.setPixel(x, y, Color{ .r = r, .g = g, .b = b, .a = 255 });
        }
    }
}

// ============================================================================
// Bit Reader Helper
// ============================================================================

const BitReader = struct {
    data: []const u8,
    pos: usize, // Bit position

    fn readBit(self: *BitReader) ?bool {
        const byte_pos = self.pos / 8;
        const bit_pos: u3 = @intCast(self.pos % 8);

        if (byte_pos >= self.data.len) return null;

        const bit = (self.data[byte_pos] >> bit_pos) & 1;
        self.pos += 1;
        return bit == 1;
    }

    fn readBits(self: *BitReader, n: u6) ?u32 {
        var result: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const bit = self.readBit() orelse return null;
            if (bit) {
                result |= @as(u32, 1) << i;
            }
        }
        return result;
    }

    fn readU32(self: *BitReader) ?u32 {
        // JXL U32 encoding
        const selector = self.readBits(2) orelse return null;

        return switch (selector) {
            0 => 0,
            1 => (self.readBits(4) orelse return null) + 1,
            2 => (self.readBits(8) orelse return null) + 17,
            3 => (self.readBits(12) orelse return null) + 273,
            else => null,
        };
    }
};

// ============================================================================
// JXL Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write container signature
    try output.appendSlice(&JXL_CONTAINER_SIGNATURE);

    // Create codestream
    var codestream = std.ArrayList(u8).init(allocator);
    defer codestream.deinit();

    // Write codestream signature
    try codestream.appendSlice(&JXL_CODESTREAM_SIGNATURE);

    // Write SizeHeader
    try writeSizeHeader(&codestream, img.width, img.height);

    // Write minimal ImageMetadata (all defaults)
    try codestream.append(1); // all_default = true

    // Write basic frame header
    try writeFrameHeader(&codestream, img);

    // Write pixel data (simplified - real JXL uses complex transforms)
    try writePixelData(&codestream, img);

    // Write codestream box
    try writeBox(&output, BOX_JXLC, codestream.items);

    return output.toOwnedSlice();
}

fn writeSizeHeader(output: *std.ArrayList(u8), width: u32, height: u32) !void {
    var bits = std.ArrayList(u8).init(output.allocator);
    defer bits.deinit();

    // Check if small image format can be used
    if (width % 8 == 0 and height % 8 == 0 and width <= 256 and height <= 256) {
        // Small format: div8 = 1
        var byte: u8 = 1; // div8 bit
        const h_val: u8 = @intCast((height / 8) - 1);
        byte |= h_val << 1;
        try bits.append(byte);

        // ratio = 0 (explicit width)
        var byte2: u8 = 0; // ratio bits
        const w_val: u8 = @intCast((width / 8) - 1);
        byte2 |= w_val << 3;
        try bits.append(byte2);
    } else {
        // Full format: div8 = 0
        try bits.append(0);

        // Write height as U32
        try writeU32(&bits, height - 1);

        // ratio = 0
        try bits.append(0);

        // Write width as U32
        try writeU32(&bits, width - 1);
    }

    try output.appendSlice(bits.items);
}

fn writeU32(output: *std.ArrayList(u8), value: u32) !void {
    if (value == 0) {
        try output.append(0); // selector = 0
    } else if (value <= 16) {
        try output.append(1); // selector = 1
        try output.append(@intCast(value - 1)); // 4 bits value
    } else if (value <= 272) {
        try output.append(2); // selector = 2
        try output.append(@intCast(value - 17)); // 8 bits value
    } else {
        try output.append(3); // selector = 3
        const v = value - 273;
        try output.append(@truncate(v)); // low 8 bits
        try output.append(@truncate(v >> 8)); // high 4 bits
    }
}

fn writeFrameHeader(output: *std.ArrayList(u8), img: *const Image) !void {
    _ = img;
    // Minimal frame header
    try output.append(0); // Regular frame, no special flags
}

fn writePixelData(output: *std.ArrayList(u8), img: *const Image) !void {
    // Simple uncompressed pixel data (placeholder)
    // Real JXL uses modular encoding, VarDCT, etc.
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const color = img.getPixel(x, y) orelse Color.BLACK;
            try output.append(color.r);
            try output.append(color.g);
            try output.append(color.b);
            if (img.format.hasAlpha()) {
                try output.append(color.a);
            }
        }
    }
}

fn writeBox(output: *std.ArrayList(u8), box_type: *const [4]u8, data: []const u8) !void {
    const box_size: u32 = @intCast(8 + data.len);

    // Box size
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, box_size)));

    // Box type
    try output.appendSlice(box_type);

    // Box data
    try output.appendSlice(data);
}

// ============================================================================
// Tests
// ============================================================================

test "JXL container signature" {
    try std.testing.expectEqual(@as(u8, 0x00), JXL_CONTAINER_SIGNATURE[0]);
    try std.testing.expectEqual(@as(u8, 0x4A), JXL_CONTAINER_SIGNATURE[4]); // 'J'
    try std.testing.expectEqual(@as(u8, 0x58), JXL_CONTAINER_SIGNATURE[5]); // 'X'
    try std.testing.expectEqual(@as(u8, 0x4C), JXL_CONTAINER_SIGNATURE[6]); // 'L'
}

test "JXL codestream signature" {
    try std.testing.expectEqual(@as(u8, 0xFF), JXL_CODESTREAM_SIGNATURE[0]);
    try std.testing.expectEqual(@as(u8, 0x0A), JXL_CODESTREAM_SIGNATURE[1]);
}

test "Width from ratio" {
    try std.testing.expectEqual(@as(u32, 100), getWidthFromRatio(100, 1)); // 1:1
    try std.testing.expectEqual(@as(u32, 120), getWidthFromRatio(100, 2)); // 1.2:1
    try std.testing.expectEqual(@as(u32, 177), getWidthFromRatio(100, 5)); // 16:9
}

test "BitReader" {
    const data = [_]u8{ 0b10110101, 0b11001010 };
    var reader = BitReader{ .data = &data, .pos = 0 };

    // Read first bit (LSB of first byte)
    try std.testing.expect(reader.readBit().? == true); // bit 0 = 1

    // Read next 3 bits
    const bits = reader.readBits(3).?;
    try std.testing.expectEqual(@as(u32, 0b010), bits); // bits 1-3 = 010
}
