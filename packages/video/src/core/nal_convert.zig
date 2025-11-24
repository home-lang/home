// Home Video Library - NAL Unit Bitstream Conversion
// Convert between Annex B and length-prefixed NAL unit formats

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// NAL Formats
// ============================================================================

pub const NalFormat = enum {
    annex_b, // Start code prefixed (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
    avcc, // Length-prefixed (used in MP4 for H.264)
    hvcc, // Length-prefixed (used in MP4 for H.265/HEVC)
    vvcc, // Length-prefixed (used in MP4 for H.266/VVC)
};

pub const CodecType = enum {
    h264, // AVC - 1-byte NAL header
    h265, // HEVC - 2-byte NAL header
    h266, // VVC - 2-byte NAL header
};

// ============================================================================
// NAL Unit Types
// ============================================================================

pub const NalUnit = struct {
    data: []const u8, // NAL unit data without start code/length prefix
    nal_type: u8, // NAL unit type
    temporal_id: u8 = 0, // For HEVC/VVC
    layer_id: u8 = 0, // For HEVC/VVC

    /// Get the NAL type from the first byte(s)
    pub fn getNalType(data: []const u8, codec: CodecType) u8 {
        if (data.len == 0) return 0;

        return switch (codec) {
            .h264 => data[0] & 0x1F,
            .h265 => (data[0] >> 1) & 0x3F,
            .h266 => if (data.len >= 2) (data[1] >> 3) & 0x1F else 0,
        };
    }

    /// Check if this NAL is a VCL (video coding layer) NAL
    pub fn isVcl(self: *const NalUnit, codec: CodecType) bool {
        return switch (codec) {
            .h264 => self.nal_type >= 1 and self.nal_type <= 5,
            .h265 => self.nal_type <= 31, // VCL NALs are 0-31
            .h266 => self.nal_type <= 12, // VCL NALs for VVC
        };
    }

    /// Check if this NAL is a parameter set (SPS/PPS/VPS)
    pub fn isParameterSet(self: *const NalUnit, codec: CodecType) bool {
        return switch (codec) {
            .h264 => self.nal_type == 7 or self.nal_type == 8, // SPS, PPS
            .h265 => self.nal_type >= 32 and self.nal_type <= 34, // VPS, SPS, PPS
            .h266 => self.nal_type >= 14 and self.nal_type <= 16, // VPS, SPS, PPS
        };
    }

    /// Check if this NAL is an IDR/IRAP picture
    pub fn isKeyFrame(self: *const NalUnit, codec: CodecType) bool {
        return switch (codec) {
            .h264 => self.nal_type == 5, // IDR
            .h265 => self.nal_type >= 16 and self.nal_type <= 21, // BLA, IDR, CRA
            .h266 => self.nal_type >= 7 and self.nal_type <= 9, // IDR_W_RADL, IDR_N_LP, CRA
        };
    }
};

// ============================================================================
// Annex B Parsing
// ============================================================================

/// Parse NAL units from Annex B format
pub fn parseAnnexB(data: []const u8, allocator: Allocator) !std.ArrayListUnmanaged(NalUnit) {
    var nals: std.ArrayListUnmanaged(NalUnit) = .empty;
    errdefer nals.deinit(allocator);

    var i: usize = 0;

    while (i < data.len) {
        // Find start code
        const start = findStartCode(data[i..]);
        if (start == null) break;

        const nal_start = i + start.?.offset + start.?.length;
        i = nal_start;

        // Find end of NAL (next start code or end of data)
        var nal_end = data.len;
        var j = nal_start;
        while (j < data.len) {
            if (findStartCode(data[j..])) |next| {
                nal_end = j + next.offset;
                break;
            }
            j += 1;
        }

        if (nal_start < nal_end) {
            const nal_data = data[nal_start..nal_end];
            try nals.append(allocator, .{
                .data = nal_data,
                .nal_type = if (nal_data.len > 0) nal_data[0] & 0x1F else 0,
            });
        }

        i = nal_end;
    }

    return nals;
}

const StartCode = struct {
    offset: usize,
    length: usize, // 3 or 4
};

