// Home Video Library - MXF Container Support
// Material eXchange Format (SMPTE ST 377) parsing

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// MXF Constants
// ============================================================================

/// MXF Partition Pack Key (16 bytes)
pub const PARTITION_PACK_KEY = [16]u8{
    0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
    0x0D, 0x01, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00,
};

/// Primer Pack Key
pub const PRIMER_PACK_KEY = [16]u8{
    0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
    0x0D, 0x01, 0x02, 0x01, 0x01, 0x05, 0x01, 0x00,
};

/// Preface Set Key
pub const PREFACE_SET_KEY = [16]u8{
    0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
    0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x2F, 0x00,
};

// ============================================================================
// Universal Labels (UL)
// ============================================================================

pub const UniversalLabel = [16]u8;

pub const ULRegistry = struct {
    // Operational Patterns
    pub const OP1a = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x01, 0x09, 0x00 };
    pub const OP1b = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x02, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x09, 0x00 };
    pub const OP_Atom = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x02, 0x0D, 0x01, 0x02, 0x01, 0x10, 0x00, 0x00, 0x00 };

    // Essence Container Labels
    pub const MPEG2_FrameWrapped = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x02, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x04, 0x60, 0x01 };
    pub const AVC_FrameWrapped = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x10, 0x60, 0x01 };
    pub const HEVC_FrameWrapped = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0D, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x12, 0x01, 0x00 };
    pub const JPEG2000 = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x07, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x0C, 0x01, 0x00 };
    pub const ProRes = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0D, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x1C, 0x01, 0x00 };
    pub const DNxHD = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x11, 0x01, 0x00 };

    // Audio
    pub const PCM = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x06, 0x01, 0x00 };
    pub const AES3 = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x06, 0x03, 0x00 };

    // Picture Essence Coding
    pub const MPEG2_Main = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x03, 0x04, 0x01, 0x02, 0x02, 0x01, 0x03, 0x03, 0x00 };
    pub const AVC_High = [16]u8{ 0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01, 0x32, 0x20, 0x01 };
};

// ============================================================================
// MXF Types
// ============================================================================

pub const PartitionStatus = enum(u8) {
    unknown = 0x00,
    open_incomplete = 0x01,
    closed_incomplete = 0x02,
    open_complete = 0x03,
    closed_complete = 0x04,
};

pub const PartitionType = enum {
    header,
    body,
    footer,
    unknown,
};

pub const OperationalPattern = enum {
    op1a, // Single item, single package
    op1b, // Single item, ganged packages
    op2a, // Play-list items, single package
    op2b, // Play-list items, ganged packages
    op3a, // Edit items, single package
    op3b, // Edit items, ganged packages
    op_atom, // Atom (simple essence container)
    unknown,
};

pub const EssenceType = enum {
    video_mpeg2,
    video_avc,
    video_hevc,
    video_jpeg2000,
    video_prores,
    video_dnxhd,
    video_unknown,
    audio_pcm,
    audio_aes3,
    audio_unknown,
    data,
    unknown,
};

// ============================================================================
// KLV (Key-Length-Value) Triplet
// ============================================================================

pub const KLV = struct {
    key: UniversalLabel,
    length: u64,
    value_offset: usize, // Offset to value data
    total_size: usize, // Total bytes including KLV header

    pub fn parse(data: []const u8) ?KLV {
        if (data.len < 17) return null; // 16 byte key + at least 1 byte length

        var key: UniversalLabel = undefined;
        @memcpy(&key, data[0..16]);

        // Parse BER length
        const length_result = parseBerLength(data[16..]) orelse return null;

        return KLV{
            .key = key,
            .length = length_result.value,
            .value_offset = 16 + length_result.bytes_read,
            .total_size = 16 + length_result.bytes_read + @as(usize, @intCast(length_result.value)),
        };
    }

    pub fn getValue(self: *const KLV, data: []const u8) ?[]const u8 {
        const end = self.value_offset + @as(usize, @intCast(self.length));
        if (end > data.len) return null;
        return data[self.value_offset..end];
    }
};

/// Parse BER (Basic Encoding Rules) length
fn parseBerLength(data: []const u8) ?struct { value: u64, bytes_read: usize } {
    if (data.len < 1) return null;

    const first = data[0];
    if (first < 0x80) {
        // Short form
        return .{ .value = first, .bytes_read = 1 };
    }

    if (first == 0x80) {
        // Indefinite length (not commonly used in MXF)
        return .{ .value = 0, .bytes_read = 1 };
    }

    // Long form
    const num_octets = first & 0x7F;
    if (num_octets > 8 or data.len < 1 + num_octets) return null;

    var value: u64 = 0;
    for (0..num_octets) |i| {
        value = (value << 8) | data[1 + i];
    }

    return .{ .value = value, .bytes_read = 1 + num_octets };
}

