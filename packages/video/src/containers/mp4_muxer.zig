// Home Video Library - MP4 Muxer
// Write MP4/MOV files (ISO Base Media File Format)

const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");
const err = @import("../core/error.zig");
const target = @import("../io/target.zig");
const mp4 = @import("mp4.zig");

pub const VideoError = err.VideoError;
pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;
pub const Target = target.Target;
pub const BufferTarget = target.BufferTarget;
pub const BoxType = mp4.BoxType;

// ============================================================================
// Sample Entry for muxing
// ============================================================================

pub const Sample = struct {
    data: []const u8,
    duration: u32, // In timescale units
    pts: i64, // Presentation timestamp
    dts: i64, // Decode timestamp
    is_keyframe: bool,
    composition_offset: i32, // PTS - DTS
};

// ============================================================================
// Track Configuration
// ============================================================================

pub const VideoTrackConfig = struct {
    width: u16,
    height: u16,
    codec: types.VideoCodec,
    timescale: u32 = 90000, // Default video timescale
    codec_config: ?[]const u8 = null, // avcC, hvcC, etc.
};

pub const AudioTrackConfig = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u16 = 16,
    codec: types.AudioCodec,
    timescale: u32 = 0, // 0 = use sample_rate
    codec_config: ?[]const u8 = null, // esds, dOps, etc.
};

// ============================================================================
// MP4 Muxer
// ============================================================================

