// Home Video Library - WebM Muxer
// WebM container format (Matroska subset) for VP8/VP9/AV1

const std = @import("std");
const core = @import("../core.zig");
const MediaFile = core.MediaFile;

/// EBML element IDs
const EBML = struct {
    const Header = 0x1A45DFA3;
    const Version = 0x4286;
    const ReadVersion = 0x42F7;
    const MaxIDLength = 0x42F2;
    const MaxSizeLength = 0x42F3;
    const DocType = 0x4282;
    const DocTypeVersion = 0x4287;
    const DocTypeReadVersion = 0x4285;
};

/// Matroska/WebM segment element IDs
const Segment = struct {
    const ID = 0x18538067;
    const Info = 0x1549A966;
    const Tracks = 0x1654AE6B;
    const Cluster = 0x1F43B675;
    const Cues = 0x1C53BB6B;
};

/// Segment Info element IDs
const Info = struct {
    const TimestampScale = 0x2AD7B1;
    const MuxingApp = 0x4D80;
    const WritingApp = 0x5741;
    const Duration = 0x4489;
};

/// Track element IDs
const Track = struct {
    const Entry = 0xAE;
    const Number = 0xD7;
    const UID = 0x73C5;
    const Type = 0x83;
    const CodecID = 0x86;
    const CodecPrivate = 0x63A2;
    const Video = 0xE0;
    const Audio = 0xE1;
};

/// Video element IDs
const Video = struct {
    const PixelWidth = 0xB0;
    const PixelHeight = 0xBA;
    const DisplayWidth = 0x54B0;
    const DisplayHeight = 0x54BA;
};

/// Audio element IDs
const Audio = struct {
    const SamplingFrequency = 0xB5;
    const Channels = 0x9F;
    const BitDepth = 0x6264;
};

/// Cluster element IDs
const Cluster = struct {
    const Timestamp = 0xE7;
    const SimpleBlock = 0xA3;
    const BlockGroup = 0xA0;
    const Block = 0xA1;
};

