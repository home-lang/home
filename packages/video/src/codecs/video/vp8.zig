const std = @import("std");

/// VP8 video codec (Google's previous generation codec, predecessor to VP9)
pub const Vp8 = struct {
    /// VP8 frame type
    pub const FrameType = enum(u1) {
        keyframe = 0,
        interframe = 1,
    };

    /// VP8 frame header
    pub const FrameHeader = struct {
        frame_type: FrameType,
        version: u3,
        show_frame: bool,
        first_partition_size: u19,
        width: u16,
        height: u16,
        horizontal_scale: u2,
        vertical_scale: u2,
    };

    /// VP8 frame tag (first 3 bytes)
    pub const FrameTag = packed struct {
        frame_type: u1,
        version: u3,
        show_frame: u1,
        first_partition_size_low: u19, // Actually spans into next bytes
    };
};

/// VP8 frame parser
pub const Vp8FrameParser = struct {
    pub fn parseFrameHeader(data: []const u8) !Vp8.FrameHeader {
        if (data.len < 10) return error.InsufficientData;

        var header: Vp8.FrameHeader = undefined;

        // First 3 bytes contain frame tag
        const frame_tag = data[0] | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);

        header.frame_type = @enumFromInt(@as(u1, @truncate(frame_tag & 0x01)));
        header.version = @truncate((frame_tag >> 1) & 0x07);
        header.show_frame = ((frame_tag >> 4) & 0x01) != 0;
        header.first_partition_size = @truncate((frame_tag >> 5) & 0x7FFFF);

        // Parse dimensions for keyframes
        if (header.frame_type == .keyframe) {
            if (data.len < 10) return error.InsufficientData;

            // Start code check (should be 0x9d 0x01 0x2a)
            if (data[3] != 0x9D or data[4] != 0x01 or data[5] != 0x2A) {
                return error.InvalidStartCode;
            }

            // Width and height (14 bits each + 2 bits scale)
            const size_code = @as(u32, data[6]) | (@as(u32, data[7]) << 8) | (@as(u32, data[8]) << 16) | (@as(u32, data[9]) << 24);

            header.width = @truncate(size_code & 0x3FFF);
            header.horizontal_scale = @truncate((size_code >> 14) & 0x03);

            header.height = @truncate((size_code >> 16) & 0x3FFF);
            header.vertical_scale = @truncate((size_code >> 30) & 0x03);
        } else {
            header.width = 0;
            header.height = 0;
            header.horizontal_scale = 0;
            header.vertical_scale = 0;
        }

        return header;
    }

    pub fn isKeyframe(data: []const u8) bool {
        if (data.len < 1) return false;
        return (data[0] & 0x01) == 0;
    }
};

/// VP8 decoder configuration
pub const Vp8DecoderConfig = struct {
    width: u16,
    height: u16,
    threads: u8,
};
