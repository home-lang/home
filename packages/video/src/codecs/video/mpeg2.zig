const std = @import("std");

/// MPEG-2 video codec (ITU-T H.262)
pub const Mpeg2 = struct {
    /// Picture coding type
    pub const PictureType = enum(u3) {
        forbidden = 0,
        i_frame = 1, // Intra-coded
        p_frame = 2, // Predictive-coded
        b_frame = 3, // Bidirectionally predictive-coded
        d_frame = 4, // DC intra-coded (rarely used)
        reserved_5 = 5,
        reserved_6 = 6,
        reserved_7 = 7,
    };

    /// MPEG-2 profile
    pub const Profile = enum(u3) {
        simple = 5,
        main = 4,
        snr_scalable = 3,
        spatially_scalable = 2,
        high = 1,
        multi_view = 0,
        @"422" = 0, // Overlaps with multi_view in different level
    };

    /// MPEG-2 level
    pub const Level = enum(u4) {
        low = 10,
        main = 8,
        high_1440 = 6,
        high = 4,
    };

    /// Sequence header
    pub const SequenceHeader = struct {
        width: u16,
        height: u16,
        aspect_ratio: AspectRatio,
        frame_rate: FrameRate,
        bit_rate: u32, // 400 bits/s units
        vbv_buffer_size: u16, // 16 kb units
        constrained_parameters: bool,
        load_intra_quantizer_matrix: bool,
        load_non_intra_quantizer_matrix: bool,
    };

    pub const AspectRatio = enum(u4) {
        forbidden = 0,
        square = 1, // 1:1
        ratio_4_3 = 2, // 4:3
        ratio_16_9 = 3, // 16:9
        ratio_2_21_1 = 4, // 2.21:1
        reserved_5 = 5,
        reserved_6 = 6,
        reserved_7 = 7,
        reserved_8 = 8,
        reserved_9 = 9,
        reserved_10 = 10,
        reserved_11 = 11,
        reserved_12 = 12,
        reserved_13 = 13,
        reserved_14 = 14,
        reserved_15 = 15,
    };

    pub const FrameRate = enum(u4) {
        forbidden = 0,
        @"23.976" = 1,
        @"24" = 2,
        @"25" = 3,
        @"29.97" = 4,
        @"30" = 5,
        @"50" = 6,
        @"59.94" = 7,
        @"60" = 8,
        reserved_9 = 9,
        reserved_10 = 10,
        reserved_11 = 11,
        reserved_12 = 12,
        reserved_13 = 13,
        reserved_14 = 14,
        reserved_15 = 15,
    };

    /// Picture header
    pub const PictureHeader = struct {
        temporal_reference: u10,
        picture_type: PictureType,
        vbv_delay: u16,
        full_pel_forward_vector: bool,
        forward_f_code: u3,
        full_pel_backward_vector: bool,
        backward_f_code: u3,
    };

    /// GOP (Group of Pictures) header
    pub const GopHeader = struct {
        time_code: u25,
        closed_gop: bool,
        broken_link: bool,
    };

    /// Start codes
    pub const StartCode = enum(u32) {
        picture = 0x00000100,
        slice_start = 0x00000101, // 0x101-0x1AF for slices
        user_data = 0x000001B2,
        sequence_header = 0x000001B3,
        sequence_error = 0x000001B4,
        extension = 0x000001B5,
        sequence_end = 0x000001B7,
        gop = 0x000001B8,
    };
};

