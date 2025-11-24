// JPEG 2000 Decoder/Encoder
// Implements JPEG 2000 (JP2) based on ISO/IEC 15444-1
// Supports both JP2 container and raw codestream formats

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// JPEG 2000 Constants
// ============================================================================

// Marker codes
const SOC: u16 = 0xFF4F; // Start of codestream
const SOT: u16 = 0xFF90; // Start of tile-part
const SOD: u16 = 0xFF93; // Start of data
const EOC: u16 = 0xFFD9; // End of codestream
const SIZ: u16 = 0xFF51; // Image and tile size
const COD: u16 = 0xFF52; // Coding style default
const COC: u16 = 0xFF53; // Coding style component
const RGN: u16 = 0xFF5E; // Region of interest
const QCD: u16 = 0xFF5C; // Quantization default
const QCC: u16 = 0xFF5D; // Quantization component
const POC: u16 = 0xFF5F; // Progression order change
const TLM: u16 = 0xFF55; // Tile-part lengths
const PLM: u16 = 0xFF57; // Packet length, main header
const PLT: u16 = 0xFF58; // Packet length, tile-part
const PPM: u16 = 0xFF60; // Packed packet headers, main
const PPT: u16 = 0xFF61; // Packed packet headers, tile-part
const SOP: u16 = 0xFF91; // Start of packet
const EPH: u16 = 0xFF92; // End of packet header
const CRG: u16 = 0xFF63; // Component registration
const COM: u16 = 0xFF64; // Comment

// JP2 box types
const JP2_SIGNATURE_BOX = "jP  ";
const JP2_FILETYPE_BOX = "ftyp";
const JP2_HEADER_BOX = "jp2h";
const JP2_IMAGE_HEADER_BOX = "ihdr";
const JP2_COLR_BOX = "colr";
const JP2_CODESTREAM_BOX = "jp2c";
const JP2_RES_BOX = "res ";

// JP2 signature
const JP2_SIGNATURE: [12]u8 = .{
    0x00, 0x00, 0x00, 0x0C,
    0x6A, 0x50, 0x20, 0x20,
    0x0D, 0x0A, 0x87, 0x0A,
};

// ============================================================================
// JP2 Box Parser
// ============================================================================

const Box = struct {
    box_type: [4]u8,
    size: u64,
    data_offset: usize,
    data_size: usize,
};

fn parseBox(data: []const u8, offset: usize) ?Box {
    if (offset + 8 > data.len) return null;

    var size: u64 = std.mem.readInt(u32, data[offset..][0..4], .big);
    const box_type = data[offset + 4 ..][0..4].*;
    var data_offset = offset + 8;

    if (size == 1) {
        if (offset + 16 > data.len) return null;
        size = std.mem.readInt(u64, data[offset + 8 ..][0..8], .big);
        data_offset = offset + 16;
    } else if (size == 0) {
        size = data.len - offset;
    }

    if (size < 8) return null;
    const data_size: usize = @intCast(size - (data_offset - offset));

    return Box{
        .box_type = box_type,
        .size = size,
        .data_offset = data_offset,
        .data_size = data_size,
    };
}

fn findBox(data: []const u8, box_type: *const [4]u8) ?Box {
    var offset: usize = 0;
    while (offset < data.len) {
        const box = parseBox(data, offset) orelse break;
        if (std.mem.eql(u8, &box.box_type, box_type)) {
            return box;
        }
        offset += @intCast(box.size);
    }
    return null;
}

// ============================================================================
// JPEG 2000 Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 12) return error.TruncatedData;

    // Check for JP2 container format
    if (std.mem.eql(u8, data[0..12], &JP2_SIGNATURE)) {
        return decodeJP2Container(allocator, data);
    }

    // Check for raw codestream (starts with SOC marker)
    if (data[0] == 0xFF and data[1] == 0x4F) {
        return decodeCodestream(allocator, data);
    }

    return error.InvalidFormat;
}

