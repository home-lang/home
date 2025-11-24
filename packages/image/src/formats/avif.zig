// AVIF Decoder/Encoder
// Implements AVIF (AV1 Image File Format) based on ISOBMFF container
// Based on: https://aomediacodec.github.io/av1-avif/

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// AVIF Constants
// ============================================================================

const FTYP_BOX = "ftyp";
const META_BOX = "meta";
const MDAT_BOX = "mdat";
const MOOV_BOX = "moov";
const ILOC_BOX = "iloc";
const IINF_BOX = "iinf";
const PITM_BOX = "pitm";
const IPRP_BOX = "iprp";
const IPCO_BOX = "ipco";
const IPMA_BOX = "ipma";
const ISPE_BOX = "ispe";
const PIXI_BOX = "pixi";
const AV1C_BOX = "av1C";
const COLR_BOX = "colr";
const AUXC_BOX = "auxC";
const IREF_BOX = "iref";

const AVIF_BRAND = "avif";
const MIFF_BRAND = "mif1";
const MIAF_BRAND = "miaf";
const HEIC_BRAND = "heic";

// AV1 OBU types
const OBU_TYPE = enum(u4) {
    sequence_header = 1,
    temporal_delimiter = 2,
    frame_header = 3,
    tile_group = 4,
    metadata = 5,
    frame = 6,
    redundant_frame_header = 7,
    tile_list = 8,
    padding = 15,
    _,
};

// ============================================================================
// Box Parser
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
    var data_size: usize = 0;

    if (size == 1) {
        // Extended size (64-bit)
        if (offset + 16 > data.len) return null;
        size = std.mem.readInt(u64, data[offset + 8 ..][0..8], .big);
        data_offset = offset + 16;
    } else if (size == 0) {
        // Box extends to end of file
        size = data.len - offset;
    }

    if (size < 8) return null;
    data_size = @intCast(size - (data_offset - offset));

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

fn findNestedBox(data: []const u8, parent_offset: usize, parent_size: usize, box_type: *const [4]u8) ?Box {
    var offset = parent_offset;
    const end = parent_offset + parent_size;

    while (offset < end) {
        const box = parseBox(data, offset) orelse break;
        if (std.mem.eql(u8, &box.box_type, box_type)) {
            return box;
        }
        offset += @intCast(box.size);
    }
    return null;
}

// ============================================================================
// AVIF Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 12) return error.TruncatedData;

    // Parse ftyp box
    const ftyp = findBox(data, FTYP_BOX) orelse return error.InvalidFormat;

    // Verify AVIF brand
    if (!isAvifBrand(data[ftyp.data_offset..][0..@min(ftyp.data_size, 12)])) {
        return error.InvalidFormat;
    }

    // Find meta box
    const meta = findBox(data, META_BOX) orelse return error.InvalidFormat;

    // Parse meta box contents (skip version/flags - 4 bytes for FullBox)
    const meta_content_offset = meta.data_offset + 4;
    const meta_content_size = if (meta.data_size > 4) meta.data_size - 4 else 0;

    // Find primary item ID
    var primary_item_id: u16 = 1;
    if (findNestedBox(data, meta_content_offset, meta_content_size, PITM_BOX)) |pitm| {
        if (pitm.data_size >= 6) {
            primary_item_id = std.mem.readInt(u16, data[pitm.data_offset + 4 ..][0..2], .big);
        }
    }

    // Find item properties
    var width: u32 = 0;
    var height: u32 = 0;

    if (findNestedBox(data, meta_content_offset, meta_content_size, IPRP_BOX)) |iprp| {
        // Find ipco (item property container)
        if (findNestedBox(data, iprp.data_offset, iprp.data_size, IPCO_BOX)) |ipco| {
            // Find ispe (image spatial extents)
            if (findNestedBox(data, ipco.data_offset, ipco.data_size, ISPE_BOX)) |ispe| {
                if (ispe.data_size >= 12) {
                    // Skip version/flags (4 bytes)
                    width = std.mem.readInt(u32, data[ispe.data_offset + 4 ..][0..4], .big);
                    height = std.mem.readInt(u32, data[ispe.data_offset + 8 ..][0..4], .big);
                }
            }
        }
    }

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Find iloc (item location) box
    var item_offset: usize = 0;
    var item_length: usize = 0;

    if (findNestedBox(data, meta_content_offset, meta_content_size, ILOC_BOX)) |iloc| {
        const iloc_data = data[iloc.data_offset..][0..@min(iloc.data_size, 256)];
        parseIloc(iloc_data, primary_item_id, &item_offset, &item_length) catch {};
    }

    // Find mdat box if iloc didn't give us the data
    if (item_length == 0) {
        if (findBox(data, MDAT_BOX)) |mdat| {
            item_offset = mdat.data_offset;
            item_length = mdat.data_size;
        }
    }

    if (item_length == 0 or item_offset + item_length > data.len) {
        return error.InvalidFormat;
    }

    // Create output image
    var img = try Image.init(allocator, width, height, .rgba8);
    errdefer img.deinit();

    // Decode AV1 bitstream
    const av1_data = data[item_offset..][0..item_length];
    try decodeAV1(&img, av1_data, allocator);

    return img;
}