/// WebM muxer for .webm files
pub const WebMMuxer = struct {
    allocator: std.mem.Allocator,
    tracks: std.ArrayList(TrackInfo),
    clusters: std.ArrayList(ClusterData),

    // Options
    append_mode: bool = false,  // For live streaming
    timestamp_scale: u64 = 1000000, // 1ms

    // State
    cluster_timestamp: u64 = 0,
    cluster_max_duration: u64 = 2000, // 2 seconds

    const Self = @This();

    const TrackInfo = struct {
        track_number: u32,
        track_uid: u64,
        track_type: TrackType,
        codec_id: []const u8,
        codec_private: ?[]const u8 = null,

        // Video
        width: u32 = 0,
        height: u32 = 0,

        // Audio
        sample_rate: f64 = 0,
        channels: u8 = 0,
        bit_depth: u8 = 0,
    };

    const TrackType = enum(u8) {
        video = 1,
        audio = 2,
        subtitle = 17,
    };

    const ClusterData = struct {
        timestamp: u64,
        blocks: std.ArrayList(BlockData),
    };

    const BlockData = struct {
        track_number: u32,
        timestamp_offset: i16,
        flags: u8,
        data: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, media: *const MediaFile) !Self {
        var tracks = std.ArrayList(TrackInfo).init(allocator);
        errdefer tracks.deinit();

        // Add video tracks
        for (media.video_streams.items, 0..) |stream, idx| {
            const codec_id = switch (stream.codec) {
                .vp8 => "V_VP8",
                .vp9 => "V_VP9",
                .av1 => "V_AV1",
                else => return error.UnsupportedCodecForWebM,
            };

            try tracks.append(.{
                .track_number = @intCast(idx + 1),
                .track_uid = @intCast(idx + 1),
                .track_type = .video,
                .codec_id = codec_id,
                .width = stream.width,
                .height = stream.height,
            });
        }

        // Add audio tracks
        for (media.audio_streams.items, 0..) |stream, idx| {
            const codec_id = switch (stream.codec) {
                .opus => "A_OPUS",
                .vorbis => "A_VORBIS",
                else => return error.UnsupportedCodecForWebM,
            };

            try tracks.append(.{
                .track_number = @intCast(media.video_streams.items.len + idx + 1),
                .track_uid = @intCast(media.video_streams.items.len + idx + 1),
                .track_type = .audio,
                .codec_id = codec_id,
                .sample_rate = @floatFromInt(stream.sample_rate),
                .channels = stream.channels,
            });
        }

        return .{
            .allocator = allocator,
            .tracks = tracks,
            .clusters = std.ArrayList(ClusterData).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.clusters.items) |*cluster| {
            cluster.blocks.deinit();
        }
        self.clusters.deinit();
        self.tracks.deinit();
    }

    pub fn addFrame(self: *Self, track_number: u32, timestamp: u64, data: []const u8, is_keyframe: bool) !void {
        // Start new cluster if needed
        if (self.clusters.items.len == 0 or
            timestamp - self.cluster_timestamp >= self.cluster_max_duration) {
            try self.startNewCluster(timestamp);
        }

        const timestamp_offset: i16 = @intCast(@as(i64, @intCast(timestamp)) - @as(i64, @intCast(self.cluster_timestamp)));

        const flags: u8 = if (is_keyframe) 0x80 else 0x00; // Bit 7 = keyframe

        var cluster = &self.clusters.items[self.clusters.items.len - 1];
        try cluster.blocks.append(.{
            .track_number = track_number,
            .timestamp_offset = timestamp_offset,
            .flags = flags,
            .data = data,
        });
    }

    fn startNewCluster(self: *Self, timestamp: u64) !void {
        var cluster = ClusterData{
            .timestamp = timestamp,
            .blocks = std.ArrayList(BlockData).init(self.allocator),
        };

        try self.clusters.append(cluster);
        self.cluster_timestamp = timestamp;
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write EBML header
        try self.writeEBMLHeader(&output);

        // Write Segment
        const segment_start = output.items.len;
        try self.writeElementID(&output, Segment.ID);
        try self.writeVInt(&output, 0); // Unknown size (will patch if not streaming)

        // Segment Info
        try self.writeSegmentInfo(&output);

        // Tracks
        try self.writeTracks(&output);

        // Clusters
        for (self.clusters.items) |*cluster| {
            try self.writeCluster(&output, cluster);
        }

        // Patch segment size if not in append mode
        if (!self.append_mode) {
            const segment_size = output.items.len - segment_start - 8; // 4 for ID, 4 for size field (approx)
            // Note: Would need to properly encode EBML variable-length int
            _ = segment_size;
        }

        return output.toOwnedSlice();
    }

    fn writeEBMLHeader(self: *Self, output: *std.ArrayList(u8)) !void {
        _ = self;

        // EBML Header element
        try writeElementID(output, EBML.Header);

        var header_data = std.ArrayList(u8).init(output.allocator);
        defer header_data.deinit();

        // Version
        try writeElementID(&header_data, EBML.Version);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(1);

        // ReadVersion
        try writeElementID(&header_data, EBML.ReadVersion);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(1);

        // MaxIDLength
        try writeElementID(&header_data, EBML.MaxIDLength);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(4);

        // MaxSizeLength
        try writeElementID(&header_data, EBML.MaxSizeLength);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(8);

        // DocType
        try writeElementID(&header_data, EBML.DocType);
        const doctype = "webm";
        try writeVInt(&header_data, doctype.len);
        try header_data.appendSlice(doctype);

        // DocTypeVersion
        try writeElementID(&header_data, EBML.DocTypeVersion);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(2);

        // DocTypeReadVersion
        try writeElementID(&header_data, EBML.DocTypeReadVersion);
        try writeVInt(&header_data, 1);
        try header_data.writer().writeByte(2);

        // Write size and data
        try writeVInt(output, header_data.items.len);
        try output.appendSlice(header_data.items);
    }

    fn writeSegmentInfo(self: *Self, output: *std.ArrayList(u8)) !void {
        try writeElementID(output, Segment.Info);

        var info_data = std.ArrayList(u8).init(output.allocator);
        defer info_data.deinit();

        // TimestampScale (in nanoseconds)
        try writeElementID(&info_data, Info.TimestampScale);
        try writeVInt(&info_data, 8);
        try info_data.writer().writeInt(u64, self.timestamp_scale, .big);

        // MuxingApp
        try writeElementID(&info_data, Info.MuxingApp);
        const muxing_app = "Home Video Library";
        try writeVInt(&info_data, muxing_app.len);
        try info_data.appendSlice(muxing_app);

        // WritingApp
        try writeElementID(&info_data, Info.WritingApp);
        const writing_app = "Home Video Library";
        try writeVInt(&info_data, writing_app.len);
        try info_data.appendSlice(writing_app);

        // Duration (calculate from clusters)
        if (self.clusters.items.len > 0) {
            const last_cluster = &self.clusters.items[self.clusters.items.len - 1];
            if (last_cluster.blocks.items.len > 0) {
                const duration_ms = last_cluster.timestamp;
                const duration_f64: f64 = @floatFromInt(duration_ms);

                try writeElementID(&info_data, Info.Duration);
                try writeVInt(&info_data, 8);
                try info_data.writer().writeAll(std.mem.asBytes(&duration_f64));
            }
        }

        try writeVInt(output, info_data.items.len);
        try output.appendSlice(info_data.items);
    }

    fn writeTracks(self: *Self, output: *std.ArrayList(u8)) !void {
        try writeElementID(output, Segment.Tracks);

        var tracks_data = std.ArrayList(u8).init(output.allocator);
        defer tracks_data.deinit();

        for (self.tracks.items) |*track_info| {
            try self.writeTrackEntry(&tracks_data, track_info);
        }

        try writeVInt(output, tracks_data.items.len);
        try output.appendSlice(tracks_data.items);
    }

    fn writeTrackEntry(self: *Self, output: *std.ArrayList(u8), track_info: *const TrackInfo) !void {
        _ = self;

        try writeElementID(output, Track.Entry);

        var entry_data = std.ArrayList(u8).init(output.allocator);
        defer entry_data.deinit();

        // Track Number
        try writeElementID(&entry_data, Track.Number);
        try writeVInt(&entry_data, 1);
        try entry_data.writer().writeByte(@intCast(track_info.track_number));

        // Track UID
        try writeElementID(&entry_data, Track.UID);
        try writeVInt(&entry_data, 8);
        try entry_data.writer().writeInt(u64, track_info.track_uid, .big);

        // Track Type
        try writeElementID(&entry_data, Track.Type);
        try writeVInt(&entry_data, 1);
        try entry_data.writer().writeByte(@intFromEnum(track_info.track_type));

        // Codec ID
        try writeElementID(&entry_data, Track.CodecID);
        try writeVInt(&entry_data, track_info.codec_id.len);
        try entry_data.appendSlice(track_info.codec_id);

        // Video/Audio specific
        if (track_info.track_type == .video) {
            try writeVideoInfo(&entry_data, track_info);
        } else if (track_info.track_type == .audio) {
            try writeAudioInfo(&entry_data, track_info);
        }

        try writeVInt(output, entry_data.items.len);
        try output.appendSlice(entry_data.items);
    }

    fn writeVideoInfo(output: *std.ArrayList(u8), track_info: *const TrackInfo) !void {
        try writeElementID(output, Track.Video);

        var video_data = std.ArrayList(u8).init(output.allocator);
        defer video_data.deinit();

        // PixelWidth
        try writeElementID(&video_data, Video.PixelWidth);
        try writeVInt(&video_data, 4);
        try video_data.writer().writeInt(u32, track_info.width, .big);

        // PixelHeight
        try writeElementID(&video_data, Video.PixelHeight);
        try writeVInt(&video_data, 4);
        try video_data.writer().writeInt(u32, track_info.height, .big);

        try writeVInt(output, video_data.items.len);
        try output.appendSlice(video_data.items);
    }

    fn writeAudioInfo(output: *std.ArrayList(u8), track_info: *const TrackInfo) !void {
        try writeElementID(output, Track.Audio);

        var audio_data = std.ArrayList(u8).init(output.allocator);
        defer audio_data.deinit();

        // SamplingFrequency
        try writeElementID(&audio_data, Audio.SamplingFrequency);
        try writeVInt(&audio_data, 8);
        try audio_data.writer().writeAll(std.mem.asBytes(&track_info.sample_rate));

        // Channels
        try writeElementID(&audio_data, Audio.Channels);
        try writeVInt(&audio_data, 1);
        try audio_data.writer().writeByte(track_info.channels);

        try writeVInt(output, audio_data.items.len);
        try output.appendSlice(audio_data.items);
    }

    fn writeCluster(self: *Self, output: *std.ArrayList(u8), cluster: *const ClusterData) !void {
        _ = self;

        try writeElementID(output, Segment.Cluster);

        var cluster_data = std.ArrayList(u8).init(output.allocator);
        defer cluster_data.deinit();

        // Timestamp
        try writeElementID(&cluster_data, Cluster.Timestamp);
        try writeVInt(&cluster_data, 8);
        try cluster_data.writer().writeInt(u64, cluster.timestamp, .big);

        // SimpleBlocks
        for (cluster.blocks.items) |*block| {
            try writeSimpleBlock(&cluster_data, block);
        }

        try writeVInt(output, cluster_data.items.len);
        try output.appendSlice(cluster_data.items);
    }

    fn writeSimpleBlock(output: *std.ArrayList(u8), block: *const BlockData) !void {
        try writeElementID(output, Cluster.SimpleBlock);

        // Calculate block size
        const block_size = 1 + 2 + 1 + block.data.len; // track + timestamp + flags + data
        try writeVInt(output, block_size);

        // Track number (variable length)
        try output.writer().writeByte(@intCast(block.track_number));

        // Timestamp offset (signed 16-bit)
        try output.writer().writeInt(i16, block.timestamp_offset, .big);

        // Flags
        try output.writer().writeByte(block.flags);

        // Frame data
        try output.appendSlice(block.data);
    }

    fn writeElementID(output: *std.ArrayList(u8), id: u32) !void {
        // Determine EBML element ID encoding (variable length)
        if (id <= 0x7F) {
            try output.writer().writeByte(@intCast(id));
        } else if (id <= 0x3FFF) {
            try output.writer().writeInt(u16, @intCast(id | 0x4000), .big);
        } else if (id <= 0x1FFFFF) {
            const b1: u8 = @intCast((id >> 16) | 0x20);
            const b2: u8 = @intCast((id >> 8) & 0xFF);
            const b3: u8 = @intCast(id & 0xFF);
            try output.writer().writeByte(b1);
            try output.writer().writeByte(b2);
            try output.writer().writeByte(b3);
        } else {
            try output.writer().writeInt(u32, id, .big);
        }
    }

    fn writeVInt(output: *std.ArrayList(u8), value: usize) !void {
        // EBML variable-length integer encoding
        if (value < 127) {
            try output.writer().writeByte(@as(u8, @intCast(value)) | 0x80);
        } else if (value < 16383) {
            try output.writer().writeByte(@as(u8, @intCast((value >> 8))) | 0x40);
            try output.writer().writeByte(@as(u8, @intCast(value & 0xFF)));
        } else if (value < 2097151) {
            try output.writer().writeByte(@as(u8, @intCast((value >> 16))) | 0x20);
            try output.writer().writeByte(@as(u8, @intCast((value >> 8) & 0xFF)));
            try output.writer().writeByte(@as(u8, @intCast(value & 0xFF)));
        } else {
            // Full 4-byte encoding
            try output.writer().writeByte(@as(u8, @intCast((value >> 24))) | 0x10);
            try output.writer().writeByte(@as(u8, @intCast((value >> 16) & 0xFF)));
            try output.writer().writeByte(@as(u8, @intCast((value >> 8) & 0xFF)));
            try output.writer().writeByte(@as(u8, @intCast(value & 0xFF)));
        }
    }
};