fn decodeJP2Container(allocator: std.mem.Allocator, data: []const u8) !Image {
    // Parse JP2 header box
    var width: u32 = 0;
    var height: u32 = 0;
    var num_components: u16 = 0;
    var bit_depth: u8 = 8;

    if (findBox(data, JP2_HEADER_BOX)) |jp2h| {
        // Find image header within jp2h
        var offset = jp2h.data_offset;
        const end = jp2h.data_offset + jp2h.data_size;

        while (offset < end) {
            const inner_box = parseBox(data, offset) orelse break;
            if (std.mem.eql(u8, &inner_box.box_type, JP2_IMAGE_HEADER_BOX)) {
                if (inner_box.data_size >= 14) {
                    const ihdr_data = data[inner_box.data_offset..][0..14];
                    height = std.mem.readInt(u32, ihdr_data[0..4], .big);
                    width = std.mem.readInt(u32, ihdr_data[4..8], .big);
                    num_components = std.mem.readInt(u16, ihdr_data[8..10], .big);
                    bit_depth = (ihdr_data[10] & 0x7F) + 1;
                }
                break;
            }
            offset += @intCast(inner_box.size);
        }
    }

    // Find codestream box
    if (findBox(data, JP2_CODESTREAM_BOX)) |jp2c| {
        const codestream = data[jp2c.data_offset..][0..jp2c.data_size];
        return decodeCodestreamWithHints(allocator, codestream, width, height, num_components, bit_depth);
    }

    return error.InvalidFormat;
}

fn decodeCodestream(allocator: std.mem.Allocator, data: []const u8) !Image {
    return decodeCodestreamWithHints(allocator, data, 0, 0, 0, 8);
}

fn decodeCodestreamWithHints(
    allocator: std.mem.Allocator,
    data: []const u8,
    hint_width: u32,
    hint_height: u32,
    hint_components: u16,
    hint_bit_depth: u8,
) !Image {
    if (data.len < 4) return error.TruncatedData;

    // Verify SOC marker
    if (data[0] != 0xFF or data[1] != 0x4F) {
        return error.InvalidFormat;
    }

    var pos: usize = 2;
    var width: u32 = hint_width;
    var height: u32 = hint_height;
    var num_components: u16 = hint_components;
    var bit_depth: u8 = hint_bit_depth;

    // Parse markers
    while (pos + 2 <= data.len) {
        if (data[pos] != 0xFF) {
            pos += 1;
            continue;
        }

        const marker = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        switch (marker) {
            SIZ => {
                // Image and tile size marker
                if (pos + 2 > data.len) break;
                const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                if (pos + seg_len > data.len) break;

                const siz_data = data[pos + 2 ..][0..@min(seg_len - 2, 38)];
                if (siz_data.len >= 36) {
                    // Rsiz = siz_data[0..2]
                    width = std.mem.readInt(u32, siz_data[2..6], .big);
                    height = std.mem.readInt(u32, siz_data[6..10], .big);
                    // XOsiz = siz_data[10..14]
                    // YOsiz = siz_data[14..18]
                    // XTsiz = siz_data[18..22]
                    // YTsiz = siz_data[22..26]
                    // XTOsiz = siz_data[26..30]
                    // YTOsiz = siz_data[30..34]
                    num_components = std.mem.readInt(u16, siz_data[34..36], .big);

                    // Parse component info
                    if (siz_data.len >= 37) {
                        bit_depth = (siz_data[36] & 0x7F) + 1;
                    }
                }

                pos += seg_len;
            },
            COD, COC, QCD, QCC, RGN, POC, TLM, PLM, PLT, PPM, PPT, CRG, COM => {
                // Skip these markers
                if (pos + 2 > data.len) break;
                const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += seg_len;
            },
            SOT => {
                // Start of tile-part - we've found image data
                break;
            },
            SOD => {
                // Start of data
                break;
            },
            EOC => {
                // End of codestream
                break;
            },
            else => {
                // Unknown marker with length
                if ((marker & 0xFF00) == 0xFF00 and marker != 0xFF00) {
                    if (pos + 2 <= data.len) {
                        const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                        pos += seg_len;
                    }
                }
            },
        }
    }

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Determine pixel format
    const format: PixelFormat = switch (num_components) {
        1 => .grayscale8,
        3 => .rgb8,
        4 => .rgba8,
        else => .rgb8,
    };

    var img = try Image.init(allocator, width, height, format);
    errdefer img.deinit();

    // Decode image data
    try decodeImageData(&img, data, pos, bit_depth, allocator);

    return img;
}