fn findStartCode(data: []const u8) ?StartCode {
    if (data.len < 3) return null;

    var i: usize = 0;
    while (i + 2 < data.len) {
        if (data[i] == 0 and data[i + 1] == 0) {
            // Check for 4-byte start code (0x00000001)
            if (i + 3 < data.len and data[i + 2] == 0 and data[i + 3] == 1) {
                return .{ .offset = i, .length = 4 };
            }
            // Check for 3-byte start code (0x000001)
            if (data[i + 2] == 1) {
                return .{ .offset = i, .length = 3 };
            }
        }
        i += 1;
    }

    return null;
}

// ============================================================================
// Length-Prefixed Parsing
// ============================================================================

/// Parse NAL units from length-prefixed format (AVCC/HVCC/VVCC)
pub fn parseLengthPrefixed(
    data: []const u8,
    length_size: u8, // 1, 2, or 4 bytes
    allocator: Allocator,
) !std.ArrayListUnmanaged(NalUnit) {
    var nals: std.ArrayListUnmanaged(NalUnit) = .empty;
    errdefer nals.deinit(allocator);

    var i: usize = 0;

    while (i + length_size <= data.len) {
        // Read NAL length
        const nal_length: usize = switch (length_size) {
            1 => data[i],
            2 => std.mem.readInt(u16, data[i..][0..2], .big),
            4 => std.mem.readInt(u32, data[i..][0..4], .big),
            else => return error.InvalidLengthSize,
        };

        i += length_size;

        if (i + nal_length > data.len) {
            return error.TruncatedNal;
        }

        const nal_data = data[i..][0..nal_length];
        try nals.append(allocator, .{
            .data = nal_data,
            .nal_type = if (nal_data.len > 0) nal_data[0] & 0x1F else 0,
        });

        i += nal_length;
    }

    return nals;
}

// ============================================================================
// Conversion Functions
// ============================================================================

/// Convert from Annex B to length-prefixed format
pub fn annexBToLengthPrefixed(
    data: []const u8,
    length_size: u8,
    allocator: Allocator,
) ![]u8 {
    var nals = try parseAnnexB(data, allocator);
    defer nals.deinit(allocator);

    // Calculate output size
    var output_size: usize = 0;
    for (nals.items) |nal| {
        output_size += length_size + nal.data.len;
    }

    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    // Write NALs with length prefix
    var offset: usize = 0;
    for (nals.items) |nal| {
        const len: u32 = @intCast(nal.data.len);
        switch (length_size) {
            1 => {
                if (len > 255) return error.NalTooLarge;
                output[offset] = @truncate(len);
            },
            2 => {
                if (len > 65535) return error.NalTooLarge;
                std.mem.writeInt(u16, output[offset..][0..2], @truncate(len), .big);
            },
            4 => {
                std.mem.writeInt(u32, output[offset..][0..4], len, .big);
            },
            else => return error.InvalidLengthSize,
        }
        offset += length_size;

        @memcpy(output[offset..][0..nal.data.len], nal.data);
        offset += nal.data.len;
    }

    return output;
}

/// Convert from length-prefixed to Annex B format
pub fn lengthPrefixedToAnnexB(
    data: []const u8,
    length_size: u8,
    use_long_start_code: bool, // Use 4-byte start code instead of 3-byte
    allocator: Allocator,
) ![]u8 {
    var nals = try parseLengthPrefixed(data, length_size, allocator);
    defer nals.deinit(allocator);

    const start_code_len: usize = if (use_long_start_code) 4 else 3;

    // Calculate output size
    var output_size: usize = 0;
    for (nals.items) |nal| {
        output_size += start_code_len + nal.data.len;
    }

    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    // Write NALs with start codes
    var offset: usize = 0;
    for (nals.items) |nal| {
        // Write start code
        if (use_long_start_code) {
            output[offset] = 0x00;
            output[offset + 1] = 0x00;
            output[offset + 2] = 0x00;
            output[offset + 3] = 0x01;
            offset += 4;
        } else {
            output[offset] = 0x00;
            output[offset + 1] = 0x00;
            output[offset + 2] = 0x01;
            offset += 3;
        }

        @memcpy(output[offset..][0..nal.data.len], nal.data);
        offset += nal.data.len;
    }

    return output;
}

