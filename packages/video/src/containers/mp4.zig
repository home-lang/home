// Home Video Library - MP4 Container
// ISO Base Media File Format (ISO/IEC 14496-12)
// Supports MP4, MOV, M4A, M4V, 3GP

const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");
const err = @import("../core/error.zig");
const source = @import("../io/source.zig");
const target = @import("../io/target.zig");

pub const VideoError = err.VideoError;
pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;
pub const Timestamp = types.Timestamp;
pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const Source = source.Source;
pub const Target = target.Target;

// ============================================================================
// MP4 Box Types (FourCC codes)
// ============================================================================

pub const BoxType = enum(u32) {
    // Container boxes
    ftyp = fourcc("ftyp"), // File type
    moov = fourcc("moov"), // Movie (metadata container)
    mdat = fourcc("mdat"), // Media data
    free = fourcc("free"), // Free space
    skip = fourcc("skip"), // Skip
    wide = fourcc("wide"), // Wide (64-bit extension)
    moof = fourcc("moof"), // Movie fragment
    mfra = fourcc("mfra"), // Movie fragment random access

    // Movie boxes (inside moov)
    mvhd = fourcc("mvhd"), // Movie header
    trak = fourcc("trak"), // Track
    mvex = fourcc("mvex"), // Movie extends
    udta = fourcc("udta"), // User data
    meta = fourcc("meta"), // Metadata

    // Track boxes (inside trak)
    tkhd = fourcc("tkhd"), // Track header
    edts = fourcc("edts"), // Edit list container
    elst = fourcc("elst"), // Edit list
    mdia = fourcc("mdia"), // Media

    // Media boxes (inside mdia)
    mdhd = fourcc("mdhd"), // Media header
    hdlr = fourcc("hdlr"), // Handler reference
    minf = fourcc("minf"), // Media information

    // Media info boxes (inside minf)
    vmhd = fourcc("vmhd"), // Video media header
    smhd = fourcc("smhd"), // Sound media header
    hmhd = fourcc("hmhd"), // Hint media header
    nmhd = fourcc("nmhd"), // Null media header
    dinf = fourcc("dinf"), // Data information
    stbl = fourcc("stbl"), // Sample table

    // Data info boxes (inside dinf)
    dref = fourcc("dref"), // Data reference
    url_ = fourcc("url "), // URL

    // Sample table boxes (inside stbl)
    stsd = fourcc("stsd"), // Sample description
    stts = fourcc("stts"), // Time-to-sample
    ctts = fourcc("ctts"), // Composition time-to-sample
    stsc = fourcc("stsc"), // Sample-to-chunk
    stsz = fourcc("stsz"), // Sample size
    stco = fourcc("stco"), // Chunk offset (32-bit)
    co64 = fourcc("co64"), // Chunk offset (64-bit)
    stss = fourcc("stss"), // Sync sample (keyframes)
    sdtp = fourcc("sdtp"), // Sample dependency type

    // Video sample entries
    avc1 = fourcc("avc1"), // H.264/AVC
    avc3 = fourcc("avc3"), // H.264/AVC (in-band parameter sets)
    hev1 = fourcc("hev1"), // HEVC/H.265
    hvc1 = fourcc("hvc1"), // HEVC/H.265
    vp09 = fourcc("vp09"), // VP9
    av01 = fourcc("av01"), // AV1

    // Video config boxes
    avcC = fourcc("avcC"), // AVC decoder config
    hvcC = fourcc("hvcC"), // HEVC decoder config
    vpcC = fourcc("vpcC"), // VP codec config
    av1C = fourcc("av1C"), // AV1 codec config
    colr = fourcc("colr"), // Color info
    pasp = fourcc("pasp"), // Pixel aspect ratio

    // Audio sample entries
    mp4a = fourcc("mp4a"), // AAC/MP4 audio
    ac_3 = fourcc("ac-3"), // AC-3
    ec_3 = fourcc("ec-3"), // E-AC-3
    Opus = fourcc("Opus"), // Opus
    fLaC = fourcc("fLaC"), // FLAC
    alac = fourcc("alac"), // Apple Lossless

    // Audio config boxes
    esds = fourcc("esds"), // Elementary stream descriptor
    dac3 = fourcc("dac3"), // AC-3 config
    dec3 = fourcc("dec3"), // E-AC-3 config
    dOps = fourcc("dOps"), // Opus config
    dfLa = fourcc("dfLa"), // FLAC config

    // Fragment boxes
    mfhd = fourcc("mfhd"), // Movie fragment header
    traf = fourcc("traf"), // Track fragment
    tfhd = fourcc("tfhd"), // Track fragment header
    tfdt = fourcc("tfdt"), // Track fragment decode time
    trun = fourcc("trun"), // Track run
    saiz = fourcc("saiz"), // Sample auxiliary info sizes
    saio = fourcc("saio"), // Sample auxiliary info offsets

    // Metadata boxes
    ilst = fourcc("ilst"), // iTunes metadata list
    data = fourcc("data"), // Data atom

    // Unknown
    unknown = 0,

    pub fn fromBytes(bytes: [4]u8) BoxType {
        const value = std.mem.readInt(u32, &bytes, .big);
        return std.meta.intToEnum(BoxType, value) catch .unknown;
    }

    pub fn toBytes(self: BoxType) [4]u8 {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intFromEnum(self), .big);
        return bytes;
    }
};

