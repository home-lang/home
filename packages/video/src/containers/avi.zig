const std = @import("std");
const types = @import("../core/types.zig");

/// AVI (Audio Video Interleave) container format
/// Legacy Microsoft RIFF container, includes OpenDML extensions for >2GB files
pub const Avi = struct {
    /// RIFF chunk FourCC codes
    pub const FourCC = enum(u32) {
        riff = 0x46464952, // 'RIFF'
        list = 0x5453494C, // 'LIST'
        junk = 0x4B4E554A, // 'JUNK'
        avi = 0x20495641, // 'AVI '
        hdrl = 0x6C726468, // 'hdrl'
        avih = 0x68697661, // 'avih'
        strl = 0x6C727473, // 'strl'
        strh = 0x68727473, // 'strh'
        strf = 0x66727473, // 'strf'
        strn = 0x6E727473, // 'strn' - stream name
        movi = 0x69766F6D, // 'movi'
        idx1 = 0x31786469, // 'idx1'
        odml = 0x6C6D646F, // 'odml' - OpenDML extension
        dmlh = 0x686C6D64, // 'dmlh'
        indx = 0x78646E69, // 'indx' - OpenDML index
        _,

        pub fn fromBytes(bytes: [4]u8) FourCC {
            return @enumFromInt(@as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24));
        }

        pub fn toBytes(self: FourCC) [4]u8 {
            const val = @intFromEnum(self);
            return [4]u8{
                @truncate(val),
                @truncate(val >> 8),
                @truncate(val >> 16),
                @truncate(val >> 24),
            };
        }
    };

    /// Main AVI header
    pub const MainHeader = struct {
        microsec_per_frame: u32, // Frame duration in microseconds
        max_bytes_per_sec: u32, // Maximum data rate
        padding_granularity: u32,
        flags: u32,
        total_frames: u32,
        initial_frames: u32,
        streams: u32, // Number of streams
        suggested_buffer_size: u32,
        width: u32,
        height: u32,
        reserved: [4]u32,
    };

    /// Stream header
    pub const StreamHeader = struct {
        fcc_type: [4]u8, // 'vids', 'auds', 'txts'
        fcc_handler: [4]u8, // Codec FourCC
        flags: u32,
        priority: u16,
        language: u16,
        initial_frames: u32,
        scale: u32, // Time scale
        rate: u32, // Rate / Scale = samples/frames per second
        start: u32,
        length: u32, // Number of frames/samples
        suggested_buffer_size: u32,
        quality: u32,
        sample_size: u32,
        frame: struct { left: i16, top: i16, right: i16, bottom: i16 },
    };

    /// Video stream format (BITMAPINFOHEADER)
    pub const VideoFormat = struct {
        size: u32, // Structure size
        width: i32,
        height: i32,
        planes: u16,
        bit_count: u16, // Bits per pixel
        compression: [4]u8, // Codec FourCC
        size_image: u32,
        x_pels_per_meter: i32,
        y_pels_per_meter: i32,
        clr_used: u32,
        clr_important: u32,
    };

    /// Audio stream format (WAVEFORMATEX)
    pub const AudioFormat = struct {
        format_tag: u16, // Audio format code
        channels: u16,
        samples_per_sec: u32,
        avg_bytes_per_sec: u32,
        block_align: u16,
        bits_per_sample: u16,
        cb_size: u16, // Extra format bytes
    };

    /// Index entry (old-style idx1)
    pub const IndexEntry = struct {
        chunk_id: [4]u8,
        flags: u32,
        offset: u32, // Offset from movi
        size: u32,
    };

    /// OpenDML header (for large files)
    pub const DmlHeader = struct {
        total_frames: u32, // Total frames in all RIFF chunks
    };
};

