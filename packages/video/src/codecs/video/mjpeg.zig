const std = @import("std");

/// Motion JPEG codec (sequence of JPEG images)
pub const Mjpeg = struct {
    /// JPEG markers
    pub const Marker = enum(u16) {
        soi = 0xFFD8, // Start of Image
        eoi = 0xFFD9, // End of Image
        sos = 0xFFDA, // Start of Scan
        sof0 = 0xFFC0, // Start of Frame (Baseline DCT)
        sof2 = 0xFFC2, // Start of Frame (Progressive DCT)
        dht = 0xFFC4, // Define Huffman Table
        dqt = 0xFFDB, // Define Quantization Table
        dri = 0xFFDD, // Define Restart Interval
        app0 = 0xFFE0, // Application-specific (JFIF)
        app1 = 0xFFE1, // Application-specific (EXIF)
        com = 0xFFFE, // Comment
    };

    /// JPEG frame component
    pub const Component = struct {
        id: u8,
        horizontal_sampling: u4,
        vertical_sampling: u4,
        quantization_table: u8,
    };

    /// JPEG frame info
    pub const FrameInfo = struct {
        width: u16,
        height: u16,
        bit_depth: u8,
        component_count: u8,
        components: [4]Component,
    };
};

/// MJPEG frame parser
pub const MjpegParser = struct {
    pub fn parseFrameInfo(data: []const u8) !Mjpeg.FrameInfo {
        if (!isJpeg(data)) return error.NotJpeg;

        var offset: usize = 2; // Skip SOI marker

        while (offset + 1 < data.len) {
            // Find marker
            if (data[offset] != 0xFF) return error.InvalidMarker;
            const marker_byte = data[offset + 1];
            offset += 2;

            // Skip padding bytes
            while (offset < data.len and data[offset] == 0xFF) {
                offset += 1;
            }

            const marker = (@as(u16, 0xFF) << 8) | marker_byte;

            // Check for SOF markers
            if (marker == @intFromEnum(Mjpeg.Marker.sof0) or marker == @intFromEnum(Mjpeg.Marker.sof2)) {
                return try parseSof(data[offset..]);
            }

            // Skip segment
            if (offset + 1 >= data.len) break;
            const segment_length = (@as(u16, data[offset]) << 8) | data[offset + 1];
            offset += segment_length;
        }

        return error.NoFrameInfo;
    }

    fn parseSof(data: []const u8) !Mjpeg.FrameInfo {
        if (data.len < 8) return error.InsufficientData;

        var info: Mjpeg.FrameInfo = undefined;

        const length = (@as(u16, data[0]) << 8) | data[1];
        _ = length;

        info.bit_depth = data[2];
        info.height = (@as(u16, data[3]) << 8) | data[4];
        info.width = (@as(u16, data[5]) << 8) | data[6];
        info.component_count = data[7];

        if (info.component_count > 4) return error.TooManyComponents;

        var offset: usize = 8;
        for (0..info.component_count) |i| {
            if (offset + 2 >= data.len) return error.InsufficientData;

            info.components[i].id = data[offset];
            const sampling = data[offset + 1];
            info.components[i].horizontal_sampling = @truncate(sampling >> 4);
            info.components[i].vertical_sampling = @truncate(sampling & 0x0F);
            info.components[i].quantization_table = data[offset + 2];

            offset += 3;
        }

        return info;
    }

    pub fn isKeyframe(data: []const u8) bool {
        // All MJPEG frames are keyframes (intra-only)
        return isJpeg(data);
    }

    pub fn extractFrame(data: []const u8) ![]const u8 {
        // MJPEG frames are complete JPEG images
        if (!isJpeg(data)) return error.NotJpeg;

        // Find EOI marker
        var offset: usize = data.len - 2;
        while (offset > 0) : (offset -= 1) {
            if (data[offset] == 0xFF and data[offset + 1] == 0xD9) {
                return data[0 .. offset + 2];
            }
        }

        return data;
    }
};

/// Check if data is JPEG
pub fn isJpeg(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[0] == 0xFF and data[1] == 0xD8;
}

/// MJPEG encoder configuration
pub const MjpegEncoderConfig = struct {
    quality: u8, // 1-100
    chroma_subsampling: ChromaSubsampling,

    pub const ChromaSubsampling = enum {
        yuv420, // 4:2:0 (most common)
        yuv422, // 4:2:2
        yuv444, // 4:4:4 (no subsampling)
    };
};

/// MJPEG decoder
pub const MjpegDecoder = struct {
    allocator: std.mem.Allocator,
    frame_info: ?Mjpeg.FrameInfo,

    pub fn init(allocator: std.mem.Allocator) MjpegDecoder {
        return .{
            .allocator = allocator,
            .frame_info = null,
        };
    }

    pub fn decodeFrame(self: *MjpegDecoder, data: []const u8) ![]u8 {
        const info = try MjpegParser.parseFrameInfo(data);
        self.frame_info = info;

        // Would decode JPEG data to raw pixels
        // For now, return placeholder
        const pixel_count = @as(usize, info.width) * info.height * 3; // RGB
        const pixels = try self.allocator.alloc(u8, pixel_count);
        @memset(pixels, 0);

        return pixels;
    }
};
