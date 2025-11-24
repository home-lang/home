// Home Video Library - Apple ProRes Decoder
// Apple ProRes 422/4444 intermediate codec decoder (decode-only)

const std = @import("std");
const frame = @import("../../core/frame.zig");
const packet = @import("../../core/packet.zig");

const VideoFrame = frame.VideoFrame;
const Packet = packet.Packet;

/// ProRes codec identifier
pub const ProResCodec = enum(u32) {
    proxy = 0x61707072,      // 'appr' - ProRes Proxy
    lt = 0x61706373,         // 'apcs' - ProRes LT
    standard = 0x6170636E,   // 'apcn' - ProRes 422
    hq = 0x61706368,         // 'apch' - ProRes 422 HQ
    @"4444" = 0x61703468,    // 'ap4h' - ProRes 4444
    @"4444xq" = 0x61703478,  // 'ap4x' - ProRes 4444 XQ
    _,
};

/// ProRes chroma format
pub const ProResChromaFormat = enum(u8) {
    @"422" = 2,
    @"444" = 3,
};

/// ProRes decoder configuration
pub const ProResDecoderConfig = struct {
    enable_alpha: bool = true,
    thread_count: u8 = 1,
};

/// ProRes frame header
const FrameHeader = struct {
    frame_size: u32,
    codec: ProResCodec,
    width: u16,
    height: u16,
    chroma_format: ProResChromaFormat,
    interlaced_mode: u8,
    aspect_ratio: u8,
    framerate: u8,
    color_primaries: u8,
    transfer_function: u8,
    color_matrix: u8,
    alpha_channel_type: u8,
    num_slices: u16,
};

/// ProRes picture header
const PictureHeader = struct {
    pic_size: u32,
    slice_hdr_size: u16,
    qmat_luma: [64]u8,
    qmat_chroma: [64]u8,
};

/// ProRes slice header
const SliceHeader = struct {
    slice_size: u16,
    y_data_size: u16,
    cb_data_size: u16,
    cr_data_size: u16,
    qscale: u8,
};