pub const Mp4Muxer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    // Track data
    tracks: std.ArrayList(TrackData),

    // Configuration
    brand: [4]u8 = "isom".*,
    minor_version: u32 = 512,
    compatible_brands: std.ArrayList([4]u8),

    // State
    mdat_start: usize = 0,
    mdat_size: u64 = 0,

    const Self = @This();

    const TrackData = struct {
        config: TrackConfig,
        samples: std.ArrayList(SampleInfo),
        chunk_offsets: std.ArrayList(u64),
        current_chunk_samples: u32,
        current_chunk_offset: u64,
        duration: u64,

        const SampleInfo = struct {
            size: u32,
            duration: u32,
            composition_offset: i32,
            is_keyframe: bool,
        };
    };

    const TrackConfig = union(enum) {
        video: VideoTrackConfig,
        audio: AudioTrackConfig,

        pub fn timescale(self: TrackConfig) u32 {
            return switch (self) {
                .video => |v| v.timescale,
                .audio => |a| if (a.timescale != 0) a.timescale else a.sample_rate,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .buffer = .empty,
            .tracks = .empty,
            .compatible_brands = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
        for (self.tracks.items) |*track| {
            track.samples.deinit(self.allocator);
            track.chunk_offsets.deinit(self.allocator);
        }
        self.tracks.deinit(self.allocator);
        self.compatible_brands.deinit(self.allocator);
    }

    /// Add a video track
    pub fn addVideoTrack(self: *Self, config: VideoTrackConfig) !u32 {
        const track_id: u32 = @intCast(self.tracks.items.len + 1);

        try self.tracks.append(self.allocator, .{
            .config = .{ .video = config },
            .samples = .empty,
            .chunk_offsets = .empty,
            .current_chunk_samples = 0,
            .current_chunk_offset = 0,
            .duration = 0,
        });

        return track_id;
    }

    /// Add an audio track
    pub fn addAudioTrack(self: *Self, config: AudioTrackConfig) !u32 {
        const track_id: u32 = @intCast(self.tracks.items.len + 1);

        try self.tracks.append(self.allocator, .{
            .config = .{ .audio = config },
            .samples = .empty,
            .chunk_offsets = .empty,
            .current_chunk_samples = 0,
            .current_chunk_offset = 0,
            .duration = 0,
        });

        return track_id;
    }

    /// Write a sample to a track
    pub fn writeSample(self: *Self, track_id: u32, sample: Sample) !void {
        if (track_id == 0 or track_id > self.tracks.items.len) {
            return VideoError.InvalidStreamIndex;
        }

        var track = &self.tracks.items[track_id - 1];

        // Start new chunk if needed (every 10 samples or on keyframe)
        if (track.current_chunk_samples == 0 or
            (sample.is_keyframe and track.current_chunk_samples > 0) or
            track.current_chunk_samples >= 10)
        {
            if (track.current_chunk_samples > 0) {
                try track.chunk_offsets.append(self.allocator, track.current_chunk_offset);
            }
            track.current_chunk_offset = self.mdat_start + 8 + self.mdat_size;
            track.current_chunk_samples = 0;
        }

        // Add sample info
        try track.samples.append(self.allocator, .{
            .size = @intCast(sample.data.len),
            .duration = sample.duration,
            .composition_offset = sample.composition_offset,
            .is_keyframe = sample.is_keyframe,
        });

        // Write sample data to mdat
        try self.buffer.appendSlice(self.allocator, sample.data);
        self.mdat_size += sample.data.len;
        track.current_chunk_samples += 1;
        track.duration += sample.duration;
    }

    /// Finalize and get MP4 data
    pub fn finalize(self: *Self) ![]u8 {
        // Finalize last chunks
        for (self.tracks.items) |*track| {
            if (track.current_chunk_samples > 0) {
                try track.chunk_offsets.append(self.allocator, track.current_chunk_offset);
            }
        }

        // Build the complete file
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);

        // Calculate moov size first (needed for mdat offset fixup)
        const ftyp_size = self.calculateFtypSize();

        // Write ftyp
        try self.writeFtyp(&output);

        // Write mdat header with placeholder size
        try writeU32Be(&output, self.allocator, 1); // Extended size marker
        try output.appendSlice(self.allocator, "mdat");
        try writeU64Be(&output, self.allocator, self.mdat_size + 16); // 16 = header size

        // Update chunk offsets (add ftyp + mdat header offset)
        const data_offset = ftyp_size + 16; // ftyp + mdat header
        for (self.tracks.items) |*track| {
            for (track.chunk_offsets.items) |*offset| {
                offset.* += data_offset;
            }
        }

        // Write mdat content
        try output.appendSlice(self.allocator, self.buffer.items);

        // Write moov
        try self.writeMoov(&output);

        return output.toOwnedSlice(self.allocator);
    }

    fn calculateFtypSize(self: *const Self) usize {
        return 8 + 8 + (self.compatible_brands.items.len + 1) * 4;
    }

    fn writeFtyp(self: *Self, output: *std.ArrayList(u8)) !void {
        const size: u32 = @intCast(self.calculateFtypSize());
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "ftyp");
        try output.appendSlice(self.allocator, &self.brand);
        try writeU32Be(output, self.allocator, self.minor_version);

        // Write isom as compatible brand
        try output.appendSlice(self.allocator, "isom");

        for (self.compatible_brands.items) |brand| {
            try output.appendSlice(self.allocator, &brand);
        }
    }

    fn writeMoov(self: *Self, output: *std.ArrayList(u8)) !void {
        const moov_start = output.items.len;

        // Placeholder for size
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "moov");

        // Write mvhd
        try self.writeMvhd(output);

        // Write tracks
        for (self.tracks.items, 0..) |*track, i| {
            try self.writeTrak(output, track, @intCast(i + 1));
        }

        // Fix moov size
        const moov_size: u32 = @intCast(output.items.len - moov_start);
        std.mem.writeInt(u32, output.items[moov_start..][0..4], moov_size, .big);
    }

    fn writeMvhd(self: *Self, output: *std.ArrayList(u8)) !void {
        // Calculate movie duration (max of all tracks)
        var max_duration: u64 = 0;
        const timescale: u32 = 1000; // Movie timescale

        for (self.tracks.items) |track| {
            const track_ts = track.config.timescale();
            const track_dur_in_movie_ts = @divTrunc(track.duration * timescale, track_ts);
            if (track_dur_in_movie_ts > max_duration) {
                max_duration = track_dur_in_movie_ts;
            }
        }

        const size: u32 = 108; // Version 0 mvhd
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "mvhd");

        // Version and flags
        try writeU32Be(output, self.allocator, 0);

        // Creation/modification time
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Timescale and duration
        try writeU32Be(output, self.allocator, timescale);
        try writeU32Be(output, self.allocator, @intCast(max_duration));

        // Rate (1.0 = 0x00010000)
        try writeU32Be(output, self.allocator, 0x00010000);

        // Volume (1.0 = 0x0100)
        try writeU16Be(output, self.allocator, 0x0100);

        // Reserved
        try writeU16Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Matrix (identity)
        try writeU32Be(output, self.allocator, 0x00010000);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0x00010000);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0x40000000);

        // Pre-defined (6 * 4 bytes)
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            try writeU32Be(output, self.allocator, 0);
        }

        // Next track ID
        try writeU32Be(output, self.allocator, @intCast(self.tracks.items.len + 1));
    }

    fn writeTrak(self: *Self, output: *std.ArrayList(u8), track: *TrackData, track_id: u32) !void {
        const trak_start = output.items.len;
        try writeU32Be(output, self.allocator, 0); // Placeholder
        try output.appendSlice(self.allocator, "trak");

        try self.writeTkhd(output, track, track_id);
        try self.writeMdia(output, track);

        const trak_size: u32 = @intCast(output.items.len - trak_start);
        std.mem.writeInt(u32, output.items[trak_start..][0..4], trak_size, .big);
    }

    fn writeTkhd(self: *Self, output: *std.ArrayList(u8), track: *TrackData, track_id: u32) !void {
        const size: u32 = 92; // Version 0
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "tkhd");

        // Version and flags (track enabled, in movie, in preview)
        try writeU32Be(output, self.allocator, 0x00000007);

        // Creation/modification time
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Track ID
        try writeU32Be(output, self.allocator, track_id);

        // Reserved
        try writeU32Be(output, self.allocator, 0);

        // Duration (in movie timescale)
        const movie_ts: u32 = 1000;
        const track_ts = track.config.timescale();
        const duration = @divTrunc(track.duration * movie_ts, track_ts);
        try writeU32Be(output, self.allocator, @intCast(duration));

        // Reserved
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Layer and alternate group
        try writeU16Be(output, self.allocator, 0);
        try writeU16Be(output, self.allocator, 0);

        // Volume (audio = 0x0100, video = 0)
        const volume: u16 = switch (track.config) {
            .audio => 0x0100,
            .video => 0,
        };
        try writeU16Be(output, self.allocator, volume);

        // Reserved
        try writeU16Be(output, self.allocator, 0);

        // Matrix (identity)
        try writeU32Be(output, self.allocator, 0x00010000);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0x00010000);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0x40000000);

        // Width and height (16.16 fixed point)
        switch (track.config) {
            .video => |v| {
                try writeU32Be(output, self.allocator, @as(u32, v.width) << 16);
                try writeU32Be(output, self.allocator, @as(u32, v.height) << 16);
            },
            .audio => {
                try writeU32Be(output, self.allocator, 0);
                try writeU32Be(output, self.allocator, 0);
            },
        }
    }

    fn writeMdia(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const mdia_start = output.items.len;
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "mdia");

        try self.writeMdhd(output, track);
        try self.writeHdlr(output, track);
        try self.writeMinf(output, track);

        const mdia_size: u32 = @intCast(output.items.len - mdia_start);
        std.mem.writeInt(u32, output.items[mdia_start..][0..4], mdia_size, .big);
    }

    fn writeMdhd(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const size: u32 = 32; // Version 0
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "mdhd");

        // Version and flags
        try writeU32Be(output, self.allocator, 0);

        // Creation/modification time
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Timescale
        try writeU32Be(output, self.allocator, track.config.timescale());

        // Duration
        try writeU32Be(output, self.allocator, @intCast(track.duration));

        // Language (und = undetermined)
        try writeU16Be(output, self.allocator, 0x55C4);

        // Pre-defined
        try writeU16Be(output, self.allocator, 0);
    }

    fn writeHdlr(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const handler_type: [4]u8 = switch (track.config) {
            .video => "vide".*,
            .audio => "soun".*,
        };
        const name = switch (track.config) {
            .video => "VideoHandler",
            .audio => "SoundHandler",
        };

        const size: u32 = @intCast(32 + name.len + 1);
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "hdlr");

        // Version and flags
        try writeU32Be(output, self.allocator, 0);

        // Pre-defined
        try writeU32Be(output, self.allocator, 0);

        // Handler type
        try output.appendSlice(self.allocator, &handler_type);

        // Reserved
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, 0);

        // Name (null-terminated)
        try output.appendSlice(self.allocator, name);
        try output.append(self.allocator, 0);
    }

    fn writeMinf(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const minf_start = output.items.len;
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "minf");

        // Write vmhd or smhd
        switch (track.config) {
            .video => try self.writeVmhd(output),
            .audio => try self.writeSmhd(output),
        }

        try self.writeDinf(output);
        try self.writeStbl(output, track);

        const minf_size: u32 = @intCast(output.items.len - minf_start);
        std.mem.writeInt(u32, output.items[minf_start..][0..4], minf_size, .big);
    }

    fn writeVmhd(self: *Self, output: *std.ArrayList(u8)) !void {
        try writeU32Be(output, self.allocator, 20);
        try output.appendSlice(self.allocator, "vmhd");
        try writeU32Be(output, self.allocator, 1); // Version 0, flags 1
        try writeU16Be(output, self.allocator, 0); // Graphics mode
        try writeU16Be(output, self.allocator, 0); // Opcolor
        try writeU16Be(output, self.allocator, 0);
        try writeU16Be(output, self.allocator, 0);
    }

    fn writeSmhd(self: *Self, output: *std.ArrayList(u8)) !void {
        try writeU32Be(output, self.allocator, 16);
        try output.appendSlice(self.allocator, "smhd");
        try writeU32Be(output, self.allocator, 0); // Version and flags
        try writeU16Be(output, self.allocator, 0); // Balance
        try writeU16Be(output, self.allocator, 0); // Reserved
    }

    fn writeDinf(self: *Self, output: *std.ArrayList(u8)) !void {
        // dinf > dref > url
        try writeU32Be(output, self.allocator, 36);
        try output.appendSlice(self.allocator, "dinf");

        try writeU32Be(output, self.allocator, 28);
        try output.appendSlice(self.allocator, "dref");
        try writeU32Be(output, self.allocator, 0); // Version and flags
        try writeU32Be(output, self.allocator, 1); // Entry count

        try writeU32Be(output, self.allocator, 12);
        try output.appendSlice(self.allocator, "url ");
        try writeU32Be(output, self.allocator, 1); // Self-contained flag
    }

    fn writeStbl(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const stbl_start = output.items.len;
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "stbl");

        try self.writeStsd(output, track);
        try self.writeStts(output, track);

        // Write ctts if we have composition offsets
        var has_ctts = false;
        for (track.samples.items) |sample| {
            if (sample.composition_offset != 0) {
                has_ctts = true;
                break;
            }
        }
        if (has_ctts) {
            try self.writeCtts(output, track);
        }

        try self.writeStsc(output, track);
        try self.writeStsz(output, track);
        try self.writeStco(output, track);

        // Write stss if video track
        if (track.config == .video) {
            try self.writeStss(output, track);
        }

        const stbl_size: u32 = @intCast(output.items.len - stbl_start);
        std.mem.writeInt(u32, output.items[stbl_start..][0..4], stbl_size, .big);
    }

    fn writeStsd(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        const stsd_start = output.items.len;
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "stsd");
        try writeU32Be(output, self.allocator, 0); // Version and flags
        try writeU32Be(output, self.allocator, 1); // Entry count

        switch (track.config) {
            .video => |v| try self.writeVideoSampleEntry(output, v),
            .audio => |a| try self.writeAudioSampleEntry(output, a),
        }

        const stsd_size: u32 = @intCast(output.items.len - stsd_start);
        std.mem.writeInt(u32, output.items[stsd_start..][0..4], stsd_size, .big);
    }

    fn writeVideoSampleEntry(self: *Self, output: *std.ArrayList(u8), config: VideoTrackConfig) !void {
        const entry_start = output.items.len;
        try writeU32Be(output, self.allocator, 0); // Placeholder

        // Codec type
        const codec_tag: [4]u8 = switch (config.codec) {
            .h264 => "avc1".*,
            .hevc => "hvc1".*,
            .vp9 => "vp09".*,
            .av1 => "av01".*,
            else => "mp4v".*,
        };
        try output.appendSlice(self.allocator, &codec_tag);

        // Reserved
        try output.appendSlice(self.allocator, &[_]u8{0} ** 6);

        // Data reference index
        try writeU16Be(output, self.allocator, 1);

        // Pre-defined and reserved
        try writeU16Be(output, self.allocator, 0);
        try writeU16Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, &[_]u8{0} ** 12);

        // Width and height
        try writeU16Be(output, self.allocator, config.width);
        try writeU16Be(output, self.allocator, config.height);

        // Horizontal and vertical resolution (72 dpi = 0x00480000)
        try writeU32Be(output, self.allocator, 0x00480000);
        try writeU32Be(output, self.allocator, 0x00480000);

        // Reserved
        try writeU32Be(output, self.allocator, 0);

        // Frame count
        try writeU16Be(output, self.allocator, 1);

        // Compressor name (32 bytes, first byte is length)
        try output.appendSlice(self.allocator, &[_]u8{0} ** 32);

        // Depth
        try writeU16Be(output, self.allocator, 0x0018); // 24-bit

        // Pre-defined
        try writeU16Be(output, self.allocator, 0xFFFF);

        // Write codec config (avcC, hvcC, etc.)
        if (config.codec_config) |codec_config| {
            const config_tag: [4]u8 = switch (config.codec) {
                .h264 => "avcC".*,
                .hevc => "hvcC".*,
                .vp9 => "vpcC".*,
                .av1 => "av1C".*,
                else => "esds".*,
            };

            try writeU32Be(output, self.allocator, @intCast(8 + codec_config.len));
            try output.appendSlice(self.allocator, &config_tag);
            try output.appendSlice(self.allocator, codec_config);
        }

        const entry_size: u32 = @intCast(output.items.len - entry_start);
        std.mem.writeInt(u32, output.items[entry_start..][0..4], entry_size, .big);
    }

    fn writeAudioSampleEntry(self: *Self, output: *std.ArrayList(u8), config: AudioTrackConfig) !void {
        const entry_start = output.items.len;
        try writeU32Be(output, self.allocator, 0); // Placeholder

        // Codec type
        const codec_tag: [4]u8 = switch (config.codec) {
            .aac => "mp4a".*,
            .opus => "Opus".*,
            .flac => "fLaC".*,
            .alac => "alac".*,
            else => "mp4a".*,
        };
        try output.appendSlice(self.allocator, &codec_tag);

        // Reserved
        try output.appendSlice(self.allocator, &[_]u8{0} ** 6);

        // Data reference index
        try writeU16Be(output, self.allocator, 1);

        // Version and revision
        try writeU16Be(output, self.allocator, 0);
        try writeU16Be(output, self.allocator, 0);

        // Vendor
        try writeU32Be(output, self.allocator, 0);

        // Channels
        try writeU16Be(output, self.allocator, config.channels);

        // Sample size
        try writeU16Be(output, self.allocator, config.bits_per_sample);

        // Compression ID and packet size
        try writeU16Be(output, self.allocator, 0);
        try writeU16Be(output, self.allocator, 0);

        // Sample rate (16.16 fixed point)
        try writeU32Be(output, self.allocator, config.sample_rate << 16);

        // Write esds for AAC
        if (config.codec == .aac) {
            try self.writeEsds(output, config);
        } else if (config.codec_config) |codec_cfg| {
            const config_tag: [4]u8 = switch (config.codec) {
                .opus => "dOps".*,
                .flac => "dfLa".*,
                else => "esds".*,
            };
            try writeU32Be(output, self.allocator, @intCast(8 + codec_cfg.len));
            try output.appendSlice(self.allocator, &config_tag);
            try output.appendSlice(self.allocator, codec_cfg);
        }

        const entry_size: u32 = @intCast(output.items.len - entry_start);
        std.mem.writeInt(u32, output.items[entry_start..][0..4], entry_size, .big);
    }

    fn writeEsds(self: *Self, output: *std.ArrayList(u8), config: AudioTrackConfig) !void {
        // Build AudioSpecificConfig
        const asc = config.codec_config orelse &[_]u8{ 0x11, 0x90 }; // Default AAC-LC 48kHz stereo

        const esds_start = output.items.len;
        try writeU32Be(output, self.allocator, 0);
        try output.appendSlice(self.allocator, "esds");
        try writeU32Be(output, self.allocator, 0); // Version and flags

        // ES_Descriptor
        try output.append(self.allocator, 0x03); // Tag
        const es_desc_size = 23 + asc.len;
        try writeDescriptorLength(output, self.allocator, @intCast(es_desc_size));
        try writeU16Be(output, self.allocator, 0); // ES_ID
        try output.append(self.allocator, 0); // Flags

        // DecoderConfigDescriptor
        try output.append(self.allocator, 0x04); // Tag
        try writeDescriptorLength(output, self.allocator, @intCast(15 + asc.len));
        try output.append(self.allocator, 0x40); // ObjectTypeIndication (AAC)
        try output.append(self.allocator, 0x15); // StreamType (AudioStream)
        try output.appendSlice(self.allocator, &[_]u8{ 0, 0, 0 }); // Buffer size
        try writeU32Be(output, self.allocator, 128000); // Max bitrate
        try writeU32Be(output, self.allocator, 128000); // Avg bitrate

        // DecoderSpecificInfo
        try output.append(self.allocator, 0x05); // Tag
        try writeDescriptorLength(output, self.allocator, @intCast(asc.len));
        try output.appendSlice(self.allocator, asc);

        // SLConfigDescriptor
        try output.append(self.allocator, 0x06); // Tag
        try writeDescriptorLength(output, self.allocator, 1);
        try output.append(self.allocator, 0x02); // Predefined

        const esds_size: u32 = @intCast(output.items.len - esds_start);
        std.mem.writeInt(u32, output.items[esds_start..][0..4], esds_size, .big);
    }

    fn writeStts(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // Run-length encode durations
        var entries: std.ArrayList(struct { count: u32, delta: u32 }) = .empty;
        defer entries.deinit(self.allocator);

        if (track.samples.items.len > 0) {
            var current_delta = track.samples.items[0].duration;
            var count: u32 = 1;

            for (track.samples.items[1..]) |sample| {
                if (sample.duration == current_delta) {
                    count += 1;
                } else {
                    try entries.append(self.allocator, .{ .count = count, .delta = current_delta });
                    current_delta = sample.duration;
                    count = 1;
                }
            }
            try entries.append(self.allocator, .{ .count = count, .delta = current_delta });
        }

        const size: u32 = @intCast(16 + entries.items.len * 8);
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "stts");
        try writeU32Be(output, self.allocator, 0); // Version and flags
        try writeU32Be(output, self.allocator, @intCast(entries.items.len));

        for (entries.items) |entry| {
            try writeU32Be(output, self.allocator, entry.count);
            try writeU32Be(output, self.allocator, entry.delta);
        }
    }

    fn writeCtts(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // Run-length encode composition offsets
        var entries: std.ArrayList(struct { count: u32, offset: i32 }) = .empty;
        defer entries.deinit(self.allocator);

        if (track.samples.items.len > 0) {
            var current_offset = track.samples.items[0].composition_offset;
            var count: u32 = 1;

            for (track.samples.items[1..]) |sample| {
                if (sample.composition_offset == current_offset) {
                    count += 1;
                } else {
                    try entries.append(self.allocator, .{ .count = count, .offset = current_offset });
                    current_offset = sample.composition_offset;
                    count = 1;
                }
            }
            try entries.append(self.allocator, .{ .count = count, .offset = current_offset });
        }

        const size: u32 = @intCast(16 + entries.items.len * 8);
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "ctts");
        try writeU32Be(output, self.allocator, 0x01000000); // Version 1 for signed offsets

        try writeU32Be(output, self.allocator, @intCast(entries.items.len));
        for (entries.items) |entry| {
            try writeU32Be(output, self.allocator, entry.count);
            try writeI32Be(output, self.allocator, entry.offset);
        }
    }

    fn writeStsc(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // For simplicity, write one entry covering all chunks
        // In a more sophisticated muxer, we'd group chunks with same sample count
        const size: u32 = 28;
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "stsc");
        try writeU32Be(output, self.allocator, 0); // Version and flags
        try writeU32Be(output, self.allocator, 1); // Entry count

        // First chunk, samples per chunk, sample description index
        const samples_per_chunk = if (track.chunk_offsets.items.len > 0)
            @divTrunc(track.samples.items.len, track.chunk_offsets.items.len)
        else
            track.samples.items.len;

        try writeU32Be(output, self.allocator, 1);
        try writeU32Be(output, self.allocator, @intCast(samples_per_chunk));
        try writeU32Be(output, self.allocator, 1);
    }

    fn writeStsz(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // Check if all samples have same size
        var same_size = true;
        const first_size = if (track.samples.items.len > 0) track.samples.items[0].size else 0;
        for (track.samples.items) |sample| {
            if (sample.size != first_size) {
                same_size = false;
                break;
            }
        }

        if (same_size) {
            // Compact form
            try writeU32Be(output, self.allocator, 20);
            try output.appendSlice(self.allocator, "stsz");
            try writeU32Be(output, self.allocator, 0);
            try writeU32Be(output, self.allocator, first_size);
            try writeU32Be(output, self.allocator, @intCast(track.samples.items.len));
        } else {
            // Full form
            const size: u32 = @intCast(20 + track.samples.items.len * 4);
            try writeU32Be(output, self.allocator, size);
            try output.appendSlice(self.allocator, "stsz");
            try writeU32Be(output, self.allocator, 0);
            try writeU32Be(output, self.allocator, 0);
            try writeU32Be(output, self.allocator, @intCast(track.samples.items.len));

            for (track.samples.items) |sample| {
                try writeU32Be(output, self.allocator, sample.size);
            }
        }
    }

    fn writeStco(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // Check if we need 64-bit offsets
        var need_64bit = false;
        for (track.chunk_offsets.items) |offset| {
            if (offset > 0xFFFFFFFF) {
                need_64bit = true;
                break;
            }
        }

        if (need_64bit) {
            const size: u32 = @intCast(16 + track.chunk_offsets.items.len * 8);
            try writeU32Be(output, self.allocator, size);
            try output.appendSlice(self.allocator, "co64");
            try writeU32Be(output, self.allocator, 0);
            try writeU32Be(output, self.allocator, @intCast(track.chunk_offsets.items.len));

            for (track.chunk_offsets.items) |offset| {
                try writeU64Be(output, self.allocator, offset);
            }
        } else {
            const size: u32 = @intCast(16 + track.chunk_offsets.items.len * 4);
            try writeU32Be(output, self.allocator, size);
            try output.appendSlice(self.allocator, "stco");
            try writeU32Be(output, self.allocator, 0);
            try writeU32Be(output, self.allocator, @intCast(track.chunk_offsets.items.len));

            for (track.chunk_offsets.items) |offset| {
                try writeU32Be(output, self.allocator, @intCast(offset));
            }
        }
    }

    fn writeStss(self: *Self, output: *std.ArrayList(u8), track: *TrackData) !void {
        // Count keyframes
        var keyframe_count: u32 = 0;
        for (track.samples.items) |sample| {
            if (sample.is_keyframe) keyframe_count += 1;
        }

        // If all frames are keyframes, don't write stss
        if (keyframe_count == track.samples.items.len) return;

        const size: u32 = @intCast(16 + keyframe_count * 4);
        try writeU32Be(output, self.allocator, size);
        try output.appendSlice(self.allocator, "stss");
        try writeU32Be(output, self.allocator, 0);
        try writeU32Be(output, self.allocator, keyframe_count);

        for (track.samples.items, 0..) |sample, i| {
            if (sample.is_keyframe) {
                try writeU32Be(output, self.allocator, @intCast(i + 1)); // 1-indexed
            }
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn writeU16Be(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .big);
    try output.appendSlice(allocator, &buf);
}

fn writeU32Be(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try output.appendSlice(allocator, &buf);
}

fn writeI32Be(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .big);
    try output.appendSlice(allocator, &buf);
}