// ============================================================================
// Partition Pack
// ============================================================================

pub const PartitionPack = struct {
    partition_type: PartitionType,
    status: PartitionStatus,
    major_version: u16,
    minor_version: u16,
    kag_size: u32, // KLV Alignment Grid
    this_partition: u64,
    previous_partition: u64,
    footer_partition: u64,
    header_byte_count: u64,
    index_byte_count: u64,
    index_sid: u32,
    body_offset: u64,
    body_sid: u32,
    operational_pattern: UniversalLabel,
    essence_containers: []UniversalLabel,

    pub fn parse(data: []const u8, allocator: Allocator) ?PartitionPack {
        if (data.len < 88) return null;

        // Determine partition type from key byte 13
        const partition_type: PartitionType = switch (data[13]) {
            0x02 => .header,
            0x03 => .body,
            0x04 => .footer,
            else => .unknown,
        };

        // Parse partition pack values
        const status: PartitionStatus = @enumFromInt(data[16]);
        const major = std.mem.readInt(u16, data[17..19], .big);
        const minor = std.mem.readInt(u16, data[19..21], .big);
        const kag = std.mem.readInt(u32, data[21..25], .big);
        const this_part = std.mem.readInt(u64, data[25..33], .big);
        const prev_part = std.mem.readInt(u64, data[33..41], .big);
        const footer_part = std.mem.readInt(u64, data[41..49], .big);
        const header_bytes = std.mem.readInt(u64, data[49..57], .big);
        const index_bytes = std.mem.readInt(u64, data[57..65], .big);
        const idx_sid = std.mem.readInt(u32, data[65..69], .big);
        const body_off = std.mem.readInt(u64, data[69..77], .big);
        const bdy_sid = std.mem.readInt(u32, data[77..81], .big);

        var op: UniversalLabel = undefined;
        @memcpy(&op, data[81..97]);

        // Parse essence container batch
        var essence_list = std.ArrayList(UniversalLabel).init(allocator);
        if (data.len >= 101) {
            const ec_count = std.mem.readInt(u32, data[97..101], .big);
            const ec_size = std.mem.readInt(u32, data[101..105], .big);
            _ = ec_size;

            var offset: usize = 105;
            for (0..ec_count) |_| {
                if (offset + 16 > data.len) break;
                var ul: UniversalLabel = undefined;
                @memcpy(&ul, data[offset..][0..16]);
                essence_list.append(ul) catch break;
                offset += 16;
            }
        }

        return PartitionPack{
            .partition_type = partition_type,
            .status = status,
            .major_version = major,
            .minor_version = minor,
            .kag_size = kag,
            .this_partition = this_part,
            .previous_partition = prev_part,
            .footer_partition = footer_part,
            .header_byte_count = header_bytes,
            .index_byte_count = index_bytes,
            .index_sid = idx_sid,
            .body_offset = body_off,
            .body_sid = bdy_sid,
            .operational_pattern = op,
            .essence_containers = essence_list.toOwnedSlice() catch &[_]UniversalLabel{},
        };
    }

    pub fn deinit(self: *PartitionPack, allocator: Allocator) void {
        allocator.free(self.essence_containers);
    }

    pub fn getOperationalPattern(self: *const PartitionPack) OperationalPattern {
        if (std.mem.eql(u8, &self.operational_pattern, &ULRegistry.OP1a)) return .op1a;
        if (std.mem.eql(u8, &self.operational_pattern, &ULRegistry.OP1b)) return .op1b;
        if (std.mem.eql(u8, &self.operational_pattern, &ULRegistry.OP_Atom)) return .op_atom;
        return .unknown;
    }
};

// ============================================================================
// Index Table
// ============================================================================

pub const IndexEntry = struct {
    temporal_offset: i8,
    key_frame_offset: i8,
    flags: u8,
    stream_offset: u64,

    pub fn isKeyframe(self: *const IndexEntry) bool {
        return (self.flags & 0x80) != 0;
    }
};