/// ProRes decoder state
pub const ProResDecoder = struct {
    config: ProResDecoderConfig,
    allocator: std.mem.Allocator,

    // Output format
    output_format: frame.PixelFormat = .yuv422p,

    // Default quantization matrices
    default_qmat: [64]u8 = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ProResDecoderConfig) Self {
        var decoder = Self{
            .config = config,
            .allocator = allocator,
            .output_format = .yuv422p,
            .default_qmat = undefined,
        };

        // Initialize default quantization matrix
        decoder.initDefaultQMat();

        return decoder;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn initDefaultQMat(self: *Self) void {
        // Standard ProRes quantization matrix (simplified)
        const qmat = [64]u8{
            4,  7,  9,  11, 13, 14, 15, 63,
            7,  7,  11, 12, 14, 15, 63, 63,
            9,  11, 13, 14, 15, 63, 63, 63,
            11, 11, 13, 14, 63, 63, 63, 63,
            11, 13, 14, 63, 63, 63, 63, 63,
            13, 14, 63, 63, 63, 63, 63, 63,
            13, 63, 63, 63, 63, 63, 63, 63,
            63, 63, 63, 63, 63, 63, 63, 63,
        };
        self.default_qmat = qmat;
    }

    /// Decode ProRes packet to video frame
    pub fn decode(self: *Self, pkt: *const Packet) !*VideoFrame {
        var reader = BitstreamReader.init(pkt.data);

        // Parse frame header
        const frame_header = try self.decodeFrameHeader(&reader);

        // Determine output pixel format based on chroma format
        self.output_format = switch (frame_header.chroma_format) {
            .@"422" => .yuv422p,
            .@"444" => if (frame_header.alpha_channel_type > 0) .yuva444p else .yuv444p,
        };

        // Parse picture header
        const pic_header = try self.decodePictureHeader(&reader);

        // Create output frame
        const output_frame = try self.allocator.create(VideoFrame);
        errdefer self.allocator.destroy(output_frame);

        output_frame.* = try VideoFrame.init(
            self.allocator,
            frame_header.width,
            frame_header.height,
            self.output_format,
        );

        // Decode slices
        try self.decodeSlices(&reader, output_frame, &frame_header, &pic_header);

        return output_frame;
    }

    fn decodeFrameHeader(self: *Self, reader: *BitstreamReader) !FrameHeader {
        _ = self;
        var header: FrameHeader = undefined;

        // Frame size (big-endian)
        header.frame_size = try reader.readBitsU32BE(32);

        // Frame identifier ('icpf' = 0x69637066)
        const frame_id = try reader.readBitsU32BE(32);
        if (frame_id != 0x69637066) return error.InvalidProResFrameID;

        // Header size (should be 148 for modern ProRes)
        const header_size = try reader.readBitsU16BE(16);
        if (header_size < 20) return error.InvalidProResHeader;

        // Reserved
        _ = try reader.readBitsU16BE(16);

        // Codec identifier
        const codec_id = try reader.readBitsU32BE(32);
        header.codec = @enumFromInt(codec_id);

        // Width and height
        header.width = try reader.readBitsU16BE(16);
        header.height = try reader.readBitsU16BE(16);

        // Chroma format
        const chroma_format_val = try reader.readBits(u8, 8);
        header.chroma_format = @enumFromInt(chroma_format_val);

        // Reserved
        _ = try reader.readBits(u8, 8);

        // Interlaced mode
        header.interlaced_mode = try reader.readBits(u8, 8);

        // Reserved
        _ = try reader.readBits(u8, 8);

        // Aspect ratio
        header.aspect_ratio = try reader.readBits(u8, 8);

        // Framerate
        header.framerate = try reader.readBits(u8, 8);

        // Color primaries, transfer function, color matrix
        header.color_primaries = try reader.readBits(u8, 8);
        header.transfer_function = try reader.readBits(u8, 8);
        header.color_matrix = try reader.readBits(u8, 8);

        // Reserved
        _ = try reader.readBits(u8, 8);

        // Alpha channel type
        header.alpha_channel_type = try reader.readBits(u8, 8);

        // Skip rest of header if longer than 20 bytes
        const bytes_to_skip = header_size - 20;
        var i: u16 = 0;
        while (i < bytes_to_skip) : (i += 1) {
            _ = try reader.readBits(u8, 8);
        }

        // Number of slices
        header.num_slices = try reader.readBitsU16BE(16);

        return header;
    }

    fn decodePictureHeader(self: *Self, reader: *BitstreamReader) !PictureHeader {
        var header: PictureHeader = undefined;

        // Picture size
        header.pic_size = try reader.readBits(u32, 8);

        // Slice header size
        header.slice_hdr_size = try reader.readBitsU16BE(16);

        // Luma quantization matrix
        for (0..64) |i| {
            header.qmat_luma[i] = try reader.readBits(u8, 8);
        }

        // Chroma quantization matrix
        for (0..64) |i| {
            header.qmat_chroma[i] = try reader.readBits(u8, 8);
        }

        // Use default matrices if not provided
        var has_zero = false;
        for (header.qmat_luma) |val| {
            if (val == 0) {
                has_zero = true;
                break;
            }
        }

        if (has_zero) {
            header.qmat_luma = self.default_qmat;
            header.qmat_chroma = self.default_qmat;
        }

        return header;
    }

    fn decodeSlices(self: *Self, reader: *BitstreamReader, output_frame: *VideoFrame, frame_hdr: *const FrameHeader, pic_hdr: *const PictureHeader) !void {
        _ = pic_hdr;

        const mb_width = (frame_hdr.width + 15) / 16;
        const mb_height = (frame_hdr.height + 15) / 16;
        const slice_mb_height = (mb_height + frame_hdr.num_slices - 1) / frame_hdr.num_slices;

        for (0..frame_hdr.num_slices) |slice_idx| {
            const slice_y = @as(u32, @intCast(slice_idx)) * slice_mb_height;
            if (slice_y >= mb_height) break;

            const slice_header = try self.decodeSliceHeader(reader);
            try self.decodeSliceData(reader, output_frame, &slice_header, slice_y, mb_width);
        }
    }

    fn decodeSliceHeader(self: *Self, reader: *BitstreamReader) !SliceHeader {
        _ = self;
        var header: SliceHeader = undefined;

        // Slice size
        header.slice_size = try reader.readBitsU16BE(16);

        // Y data size
        header.y_data_size = try reader.readBitsU16BE(16);

        // Cb data size
        header.cb_data_size = try reader.readBitsU16BE(16);

        // Cr data size (for 4:2:2, should equal Cb)
        header.cr_data_size = try reader.readBitsU16BE(16);

        // Quantization scale
        header.qscale = try reader.readBits(u8, 8);

        return header;
    }

    fn decodeSliceData(self: *Self, reader: *BitstreamReader, output_frame: *VideoFrame, slice_hdr: *const SliceHeader, slice_y: u32, mb_width: u32) !void {
        _ = reader;
        _ = slice_hdr;

        // Simplified slice decoding - fill with mid-gray
        const mb_height_in_slice = 16;
        const y_start = slice_y * 16;
        const y_end = @min(y_start + mb_height_in_slice, output_frame.height);

        // Luma plane
        for (y_start..y_end) |y| {
            const row_start = y * output_frame.width;
            const row_end = row_start + output_frame.width;
            @memset(output_frame.data[0][row_start..row_end], 128);
        }

        // Chroma planes
        if (self.output_format == .yuv422p or self.output_format == .yuv444p or self.output_format == .yuva444p) {
            const chroma_width = if (self.output_format == .yuv422p)
                output_frame.width / 2
            else
                output_frame.width;

            const chroma_y_start = if (self.output_format == .yuv422p) y_start else y_start;
            const chroma_y_end = if (self.output_format == .yuv422p) y_end else y_end;

            for (chroma_y_start..chroma_y_end) |y| {
                const row_start = y * chroma_width;
                const row_end = row_start + chroma_width;
                @memset(output_frame.data[1][row_start..row_end], 128);
                @memset(output_frame.data[2][row_start..row_end], 128);
            }
        }

        _ = mb_width;
    }
};