fn fourcc(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

// ============================================================================
// MP4 Box Header
// ============================================================================

pub const BoxHeader = struct {
    box_type: BoxType,
    size: u64, // Total box size including header
    header_size: u8, // 8 for normal, 16 for extended size
    data_offset: u64, // Offset to box data in file

    const Self = @This();

    pub fn dataSize(self: Self) u64 {
        return self.size - self.header_size;
    }
};

// ============================================================================
// MP4 Track Info
// ============================================================================

pub const TrackType = enum {
    video,
    audio,
    subtitle,
    hint,
    other,
};

pub const TrackInfo = struct {
    track_id: u32,
    track_type: TrackType,
    duration: u64, // In timescale units
    timescale: u32,

    // Video specific
    width: u16,
    height: u16,
    video_codec: VideoCodec,

    // Audio specific
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u16,
    audio_codec: AudioCodec,

    // Codec config
    codec_config: ?[]const u8,

    const Self = @This();

    pub fn durationSeconds(self: Self) f64 {
        if (self.timescale == 0) return 0;
        return @as(f64, @floatFromInt(self.duration)) / @as(f64, @floatFromInt(self.timescale));
    }
};

// ============================================================================
// Sample Table Entries
// ============================================================================

/// Time-to-sample entry
pub const SttsEntry = struct {
    sample_count: u32,
    sample_delta: u32, // Duration in timescale units
};

/// Sample-to-chunk entry
pub const StscEntry = struct {
    first_chunk: u32,
    samples_per_chunk: u32,
    sample_description_index: u32,
};

/// Composition time offset entry
pub const CttsEntry = struct {
    sample_count: u32,
    sample_offset: i32, // Can be negative in version 1
};

// ============================================================================
// Sample Table (stbl) - Core of MP4 structure
// ============================================================================

pub const SampleTable = struct {
    // Time-to-sample (stts)
    time_to_sample: std.ArrayList(SttsEntry),

    // Composition time-to-sample (ctts) - optional
    comp_time_to_sample: ?std.ArrayList(CttsEntry),

    // Sample-to-chunk (stsc)
    sample_to_chunk: std.ArrayList(StscEntry),

    // Sample sizes (stsz) - either fixed or per-sample
    sample_size: u32, // If non-zero, all samples have this size
    sample_sizes: ?std.ArrayList(u32), // Per-sample sizes if sample_size == 0

    // Chunk offsets (stco/co64)
    chunk_offsets: std.ArrayList(u64),

    // Sync samples (stss) - keyframes, optional
    sync_samples: ?std.ArrayList(u32),

    // Cached values
    total_samples: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .time_to_sample = .empty,
            .comp_time_to_sample = null,
            .sample_to_chunk = .empty,
            .sample_size = 0,
            .sample_sizes = null,
            .chunk_offsets = .empty,
            .sync_samples = null,
            .total_samples = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.time_to_sample.deinit(self.allocator);
        if (self.comp_time_to_sample) |*ctts| ctts.deinit(self.allocator);
        self.sample_to_chunk.deinit(self.allocator);
        if (self.sample_sizes) |*sizes| sizes.deinit(self.allocator);
        self.chunk_offsets.deinit(self.allocator);
        if (self.sync_samples) |*ss| ss.deinit(self.allocator);
    }

    /// Get size of a specific sample (0-indexed)
    pub fn getSampleSize(self: *const Self, sample_index: u32) ?u32 {
        if (self.sample_size != 0) {
            return self.sample_size;
        }
        if (self.sample_sizes) |sizes| {
            if (sample_index < sizes.items.len) {
                return sizes.items[sample_index];
            }
        }
        return null;
    }

    /// Get file offset of a specific sample (0-indexed)
    pub fn getSampleOffset(self: *const Self, sample_index: u32) ?u64 {
        // Find which chunk contains this sample
        var samples_before: u32 = 0;
        var chunk_index: u32 = 0;
        var samples_in_chunk: u32 = 0;

        for (self.sample_to_chunk.items, 0..) |entry, i| {
            const next_first_chunk = if (i + 1 < self.sample_to_chunk.items.len)
                self.sample_to_chunk.items[i + 1].first_chunk
            else
                @as(u32, @intCast(self.chunk_offsets.items.len)) + 1;

            const chunks_with_this_count = next_first_chunk - entry.first_chunk;
            const samples_in_range = chunks_with_this_count * entry.samples_per_chunk;

            if (samples_before + samples_in_range > sample_index) {
                // Sample is in this range
                const sample_in_range = sample_index - samples_before;
                chunk_index = entry.first_chunk - 1 + sample_in_range / entry.samples_per_chunk;
                samples_in_chunk = sample_in_range % entry.samples_per_chunk;
                break;
            }

            samples_before += samples_in_range;
        }

        if (chunk_index >= self.chunk_offsets.items.len) {
            return null;
        }

        // Get chunk offset
        var offset = self.chunk_offsets.items[chunk_index];

        // Add sizes of samples before this one in the chunk
        const first_sample_in_chunk = sample_index - samples_in_chunk;
        var i: u32 = first_sample_in_chunk;
        while (i < sample_index) : (i += 1) {
            offset += self.getSampleSize(i) orelse 0;
        }

        return offset;
    }

    /// Check if sample is a keyframe
    pub fn isSyncSample(self: *const Self, sample_index: u32) bool {
        if (self.sync_samples) |ss| {
            // sync_samples uses 1-based indexing
            for (ss.items) |sync| {
                if (sync == sample_index + 1) return true;
                if (sync > sample_index + 1) break;
            }
            return false;
        }
        // If no sync sample table, all samples are sync samples
        return true;
    }

    /// Get decode timestamp for a sample
    pub fn getSampleDts(self: *const Self, sample_index: u32) u64 {
        var dts: u64 = 0;
        var sample_count: u32 = 0;

        for (self.time_to_sample.items) |entry| {
            if (sample_count + entry.sample_count > sample_index) {
                dts += @as(u64, sample_index - sample_count) * entry.sample_delta;
                break;
            }
            dts += @as(u64, entry.sample_count) * entry.sample_delta;
            sample_count += entry.sample_count;
        }

        return dts;
    }

    /// Get presentation timestamp for a sample (DTS + composition offset)
    pub fn getSamplePts(self: *const Self, sample_index: u32) u64 {
        const dts = self.getSampleDts(sample_index);

        if (self.comp_time_to_sample) |ctts| {
            var sample_count: u32 = 0;
            for (ctts.items) |entry| {
                if (sample_count + entry.sample_count > sample_index) {
                    if (entry.sample_offset >= 0) {
                        return dts + @as(u64, @intCast(entry.sample_offset));
                    } else {
                        const neg: u64 = @intCast(-entry.sample_offset);
                        return if (dts >= neg) dts - neg else 0;
                    }
                }
                sample_count += entry.sample_count;
            }
        }

        return dts;
    }
};