/// Convert between length prefix sizes
pub fn convertLengthSize(
    data: []const u8,
    src_length_size: u8,
    dst_length_size: u8,
    allocator: Allocator,
) ![]u8 {
    if (src_length_size == dst_length_size) {
        const output = try allocator.alloc(u8, data.len);
        @memcpy(output, data);
        return output;
    }

    var nals = try parseLengthPrefixed(data, src_length_size, allocator);
    defer nals.deinit(allocator);

    // Calculate output size
    var output_size: usize = 0;
    for (nals.items) |nal| {
        output_size += dst_length_size + nal.data.len;
    }

    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    // Write with new length size
    var offset: usize = 0;
    for (nals.items) |nal| {
        const len: u32 = @intCast(nal.data.len);
        switch (dst_length_size) {
            1 => {
                if (len > 255) return error.NalTooLarge;
                output[offset] = @truncate(len);
            },
            2 => {
                if (len > 65535) return error.NalTooLarge;
                std.mem.writeInt(u16, output[offset..][0..2], @truncate(len), .big);
            },
            4 => {
                std.mem.writeInt(u32, output[offset..][0..4], len, .big);
            },
            else => return error.InvalidLengthSize,
        }
        offset += dst_length_size;

        @memcpy(output[offset..][0..nal.data.len], nal.data);
        offset += nal.data.len;
    }

    return output;
}

// ============================================================================
// Emulation Prevention
// ============================================================================

/// Remove emulation prevention bytes (0x03 after 0x0000)
pub fn removeEmulationPrevention(data: []const u8, allocator: Allocator) ![]u8 {
    // Count bytes needed
    var count: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (i + 2 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 3) {
            count += 2;
            i += 3;
        } else {
            count += 1;
            i += 1;
        }
    }

    const output = try allocator.alloc(u8, count);
    errdefer allocator.free(output);

    var out_idx: usize = 0;
    i = 0;
    while (i < data.len) {
        if (i + 2 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 3) {
            output[out_idx] = 0;
            output[out_idx + 1] = 0;
            out_idx += 2;
            i += 3;
        } else {
            output[out_idx] = data[i];
            out_idx += 1;
            i += 1;
        }
    }

    return output;
}

/// Add emulation prevention bytes where needed
pub fn addEmulationPrevention(data: []const u8, allocator: Allocator) ![]u8 {
    // Count bytes needed (pessimistic)
    var count: usize = data.len;
    var i: usize = 0;
    while (i + 1 < data.len) {
        if (data[i] == 0 and data[i + 1] == 0) {
            if (i + 2 < data.len and data[i + 2] <= 3) {
                count += 1;
            }
        }
        i += 1;
    }

    const output = try allocator.alloc(u8, count);
    errdefer allocator.free(output);

    var out_idx: usize = 0;
    i = 0;
    while (i < data.len) {
        if (i + 2 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] <= 3) {
            output[out_idx] = 0;
            output[out_idx + 1] = 0;
            output[out_idx + 2] = 3; // Insert emulation prevention byte
            out_idx += 3;
            i += 2;
        } else {
            output[out_idx] = data[i];
            out_idx += 1;
            i += 1;
        }
    }

    return output[0..out_idx];
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Extract parameter sets from NAL stream
pub fn extractParameterSets(
    data: []const u8,
    codec: CodecType,
    allocator: Allocator,
) !struct {
    vps: ?[]const u8,
    sps: ?[]const u8,
    pps: ?[]const u8,
} {
    var nals = try parseAnnexB(data, allocator);
    defer nals.deinit(allocator);

    var result: struct {
        vps: ?[]const u8,
        sps: ?[]const u8,
        pps: ?[]const u8,
    } = .{
        .vps = null,
        .sps = null,
        .pps = null,
    };

    for (nals.items) |nal| {
        const nal_type = NalUnit.getNalType(nal.data, codec);

        switch (codec) {
            .h264 => {
                if (nal_type == 7) result.sps = nal.data; // SPS
                if (nal_type == 8) result.pps = nal.data; // PPS
            },
            .h265 => {
                if (nal_type == 32) result.vps = nal.data; // VPS
                if (nal_type == 33) result.sps = nal.data; // SPS
                if (nal_type == 34) result.pps = nal.data; // PPS
            },
            .h266 => {
                if (nal_type == 14) result.vps = nal.data; // VPS
                if (nal_type == 15) result.sps = nal.data; // SPS
                if (nal_type == 16) result.pps = nal.data; // PPS
            },
        }
    }

    return result;
}