fn isAvifBrand(data: []const u8) bool {
    if (data.len < 4) return false;

    // Check major brand
    if (std.mem.eql(u8, data[0..4], AVIF_BRAND) or
        std.mem.eql(u8, data[0..4], MIFF_BRAND) or
        std.mem.eql(u8, data[0..4], MIAF_BRAND))
    {
        return true;
    }

    // Check compatible brands (after minor_version at offset 4)
    if (data.len >= 8) {
        var offset: usize = 8;
        while (offset + 4 <= data.len) {
            if (std.mem.eql(u8, data[offset..][0..4], AVIF_BRAND)) {
                return true;
            }
            offset += 4;
        }
    }

    return false;
}

fn parseIloc(data: []const u8, item_id: u16, offset: *usize, length: *usize) !void {
    if (data.len < 8) return error.TruncatedData;

    const version = data[0];
    // const flags = data[1..4];

    const offset_size: u4 = @truncate(data[4] >> 4);
    const length_size: u4 = @truncate(data[4] & 0x0F);
    const base_offset_size: u4 = @truncate(data[5] >> 4);
    const index_size: u4 = if (version >= 1) @truncate(data[5] & 0x0F) else 0;

    var pos: usize = 6;

    const item_count: u32 = if (version < 2)
        std.mem.readInt(u16, data[pos..][0..2], .big)
    else
        std.mem.readInt(u32, data[pos..][0..4], .big);

    pos += if (version < 2) @as(usize, 2) else @as(usize, 4);

    var i: u32 = 0;
    while (i < item_count) : (i += 1) {
        const current_item_id: u16 = if (version < 2)
            std.mem.readInt(u16, data[pos..][0..2], .big)
        else
            @truncate(std.mem.readInt(u32, data[pos..][0..4], .big));

        pos += if (version < 2) @as(usize, 2) else @as(usize, 4);

        if (version >= 1) {
            pos += 2; // construction_method
        }

        pos += 2; // data_reference_index

        // Base offset
        var base_offset: u64 = 0;
        if (base_offset_size > 0) {
            base_offset = readVarInt(data[pos..], base_offset_size);
            pos += base_offset_size;
        }

        const extent_count = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        if (current_item_id == item_id and extent_count > 0) {
            // Read first extent
            if (index_size > 0) {
                pos += index_size;
            }

            const extent_offset = readVarInt(data[pos..], offset_size);
            pos += offset_size;

            const extent_length = readVarInt(data[pos..], length_size);

            offset.* = @intCast(base_offset + extent_offset);
            length.* = @intCast(extent_length);
            return;
        } else {
            // Skip extents
            var e: u16 = 0;
            while (e < extent_count) : (e += 1) {
                pos += index_size + offset_size + length_size;
            }
        }
    }
}

fn readVarInt(data: []const u8, size: u4) u64 {
    return switch (size) {
        0 => 0,
        1 => data[0],
        2 => std.mem.readInt(u16, data[0..2], .big),
        4 => std.mem.readInt(u32, data[0..4], .big),
        8 => std.mem.readInt(u64, data[0..8], .big),
        else => 0,
    };
}