// ============================================================================
// MP4 Reader
// ============================================================================

pub const Mp4Reader = struct {
    source: *Source,
    allocator: std.mem.Allocator,

    // Parsed data
    file_size: u64,
    brand: [4]u8,
    compatible_brands: std.ArrayList([4]u8),
    timescale: u32, // Movie timescale
    duration: u64, // Movie duration in timescale units

    // Tracks
    tracks: std.ArrayList(Track),

    // mdat location
    mdat_offset: u64,
    mdat_size: u64,

    const Self = @This();

    pub const Track = struct {
        info: TrackInfo,
        sample_table: SampleTable,
    };

    pub fn init(allocator: std.mem.Allocator, src: *Source) Self {
        return Self{
            .source = src,
            .allocator = allocator,
            .file_size = 0,
            .brand = [_]u8{ 0, 0, 0, 0 },
            .compatible_brands = .empty,
            .timescale = 0,
            .duration = 0,
            .tracks = .empty,
            .mdat_offset = 0,
            .mdat_size = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.compatible_brands.deinit(self.allocator);
        for (self.tracks.items) |*track| {
            track.sample_table.deinit();
            if (track.info.codec_config) |config| {
                self.allocator.free(config);
            }
        }
        self.tracks.deinit(self.allocator);
    }

    /// Parse the MP4 file structure
    pub fn parse(self: *Self) !void {
        // Get file size
        self.file_size = try self.source.getSize();

        // Parse top-level boxes
        var offset: u64 = 0;
        while (offset < self.file_size) {
            const header = try self.readBoxHeader(offset);

            switch (header.box_type) {
                .ftyp => try self.parseFtyp(header),
                .moov => try self.parseMoov(header),
                .mdat => {
                    self.mdat_offset = header.data_offset;
                    self.mdat_size = header.dataSize();
                },
                else => {}, // Skip unknown boxes
            }

            offset += header.size;
            if (header.size == 0) break; // Size 0 means extends to EOF
        }

        // Validate we found required boxes
        if (self.timescale == 0) {
            return VideoError.MissingRequiredAtom;
        }
    }

    /// Read box header at given offset
    fn readBoxHeader(self: *Self, offset: u64) !BoxHeader {
        try self.source.seekTo(offset);

        // Read size and type
        var header_buf: [8]u8 = undefined;
        const bytes_read = try self.source.read(&header_buf);
        if (bytes_read < 8) return VideoError.TruncatedData;

        var size: u64 = std.mem.readInt(u32, header_buf[0..4], .big);
        const box_type = BoxType.fromBytes(header_buf[4..8].*);
        var header_size: u8 = 8;

        // Handle extended size
        if (size == 1) {
            var ext_buf: [8]u8 = undefined;
            const ext_read = try self.source.read(&ext_buf);
            if (ext_read < 8) return VideoError.TruncatedData;
            size = std.mem.readInt(u64, &ext_buf, .big);
            header_size = 16;
        } else if (size == 0) {
            // Box extends to end of file
            size = self.file_size - offset;
        }

        return BoxHeader{
            .box_type = box_type,
            .size = size,
            .header_size = header_size,
            .data_offset = offset + header_size,
        };
    }

    /// Parse ftyp box
    fn parseFtyp(self: *Self, header: BoxHeader) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        @memcpy(&self.brand, buf[0..4]);
        // buf[4..8] is minor_version

        // Read compatible brands
        const remaining = header.dataSize() - 8;
        var i: u64 = 0;
        while (i < remaining) : (i += 4) {
            var brand: [4]u8 = undefined;
            const read = try self.source.read(&brand);
            if (read < 4) break;
            try self.compatible_brands.append(self.allocator, brand);
        }
    }

    /// Parse moov box (movie container)
    fn parseMoov(self: *Self, header: BoxHeader) !void {
        var offset = header.data_offset;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .mvhd => try self.parseMvhd(child),
                .trak => try self.parseTrak(child),
                .udta => {}, // User data - skip for now
                .meta => {}, // Metadata - skip for now
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse mvhd box (movie header)
    fn parseMvhd(self: *Self, header: BoxHeader) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [108]u8 = undefined;
        _ = try self.source.read(&buf);

        const version = buf[0];

        if (version == 0) {
            // 32-bit times
            self.timescale = std.mem.readInt(u32, buf[12..16], .big);
            self.duration = std.mem.readInt(u32, buf[16..20], .big);
        } else {
            // 64-bit times (version 1)
            self.timescale = std.mem.readInt(u32, buf[20..24], .big);
            self.duration = std.mem.readInt(u64, buf[24..32], .big);
        }
    }

    /// Parse trak box (track)
    fn parseTrak(self: *Self, header: BoxHeader) !void {
        var track = Track{
            .info = TrackInfo{
                .track_id = 0,
                .track_type = .other,
                .duration = 0,
                .timescale = 0,
                .width = 0,
                .height = 0,
                .video_codec = .unknown,
                .channels = 0,
                .sample_rate = 0,
                .bits_per_sample = 0,
                .audio_codec = .unknown,
                .codec_config = null,
            },
            .sample_table = SampleTable.init(self.allocator),
        };

        var offset = header.data_offset;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .tkhd => try self.parseTkhd(child, &track.info),
                .mdia => try self.parseMdia(child, &track),
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }

        try self.tracks.append(self.allocator, track);
    }

    /// Parse tkhd box (track header)
    fn parseTkhd(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [92]u8 = undefined;
        _ = try self.source.read(&buf);

        const version = buf[0];

        if (version == 0) {
            info.track_id = std.mem.readInt(u32, buf[12..16], .big);
            info.duration = std.mem.readInt(u32, buf[20..24], .big);
            // Width and height are 16.16 fixed point at bytes 76-84
            info.width = @intCast(std.mem.readInt(u32, buf[76..80], .big) >> 16);
            info.height = @intCast(std.mem.readInt(u32, buf[80..84], .big) >> 16);
        } else {
            info.track_id = std.mem.readInt(u32, buf[20..24], .big);
            info.duration = std.mem.readInt(u64, buf[28..36], .big);
            info.width = @intCast(std.mem.readInt(u32, buf[84..88], .big) >> 16);
            info.height = @intCast(std.mem.readInt(u32, buf[88..92], .big) >> 16);
        }
    }

    /// Parse mdia box (media)
    fn parseMdia(self: *Self, header: BoxHeader, track: *Track) !void {
        var offset = header.data_offset;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .mdhd => try self.parseMdhd(child, &track.info),
                .hdlr => try self.parseHdlr(child, &track.info),
                .minf => try self.parseMinf(child, track),
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse mdhd box (media header)
    fn parseMdhd(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [32]u8 = undefined;
        _ = try self.source.read(&buf);

        const version = buf[0];

        if (version == 0) {
            info.timescale = std.mem.readInt(u32, buf[12..16], .big);
            info.duration = std.mem.readInt(u32, buf[16..20], .big);
        } else {
            info.timescale = std.mem.readInt(u32, buf[20..24], .big);
            info.duration = std.mem.readInt(u64, buf[24..32], .big);
        }
    }

    /// Parse hdlr box (handler reference)
    fn parseHdlr(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [12]u8 = undefined;
        _ = try self.source.read(&buf);

        const handler_type = buf[8..12];

        if (std.mem.eql(u8, handler_type, "vide")) {
            info.track_type = .video;
        } else if (std.mem.eql(u8, handler_type, "soun")) {
            info.track_type = .audio;
        } else if (std.mem.eql(u8, handler_type, "subt") or std.mem.eql(u8, handler_type, "text")) {
            info.track_type = .subtitle;
        } else if (std.mem.eql(u8, handler_type, "hint")) {
            info.track_type = .hint;
        }
    }

    /// Parse minf box (media information)
    fn parseMinf(self: *Self, header: BoxHeader, track: *Track) !void {
        var offset = header.data_offset;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .stbl => try self.parseStbl(child, track),
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse stbl box (sample table)
    fn parseStbl(self: *Self, header: BoxHeader, track: *Track) !void {
        var offset = header.data_offset;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .stsd => try self.parseStsd(child, &track.info),
                .stts => try self.parseStts(child, &track.sample_table),
                .ctts => try self.parseCtts(child, &track.sample_table),
                .stsc => try self.parseStsc(child, &track.sample_table),
                .stsz => try self.parseStsz(child, &track.sample_table),
                .stco => try self.parseStco(child, &track.sample_table),
                .co64 => try self.parseCo64(child, &track.sample_table),
                .stss => try self.parseStss(child, &track.sample_table),
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse stsd box (sample description)
    fn parseStsd(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);
        if (entry_count == 0) return;

        // Read first sample entry
        const entry_header = try self.readBoxHeader(header.data_offset + 8);

        switch (entry_header.box_type) {
            // Video codecs
            .avc1, .avc3 => {
                info.video_codec = .h264;
                try self.parseVisualSampleEntry(entry_header, info);
            },
            .hev1, .hvc1 => {
                info.video_codec = .hevc;
                try self.parseVisualSampleEntry(entry_header, info);
            },
            .vp09 => {
                info.video_codec = .vp9;
                try self.parseVisualSampleEntry(entry_header, info);
            },
            .av01 => {
                info.video_codec = .av1;
                try self.parseVisualSampleEntry(entry_header, info);
            },

            // Audio codecs
            .mp4a => {
                info.audio_codec = .aac;
                try self.parseAudioSampleEntry(entry_header, info);
            },
            .Opus => {
                info.audio_codec = .opus;
                try self.parseAudioSampleEntry(entry_header, info);
            },
            .fLaC => {
                info.audio_codec = .flac;
                try self.parseAudioSampleEntry(entry_header, info);
            },
            .alac => {
                info.audio_codec = .alac;
                try self.parseAudioSampleEntry(entry_header, info);
            },
            else => {},
        }
    }

    /// Parse visual sample entry (video codec config)
    fn parseVisualSampleEntry(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [78]u8 = undefined;
        _ = try self.source.read(&buf);

        // Width and height at bytes 24-28
        info.width = std.mem.readInt(u16, buf[24..26], .big);
        info.height = std.mem.readInt(u16, buf[26..28], .big);

        // Parse child boxes for codec config
        var offset = header.data_offset + 78;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .avcC, .hvcC, .vpcC, .av1C => {
                    // Read codec config
                    const config_size = child.dataSize();
                    if (config_size > 0 and config_size < 1024 * 1024) {
                        const config = try self.allocator.alloc(u8, @intCast(config_size));
                        try self.source.seekTo(child.data_offset);
                        _ = try self.source.read(config);
                        info.codec_config = config;
                    }
                },
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse audio sample entry
    fn parseAudioSampleEntry(self: *Self, header: BoxHeader, info: *TrackInfo) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [28]u8 = undefined;
        _ = try self.source.read(&buf);

        // Channels at bytes 16-18, sample rate at 24-28 (16.16 fixed point)
        info.channels = @intCast(std.mem.readInt(u16, buf[16..18], .big));
        info.bits_per_sample = std.mem.readInt(u16, buf[18..20], .big);
        info.sample_rate = std.mem.readInt(u32, buf[24..28], .big) >> 16;

        // Parse child boxes for codec config (esds for AAC)
        var offset = header.data_offset + 28;
        const end = header.data_offset + header.dataSize();

        while (offset < end) {
            const child = try self.readBoxHeader(offset);

            switch (child.box_type) {
                .esds => {
                    // Read elementary stream descriptor
                    const config_size = child.dataSize();
                    if (config_size > 0 and config_size < 1024 * 1024) {
                        const config = try self.allocator.alloc(u8, @intCast(config_size));
                        try self.source.seekTo(child.data_offset);
                        _ = try self.source.read(config);
                        info.codec_config = config;
                    }
                },
                .dOps, .dfLa => {
                    // Opus/FLAC config
                    const config_size = child.dataSize();
                    if (config_size > 0 and config_size < 1024 * 1024) {
                        const config = try self.allocator.alloc(u8, @intCast(config_size));
                        try self.source.seekTo(child.data_offset);
                        _ = try self.source.read(config);
                        info.codec_config = config;
                    }
                },
                else => {},
            }

            offset += child.size;
            if (child.size == 0) break;
        }
    }

    /// Parse stts box (time-to-sample)
    fn parseStts(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var total_samples: u32 = 0;
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var entry_buf: [8]u8 = undefined;
            _ = try self.source.read(&entry_buf);

            const entry = SttsEntry{
                .sample_count = std.mem.readInt(u32, entry_buf[0..4], .big),
                .sample_delta = std.mem.readInt(u32, entry_buf[4..8], .big),
            };
            total_samples += entry.sample_count;
            try stbl.time_to_sample.append(self.allocator, entry);
        }
        stbl.total_samples = total_samples;
    }

    /// Parse ctts box (composition time-to-sample)
    fn parseCtts(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const version = buf[0];
        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var ctts: std.ArrayList(CttsEntry) = .empty;

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var entry_buf: [8]u8 = undefined;
            _ = try self.source.read(&entry_buf);

            const entry = CttsEntry{
                .sample_count = std.mem.readInt(u32, entry_buf[0..4], .big),
                .sample_offset = if (version == 0)
                    @intCast(std.mem.readInt(u32, entry_buf[4..8], .big))
                else
                    std.mem.readInt(i32, entry_buf[4..8], .big),
            };
            try ctts.append(self.allocator, entry);
        }
        stbl.comp_time_to_sample = ctts;
    }

    /// Parse stsc box (sample-to-chunk)
    fn parseStsc(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var entry_buf: [12]u8 = undefined;
            _ = try self.source.read(&entry_buf);

            const entry = StscEntry{
                .first_chunk = std.mem.readInt(u32, entry_buf[0..4], .big),
                .samples_per_chunk = std.mem.readInt(u32, entry_buf[4..8], .big),
                .sample_description_index = std.mem.readInt(u32, entry_buf[8..12], .big),
            };
            try stbl.sample_to_chunk.append(self.allocator, entry);
        }
    }

    /// Parse stsz box (sample sizes)
    fn parseStsz(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [12]u8 = undefined;
        _ = try self.source.read(&buf);

        stbl.sample_size = std.mem.readInt(u32, buf[4..8], .big);
        const sample_count = std.mem.readInt(u32, buf[8..12], .big);

        if (stbl.sample_size == 0) {
            // Variable size samples
            var sizes: std.ArrayList(u32) = .empty;
            var i: u32 = 0;
            while (i < sample_count) : (i += 1) {
                var size_buf: [4]u8 = undefined;
                _ = try self.source.read(&size_buf);
                try sizes.append(self.allocator, std.mem.readInt(u32, &size_buf, .big));
            }
            stbl.sample_sizes = sizes;
        }

        if (stbl.total_samples == 0) {
            stbl.total_samples = sample_count;
        }
    }

    /// Parse stco box (chunk offsets 32-bit)
    fn parseStco(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var offset_buf: [4]u8 = undefined;
            _ = try self.source.read(&offset_buf);
            try stbl.chunk_offsets.append(self.allocator, std.mem.readInt(u32, &offset_buf, .big));
        }
    }

    /// Parse co64 box (chunk offsets 64-bit)
    fn parseCo64(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var offset_buf: [8]u8 = undefined;
            _ = try self.source.read(&offset_buf);
            try stbl.chunk_offsets.append(self.allocator, std.mem.readInt(u64, &offset_buf, .big));
        }
    }

    /// Parse stss box (sync samples / keyframes)
    fn parseStss(self: *Self, header: BoxHeader, stbl: *SampleTable) !void {
        try self.source.seekTo(header.data_offset);

        var buf: [8]u8 = undefined;
        _ = try self.source.read(&buf);

        const entry_count = std.mem.readInt(u32, buf[4..8], .big);

        var ss: std.ArrayList(u32) = .empty;
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var sample_buf: [4]u8 = undefined;
            _ = try self.source.read(&sample_buf);
            try ss.append(self.allocator, std.mem.readInt(u32, &sample_buf, .big));
        }
        stbl.sync_samples = ss;
    }

    // ========================================================================
    // Public API
    // ========================================================================

    /// Get number of tracks
    pub fn getTrackCount(self: *const Self) usize {
        return self.tracks.items.len;
    }

    /// Get track info
    pub fn getTrack(self: *const Self, index: usize) ?*const Track {
        if (index >= self.tracks.items.len) return null;
        return &self.tracks.items[index];
    }

    /// Get video track (first one found)
    pub fn getVideoTrack(self: *const Self) ?*const Track {
        for (self.tracks.items) |*track| {
            if (track.info.track_type == .video) return track;
        }
        return null;
    }

    /// Get audio track (first one found)
    pub fn getAudioTrack(self: *const Self) ?*const Track {
        for (self.tracks.items) |*track| {
            if (track.info.track_type == .audio) return track;
        }
        return null;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.timescale == 0) return 0;
        return @as(f64, @floatFromInt(self.duration)) / @as(f64, @floatFromInt(self.timescale));
    }

    /// Read sample data
    pub fn readSample(self: *Self, track_index: usize, sample_index: u32, buffer: []u8) !usize {
        if (track_index >= self.tracks.items.len) return VideoError.InvalidStreamIndex;

        const track = &self.tracks.items[track_index];
        const offset = track.sample_table.getSampleOffset(sample_index) orelse return VideoError.InvalidArgument;
        const size = track.sample_table.getSampleSize(sample_index) orelse return VideoError.InvalidArgument;

        if (buffer.len < size) return VideoError.BufferTooSmall;

        try self.source.seekTo(offset);
        return try self.source.read(buffer[0..size]);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BoxType fourcc" {
    try std.testing.expectEqual(BoxType.ftyp, BoxType.fromBytes("ftyp".*));
    try std.testing.expectEqual(BoxType.moov, BoxType.fromBytes("moov".*));
    try std.testing.expectEqual(BoxType.mdat, BoxType.fromBytes("mdat".*));
    try std.testing.expectEqual(BoxType.avc1, BoxType.fromBytes("avc1".*));
    try std.testing.expectEqual(BoxType.mp4a, BoxType.fromBytes("mp4a".*));
}

test "BoxType toBytes roundtrip" {
    const types_to_test = [_]BoxType{ .ftyp, .moov, .mdat, .trak, .stbl };
    for (types_to_test) |bt| {
        const bytes = bt.toBytes();
        try std.testing.expectEqual(bt, BoxType.fromBytes(bytes));
    }
}

test "SampleTable init and deinit" {
    var stbl = SampleTable.init(std.testing.allocator);
    defer stbl.deinit();

    try stbl.time_to_sample.append(std.testing.allocator, .{
        .sample_count = 100,
        .sample_delta = 1024,
    });
    try stbl.chunk_offsets.append(std.testing.allocator, 1000);

    try std.testing.expectEqual(@as(usize, 1), stbl.time_to_sample.items.len);
}