pub const IndexTableSegment = struct {
    instance_id: [16]u8,
    index_edit_rate: Rational,
    index_start_position: i64,
    index_duration: i64,
    edit_unit_byte_count: u32,
    index_sid: u32,
    body_sid: u32,
    slice_count: u8,
    entries: []IndexEntry,

    pub fn deinit(self: *IndexTableSegment, allocator: Allocator) void {
        allocator.free(self.entries);
    }
};

pub const Rational = struct {
    numerator: i32,
    denominator: i32,

    pub fn toFloat(self: *const Rational) f64 {
        if (self.denominator == 0) return 0;
        return @as(f64, @floatFromInt(self.numerator)) /
            @as(f64, @floatFromInt(self.denominator));
    }
};

// ============================================================================
// Track Information
// ============================================================================

pub const MxfTrack = struct {
    track_id: u32,
    track_number: u32,
    track_name: []const u8,
    edit_rate: Rational,
    origin: i64,
    essence_type: EssenceType,
    essence_container: UniversalLabel,

    // Video specific
    width: ?u32 = null,
    height: ?u32 = null,
    aspect_ratio: ?Rational = null,
    color_depth: ?u8 = null,
    frame_layout: ?FrameLayout = null,

    // Audio specific
    sample_rate: ?Rational = null,
    channels: ?u32 = null,
    bits_per_sample: ?u32 = null,
};

pub const FrameLayout = enum(u8) {
    full_frame = 0,
    separate_fields = 1,
    single_field = 2,
    mixed_fields = 3,
    segmented_frame = 4,
};

// ============================================================================
// MXF Metadata
// ============================================================================

pub const MxfMetadata = struct {
    operational_pattern: OperationalPattern,
    creation_date: ?[8]u8 = null, // Timestamp
    modification_date: ?[8]u8 = null,
    material_package_name: ?[]const u8 = null,
    tracks: []MxfTrack,
    duration: ?i64 = null,

    pub fn deinit(self: *MxfMetadata, allocator: Allocator) void {
        allocator.free(self.tracks);
    }

    pub fn getVideoTrack(self: *const MxfMetadata) ?*const MxfTrack {
        for (self.tracks) |*track| {
            if (track.essence_type == .video_mpeg2 or
                track.essence_type == .video_avc or
                track.essence_type == .video_hevc or
                track.essence_type == .video_jpeg2000 or
                track.essence_type == .video_prores or
                track.essence_type == .video_dnxhd)
            {
                return track;
            }
        }
        return null;
    }

    pub fn getAudioTracks(self: *const MxfMetadata, allocator: Allocator) ![]const *const MxfTrack {
        var audio_tracks = std.ArrayList(*const MxfTrack).init(allocator);
        for (self.tracks) |*track| {
            if (track.essence_type == .audio_pcm or
                track.essence_type == .audio_aes3)
            {
                try audio_tracks.append(track);
            }
        }
        return audio_tracks.toOwnedSlice();
    }
};

// ============================================================================
// MXF Demuxer
// ============================================================================