/// MPEG-2 sequence parser
pub const Mpeg2Parser = struct {
    pub fn parseSequenceHeader(data: []const u8) !Mpeg2.SequenceHeader {
        if (data.len < 12) return error.InsufficientData;

        // Check for sequence header start code
        if (!std.mem.eql(u8, data[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xB3 })) {
            return error.InvalidStartCode;
        }

        var header: Mpeg2.SequenceHeader = undefined;

        // Width (12 bits)
        header.width = (@as(u16, data[4]) << 4) | (@as(u16, data[5]) >> 4);

        // Height (12 bits)
        header.height = ((@as(u16, data[5]) & 0x0F) << 8) | data[6];

        // Aspect ratio (4 bits)
        header.aspect_ratio = @enumFromInt(@as(u4, @truncate(data[7] >> 4)));

        // Frame rate (4 bits)
        header.frame_rate = @enumFromInt(@as(u4, @truncate(data[7] & 0x0F)));

        // Bit rate (18 bits)
        header.bit_rate = (@as(u32, data[8]) << 10) | (@as(u32, data[9]) << 2) | (@as(u32, data[10]) >> 6);

        // Skip marker bit

        // VBV buffer size (10 bits)
        header.vbv_buffer_size = ((@as(u16, data[10]) & 0x1F) << 5) | (@as(u16, data[11]) >> 3);

        // Constrained parameters flag
        header.constrained_parameters = (data[11] & 0x04) != 0;

        // Quantizer matrix flags
        header.load_intra_quantizer_matrix = (data[11] & 0x02) != 0;
        header.load_non_intra_quantizer_matrix = (data[11] & 0x01) != 0;

        return header;
    }

    pub fn parsePictureHeader(data: []const u8) !Mpeg2.PictureHeader {
        if (data.len < 8) return error.InsufficientData;

        // Check for picture start code
        if (!std.mem.eql(u8, data[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0x00 })) {
            return error.InvalidStartCode;
        }

        var header: Mpeg2.PictureHeader = undefined;

        // Temporal reference (10 bits)
        header.temporal_reference = (@as(u10, data[4]) << 2) | (@as(u10, data[5]) >> 6);

        // Picture type (3 bits)
        header.picture_type = @enumFromInt(@as(u3, @truncate((data[5] >> 3) & 0x07)));

        // VBV delay (16 bits)
        header.vbv_delay = ((@as(u16, data[5]) & 0x07) << 13) | (@as(u16, data[6]) << 5) | (@as(u16, data[7]) >> 3);

        // Motion vector fields (for P and B frames)
        if (header.picture_type == .p_frame or header.picture_type == .b_frame) {
            header.full_pel_forward_vector = (data[7] & 0x04) != 0;
            header.forward_f_code = @truncate((data[7] & 0x03) << 1 | (data[8] >> 7));
        } else {
            header.full_pel_forward_vector = false;
            header.forward_f_code = 0;
        }

        if (header.picture_type == .b_frame) {
            header.full_pel_backward_vector = (data[8] & 0x40) != 0;
            header.backward_f_code = @truncate((data[8] >> 3) & 0x07);
        } else {
            header.full_pel_backward_vector = false;
            header.backward_f_code = 0;
        }

        return header;
    }

    pub fn parseGopHeader(data: []const u8) !Mpeg2.GopHeader {
        if (data.len < 8) return error.InsufficientData;

        // Check for GOP start code
        if (!std.mem.eql(u8, data[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xB8 })) {
            return error.InvalidStartCode;
        }

        var header: Mpeg2.GopHeader = undefined;

        // Time code (25 bits)
        header.time_code = (@as(u25, data[4]) << 17) | (@as(u25, data[5]) << 9) | (@as(u25, data[6]) << 1) | (@as(u25, data[7]) >> 7);

        // Closed GOP flag
        header.closed_gop = (data[7] & 0x40) != 0;

        // Broken link flag
        header.broken_gop = (data[7] & 0x20) != 0;

        return header;
    }

    pub fn findStartCode(data: []const u8, offset: usize) ?struct { code: u32, pos: usize } {
        var i = offset;
        while (i + 3 < data.len) : (i += 1) {
            if (data[i] == 0x00 and data[i + 1] == 0x00 and data[i + 2] == 0x01) {
                const code = (@as(u32, data[i]) << 24) | (@as(u32, data[i + 1]) << 16) | (@as(u32, data[i + 2]) << 8) | data[i + 3];
                return .{ .code = code, .pos = i };
            }
        }
        return null;
    }

    pub fn getFrameType(picture_type: Mpeg2.PictureType) []const u8 {
        return switch (picture_type) {
            .i_frame => "I",
            .p_frame => "P",
            .b_frame => "B",
            .d_frame => "D",
            else => "?",
        };
    }

    pub fn getFrameRateValue(frame_rate: Mpeg2.FrameRate) f32 {
        return switch (frame_rate) {
            .@"23.976" => 23.976,
            .@"24" => 24.0,
            .@"25" => 25.0,
            .@"29.97" => 29.97,
            .@"30" => 30.0,
            .@"50" => 50.0,
            .@"59.94" => 59.94,
            .@"60" => 60.0,
            else => 0.0,
        };
    }
};