/// Find the first keyframe in a NAL stream
pub fn findFirstKeyframe(
    data: []const u8,
    codec: CodecType,
    allocator: Allocator,
) !?usize {
    var nals = try parseAnnexB(data, allocator);
    defer nals.deinit(allocator);

    var offset: usize = 0;
    for (nals.items) |nal| {
        const nal_unit = NalUnit{
            .data = nal.data,
            .nal_type = NalUnit.getNalType(nal.data, codec),
        };

        if (nal_unit.isKeyFrame(codec)) {
            return offset;
        }

        // Account for start code (assume 4-byte)
        offset += 4 + nal.data.len;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "Start code detection" {
    const testing = std.testing;

    // 3-byte start code
    const data3 = [_]u8{ 0x00, 0x00, 0x01, 0x65 };
    const result3 = findStartCode(&data3);
    try testing.expect(result3 != null);
    try testing.expectEqual(@as(usize, 0), result3.?.offset);
    try testing.expectEqual(@as(usize, 3), result3.?.length);

    // 4-byte start code
    const data4 = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x65 };
    const result4 = findStartCode(&data4);
    try testing.expect(result4 != null);
    try testing.expectEqual(@as(usize, 0), result4.?.offset);
    try testing.expectEqual(@as(usize, 4), result4.?.length);

    // Start code with offset
    const data_offset = [_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x01, 0x65 };
    const result_offset = findStartCode(&data_offset);
    try testing.expect(result_offset != null);
    try testing.expectEqual(@as(usize, 2), result_offset.?.offset);
}

test "NAL type extraction" {
    const testing = std.testing;

    // H.264: NAL type in lower 5 bits
    const h264_idr = [_]u8{0x65}; // IDR slice
    try testing.expectEqual(@as(u8, 5), NalUnit.getNalType(&h264_idr, .h264));

    const h264_sps = [_]u8{0x67}; // SPS
    try testing.expectEqual(@as(u8, 7), NalUnit.getNalType(&h264_sps, .h264));

    // H.265: NAL type in bits 1-6 of first byte
    const h265_idr = [_]u8{ 0x28, 0x01 }; // IDR_W_RADL
    try testing.expectEqual(@as(u8, 20), NalUnit.getNalType(&h265_idr, .h265));
}

test "Annex B parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Two NAL units with 3-byte start codes
    const data = [_]u8{
        0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E, // SPS
        0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80, // PPS
    };

    var nals = try parseAnnexB(&data, allocator);
    defer nals.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), nals.items.len);
    try testing.expectEqual(@as(usize, 4), nals.items[0].data.len);
    try testing.expectEqual(@as(usize, 4), nals.items[1].data.len);
}

test "Length-prefixed parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Two NAL units with 4-byte length prefix
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x04, 0x67, 0x42, 0x00, 0x1E, // SPS (length=4)
        0x00, 0x00, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80, // PPS (length=4)
    };

    var nals = try parseLengthPrefixed(&data, 4, allocator);
    defer nals.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), nals.items.len);
    try testing.expectEqual(@as(usize, 4), nals.items[0].data.len);
    try testing.expectEqual(@as(usize, 4), nals.items[1].data.len);
}

test "Emulation prevention removal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Data with emulation prevention byte
    const data = [_]u8{ 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x01 };
    const result = try removeEmulationPrevention(&data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01 }, result);
}

test "NAL unit properties" {
    const testing = std.testing;

    // H.264 IDR
    const h264_idr = NalUnit{ .data = &.{0x65}, .nal_type = 5 };
    try testing.expect(h264_idr.isVcl(.h264));
    try testing.expect(h264_idr.isKeyFrame(.h264));
    try testing.expect(!h264_idr.isParameterSet(.h264));

    // H.264 SPS
    const h264_sps = NalUnit{ .data = &.{0x67}, .nal_type = 7 };
    try testing.expect(!h264_sps.isVcl(.h264));
    try testing.expect(!h264_sps.isKeyFrame(.h264));
    try testing.expect(h264_sps.isParameterSet(.h264));
}