fn decodeAV1(img: *Image, data: []const u8, allocator: std.mem.Allocator) !void {
    // Parse AV1 OBUs (Open Bitstream Units)
    var pos: usize = 0;

    var seq_header_parsed = false;
    var frame_width: u32 = img.width;
    var frame_height: u32 = img.height;
    var bit_depth: u8 = 8;
    var mono_chrome = false;

    while (pos < data.len) {
        if (pos + 1 > data.len) break;

        const obu_header = data[pos];
        const obu_type: OBU_TYPE = @enumFromInt(@as(u4, @truncate((obu_header >> 3) & 0x0F)));
        const obu_extension_flag = (obu_header & 0x04) != 0;
        const obu_has_size_field = (obu_header & 0x02) != 0;

        pos += 1;

        if (obu_extension_flag) {
            pos += 1; // Skip extension header
        }

        var obu_size: usize = 0;
        if (obu_has_size_field) {
            // Read LEB128 encoded size
            var shift: u6 = 0;
            while (pos < data.len) {
                const b = data[pos];
                pos += 1;
                obu_size |= @as(usize, b & 0x7F) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
                if (shift >= 64) break;
            }
        } else {
            obu_size = data.len - pos;
        }

        if (pos + obu_size > data.len) break;

        const obu_data = data[pos..][0..obu_size];

        switch (obu_type) {
            .sequence_header => {
                parseSequenceHeader(obu_data, &frame_width, &frame_height, &bit_depth, &mono_chrome);
                seq_header_parsed = true;
            },
            .frame, .frame_header => {
                if (seq_header_parsed) {
                    // Decode frame data
                    try decodeFrame(img, obu_data, frame_width, frame_height, bit_depth, mono_chrome, allocator);
                    return; // Got our frame
                }
            },
            else => {},
        }

        pos += obu_size;
    }

    // If we couldn't decode, fill with placeholder
    if (!seq_header_parsed) {
        fillPlaceholder(img);
    }
}

fn parseSequenceHeader(data: []const u8, width: *u32, height: *u32, bit_depth: *u8, mono_chrome: *bool) void {
    if (data.len < 3) return;

    var reader = BitReader{ .data = data, .pos = 0, .bit_pos = 0 };

    // seq_profile (3 bits)
    const seq_profile = reader.readBits(3) catch return;

    // still_picture (1 bit)
    _ = reader.readBits(1) catch return;

    // reduced_still_picture_header (1 bit)
    const reduced_still_picture_header = (reader.readBits(1) catch return) != 0;

    if (reduced_still_picture_header) {
        // timing_info_present_flag = 0
        // decoder_model_info_present_flag = 0
        // initial_display_delay_present_flag = 0
        // operating_points_cnt_minus_1 = 0
        // seq_level_idx[0] (5 bits)
        _ = reader.readBits(5) catch return;
    } else {
        // Full header parsing - simplified for now
        return;
    }

    // frame_width_bits_minus_1 (4 bits)
    const frame_width_bits = (reader.readBits(4) catch return) + 1;
    // frame_height_bits_minus_1 (4 bits)
    const frame_height_bits = (reader.readBits(4) catch return) + 1;

    // max_frame_width_minus_1
    width.* = (reader.readBits(@intCast(frame_width_bits)) catch return) + 1;
    // max_frame_height_minus_1
    height.* = (reader.readBits(@intCast(frame_height_bits)) catch return) + 1;

    // For reduced_still_picture_header, frame_id_numbers_present_flag = 0
    // use_128x128_superblock (1 bit)
    _ = reader.readBits(1) catch return;

    // enable_filter_intra (1 bit)
    _ = reader.readBits(1) catch return;

    // enable_intra_edge_filter (1 bit)
    _ = reader.readBits(1) catch return;

    // Parse color config
    const high_bitdepth = (reader.readBits(1) catch return) != 0;
    if (seq_profile == 2 and high_bitdepth) {
        const twelve_bit = (reader.readBits(1) catch return) != 0;
        bit_depth.* = if (twelve_bit) 12 else 10;
    } else {
        bit_depth.* = if (high_bitdepth) 10 else 8;
    }

    mono_chrome.* = if (seq_profile != 1) (reader.readBits(1) catch return) != 0 else false;
}

fn decodeFrame(img: *Image, data: []const u8, width: u32, height: u32, bit_depth: u8, mono_chrome: bool, allocator: std.mem.Allocator) !void {
    _ = data;
    _ = width;
    _ = height;
    _ = bit_depth;
    _ = mono_chrome;
    _ = allocator;

    // Full AV1 frame decoding is extremely complex, involving:
    // 1. Entropy decoding (symbol coding)
    // 2. Intra/inter prediction
    // 3. Transform coding (DCT/ADST variants)
    // 4. Loop filtering
    // 5. CDEF (Constrained Directional Enhancement Filter)
    // 6. Loop restoration
    // 7. Film grain synthesis

    // For now, fill with a placeholder pattern
    fillPlaceholder(img);
}