/// AVI file reader
pub const AviReader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    main_header: ?Avi.MainHeader,
    video_streams: std.ArrayList(VideoStream),
    audio_streams: std.ArrayList(AudioStream),
    movi_offset: usize,
    index_entries: std.ArrayList(Avi.IndexEntry),

    pub const VideoStream = struct {
        header: Avi.StreamHeader,
        format: Avi.VideoFormat,
        name: ?[]const u8,
    };

    pub const AudioStream = struct {
        header: Avi.StreamHeader,
        format: Avi.AudioFormat,
        name: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !AviReader {
        var reader = AviReader{
            .allocator = allocator,
            .data = data,
            .main_header = null,
            .video_streams = std.ArrayList(VideoStream).init(allocator),
            .audio_streams = std.ArrayList(AudioStream).init(allocator),
            .movi_offset = 0,
            .index_entries = std.ArrayList(Avi.IndexEntry).init(allocator),
        };

        try reader.parse();
        return reader;
    }

    pub fn deinit(self: *AviReader) void {
        self.video_streams.deinit();
        self.audio_streams.deinit();
        self.index_entries.deinit();
    }

    fn parse(self: *AviReader) !void {
        if (self.data.len < 12) return error.InsufficientData;

        // Check RIFF header
        const riff_fourcc = Avi.FourCC.fromBytes(self.data[0..4].*);
        if (riff_fourcc != .riff) return error.InvalidRiffHeader;

        const file_size = std.mem.readInt(u32, self.data[4..8], .little);
        _ = file_size;

        const form_type = Avi.FourCC.fromBytes(self.data[8..12].*);
        if (form_type != .avi) return error.NotAviFile;

        var offset: usize = 12;

        while (offset + 8 <= self.data.len) {
            const chunk_fourcc = Avi.FourCC.fromBytes(self.data[offset..][0..4].*);
            const chunk_size = std.mem.readInt(u32, self.data[offset + 4 ..][0..4], .little);
            offset += 8;

            if (offset + chunk_size > self.data.len) break;

            switch (chunk_fourcc) {
                .list => {
                    const list_type = Avi.FourCC.fromBytes(self.data[offset..][0..4].*);
                    const list_data = self.data[offset + 4 .. offset + chunk_size];

                    switch (list_type) {
                        .hdrl => try self.parseHdrl(list_data),
                        .movi => self.movi_offset = offset + 4,
                        .strl => try self.parseStrl(list_data),
                        else => {},
                    }
                },
                .idx1 => try self.parseIdx1(self.data[offset .. offset + chunk_size]),
                else => {},
            }

            offset += chunk_size;
            // Align to word boundary
            if (chunk_size % 2 != 0) offset += 1;
        }
    }

    fn parseHdrl(self: *AviReader, data: []const u8) !void {
        var offset: usize = 0;

        while (offset + 8 <= data.len) {
            const chunk_fourcc = Avi.FourCC.fromBytes(data[offset..][0..4].*);
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
            offset += 8;

            if (offset + chunk_size > data.len) break;

            switch (chunk_fourcc) {
                .avih => {
                    if (chunk_size >= 56) {
                        self.main_header = try parseMainHeader(data[offset .. offset + chunk_size]);
                    }
                },
                .list => {
                    const list_type = Avi.FourCC.fromBytes(data[offset..][0..4].*);
                    if (list_type == .strl) {
                        try self.parseStrl(data[offset + 4 .. offset + chunk_size]);
                    }
                },
                else => {},
            }

            offset += chunk_size;
            if (chunk_size % 2 != 0) offset += 1;
        }
    }

    fn parseStrl(self: *AviReader, data: []const u8) !void {
        var offset: usize = 0;
        var stream_header: ?Avi.StreamHeader = null;
        var video_format: ?Avi.VideoFormat = null;
        var audio_format: ?Avi.AudioFormat = null;
        var stream_name: ?[]const u8 = null;

        while (offset + 8 <= data.len) {
            const chunk_fourcc = Avi.FourCC.fromBytes(data[offset..][0..4].*);
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
            offset += 8;

            if (offset + chunk_size > data.len) break;

            switch (chunk_fourcc) {
                .strh => {
                    if (chunk_size >= 56) {
                        stream_header = try parseStreamHeader(data[offset .. offset + chunk_size]);
                    }
                },
                .strf => {
                    if (stream_header) |sh| {
                        if (std.mem.eql(u8, &sh.fcc_type, "vids")) {
                            video_format = try parseVideoFormat(data[offset .. offset + chunk_size]);
                        } else if (std.mem.eql(u8, &sh.fcc_type, "auds")) {
                            audio_format = try parseAudioFormat(data[offset .. offset + chunk_size]);
                        }
                    }
                },
                .strn => {
                    stream_name = data[offset .. offset + chunk_size];
                },
                else => {},
            }

            offset += chunk_size;
            if (chunk_size % 2 != 0) offset += 1;
        }

        // Add stream based on type
        if (stream_header) |sh| {
            if (std.mem.eql(u8, &sh.fcc_type, "vids")) {
                if (video_format) |vf| {
                    try self.video_streams.append(.{
                        .header = sh,
                        .format = vf,
                        .name = stream_name,
                    });
                }
            } else if (std.mem.eql(u8, &sh.fcc_type, "auds")) {
                if (audio_format) |af| {
                    try self.audio_streams.append(.{
                        .header = sh,
                        .format = af,
                        .name = stream_name,
                    });
                }
            }
        }
    }

    fn parseIdx1(self: *AviReader, data: []const u8) !void {
        var offset: usize = 0;

        while (offset + 16 <= data.len) {
            const entry = Avi.IndexEntry{
                .chunk_id = data[offset..][0..4].*,
                .flags = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little),
                .offset = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little),
                .size = std.mem.readInt(u32, data[offset + 12 ..][0..4], .little),
            };

            try self.index_entries.append(entry);
            offset += 16;
        }
    }

    pub fn getFrameRate(self: *const AviReader) f64 {
        if (self.main_header) |header| {
            if (header.microsec_per_frame > 0) {
                return 1_000_000.0 / @as(f64, @floatFromInt(header.microsec_per_frame));
            }
        }
        return 0.0;
    }

    pub fn getDuration(self: *const AviReader) u64 {
        if (self.main_header) |header| {
            return @as(u64, header.total_frames) * header.microsec_per_frame;
        }
        return 0;
    }

    pub fn getVideoStream(self: *const AviReader, index: usize) ?VideoStream {
        if (index < self.video_streams.items.len) {
            return self.video_streams.items[index];
        }
        return null;
    }

    pub fn getAudioStream(self: *const AviReader, index: usize) ?AudioStream {
        if (index < self.audio_streams.items.len) {
            return self.audio_streams.items[index];
        }
        return null;
    }
};