fn writeU64Be(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try output.appendSlice(allocator, &buf);
}

fn writeDescriptorLength(output: *std.ArrayList(u8), allocator: std.mem.Allocator, length: u32) !void {
    // ISO/IEC 14496-1 expandable size encoding
    if (length < 0x80) {
        try output.append(allocator, @intCast(length));
    } else if (length < 0x4000) {
        try output.append(allocator, @intCast(0x80 | (length >> 7)));
        try output.append(allocator, @intCast(length & 0x7F));
    } else if (length < 0x200000) {
        try output.append(allocator, @intCast(0x80 | (length >> 14)));
        try output.append(allocator, @intCast(0x80 | ((length >> 7) & 0x7F)));
        try output.append(allocator, @intCast(length & 0x7F));
    } else {
        try output.append(allocator, @intCast(0x80 | (length >> 21)));
        try output.append(allocator, @intCast(0x80 | ((length >> 14) & 0x7F)));
        try output.append(allocator, @intCast(0x80 | ((length >> 7) & 0x7F)));
        try output.append(allocator, @intCast(length & 0x7F));
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Mp4Muxer basic" {
    var muxer = Mp4Muxer.init(std.testing.allocator);
    defer muxer.deinit();

    // Add video track
    const video_track = try muxer.addVideoTrack(.{
        .width = 1920,
        .height = 1080,
        .codec = .h264,
    });
    try std.testing.expectEqual(@as(u32, 1), video_track);

    // Add audio track
    const audio_track = try muxer.addAudioTrack(.{
        .sample_rate = 48000,
        .channels = 2,
        .codec = .aac,
    });
    try std.testing.expectEqual(@as(u32, 2), audio_track);
}

test "Mp4Muxer write samples" {
    var muxer = Mp4Muxer.init(std.testing.allocator);
    defer muxer.deinit();

    const track = try muxer.addVideoTrack(.{
        .width = 640,
        .height = 480,
        .codec = .h264,
    });

    // Write some samples
    const sample_data = "fake video frame data";
    try muxer.writeSample(track, .{
        .data = sample_data,
        .duration = 3000, // 1/30 second at 90000 timescale
        .pts = 0,
        .dts = 0,
        .is_keyframe = true,
        .composition_offset = 0,
    });

    try muxer.writeSample(track, .{
        .data = sample_data,
        .duration = 3000,
        .pts = 3000,
        .dts = 3000,
        .is_keyframe = false,
        .composition_offset = 0,
    });

    try std.testing.expectEqual(@as(usize, 2), muxer.tracks.items[0].samples.items.len);
}

test "Mp4Muxer finalize" {
    var muxer = Mp4Muxer.init(std.testing.allocator);
    defer muxer.deinit();

    _ = try muxer.addAudioTrack(.{
        .sample_rate = 44100,
        .channels = 2,
        .codec = .aac,
    });

    const sample_data = [_]u8{ 0x21, 0x10, 0x05 }; // Fake AAC frame
    try muxer.writeSample(1, .{
        .data = &sample_data,
        .duration = 1024,
        .pts = 0,
        .dts = 0,
        .is_keyframe = true,
        .composition_offset = 0,
    });

    const mp4_data = try muxer.finalize();
    defer std.testing.allocator.free(mp4_data);

    // Verify ftyp box at start
    try std.testing.expectEqualSlices(u8, "ftyp", mp4_data[4..8]);

    // Find moov box (handle extended size boxes)
    var found_moov = false;
    var i: usize = 0;
    while (i + 8 < mp4_data.len) {
        var box_size: u64 = std.mem.readInt(u32, mp4_data[i..][0..4], .big);
        const box_type = mp4_data[i + 4 ..][0..4];

        // Handle extended size
        if (box_size == 1 and i + 16 < mp4_data.len) {
            box_size = std.mem.readInt(u64, mp4_data[i + 8 ..][0..8], .big);
        }

        if (std.mem.eql(u8, box_type, "moov")) {
            found_moov = true;
            break;
        }
        if (box_size == 0) break;
        i += @intCast(box_size);
    }
    try std.testing.expect(found_moov);
}