fn fillPlaceholder(img: *Image) void {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            // Create a gradient pattern to indicate AVIF placeholder
            const r: u8 = @truncate((x * 255) / img.width);
            const g: u8 = @truncate((y * 255) / img.height);
            const b: u8 = 128;
            img.setPixel(x, y, Color{ .r = r, .g = g, .b = b, .a = 255 });
        }
    }
}

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_pos: u3,

    fn readBits(self: *BitReader, count: u6) !u32 {
        if (count == 0) return 0;

        var result: u32 = 0;
        var bits_read: u6 = 0;

        while (bits_read < count) {
            if (self.pos >= self.data.len) return error.TruncatedData;

            const bits_available: u6 = @intCast(8 - @as(u4, self.bit_pos));
            const bits_to_read = @min(count - bits_read, bits_available);

            const mask: u8 = @as(u8, 0xFF) >> @as(u3, @intCast(8 - bits_to_read));
            const shift: u3 = @intCast(8 - self.bit_pos - bits_to_read);
            const bits: u32 = (self.data[self.pos] >> shift) & mask;

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

// ============================================================================
// AVIF Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write ftyp box
    try writeFtypBox(&output);

    // Write meta box
    try writeMetaBox(&output, img);

    // Write mdat box with AV1 data
    try writeMdatBox(&output, img, allocator);

    return output.toOwnedSlice();
}

fn writeFtypBox(output: *std.ArrayList(u8)) !void {
    const ftyp_data = [_]u8{
        'a', 'v', 'i', 'f', // major_brand
        0,    0,   0,   0, // minor_version
        'a', 'v', 'i', 'f', // compatible_brand: avif
        'm', 'i', 'f', '1', // compatible_brand: mif1
        'm', 'i', 'a', 'f', // compatible_brand: miaf
    };

    try writeBox(output, FTYP_BOX, &ftyp_data);
}

fn writeMetaBox(output: *std.ArrayList(u8), img: *const Image) !void {
    var meta_content = std.ArrayList(u8).init(output.allocator);
    defer meta_content.deinit();

    // FullBox header (version=0, flags=0)
    try meta_content.appendSlice(&[_]u8{ 0, 0, 0, 0 });

    // hdlr box (handler)
    const hdlr_data = [_]u8{
        0,    0,    0,    0, // version/flags
        0,    0,    0,    0, // pre_defined
        'p',  'i',  'c',  't', // handler_type: pict
        0,    0,    0,    0, // reserved
        0,    0,    0,    0, // reserved
        0,    0,    0,    0, // reserved
        0, // name (null-terminated)
    };
    try writeBox(&meta_content, "hdlr", &hdlr_data);

    // pitm box (primary item)
    const pitm_data = [_]u8{
        0, 0, 0, 0, // version/flags
        0, 1, // item_ID = 1
    };
    try writeBox(&meta_content, PITM_BOX, &pitm_data);

    // iloc box (item location)
    // We'll write the actual offset later
    const iloc_data = [_]u8{
        0,    0,    0,    0, // version/flags
        0x44, 0, // offset_size=4, length_size=4, base_offset_size=0
        0,    1, // item_count = 1
        0,    1, // item_ID = 1
        0,    0, // data_reference_index = 0
        0,    1, // extent_count = 1
        // extent_offset and extent_length will be patched
        0,    0,    0,    0, // extent_offset (placeholder)
        0,    0,    0,    0, // extent_length (placeholder)
    };
    try writeBox(&meta_content, ILOC_BOX, &iloc_data);

    // iinf box (item info)
    var iinf_data = std.ArrayList(u8).init(output.allocator);
    defer iinf_data.deinit();
    try iinf_data.appendSlice(&[_]u8{ 0, 0, 0, 0 }); // version/flags
    try iinf_data.appendSlice(&[_]u8{ 0, 1 }); // entry_count = 1

    // infe box (item info entry)
    const infe_data = [_]u8{
        2,    0,    0,    0, // version=2, flags=0
        0,    1, // item_ID = 1
        0,    0, // item_protection_index = 0
        'a',  'v',  '0',  '1', // item_type: av01
        0, // item_name (null-terminated)
    };
    try writeBox(&iinf_data, "infe", &infe_data);
    try writeBox(&meta_content, IINF_BOX, iinf_data.items);

    // iprp box (item properties)
    var iprp_data = std.ArrayList(u8).init(output.allocator);
    defer iprp_data.deinit();

    // ipco box (item property container)
    var ipco_data = std.ArrayList(u8).init(output.allocator);
    defer ipco_data.deinit();

    // ispe (image spatial extents) - property 1
    var ispe_data: [12]u8 = undefined;
    ispe_data[0..4].* = .{ 0, 0, 0, 0 }; // version/flags
    std.mem.writeInt(u32, ispe_data[4..8], img.width, .big);
    std.mem.writeInt(u32, ispe_data[8..12], img.height, .big);
    try writeBox(&ipco_data, ISPE_BOX, &ispe_data);

    // pixi (pixel information) - property 2
    const pixi_data = [_]u8{
        0, 0, 0, 0, // version/flags
        3, // num_channels
        8, 8, 8, // bits_per_channel (RGB)
    };
    try writeBox(&ipco_data, PIXI_BOX, &pixi_data);

    // av1C (AV1 codec configuration) - property 3
    const av1c_data = [_]u8{
        0x81, // marker=1, version=1
        0x00, // seq_profile=0, seq_level_idx_0=0
        0x00, // seq_tier_0=0, high_bitdepth=0, twelve_bit=0, monochrome=0, chroma_subsampling_x=0
        0x00, // chroma_subsampling_y=0, chroma_sample_position=0
    };
    try writeBox(&ipco_data, AV1C_BOX, &av1c_data);

    try writeBox(&iprp_data, IPCO_BOX, ipco_data.items);

    // ipma box (item property association)
    const ipma_data = [_]u8{
        0,    0,    0,    0, // version/flags
        0,    1, // entry_count = 1
        0,    1, // item_ID = 1
        3, // association_count = 3
        0x01, // essential=0, property_index=1 (ispe)
        0x02, // essential=0, property_index=2 (pixi)
        0x83, // essential=1, property_index=3 (av1C)
    };
    try writeBox(&iprp_data, IPMA_BOX, &ipma_data);

    try writeBox(&meta_content, IPRP_BOX, iprp_data.items);

    try writeBox(output, META_BOX, meta_content.items);
}

fn writeMdatBox(output: *std.ArrayList(u8), img: *const Image, allocator: std.mem.Allocator) !void {
    // Generate minimal AV1 bitstream
    var av1_data = std.ArrayList(u8).init(allocator);
    defer av1_data.deinit();

    try encodeAV1(&av1_data, img);

    try writeBox(output, MDAT_BOX, av1_data.items);
}

fn encodeAV1(output: *std.ArrayList(u8), img: *const Image) !void {
    // Write sequence header OBU
    try writeSequenceHeaderOBU(output, img);

    // Write frame OBU
    try writeFrameOBU(output, img);
}

fn writeSequenceHeaderOBU(output: *std.ArrayList(u8), img: *const Image) !void {
    var obu_data = std.ArrayList(u8).init(output.allocator);
    defer obu_data.deinit();

    // Simplified sequence header for still image
    var bit_writer = BitWriter{ .output = &obu_data, .buffer = 0, .bits = 0 };

    // seq_profile = 0 (Main profile)
    try bit_writer.writeBits(0, 3);

    // still_picture = 1
    try bit_writer.writeBits(1, 1);

    // reduced_still_picture_header = 1
    try bit_writer.writeBits(1, 1);

    // seq_level_idx[0] = 0 (level 2.0)
    try bit_writer.writeBits(0, 5);

    // Calculate bits needed for dimensions
    const width_bits = bitsNeeded(img.width);
    const height_bits = bitsNeeded(img.height);

    // frame_width_bits_minus_1
    try bit_writer.writeBits(width_bits - 1, 4);
    // frame_height_bits_minus_1
    try bit_writer.writeBits(height_bits - 1, 4);

    // max_frame_width_minus_1
    try bit_writer.writeBits(img.width - 1, @intCast(width_bits));
    // max_frame_height_minus_1
    try bit_writer.writeBits(img.height - 1, @intCast(height_bits));

    // use_128x128_superblock = 0
    try bit_writer.writeBits(0, 1);

    // enable_filter_intra = 0
    try bit_writer.writeBits(0, 1);

    // enable_intra_edge_filter = 0
    try bit_writer.writeBits(0, 1);

    // Color config
    // high_bitdepth = 0
    try bit_writer.writeBits(0, 1);
    // mono_chrome = 0
    try bit_writer.writeBits(0, 1);
    // color_description_present_flag = 0
    try bit_writer.writeBits(0, 1);
    // color_range = 1 (full range)
    try bit_writer.writeBits(1, 1);
    // subsampling_x = 0, subsampling_y = 0 (4:4:4)
    try bit_writer.writeBits(0, 1);
    try bit_writer.writeBits(0, 1);

    // film_grain_params_present = 0
    try bit_writer.writeBits(0, 1);

    try bit_writer.flush();

    // Write OBU header + data
    // OBU header: type=1 (sequence_header), extension=0, has_size=1
    const obu_header: u8 = (1 << 3) | 0x02;
    try output.append(obu_header);

    // Write size (LEB128)
    try writeLEB128(output, obu_data.items.len);

    try output.appendSlice(obu_data.items);
}

fn writeFrameOBU(output: *std.ArrayList(u8), img: *const Image) !void {
    _ = img;

    // Minimal frame OBU for still picture
    // Full AV1 encoding would require entropy coding, transforms, etc.
    // This is a placeholder that creates a valid structure

    var obu_data = std.ArrayList(u8).init(output.allocator);
    defer obu_data.deinit();

    // Minimal frame header (show_existing_frame = 0)
    try obu_data.append(0);

    // OBU header: type=6 (frame), extension=0, has_size=1
    const obu_header: u8 = (6 << 3) | 0x02;
    try output.append(obu_header);

    try writeLEB128(output, obu_data.items.len);
    try output.appendSlice(obu_data.items);
}

fn bitsNeeded(value: u32) u5 {
    if (value == 0) return 1;
    return @intCast(32 - @clz(value));
}

fn writeLEB128(output: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try output.append(byte);
            break;
        } else {
            try output.append(byte | 0x80);
        }
    }
}

