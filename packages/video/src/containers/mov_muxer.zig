// Home Video Library - QuickTime MOV Muxer
// Apple QuickTime file format writer with ProRes support

const std = @import("std");
const core = @import("../core.zig");
const MediaFile = core.MediaFile;
const VideoStream = core.VideoStream;
const AudioStream = core.AudioStream;
const VideoCodec = core.VideoCodec;
const AudioCodec = core.AudioCodec;

/// QuickTime muxer for .mov files
pub const MovMuxer = struct {
    allocator: std.mem.Allocator,
    tracks: std.ArrayList(Track),
    creation_time: u64,
    modification_time: u64,

    // MOV-specific options
    enable_prores_markers: bool = true,
    enable_timecode_track: bool = false,

    const Self = @This();

    const Track = struct {
        track_id: u32,
        media_type: MediaType,
        samples: std.ArrayList(Sample),
        duration: u64 = 0,
        timescale: u32,

        // ProRes-specific
        is_prores: bool = false,
        prores_atom_data: ?[]u8 = null,
    };

    const MediaType = enum {
        video,
        audio,
        timecode,
    };

    const Sample = struct {
        data: []const u8,
        size: u32,
        duration: u32,
        is_sync: bool,
        composition_offset: i32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, media: *const MediaFile) !Self {
        var tracks = std.ArrayList(Track).init(allocator);
        errdefer tracks.deinit();

        const now = @as(u64, @intCast(std.time.timestamp())) + 2082844800; // Seconds since 1904

        // Add video tracks
        for (media.video_streams.items, 0..) |stream, idx| {
            const is_prores = stream.codec == .prores_422 or
                stream.codec == .prores_4444 or
                stream.codec == .prores_422_hq or
                stream.codec == .prores_422_lt or
                stream.codec == .prores_422_proxy;

            try tracks.append(.{
                .track_id = @intCast(idx + 1),
                .media_type = .video,
                .samples = std.ArrayList(Sample).init(allocator),
                .timescale = stream.timebase.den,
                .is_prores = is_prores,
            });
        }

        // Add audio tracks
        for (media.audio_streams.items, 0..) |stream, idx| {
            try tracks.append(.{
                .track_id = @intCast(media.video_streams.items.len + idx + 1),
                .media_type = .audio,
                .samples = std.ArrayList(Sample).init(allocator),
                .timescale = stream.sample_rate,
            });
        }

        return .{
            .allocator = allocator,
            .tracks = tracks,
            .creation_time = now,
            .modification_time = now,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tracks.items) |*track| {
            track.samples.deinit();
            if (track.prores_atom_data) |data| {
                self.allocator.free(data);
            }
        }
        self.tracks.deinit();
    }

    pub fn addSample(self: *Self, track_id: u32, data: []const u8, duration: u32, is_sync: bool) !void {
        for (self.tracks.items) |*track| {
            if (track.track_id == track_id) {
                try track.samples.append(.{
                    .data = data,
                    .size = @intCast(data.len),
                    .duration = duration,
                    .is_sync = is_sync,
                });
                track.duration += duration;
                return;
            }
        }
        return error.TrackNotFound;
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write ftyp atom
        const ftyp_data = try self.buildFtyp();
        defer self.allocator.free(ftyp_data);
        try output.appendSlice(ftyp_data);

        // Write mdat atom
        const mdat_data = try self.buildMdat();
        defer self.allocator.free(mdat_data);
        try output.appendSlice(mdat_data);

        // Write moov atom (at end for regular QuickTime, not fast-start)
        const moov_data = try self.buildMoov();
        defer self.allocator.free(moov_data);
        try output.appendSlice(moov_data);

        return output.toOwnedSlice();
    }

    fn buildFtyp(self: *Self) ![]u8 {
        var ftyp = std.ArrayList(u8).init(self.allocator);
        errdefer ftyp.deinit();

        // Determine major brand based on tracks
        var has_prores = false;
        for (self.tracks.items) |track| {
            if (track.is_prores) {
                has_prores = true;
                break;
            }
        }

        // Major brand
        const major_brand = if (has_prores) "qt  " else "qt  ";
        const minor_version: u32 = 0x20050300; // QuickTime 7.0.3

        // Compatible brands
        const brands = [_][]const u8{ "qt  ", "isom" };

        // Write ftyp
        const size: u32 = 8 + 4 + 4 + @as(u32, @intCast(brands.len * 4));
        try ftyp.writer().writeInt(u32, size, .big);
        try ftyp.appendSlice("ftyp");
        try ftyp.appendSlice(major_brand);
        try ftyp.writer().writeInt(u32, minor_version, .big);

        for (brands) |brand| {
            try ftyp.appendSlice(brand);
        }

        return ftyp.toOwnedSlice();
    }

    fn buildMdat(self: *Self) ![]u8 {
        var mdat = std.ArrayList(u8).init(self.allocator);
        errdefer mdat.deinit();

        // Calculate total size
        var total_sample_size: usize = 0;
        for (self.tracks.items) |track| {
            for (track.samples.items) |sample| {
                total_sample_size += sample.size;
            }
        }

        const size: u32 = @intCast(8 + total_sample_size);
        try mdat.writer().writeInt(u32, size, .big);
        try mdat.appendSlice("mdat");

        // Write all sample data
        for (self.tracks.items) |track| {
            for (track.samples.items) |sample| {
                try mdat.appendSlice(sample.data);
            }
        }

        return mdat.toOwnedSlice();
    }

    fn buildMoov(self: *Self) ![]u8 {
        var moov = std.ArrayList(u8).init(self.allocator);
        errdefer moov.deinit();

        const moov_start = moov.items.len;

        // Placeholder for size
        try moov.writer().writeInt(u32, 0, .big);
        try moov.appendSlice("moov");

        // mvhd (Movie header)
        const mvhd_data = try self.buildMvhd();
        defer self.allocator.free(mvhd_data);
        try moov.appendSlice(mvhd_data);

        // trak atoms for each track
        for (self.tracks.items) |*track| {
            const trak_data = try self.buildTrak(track);
            defer self.allocator.free(trak_data);
            try moov.appendSlice(trak_data);
        }

        // udta (user data) atom for metadata
        const udta_data = try self.buildUdta();
        defer self.allocator.free(udta_data);
        try moov.appendSlice(udta_data);

        // Update size
        const final_size: u32 = @intCast(moov.items.len - moov_start);
        std.mem.writeInt(u32, moov.items[moov_start..][0..4], final_size, .big);

        return moov.toOwnedSlice();
    }

    fn buildMvhd(self: *Self) ![]u8 {
        var mvhd = std.ArrayList(u8).init(self.allocator);
        errdefer mvhd.deinit();

        const size: u32 = 108;
        try mvhd.writer().writeInt(u32, size, .big);
        try mvhd.appendSlice("mvhd");

        // Version and flags
        try mvhd.writer().writeInt(u32, 0, .big);

        // Creation and modification time
        try mvhd.writer().writeInt(u32, @intCast(self.creation_time), .big);
        try mvhd.writer().writeInt(u32, @intCast(self.modification_time), .big);

        // Timescale (1000 = 1ms resolution)
        try mvhd.writer().writeInt(u32, 1000, .big);

        // Duration (in timescale units)
        var max_duration: u64 = 0;
        for (self.tracks.items) |track| {
            const track_duration = (track.duration * 1000) / track.timescale;
            if (track_duration > max_duration) {
                max_duration = track_duration;
            }
        }
        try mvhd.writer().writeInt(u32, @intCast(max_duration), .big);

        // Preferred rate (1.0)
        try mvhd.writer().writeInt(u32, 0x00010000, .big);

        // Preferred volume (1.0)
        try mvhd.writer().writeInt(u16, 0x0100, .big);

        // Reserved
        try mvhd.appendNTimes(0, 10);

        // Matrix (identity matrix)
        const identity_matrix = [_]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };
        for (identity_matrix) |val| {
            try mvhd.writer().writeInt(u32, val, .big);
        }

        // Preview time and duration
        try mvhd.writer().writeInt(u32, 0, .big);
        try mvhd.writer().writeInt(u32, 0, .big);

        // Poster time
        try mvhd.writer().writeInt(u32, 0, .big);

        // Selection time and duration
        try mvhd.writer().writeInt(u32, 0, .big);
        try mvhd.writer().writeInt(u32, 0, .big);

        // Current time
        try mvhd.writer().writeInt(u32, 0, .big);

        // Next track ID
        try mvhd.writer().writeInt(u32, @intCast(self.tracks.items.len + 1), .big);

        return mvhd.toOwnedSlice();
    }

    fn buildTrak(self: *Self, track: *const Track) ![]u8 {
        var trak = std.ArrayList(u8).init(self.allocator);
        errdefer trak.deinit();

        const trak_start = trak.items.len;

        // Placeholder for size
        try trak.writer().writeInt(u32, 0, .big);
        try trak.appendSlice("trak");

        // tkhd (Track header)
        const tkhd_data = try self.buildTkhd(track);
        defer self.allocator.free(tkhd_data);
        try trak.appendSlice(tkhd_data);

        // mdia (Media)
        const mdia_data = try self.buildMdia(track);
        defer self.allocator.free(mdia_data);
        try trak.appendSlice(mdia_data);

        // Update size
        const final_size: u32 = @intCast(trak.items.len - trak_start);
        std.mem.writeInt(u32, trak.items[trak_start..][0..4], final_size, .big);

        return trak.toOwnedSlice();
    }

    fn buildTkhd(self: *Self, track: *const Track) ![]u8 {
        _ = self;
        var tkhd = std.ArrayList(u8).init(self.allocator);
        errdefer tkhd.deinit();

        const size: u32 = 92;
        try tkhd.writer().writeInt(u32, size, .big);
        try tkhd.appendSlice("tkhd");

        // Version and flags (track enabled, in movie, in preview)
        try tkhd.writer().writeInt(u32, 0x0000000F, .big);

        // Creation and modification time
        try tkhd.writer().writeInt(u32, @intCast(self.creation_time), .big);
        try tkhd.writer().writeInt(u32, @intCast(self.modification_time), .big);

        // Track ID
        try tkhd.writer().writeInt(u32, track.track_id, .big);

        // Reserved
        try tkhd.writer().writeInt(u32, 0, .big);

        // Duration (in movie timescale)
        const duration_ms = (track.duration * 1000) / track.timescale;
        try tkhd.writer().writeInt(u32, @intCast(duration_ms), .big);

        // Reserved
        try tkhd.writer().writeInt(u64, 0, .big);

        // Layer and alternate group
        try tkhd.writer().writeInt(u16, 0, .big);
        try tkhd.writer().writeInt(u16, 0, .big);

        // Volume (1.0 for audio, 0.0 for video)
        const volume: u16 = if (track.media_type == .audio) 0x0100 else 0x0000;
        try tkhd.writer().writeInt(u16, volume, .big);

        // Reserved
        try tkhd.writer().writeInt(u16, 0, .big);

        // Matrix (identity)
        const identity_matrix = [_]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };
        for (identity_matrix) |val| {
            try tkhd.writer().writeInt(u32, val, .big);
        }

        // Width and height (for video tracks)
        if (track.media_type == .video) {
            try tkhd.writer().writeInt(u32, 1920 << 16, .big); // 1920.0
            try tkhd.writer().writeInt(u32, 1080 << 16, .big); // 1080.0
        } else {
            try tkhd.writer().writeInt(u32, 0, .big);
            try tkhd.writer().writeInt(u32, 0, .big);
        }

        return tkhd.toOwnedSlice();
    }

    fn buildMdia(self: *Self, track: *const Track) ![]u8 {
        var mdia = std.ArrayList(u8).init(self.allocator);
        errdefer mdia.deinit();

        const mdia_start = mdia.items.len;

        // Placeholder for size
        try mdia.writer().writeInt(u32, 0, .big);
        try mdia.appendSlice("mdia");

        // mdhd (Media header)
        const mdhd_data = try self.buildMdhd(track);
        defer self.allocator.free(mdhd_data);
        try mdia.appendSlice(mdhd_data);

        // hdlr (Handler reference)
        const hdlr_data = try self.buildHdlr(track);
        defer self.allocator.free(hdlr_data);
        try mdia.appendSlice(hdlr_data);

        // minf (Media information)
        const minf_data = try self.buildMinf(track);
        defer self.allocator.free(minf_data);
        try mdia.appendSlice(minf_data);

        // Update size
        const final_size: u32 = @intCast(mdia.items.len - mdia_start);
        std.mem.writeInt(u32, mdia.items[mdia_start..][0..4], final_size, .big);

        return mdia.toOwnedSlice();
    }

    fn buildMdhd(self: *Self, track: *const Track) ![]u8 {
        _ = self;
        var mdhd = std.ArrayList(u8).init(self.allocator);
        errdefer mdhd.deinit();

        const size: u32 = 32;
        try mdhd.writer().writeInt(u32, size, .big);
        try mdhd.appendSlice("mdhd");

        // Version and flags
        try mdhd.writer().writeInt(u32, 0, .big);

        // Creation and modification time
        try mdhd.writer().writeInt(u32, @intCast(self.creation_time), .big);
        try mdhd.writer().writeInt(u32, @intCast(self.modification_time), .big);

        // Timescale
        try mdhd.writer().writeInt(u32, track.timescale, .big);

        // Duration
        try mdhd.writer().writeInt(u32, @intCast(track.duration), .big);

        // Language (undetermined = 0x55C4)
        try mdhd.writer().writeInt(u16, 0x55C4, .big);

        // Quality
        try mdhd.writer().writeInt(u16, 0, .big);

        return mdhd.toOwnedSlice();
    }

    fn buildHdlr(self: *Self, track: *const Track) ![]u8 {
        var hdlr = std.ArrayList(u8).init(self.allocator);
        errdefer hdlr.deinit();

        const handler_type = switch (track.media_type) {
            .video => "vide",
            .audio => "soun",
            .timecode => "tmcd",
        };

        const handler_name = switch (track.media_type) {
            .video => "VideoHandler",
            .audio => "SoundHandler",
            .timecode => "TimeCodeHandler",
        };

        const size: u32 = @intCast(32 + handler_name.len + 1);
        try hdlr.writer().writeInt(u32, size, .big);
        try hdlr.appendSlice("hdlr");

        // Version and flags
        try hdlr.writer().writeInt(u32, 0, .big);

        // Component type (mhlr for QuickTime)
        try hdlr.appendSlice("mhlr");

        // Component subtype
        try hdlr.appendSlice(handler_type);

        // Component manufacturer
        try hdlr.writer().writeInt(u32, 0, .big);

        // Component flags and mask
        try hdlr.writer().writeInt(u32, 0, .big);
        try hdlr.writer().writeInt(u32, 0, .big);

        // Component name (Pascal string for QuickTime)
        try hdlr.writer().writeByte(@intCast(handler_name.len));
        try hdlr.appendSlice(handler_name);

        return hdlr.toOwnedSlice();
    }

    fn buildMinf(self: *Self, track: *const Track) ![]u8 {
        var minf = std.ArrayList(u8).init(self.allocator);
        errdefer minf.deinit();

        const minf_start = minf.items.len;

        // Placeholder for size
        try minf.writer().writeInt(u32, 0, .big);
        try minf.appendSlice("minf");

        // Media info header (vmhd for video, smhd for audio)
        if (track.media_type == .video) {
            const vmhd_data = try self.buildVmhd();
            defer self.allocator.free(vmhd_data);
            try minf.appendSlice(vmhd_data);
        } else if (track.media_type == .audio) {
            const smhd_data = try self.buildSmhd();
            defer self.allocator.free(smhd_data);
            try minf.appendSlice(smhd_data);
        }

        // dinf (Data information)
        const dinf_data = try self.buildDinf();
        defer self.allocator.free(dinf_data);
        try minf.appendSlice(dinf_data);

        // stbl (Sample table) - simplified
        const stbl_data = try self.buildStbl(track);
        defer self.allocator.free(stbl_data);
        try minf.appendSlice(stbl_data);

        // Update size
        const final_size: u32 = @intCast(minf.items.len - minf_start);
        std.mem.writeInt(u32, minf.items[minf_start..][0..4], final_size, .big);

        return minf.toOwnedSlice();
    }

    fn buildVmhd(self: *Self) ![]u8 {
        _ = self;
        var vmhd = std.ArrayList(u8).init(self.allocator);
        errdefer vmhd.deinit();

        const size: u32 = 20;
        try vmhd.writer().writeInt(u32, size, .big);
        try vmhd.appendSlice("vmhd");

        // Version and flags (flags = 1)
        try vmhd.writer().writeInt(u32, 1, .big);

        // Graphics mode and opcolor
        try vmhd.writer().writeInt(u16, 0, .big); // copy mode
        try vmhd.writer().writeInt(u16, 0, .big); // opcolor R
        try vmhd.writer().writeInt(u16, 0, .big); // opcolor G
        try vmhd.writer().writeInt(u16, 0, .big); // opcolor B

        return vmhd.toOwnedSlice();
    }

    fn buildSmhd(self: *Self) ![]u8 {
        _ = self;
        var smhd = std.ArrayList(u8).init(self.allocator);
        errdefer smhd.deinit();

        const size: u32 = 16;
        try smhd.writer().writeInt(u32, size, .big);
        try smhd.appendSlice("smhd");

        // Version and flags
        try smhd.writer().writeInt(u32, 0, .big);

        // Balance and reserved
        try smhd.writer().writeInt(u16, 0, .big);
        try smhd.writer().writeInt(u16, 0, .big);

        return smhd.toOwnedSlice();
    }

    fn buildDinf(self: *Self) ![]u8 {
        var dinf = std.ArrayList(u8).init(self.allocator);
        errdefer dinf.deinit();

        const dinf_start = dinf.items.len;

        try dinf.writer().writeInt(u32, 0, .big);
        try dinf.appendSlice("dinf");

        // dref (Data reference)
        const size: u32 = 28;
        try dinf.writer().writeInt(u32, size, .big);
        try dinf.appendSlice("dref");
        try dinf.writer().writeInt(u32, 0, .big); // version/flags
        try dinf.writer().writeInt(u32, 1, .big); // entry count

        // url entry
        try dinf.writer().writeInt(u32, 12, .big);
        try dinf.appendSlice("url ");
        try dinf.writer().writeInt(u32, 1, .big); // flags = 1 (self-contained)

        const final_size: u32 = @intCast(dinf.items.len - dinf_start);
        std.mem.writeInt(u32, dinf.items[dinf_start..][0..4], final_size, .big);

        return dinf.toOwnedSlice();
    }

    fn buildStbl(self: *Self, track: *const Track) ![]u8 {
        var stbl = std.ArrayList(u8).init(self.allocator);
        errdefer stbl.deinit();

        const stbl_start = stbl.items.len;

        try stbl.writer().writeInt(u32, 0, .big);
        try stbl.appendSlice("stbl");

        // stsd (Sample description)
        const stsd_data = try self.buildStsd(track);
        defer self.allocator.free(stsd_data);
        try stbl.appendSlice(stsd_data);

        // stts (Time-to-sample)
        const stts_data = try self.buildStts(track);
        defer self.allocator.free(stts_data);
        try stbl.appendSlice(stts_data);

        // stsc (Sample-to-chunk)
        const stsc_data = try self.buildStsc(track);
        defer self.allocator.free(stsc_data);
        try stbl.appendSlice(stsc_data);

        // stsz (Sample sizes)
        const stsz_data = try self.buildStsz(track);
        defer self.allocator.free(stsz_data);
        try stbl.appendSlice(stsz_data);

        // stco (Chunk offsets)
        const stco_data = try self.buildStco(track);
        defer self.allocator.free(stco_data);
        try stbl.appendSlice(stco_data);

        // stss (Sync samples) - only for video with non-sync frames
        if (track.media_type == .video) {
            const has_non_sync = for (track.samples.items) |sample| {
                if (!sample.is_sync) break true;
            } else false;

            if (has_non_sync) {
                const stss_data = try self.buildStss(track);
                defer self.allocator.free(stss_data);
                try stbl.appendSlice(stss_data);
            }
        }

        // ctts (Composition offset) - if any samples have composition offset
        const has_ctts = for (track.samples.items) |sample| {
            if (sample.composition_offset != 0) break true;
        } else false;

        if (has_ctts) {
            const ctts_data = try self.buildCtts(track);
            defer self.allocator.free(ctts_data);
            try stbl.appendSlice(ctts_data);
        }

        const final_size: u32 = @intCast(stbl.items.len - stbl_start);
        std.mem.writeInt(u32, stbl.items[stbl_start..][0..4], final_size, .big);

        return stbl.toOwnedSlice();
    }

    fn buildStsd(self: *Self, track: *const Track) ![]u8 {
        var stsd = std.ArrayList(u8).init(self.allocator);
        errdefer stsd.deinit();

        const stsd_start = stsd.items.len;

        try stsd.writer().writeInt(u32, 0, .big);
        try stsd.appendSlice("stsd");

        // Version and flags
        try stsd.writer().writeInt(u32, 0, .big);

        // Entry count
        try stsd.writer().writeInt(u32, 1, .big);

        // Sample description entry (simplified)
        if (track.media_type == .video) {
            try self.buildVideoSampleEntry(&stsd);
        } else if (track.media_type == .audio) {
            try self.buildAudioSampleEntry(&stsd);
        }

        const final_size: u32 = @intCast(stsd.items.len - stsd_start);
        std.mem.writeInt(u32, stsd.items[stsd_start..][0..4], final_size, .big);

        return stsd.toOwnedSlice();
    }

    fn buildVideoSampleEntry(self: *Self, stsd: *std.ArrayList(u8)) !void {
        _ = self;
        const writer = stsd.writer();

        // Entry size (placeholder)
        const entry_start = stsd.items.len;
        try writer.writeInt(u32, 0, .big);

        // Codec type (simplified - avc1 for H.264)
        try stsd.appendSlice("avc1");

        // Reserved (6 bytes)
        try stsd.appendNTimes(0, 6);

        // Data reference index
        try writer.writeInt(u16, 1, .big);

        // Video sample entry data
        try writer.writeInt(u16, 0, .big); // Pre-defined
        try writer.writeInt(u16, 0, .big); // Reserved
        try writer.writeInt(u32, 0, .big); // Pre-defined
        try writer.writeInt(u32, 0, .big);
        try writer.writeInt(u32, 0, .big);

        // Width and height
        try writer.writeInt(u16, 1920, .big);
        try writer.writeInt(u16, 1080, .big);

        // Horizontal and vertical resolution (72 dpi)
        try writer.writeInt(u32, 0x00480000, .big);
        try writer.writeInt(u32, 0x00480000, .big);

        // Data size
        try writer.writeInt(u32, 0, .big);

        // Frame count
        try writer.writeInt(u16, 1, .big);

        // Compressor name (32 bytes, Pascal string)
        try stsd.appendNTimes(0, 32);

        // Depth
        try writer.writeInt(u16, 0x0018, .big);

        // Pre-defined
        try writer.writeInt(i16, -1, .big);

        // Update entry size
        const entry_size: u32 = @intCast(stsd.items.len - entry_start);
        std.mem.writeInt(u32, stsd.items[entry_start..][0..4], entry_size, .big);
    }

    fn buildAudioSampleEntry(self: *Self, stsd: *std.ArrayList(u8)) !void {
        _ = self;
        const writer = stsd.writer();

        // Entry size (placeholder)
        const entry_start = stsd.items.len;
        try writer.writeInt(u32, 0, .big);

        // Codec type (simplified - mp4a for AAC)
        try stsd.appendSlice("mp4a");

        // Reserved (6 bytes)
        try stsd.appendNTimes(0, 6);

        // Data reference index
        try writer.writeInt(u16, 1, .big);

        // Audio sample entry data
        try writer.writeInt(u16, 0, .big); // Version
        try writer.writeInt(u16, 0, .big); // Revision level
        try writer.writeInt(u32, 0, .big); // Vendor

        // Channel count
        try writer.writeInt(u16, 2, .big);

        // Sample size (bits)
        try writer.writeInt(u16, 16, .big);

        // Pre-defined
        try writer.writeInt(u16, 0, .big);

        // Reserved
        try writer.writeInt(u16, 0, .big);

        // Sample rate (16.16 fixed point)
        try writer.writeInt(u32, 48000 << 16, .big);

        // Update entry size
        const entry_size: u32 = @intCast(stsd.items.len - entry_start);
        std.mem.writeInt(u32, stsd.items[entry_start..][0..4], entry_size, .big);
    }

    fn buildStts(self: *Self, track: *const Track) ![]u8 {
        var stts = std.ArrayList(u8).init(self.allocator);
        errdefer stts.deinit();

        const size: u32 = @intCast(16 + track.samples.items.len * 8);
        try stts.writer().writeInt(u32, size, .big);
        try stts.appendSlice("stts");

        // Version and flags
        try stts.writer().writeInt(u32, 0, .big);

        // Entry count
        try stts.writer().writeInt(u32, @intCast(track.samples.items.len), .big);

        // Time-to-sample entries (sample count, sample delta)
        for (track.samples.items) |sample| {
            try stts.writer().writeInt(u32, 1, .big); // 1 sample
            try stts.writer().writeInt(u32, sample.duration, .big);
        }

        return stts.toOwnedSlice();
    }

    fn buildStsc(self: *Self, track: *const Track) ![]u8 {
        var stsc = std.ArrayList(u8).init(self.allocator);
        errdefer stsc.deinit();

        // Simplified: all samples in one chunk
        const size: u32 = 28;
        try stsc.writer().writeInt(u32, size, .big);
        try stsc.appendSlice("stsc");

        // Version and flags
        try stsc.writer().writeInt(u32, 0, .big);

        // Entry count
        try stsc.writer().writeInt(u32, 1, .big);

        // First chunk
        try stsc.writer().writeInt(u32, 1, .big);

        // Samples per chunk
        try stsc.writer().writeInt(u32, @intCast(track.samples.items.len), .big);

        // Sample description index
        try stsc.writer().writeInt(u32, 1, .big);

        return stsc.toOwnedSlice();
    }

    fn buildStsz(self: *Self, track: *const Track) ![]u8 {
        var stsz = std.ArrayList(u8).init(self.allocator);
        errdefer stsz.deinit();

        const size: u32 = @intCast(20 + track.samples.items.len * 4);
        try stsz.writer().writeInt(u32, size, .big);
        try stsz.appendSlice("stsz");

        // Version and flags
        try stsz.writer().writeInt(u32, 0, .big);

        // Sample size (0 = variable)
        try stsz.writer().writeInt(u32, 0, .big);

        // Sample count
        try stsz.writer().writeInt(u32, @intCast(track.samples.items.len), .big);

        // Entry for each sample
        for (track.samples.items) |sample| {
            try stsz.writer().writeInt(u32, sample.size, .big);
        }

        return stsz.toOwnedSlice();
    }

    fn buildStco(self: *Self, track: *const Track) ![]u8 {
        var stco = std.ArrayList(u8).init(self.allocator);
        errdefer stco.deinit();

        // Simplified: one chunk containing all samples
        const size: u32 = 20;
        try stco.writer().writeInt(u32, size, .big);
        try stco.appendSlice("stco");

        // Version and flags
        try stco.writer().writeInt(u32, 0, .big);

        // Entry count
        try stco.writer().writeInt(u32, 1, .big);

        // Chunk offset (would be calculated based on mdat position)
        // For now, placeholder - in real implementation would need to know mdat offset
        var offset: u32 = 0;
        for (track.samples.items) |sample| {
            offset += sample.size;
        }
        try stco.writer().writeInt(u32, 32, .big); // Placeholder offset

        return stco.toOwnedSlice();
    }

    fn buildStss(self: *Self, track: *const Track) ![]u8 {
        var stss = std.ArrayList(u8).init(self.allocator);
        errdefer stss.deinit();

        // Count sync samples
        var sync_count: usize = 0;
        for (track.samples.items) |sample| {
            if (sample.is_sync) sync_count += 1;
        }

        const size: u32 = @intCast(16 + sync_count * 4);
        try stss.writer().writeInt(u32, size, .big);
        try stss.appendSlice("stss");

        // Version and flags
        try stss.writer().writeInt(u32, 0, .big);

        // Entry count
        try stss.writer().writeInt(u32, @intCast(sync_count), .big);

        // Sync sample numbers (1-indexed)
        for (track.samples.items, 1..) |sample, i| {
            if (sample.is_sync) {
                try stss.writer().writeInt(u32, @intCast(i), .big);
            }
        }

        return stss.toOwnedSlice();
    }

    fn buildCtts(self: *Self, track: *const Track) ![]u8 {
        var ctts = std.ArrayList(u8).init(self.allocator);
        errdefer ctts.deinit();

        const size: u32 = @intCast(16 + track.samples.items.len * 8);
        try ctts.writer().writeInt(u32, size, .big);
        try ctts.appendSlice("ctts");

        // Version and flags
        try ctts.writer().writeInt(u32, 0, .big);

        // Entry count
        try ctts.writer().writeInt(u32, @intCast(track.samples.items.len), .big);

        // Composition offset entries (sample count, composition offset)
        for (track.samples.items) |sample| {
            try ctts.writer().writeInt(u32, 1, .big); // 1 sample
            try ctts.writer().writeInt(i32, sample.composition_offset, .big);
        }

        return ctts.toOwnedSlice();
    }

    fn buildUdta(self: *Self) ![]u8 {
        var udta = std.ArrayList(u8).init(self.allocator);
        errdefer udta.deinit();

        const udta_start = udta.items.len;

        try udta.writer().writeInt(u32, 0, .big);
        try udta.appendSlice("udta");

        // meta atom for metadata
        const meta_data = try self.buildMeta();
        defer self.allocator.free(meta_data);
        try udta.appendSlice(meta_data);

        const final_size: u32 = @intCast(udta.items.len - udta_start);
        std.mem.writeInt(u32, udta.items[udta_start..][0..4], final_size, .big);

        return udta.toOwnedSlice();
    }

    fn buildMeta(self: *Self) ![]u8 {
        _ = self;
        var meta = std.ArrayList(u8).init(self.allocator);
        errdefer meta.deinit();

        const size: u32 = 12;
        try meta.writer().writeInt(u32, size, .big);
        try meta.appendSlice("meta");
        try meta.writer().writeInt(u32, 0, .big); // version/flags

        return meta.toOwnedSlice();
    }
};