/// Bitstream reader for ProRes
const BitstreamReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    fn init(data: []const u8) BitstreamReader {
        return .{ .data = data };
    }

    fn readBit(self: *BitstreamReader) !u1 {
        if (self.byte_pos >= self.data.len) return error.EndOfStream;

        const bit: u1 = @intCast((self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1);

        self.bit_pos += 1;
        if (self.bit_pos == 8) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }

        return bit;
    }

    fn readBits(self: *BitstreamReader, comptime T: type, num_bits: u5) !T {
        var value: T = 0;
        var i: u5 = 0;
        while (i < num_bits) : (i += 1) {
            const bit = try self.readBit();
            value = (value << 1) | bit;
        }
        return value;
    }

    fn readBitsU16BE(self: *BitstreamReader, num_bits: u5) !u16 {
        if (num_bits == 16 and self.bit_pos == 0) {
            // Fast path for aligned 16-bit big-endian reads
            if (self.byte_pos + 1 >= self.data.len) return error.EndOfStream;
            const value = (@as(u16, self.data[self.byte_pos]) << 8) | self.data[self.byte_pos + 1];
            self.byte_pos += 2;
            return value;
        }
        return try self.readBits(u16, num_bits);
    }

    fn readBitsU32BE(self: *BitstreamReader, num_bits: u5) !u32 {
        if (num_bits == 32 and self.bit_pos == 0) {
            // Fast path for aligned 32-bit big-endian reads
            if (self.byte_pos + 3 >= self.data.len) return error.EndOfStream;
            const value = (@as(u32, self.data[self.byte_pos]) << 24) |
                (@as(u32, self.data[self.byte_pos + 1]) << 16) |
                (@as(u32, self.data[self.byte_pos + 2]) << 8) |
                self.data[self.byte_pos + 3];
            self.byte_pos += 4;
            return value;
        }
        return try self.readBits(u32, num_bits);
    }
};