fn parseMainHeader(data: []const u8) !Avi.MainHeader {
    if (data.len < 56) return error.InsufficientData;

    return Avi.MainHeader{
        .microsec_per_frame = std.mem.readInt(u32, data[0..4], .little),
        .max_bytes_per_sec = std.mem.readInt(u32, data[4..8], .little),
        .padding_granularity = std.mem.readInt(u32, data[8..12], .little),
        .flags = std.mem.readInt(u32, data[12..16], .little),
        .total_frames = std.mem.readInt(u32, data[16..20], .little),
        .initial_frames = std.mem.readInt(u32, data[20..24], .little),
        .streams = std.mem.readInt(u32, data[24..28], .little),
        .suggested_buffer_size = std.mem.readInt(u32, data[28..32], .little),
        .width = std.mem.readInt(u32, data[32..36], .little),
        .height = std.mem.readInt(u32, data[36..40], .little),
        .reserved = [4]u32{
            std.mem.readInt(u32, data[40..44], .little),
            std.mem.readInt(u32, data[44..48], .little),
            std.mem.readInt(u32, data[48..52], .little),
            std.mem.readInt(u32, data[52..56], .little),
        },
    };
}

fn parseStreamHeader(data: []const u8) !Avi.StreamHeader {
    if (data.len < 56) return error.InsufficientData;

    return Avi.StreamHeader{
        .fcc_type = data[0..4].*,
        .fcc_handler = data[4..8].*,
        .flags = std.mem.readInt(u32, data[8..12], .little),
        .priority = std.mem.readInt(u16, data[12..14], .little),
        .language = std.mem.readInt(u16, data[14..16], .little),
        .initial_frames = std.mem.readInt(u32, data[16..20], .little),
        .scale = std.mem.readInt(u32, data[20..24], .little),
        .rate = std.mem.readInt(u32, data[24..28], .little),
        .start = std.mem.readInt(u32, data[28..32], .little),
        .length = std.mem.readInt(u32, data[32..36], .little),
        .suggested_buffer_size = std.mem.readInt(u32, data[36..40], .little),
        .quality = std.mem.readInt(u32, data[40..44], .little),
        .sample_size = std.mem.readInt(u32, data[44..48], .little),
        .frame = .{
            .left = std.mem.readInt(i16, data[48..50], .little),
            .top = std.mem.readInt(i16, data[50..52], .little),
            .right = std.mem.readInt(i16, data[52..54], .little),
            .bottom = std.mem.readInt(i16, data[54..56], .little),
        },
    };
}

fn parseVideoFormat(data: []const u8) !Avi.VideoFormat {
    if (data.len < 40) return error.InsufficientData;

    return Avi.VideoFormat{
        .size = std.mem.readInt(u32, data[0..4], .little),
        .width = std.mem.readInt(i32, data[4..8], .little),
        .height = std.mem.readInt(i32, data[8..12], .little),
        .planes = std.mem.readInt(u16, data[12..14], .little),
        .bit_count = std.mem.readInt(u16, data[14..16], .little),
        .compression = data[16..20].*,
        .size_image = std.mem.readInt(u32, data[20..24], .little),
        .x_pels_per_meter = std.mem.readInt(i32, data[24..28], .little),
        .y_pels_per_meter = std.mem.readInt(i32, data[28..32], .little),
        .clr_used = std.mem.readInt(u32, data[32..36], .little),
        .clr_important = std.mem.readInt(u32, data[36..40], .little),
    };
}

fn parseAudioFormat(data: []const u8) !Avi.AudioFormat {
    if (data.len < 16) return error.InsufficientData;

    const cb_size = if (data.len >= 18) std.mem.readInt(u16, data[16..18], .little) else 0;

    return Avi.AudioFormat{
        .format_tag = std.mem.readInt(u16, data[0..2], .little),
        .channels = std.mem.readInt(u16, data[2..4], .little),
        .samples_per_sec = std.mem.readInt(u32, data[4..8], .little),
        .avg_bytes_per_sec = std.mem.readInt(u32, data[8..12], .little),
        .block_align = std.mem.readInt(u16, data[12..14], .little),
        .bits_per_sample = std.mem.readInt(u16, data[14..16], .little),
        .cb_size = cb_size,
    };
}

/// Check if data is AVI file
pub fn isAvi(data: []const u8) bool {
    if (data.len < 12) return false;

    const riff_fourcc = Avi.FourCC.fromBytes(data[0..4].*);
    const form_type = Avi.FourCC.fromBytes(data[8..12].*);

    return riff_fourcc == .riff and form_type == .avi;
}