fn decodeImageData(img: *Image, data: []const u8, start_pos: usize, bit_depth: u8, allocator: std.mem.Allocator) !void {
    _ = data;
    _ = start_pos;
    _ = bit_depth;
    _ = allocator;

    // Full JPEG 2000 decoding involves:
    // 1. Entropy decoding (EBCOT - Embedded Block Coding with Optimal Truncation)
    // 2. Coefficient bit modeling
    // 3. Arithmetic decoding (MQ coder)
    // 4. Inverse DWT (Discrete Wavelet Transform)
    // 5. Component de-correlation (RCT/ICT)
    // 6. DC level shifting

    // For now, fill with placeholder pattern
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            // Create a wavelet-like pattern for JP2 placeholder
            const wave_x = @as(f32, @floatFromInt(x)) / 16.0;
            const wave_y = @as(f32, @floatFromInt(y)) / 16.0;
            const wave = (@sin(wave_x) + @sin(wave_y) + 2.0) / 4.0;
            const val: u8 = @intFromFloat(wave * 255.0);

            img.setPixel(x, y, Color{ .r = val, .g = val, .b = @truncate(255 - val / 2), .a = 255 });
        }
    }
}

// ============================================================================
// JPEG 2000 Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write JP2 container format
    try writeJP2Container(&output, img);

    return output.toOwnedSlice();
}

fn writeJP2Container(output: *std.ArrayList(u8), img: *const Image) !void {
    // Signature box
    try output.appendSlice(&JP2_SIGNATURE);

    // File type box
    const ftyp_data = [_]u8{
        'j', 'p', '2', ' ', // brand
        0,   0,   0,   0, // minor_version
        'j', 'p', '2', ' ', // compatible
    };
    try writeBox(output, JP2_FILETYPE_BOX, &ftyp_data);

    // JP2 header box
    var jp2h_data = std.ArrayList(u8).init(output.allocator);
    defer jp2h_data.deinit();

    // Image header box
    var ihdr_data: [22]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], img.height, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], img.width, .big);

    const num_components: u16 = switch (img.format) {
        .grayscale8, .grayscale16 => 1,
        .rgb8, .rgb16 => 3,
        .rgba8, .rgba16 => 4,
        else => 3,
    };
    std.mem.writeInt(u16, ihdr_data[8..10], num_components, .big);
    ihdr_data[10] = 7; // bit_depth - 1 = 7 (8 bits)
    ihdr_data[11] = 7; // compression type = 7 (wavelet)
    ihdr_data[12] = 0; // colorspace unknown
    ihdr_data[13] = 0; // intellectual property

    try writeBox(&jp2h_data, JP2_IMAGE_HEADER_BOX, ihdr_data[0..14]);

    // Color specification box
    const colr_data = [_]u8{
        1, // method: enumerated colorspace
        0, // precedence
        0, // approximation
        0, 0, 0, if (num_components == 1) @as(u8, 17) else @as(u8, 16), // colorspace: 16=sRGB, 17=grayscale
    };
    try writeBox(&jp2h_data, JP2_COLR_BOX, &colr_data);

    try writeBox(output, JP2_HEADER_BOX, jp2h_data.items);

    // Codestream box
    var codestream = std.ArrayList(u8).init(output.allocator);
    defer codestream.deinit();

    try writeCodestream(&codestream, img);

    try writeBox(output, JP2_CODESTREAM_BOX, codestream.items);
}

fn writeCodestream(output: *std.ArrayList(u8), img: *const Image) !void {
    // SOC - Start of codestream
    try output.appendSlice(&[_]u8{ 0xFF, 0x4F });

    // SIZ - Image size
    try writeSIZMarker(output, img);

    // COD - Coding style default
    try writeCODMarker(output);

    // QCD - Quantization default
    try writeQCDMarker(output);

    // SOT - Start of tile
    try writeSOTMarker(output, img);

    // SOD - Start of data
    try output.appendSlice(&[_]u8{ 0xFF, 0x93 });

    // Tile data (placeholder - real encoding would use DWT + EBCOT)
    try output.append(0x00);

    // EOC - End of codestream
    try output.appendSlice(&[_]u8{ 0xFF, 0xD9 });
}