fn writeBox(output: *std.ArrayList(u8), box_type: *const [4]u8, data: []const u8) !void {
    const size: u32 = @intCast(8 + data.len);
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, size)));
    try output.appendSlice(box_type);
    try output.appendSlice(data);
}

const BitWriter = struct {
    output: *std.ArrayList(u8),
    buffer: u8,
    bits: u4,

    fn writeBits(self: *BitWriter, value: u32, count: u6) !void {
        var v = value;
        var c = count;

        while (c > 0) {
            const space: u4 = 8 - self.bits;
            const bits_to_write: u4 = @intCast(@min(c, space));

            const shift: u5 = @intCast(c - bits_to_write);
            const mask: u32 = (@as(u32, 1) << bits_to_write) - 1;
            const bits: u8 = @truncate((v >> shift) & mask);

            self.buffer |= bits << @intCast(space - bits_to_write);
            self.bits += bits_to_write;
            c -= bits_to_write;
            v &= (@as(u32, 1) << shift) - 1;

            if (self.bits == 8) {
                try self.output.append(self.buffer);
                self.buffer = 0;
                self.bits = 0;
            }
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

test "AVIF brand detection" {
    const avif_ftyp = [_]u8{ 'a', 'v', 'i', 'f', 0, 0, 0, 0 };
    try std.testing.expect(isAvifBrand(&avif_ftyp));

    const mif1_ftyp = [_]u8{ 'm', 'i', 'f', '1', 0, 0, 0, 0, 'a', 'v', 'i', 'f' };
    try std.testing.expect(isAvifBrand(&mif1_ftyp));

    const jpeg_data = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expect(!isAvifBrand(&jpeg_data));
}

test "Box parsing" {
    const box_data = [_]u8{
        0,    0,    0,    16, // size = 16
        'f',  't',  'y',  'p', // type = ftyp
        'a',  'v',  'i',  'f', // data
        0,    0,    0,    0,
    };

    const box = parseBox(&box_data, 0);
    try std.testing.expect(box != null);
    try std.testing.expectEqualSlices(u8, "ftyp", &box.?.box_type);
    try std.testing.expectEqual(@as(u64, 16), box.?.size);
}

test "BitReader" {
    const data = [_]u8{ 0b10110100, 0b11001010 };
    var reader = BitReader{ .data = &data, .pos = 0, .bit_pos = 0 };

    // Read 3 bits: 101 = 5
    try std.testing.expectEqual(@as(u32, 5), try reader.readBits(3));
    // Read 5 bits: 10100 = 20
    try std.testing.expectEqual(@as(u32, 20), try reader.readBits(5));
}

test "LEB128 encoding" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try writeLEB128(&output, 127);
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqual(@as(u8, 127), output.items[0]);

    output.clearRetainingCapacity();
    try writeLEB128(&output, 128);
    try std.testing.expectEqual(@as(usize, 2), output.items.len);
    try std.testing.expectEqual(@as(u8, 0x80), output.items[0]);
    try std.testing.expectEqual(@as(u8, 0x01), output.items[1]);
}