pub const MxfDemuxer = struct {
    data: []const u8,
    allocator: Allocator,
    header_partition: ?PartitionPack,
    body_partitions: []PartitionPack,
    footer_partition: ?PartitionPack,
    index_segments: []IndexTableSegment,
    metadata: ?MxfMetadata,
    essence_offset: usize,

    pub fn init(data: []const u8, allocator: Allocator) ?MxfDemuxer {
        // Verify MXF signature
        if (!isValidMxf(data)) return null;

        var demuxer = MxfDemuxer{
            .data = data,
            .allocator = allocator,
            .header_partition = null,
            .body_partitions = &[_]PartitionPack{},
            .footer_partition = null,
            .index_segments = &[_]IndexTableSegment{},
            .metadata = null,
            .essence_offset = 0,
        };

        demuxer.parsePartitions();
        demuxer.parseMetadata();

        return demuxer;
    }

    pub fn deinit(self: *MxfDemuxer) void {
        if (self.header_partition) |*hp| {
            hp.deinit(self.allocator);
        }
        for (self.body_partitions) |*bp| {
            bp.deinit(self.allocator);
        }
        self.allocator.free(self.body_partitions);
        if (self.footer_partition) |*fp| {
            fp.deinit(self.allocator);
        }
        for (self.index_segments) |*seg| {
            seg.deinit(self.allocator);
        }
        self.allocator.free(self.index_segments);
        if (self.metadata) |*meta| {
            meta.deinit(self.allocator);
        }
    }

    fn parsePartitions(self: *MxfDemuxer) void {
        var body_list = std.ArrayList(PartitionPack).init(self.allocator);
        var offset: usize = 0;

        while (offset < self.data.len) {
            const klv = KLV.parse(self.data[offset..]) orelse break;

            // Check if this is a partition pack
            if (isPartitionPackKey(&klv.key)) {
                const value = klv.getValue(self.data[offset..]) orelse break;
                var full_data = self.allocator.alloc(u8, 16 + value.len) catch break;
                defer self.allocator.free(full_data);
                @memcpy(full_data[0..16], &klv.key);
                @memcpy(full_data[16..], value);

                if (PartitionPack.parse(full_data, self.allocator)) |partition| {
                    switch (partition.partition_type) {
                        .header => {
                            if (self.header_partition) |*old| {
                                old.deinit(self.allocator);
                            }
                            self.header_partition = partition;
                            // Essence follows header metadata
                            self.essence_offset = offset + klv.total_size +
                                @as(usize, @intCast(partition.header_byte_count)) +
                                @as(usize, @intCast(partition.index_byte_count));
                        },
                        .body => {
                            body_list.append(partition) catch {};
                        },
                        .footer => {
                            if (self.footer_partition) |*old| {
                                old.deinit(self.allocator);
                            }
                            self.footer_partition = partition;
                        },
                        .unknown => {},
                    }
                }
            }

            offset += klv.total_size;
        }

        self.body_partitions = body_list.toOwnedSlice() catch &[_]PartitionPack{};
    }

    fn parseMetadata(self: *MxfDemuxer) void {
        const hp = self.header_partition orelse return;

        var meta = MxfMetadata{
            .operational_pattern = hp.getOperationalPattern(),
            .tracks = &[_]MxfTrack{},
        };

        // Parse metadata sets from header partition
        var track_list = std.ArrayList(MxfTrack).init(self.allocator);

        // Detect essence types from container labels
        for (hp.essence_containers) |ec| {
            const essence_type = detectEssenceType(&ec);
            if (essence_type != .unknown) {
                track_list.append(MxfTrack{
                    .track_id = @intCast(track_list.items.len + 1),
                    .track_number = @intCast(track_list.items.len + 1),
                    .track_name = "",
                    .edit_rate = Rational{ .numerator = 25, .denominator = 1 },
                    .origin = 0,
                    .essence_type = essence_type,
                    .essence_container = ec,
                }) catch {};
            }
        }

        meta.tracks = track_list.toOwnedSlice() catch &[_]MxfTrack{};
        self.metadata = meta;
    }

    /// Get essence data for a frame
    pub fn getEssenceFrame(self: *MxfDemuxer, frame_index: u64) ?[]const u8 {
        // Use index table if available
        for (self.index_segments) |segment| {
            if (frame_index >= @as(u64, @intCast(segment.index_start_position)) and
                frame_index < @as(u64, @intCast(segment.index_start_position + segment.index_duration)))
            {
                const local_index = frame_index - @as(u64, @intCast(segment.index_start_position));
                if (local_index < segment.entries.len) {
                    const entry = segment.entries[local_index];
                    const offset = self.essence_offset + @as(usize, @intCast(entry.stream_offset));

                    // Parse KLV at offset
                    if (offset < self.data.len) {
                        const klv = KLV.parse(self.data[offset..]) orelse return null;
                        return klv.getValue(self.data[offset..]);
                    }
                }
            }
        }

        return null;
    }

    /// Check if frame is a keyframe
    pub fn isKeyframe(self: *MxfDemuxer, frame_index: u64) bool {
        for (self.index_segments) |segment| {
            if (frame_index >= @as(u64, @intCast(segment.index_start_position)) and
                frame_index < @as(u64, @intCast(segment.index_start_position + segment.index_duration)))
            {
                const local_index = frame_index - @as(u64, @intCast(segment.index_start_position));
                if (local_index < segment.entries.len) {
                    return segment.entries[local_index].isKeyframe();
                }
            }
        }
        return false;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn isValidMxf(data: []const u8) bool {
    if (data.len < 16) return false;
    return isPartitionPackKey(data[0..16]);
}

fn isPartitionPackKey(key: *const [16]u8) bool {
    // Check SMPTE UL prefix and partition pack category
    return key[0] == 0x06 and
        key[1] == 0x0E and
        key[2] == 0x2B and
        key[3] == 0x34 and
        key[4] == 0x02 and
        key[5] == 0x05 and
        key[6] == 0x01 and
        key[7] == 0x01 and
        key[8] == 0x0D and
        key[9] == 0x01 and
        key[10] == 0x02 and
        key[11] == 0x01 and
        key[12] == 0x01;
}

fn detectEssenceType(ul: *const UniversalLabel) EssenceType {
    // Match against known essence container labels
    if (std.mem.eql(u8, ul, &ULRegistry.MPEG2_FrameWrapped)) return .video_mpeg2;
    if (std.mem.eql(u8, ul, &ULRegistry.AVC_FrameWrapped)) return .video_avc;
    if (std.mem.eql(u8, ul, &ULRegistry.HEVC_FrameWrapped)) return .video_hevc;
    if (std.mem.eql(u8, ul, &ULRegistry.JPEG2000)) return .video_jpeg2000;
    if (std.mem.eql(u8, ul, &ULRegistry.ProRes)) return .video_prores;
    if (std.mem.eql(u8, ul, &ULRegistry.DNxHD)) return .video_dnxhd;
    if (std.mem.eql(u8, ul, &ULRegistry.PCM)) return .audio_pcm;
    if (std.mem.eql(u8, ul, &ULRegistry.AES3)) return .audio_aes3;

    // Check generic video/audio patterns
    if (ul[12] == 0x02) {
        // Video essence
        return .video_unknown;
    }
    if (ul[12] == 0x06) {
        // Audio essence
        return .audio_unknown;
    }

    return .unknown;
}

/// Format Universal Label as string
pub fn formatUL(ul: *const UniversalLabel) [47]u8 {
    var buf: [47]u8 = undefined;
    const hex = "0123456789ABCDEF";

    var i: usize = 0;
    for (ul, 0..) |byte, idx| {
        buf[i] = hex[byte >> 4];
        buf[i + 1] = hex[byte & 0x0F];
        i += 2;
        if (idx < 15) {
            buf[i] = '.';
            i += 1;
        }
    }

    return buf;
}

// ============================================================================
// Tests
// ============================================================================

test "BER length parsing" {
    const testing = std.testing;

    // Short form
    const short = [_]u8{0x45};
    const short_result = parseBerLength(&short);
    try testing.expect(short_result != null);
    try testing.expectEqual(@as(u64, 0x45), short_result.?.value);
    try testing.expectEqual(@as(usize, 1), short_result.?.bytes_read);

    // Long form (2 bytes)
    const long2 = [_]u8{ 0x82, 0x01, 0x00 };
    const long2_result = parseBerLength(&long2);
    try testing.expect(long2_result != null);
    try testing.expectEqual(@as(u64, 256), long2_result.?.value);
    try testing.expectEqual(@as(usize, 3), long2_result.?.bytes_read);
}

test "KLV parsing" {
    const testing = std.testing;

    // Create a minimal KLV triplet
    var data: [20]u8 = undefined;
    @memcpy(data[0..16], &PARTITION_PACK_KEY);
    data[16] = 0x03; // Short form length = 3
    data[17] = 0xAA;
    data[18] = 0xBB;
    data[19] = 0xCC;

    const klv = KLV.parse(&data);
    try testing.expect(klv != null);
    try testing.expectEqual(@as(u64, 3), klv.?.length);
    try testing.expectEqual(@as(usize, 17), klv.?.value_offset);

    const value = klv.?.getValue(&data);
    try testing.expect(value != null);
    try testing.expectEqual(@as(usize, 3), value.?.len);
}

test "MXF validation" {
    const testing = std.testing;

    // Valid MXF header
    var valid_data: [20]u8 = undefined;
    @memcpy(valid_data[0..16], &PARTITION_PACK_KEY);
    valid_data[13] = 0x02; // Header partition
    valid_data[16..20].* = .{ 0x00, 0x00, 0x00, 0x00 };

    try testing.expect(isValidMxf(&valid_data));

    // Invalid data
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(!isValidMxf(&invalid_data));
}

test "Essence type detection" {
    const testing = std.testing;

    try testing.expectEqual(EssenceType.video_avc, detectEssenceType(&ULRegistry.AVC_FrameWrapped));
    try testing.expectEqual(EssenceType.video_prores, detectEssenceType(&ULRegistry.ProRes));
    try testing.expectEqual(EssenceType.audio_pcm, detectEssenceType(&ULRegistry.PCM));
}

test "UL formatting" {
    const testing = std.testing;

    const ul = ULRegistry.OP1a;
    const formatted = formatUL(&ul);
    try testing.expect(formatted[0] == '0');
    try testing.expect(formatted[1] == '6');
}