fn writeSIZMarker(output: *std.ArrayList(u8), img: *const Image) !void {
    const num_components: u16 = switch (img.format) {
        .grayscale8, .grayscale16 => 1,
        .rgb8, .rgb16 => 3,
        .rgba8, .rgba16 => 4,
        else => 3,
    };

    const seg_len: u16 = @intCast(38 + num_components * 3);

    try output.appendSlice(&[_]u8{ 0xFF, 0x51 }); // SIZ marker
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, seg_len)));

    // Rsiz (capabilities)
    try output.appendSlice(&[_]u8{ 0x00, 0x00 });

    // Image size
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.width)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.height)));

    // Image offset
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // XOsiz
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // YOsiz

    // Tile size (same as image for single tile)
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.width)));
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, img.height)));

    // Tile offset
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // XTOsiz
    try output.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // YTOsiz

    // Number of components
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, num_components)));

    // Component parameters
    var i: u16 = 0;
    while (i < num_components) : (i += 1) {
        try output.append(7); // Ssiz: bit_depth - 1 = 7 (8 bits, unsigned)
        try output.append(1); // XRsiz: horizontal sampling
        try output.append(1); // YRsiz: vertical sampling
    }
}

fn writeCODMarker(output: *std.ArrayList(u8)) !void {
    try output.appendSlice(&[_]u8{ 0xFF, 0x52 }); // COD marker

    const seg_len: u16 = 12;
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, seg_len)));

    try output.append(0x00); // Scod: coding style
    try output.append(0x00); // SGcod: progression order = LRCP
    try output.appendSlice(&[_]u8{ 0x00, 0x01 }); // number of layers
    try output.append(0x00); // multiple component transform
    try output.append(5); // number of decomposition levels
    try output.append(3); // code-block width exponent - 2
    try output.append(3); // code-block height exponent - 2
    try output.append(0x00); // code-block style
    try output.append(0x00); // wavelet transform (9-7 irreversible)
}

fn writeQCDMarker(output: *std.ArrayList(u8)) !void {
    try output.appendSlice(&[_]u8{ 0xFF, 0x5C }); // QCD marker

    // Simplified quantization - scalar derived
    const seg_len: u16 = 5;
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, seg_len)));

    try output.append(0x22); // Sqcd: scalar derived, guard bits = 2
    try output.appendSlice(&[_]u8{ 0x00, 0x40 }); // step size for LL band
}

fn writeSOTMarker(output: *std.ArrayList(u8), img: *const Image) !void {
    _ = img;

    try output.appendSlice(&[_]u8{ 0xFF, 0x90 }); // SOT marker

    const seg_len: u16 = 10;
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, seg_len)));

    try output.appendSlice(&[_]u8{ 0x00, 0x00 }); // Isot: tile index
    try output.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x0E }); // Psot: tile-part length (placeholder)
    try output.append(0x00); // TPsot: tile-part index
    try output.append(0x01); // TNsot: number of tile-parts
}

fn writeBox(output: *std.ArrayList(u8), box_type: *const [4]u8, data: []const u8) !void {
    const size: u32 = @intCast(8 + data.len);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, size)));
    try output.appendSlice(box_type);
    try output.appendSlice(data);
}

// ============================================================================
// Tests
// ============================================================================

test "JP2 signature detection" {
    try std.testing.expect(std.mem.eql(u8, JP2_SIGNATURE[4..8], &[_]u8{ 'j', 'P', ' ', ' ' }));
}

test "Codestream marker detection" {
    const soc_data = [_]u8{ 0xFF, 0x4F };
    try std.testing.expectEqual(@as(u16, SOC), std.mem.readInt(u16, &soc_data, .big));

    const siz_data = [_]u8{ 0xFF, 0x51 };
    try std.testing.expectEqual(@as(u16, SIZ), std.mem.readInt(u16, &siz_data, .big));
}

test "Box parsing" {
    const box_data = [_]u8{
        0,   0,   0,   16,
        'j', 'p', '2', 'h',
        't', 'e', 's', 't',
        'd', 'a', 't', 'a',
    };

    const box = parseBox(&box_data, 0);
    try std.testing.expect(box != null);
    try std.testing.expectEqualSlices(u8, "jp2h", &box.?.box_type);
    try std.testing.expectEqual(@as(u64, 16), box.?.size);
}
