// Home Video Library - Frame Accurate Seeking
// Keyframe index building, GOP detection, and precise seeking

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Frame Types
// ============================================================================

pub const FrameType = enum {
    i_frame, // Intra-coded (keyframe)
    p_frame, // Predictive (forward reference)
    b_frame, // Bi-directional (forward + backward reference)
    idr_frame, // Instantaneous Decoder Refresh (H.264/HEVC)
    unknown,

    pub fn isKeyframe(self: FrameType) bool {
        return self == .i_frame or self == .idr_frame;
    }

    pub fn isReference(self: FrameType) bool {
        return self == .i_frame or self == .p_frame or self == .idr_frame;
    }
};

pub const PictureStructure = enum {
    frame,
    top_field,
    bottom_field,
};

// ============================================================================
// Frame Index Entry
// ============================================================================

pub const FrameIndexEntry = struct {
    /// Frame number in display order
    display_order: u64,
    /// Frame number in decode order
    decode_order: u64,
    /// Byte offset in the stream
    byte_offset: u64,
    /// Frame size in bytes
    frame_size: u32,
    /// Presentation timestamp (90kHz for MPEG-based)
    pts: i64,
    /// Decode timestamp
    dts: i64,
    /// Frame type
    frame_type: FrameType,
    /// Picture structure
    structure: PictureStructure = .frame,
    /// GOP index this frame belongs to
    gop_index: u32,

    pub fn isKeyframe(self: *const FrameIndexEntry) bool {
        return self.frame_type.isKeyframe();
    }
};

// ============================================================================
// GOP (Group of Pictures) Information
// ============================================================================

pub const GopInfo = struct {
    /// Index of this GOP
    index: u32,
    /// Byte offset of GOP start
    byte_offset: u64,
    /// First frame number in this GOP
    first_frame: u64,
    /// Number of frames in this GOP
    frame_count: u32,
    /// GOP structure pattern (e.g., "IBBPBBP")
    structure: [32]u8 = [_]u8{0} ** 32,
    structure_len: u8 = 0,
    /// Closed GOP flag (no references outside)
    closed: bool = true,
    /// Broken link flag
    broken_link: bool = false,

    pub fn getStructure(self: *const GopInfo) []const u8 {
        return self.structure[0..self.structure_len];
    }

    pub fn setStructure(self: *GopInfo, pattern: []const u8) void {
        const len = @min(pattern.len, 32);
        @memcpy(self.structure[0..len], pattern[0..len]);
        self.structure_len = @intCast(len);
    }
};

// ============================================================================
// Frame Index
// ============================================================================

pub const FrameIndex = struct {
    frames: std.ArrayList(FrameIndexEntry),
    gops: std.ArrayList(GopInfo),
    allocator: Allocator,

    // Index statistics
    total_frames: u64 = 0,
    total_keyframes: u64 = 0,
    duration_pts: i64 = 0,

    // Frame rate info
    frame_rate_num: u32 = 0,
    frame_rate_den: u32 = 0,

    pub fn init(allocator: Allocator) FrameIndex {
        return .{
            .frames = std.ArrayList(FrameIndexEntry).init(allocator),
            .gops = std.ArrayList(GopInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameIndex) void {
        self.frames.deinit();
        self.gops.deinit();
    }

    pub fn addFrame(self: *FrameIndex, entry: FrameIndexEntry) !void {
        try self.frames.append(entry);
        self.total_frames += 1;
        if (entry.isKeyframe()) {
            self.total_keyframes += 1;
        }
        if (entry.pts > self.duration_pts) {
            self.duration_pts = entry.pts;
        }
    }

    pub fn addGop(self: *FrameIndex, gop: GopInfo) !void {
        try self.gops.append(gop);
    }

    /// Find the nearest keyframe at or before given PTS
    pub fn findNearestKeyframe(self: *const FrameIndex, target_pts: i64) ?*const FrameIndexEntry {
        var best: ?*const FrameIndexEntry = null;

        for (self.frames.items) |*frame| {
            if (frame.isKeyframe() and frame.pts <= target_pts) {
                if (best == null or frame.pts > best.?.pts) {
                    best = frame;
                }
            }
        }

        return best;
    }

    /// Find frame by exact PTS
    pub fn findFrameByPts(self: *const FrameIndex, target_pts: i64) ?*const FrameIndexEntry {
        for (self.frames.items) |*frame| {
            if (frame.pts == target_pts) {
                return frame;
            }
        }
        return null;
    }

    /// Find frame by display order
    pub fn findFrameByDisplayOrder(self: *const FrameIndex, display_order: u64) ?*const FrameIndexEntry {
        for (self.frames.items) |*frame| {
            if (frame.display_order == display_order) {
                return frame;
            }
        }
        return null;
    }

    /// Get GOP containing a specific frame
    pub fn getGopForFrame(self: *const FrameIndex, frame_number: u64) ?*const GopInfo {
        for (self.gops.items) |*gop| {
            if (frame_number >= gop.first_frame and
                frame_number < gop.first_frame + gop.frame_count)
            {
                return gop;
            }
        }
        return null;
    }

    /// Get all frames needed to decode a target frame
    pub fn getDependentFrames(
        self: *const FrameIndex,
        target_frame: u64,
        allocator: Allocator,
    ) ![]const *const FrameIndexEntry {
        var deps = std.ArrayList(*const FrameIndexEntry).init(allocator);

        // Find nearest keyframe
        const target = self.findFrameByDisplayOrder(target_frame) orelse return deps.toOwnedSlice();
        const keyframe = self.findNearestKeyframe(target.pts) orelse return deps.toOwnedSlice();

        // Add all frames from keyframe to target in decode order
        for (self.frames.items) |*frame| {
            if (frame.dts >= keyframe.dts and frame.dts <= target.dts) {
                try deps.append(frame);
            }
        }

        // Sort by decode order
        std.mem.sort(*const FrameIndexEntry, deps.items, {}, struct {
            fn lessThan(_: void, a: *const FrameIndexEntry, b: *const FrameIndexEntry) bool {
                return a.decode_order < b.decode_order;
            }
        }.lessThan);

        return deps.toOwnedSlice();
    }

    /// Get average GOP size
    pub fn getAverageGopSize(self: *const FrameIndex) f64 {
        if (self.gops.items.len == 0) return 0;
        var total: u64 = 0;
        for (self.gops.items) |gop| {
            total += gop.frame_count;
        }
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.gops.items.len));
    }

    /// Get keyframe interval statistics
    pub fn getKeyframeStats(self: *const FrameIndex) struct {
        min_interval: u64,
        max_interval: u64,
        avg_interval: f64,
    } {
        if (self.total_keyframes < 2) {
            return .{ .min_interval = 0, .max_interval = 0, .avg_interval = 0 };
        }

        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;
        var total: u64 = 0;
        var count: u64 = 0;
        var last_keyframe: ?u64 = null;

        for (self.frames.items) |frame| {
            if (frame.isKeyframe()) {
                if (last_keyframe) |lk| {
                    const interval = frame.display_order - lk;
                    if (interval < min) min = interval;
                    if (interval > max) max = interval;
                    total += interval;
                    count += 1;
                }
                last_keyframe = frame.display_order;
            }
        }

        return .{
            .min_interval = if (min == std.math.maxInt(u64)) 0 else min,
            .max_interval = max,
            .avg_interval = if (count > 0) @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count)) else 0,
        };
    }
};

// ============================================================================
// H.264/AVC Frame Parser
// ============================================================================

pub const AvcFrameParser = struct {
    /// NAL unit types
    pub const NAL_SLICE = 1;
    pub const NAL_SLICE_DPA = 2;
    pub const NAL_SLICE_DPB = 3;
    pub const NAL_SLICE_DPC = 4;
    pub const NAL_IDR = 5;
    pub const NAL_SEI = 6;
    pub const NAL_SPS = 7;
    pub const NAL_PPS = 8;
    pub const NAL_AUD = 9;

    /// Slice types
    pub const SLICE_P = 0;
    pub const SLICE_B = 1;
    pub const SLICE_I = 2;
    pub const SLICE_SP = 3;
    pub const SLICE_SI = 4;

    pub fn parseNalUnitType(data: []const u8) ?u8 {
        if (data.len < 1) return null;
        return data[0] & 0x1F;
    }

    pub fn getFrameType(nal_data: []const u8) FrameType {
        const nal_type = parseNalUnitType(nal_data) orelse return .unknown;

        switch (nal_type) {
            NAL_IDR => return .idr_frame,
            NAL_SLICE, NAL_SLICE_DPA, NAL_SLICE_DPB, NAL_SLICE_DPC => {
                // Need to parse slice header for slice type
                if (nal_data.len < 2) return .unknown;
                const slice_type = parseSliceType(nal_data[1..]) orelse return .unknown;
                return switch (slice_type % 5) {
                    SLICE_I, SLICE_SI => .i_frame,
                    SLICE_P, SLICE_SP => .p_frame,
                    SLICE_B => .b_frame,
                    else => .unknown,
                };
            },
            else => return .unknown,
        }
    }

    fn parseSliceType(data: []const u8) ?u8 {
        // Parse first_mb_in_slice (ue(v)) and slice_type (ue(v))
        var reader = BitReader{ .data = data, .bit_pos = 0, .byte_pos = 0 };

        // Skip first_mb_in_slice
        _ = reader.readUe() orelse return null;

        // Read slice_type
        return @intCast(reader.readUe() orelse return null);
    }
};

// ============================================================================
// HEVC Frame Parser
// ============================================================================

pub const HevcFrameParser = struct {
    /// NAL unit types
    pub const NAL_TRAIL_N = 0;
    pub const NAL_TRAIL_R = 1;
    pub const NAL_TSA_N = 2;
    pub const NAL_TSA_R = 3;
    pub const NAL_STSA_N = 4;
    pub const NAL_STSA_R = 5;
    pub const NAL_RADL_N = 6;
    pub const NAL_RADL_R = 7;
    pub const NAL_RASL_N = 8;
    pub const NAL_RASL_R = 9;
    pub const NAL_BLA_W_LP = 16;
    pub const NAL_BLA_W_RADL = 17;
    pub const NAL_BLA_N_LP = 18;
    pub const NAL_IDR_W_RADL = 19;
    pub const NAL_IDR_N_LP = 20;
    pub const NAL_CRA_NUT = 21;
    pub const NAL_VPS = 32;
    pub const NAL_SPS = 33;
    pub const NAL_PPS = 34;

    pub fn parseNalUnitType(data: []const u8) ?u8 {
        if (data.len < 2) return null;
        return (data[0] >> 1) & 0x3F;
    }

    pub fn getFrameType(nal_data: []const u8) FrameType {
        const nal_type = parseNalUnitType(nal_data) orelse return .unknown;

        // IDR frames
        if (nal_type == NAL_IDR_W_RADL or nal_type == NAL_IDR_N_LP) {
            return .idr_frame;
        }

        // BLA (Broken Link Access) - also keyframes
        if (nal_type >= NAL_BLA_W_LP and nal_type <= NAL_BLA_N_LP) {
            return .i_frame;
        }

        // CRA (Clean Random Access) - keyframe
        if (nal_type == NAL_CRA_NUT) {
            return .i_frame;
        }

        // Other slice types need further analysis
        if (nal_type <= NAL_RASL_R) {
            // These are typically non-IDR slices
            // Would need to parse slice header for exact type
            return .p_frame; // Default assumption
        }

        return .unknown;
    }

    pub fn isRandomAccessPoint(nal_type: u8) bool {
        return nal_type >= NAL_BLA_W_LP and nal_type <= NAL_CRA_NUT;
    }
};

// ============================================================================
// MPEG-2 Frame Parser
// ============================================================================

pub const Mpeg2FrameParser = struct {
    pub const PICTURE_START_CODE = 0x00;
    pub const SEQUENCE_HEADER_CODE = 0xB3;
    pub const GOP_START_CODE = 0xB8;

    /// Picture coding types
    pub const PCT_I = 1;
    pub const PCT_P = 2;
    pub const PCT_B = 3;

    pub fn findPictureHeader(data: []const u8) ?usize {
        var i: usize = 0;
        while (i + 3 < data.len) : (i += 1) {
            if (data[i] == 0x00 and data[i + 1] == 0x00 and
                data[i + 2] == 0x01 and data[i + 3] == PICTURE_START_CODE)
            {
                return i;
            }
        }
        return null;
    }

    pub fn getFrameType(data: []const u8) FrameType {
        const pic_offset = findPictureHeader(data) orelse return .unknown;

        // Picture header: start code (4) + temporal_reference (10) + picture_coding_type (3)
        if (pic_offset + 6 > data.len) return .unknown;

        const header_data = data[pic_offset + 4 ..];
        if (header_data.len < 2) return .unknown;

        // temporal_reference is 10 bits, picture_coding_type is next 3 bits
        const pct = (header_data[1] >> 3) & 0x07;

        return switch (pct) {
            PCT_I => .i_frame,
            PCT_P => .p_frame,
            PCT_B => .b_frame,
            else => .unknown,
        };
    }

    pub fn findGopHeader(data: []const u8) ?struct { offset: usize, closed: bool, broken: bool } {
        var i: usize = 0;
        while (i + 3 < data.len) : (i += 1) {
            if (data[i] == 0x00 and data[i + 1] == 0x00 and
                data[i + 2] == 0x01 and data[i + 3] == GOP_START_CODE)
            {
                if (i + 7 < data.len) {
                    const flags = data[i + 7];
                    return .{
                        .offset = i,
                        .closed = (flags & 0x40) != 0,
                        .broken = (flags & 0x20) != 0,
                    };
                }
                return .{ .offset = i, .closed = true, .broken = false };
            }
        }
        return null;
    }
};

// ============================================================================
// VP9 Frame Parser
// ============================================================================

pub const Vp9FrameParser = struct {
    pub fn getFrameType(data: []const u8) FrameType {
        if (data.len < 1) return .unknown;

        // First two bits of uncompressed header
        const frame_marker = data[0] >> 6;
        if (frame_marker != 0x02) return .unknown; // VP9 marker

        const profile_low = (data[0] >> 4) & 0x03;
        _ = profile_low;

        // Check if keyframe (frame_type bit)
        const show_existing_frame = (data[0] >> 3) & 0x01;
        if (show_existing_frame != 0) return .unknown;

        const frame_type = (data[0] >> 2) & 0x01;
        return if (frame_type == 0) .i_frame else .p_frame;
    }
};

// ============================================================================
// AV1 Frame Parser
// ============================================================================

pub const Av1FrameParser = struct {
    pub const OBU_SEQUENCE_HEADER = 1;
    pub const OBU_TEMPORAL_DELIMITER = 2;
    pub const OBU_FRAME_HEADER = 3;
    pub const OBU_TILE_GROUP = 4;
    pub const OBU_METADATA = 5;
    pub const OBU_FRAME = 6;

    pub const KEY_FRAME = 0;
    pub const INTER_FRAME = 1;
    pub const INTRA_ONLY_FRAME = 2;
    pub const SWITCH_FRAME = 3;

    pub fn getFrameType(data: []const u8) FrameType {
        // Parse OBU header
        if (data.len < 2) return .unknown;

        const obu_type = (data[0] >> 3) & 0x0F;

        if (obu_type == OBU_FRAME or obu_type == OBU_FRAME_HEADER) {
            // Parse frame header
            const has_size = (data[0] >> 1) & 0x01;
            var offset: usize = 1;

            if (has_size != 0) {
                // Skip LEB128 size
                while (offset < data.len and (data[offset] & 0x80) != 0) {
                    offset += 1;
                }
                offset += 1;
            }

            if (offset >= data.len) return .unknown;

            // First bit indicates show_existing_frame
            const show_existing = (data[offset] >> 7) & 0x01;
            if (show_existing != 0) return .unknown;

            // frame_type is next 2 bits
            const frame_type = (data[offset] >> 5) & 0x03;

            return switch (frame_type) {
                KEY_FRAME => .i_frame,
                INTRA_ONLY_FRAME => .i_frame,
                INTER_FRAME => .p_frame, // Could also be B
                SWITCH_FRAME => .p_frame,
                else => .unknown,
            };
        }

        return .unknown;
    }
};

// ============================================================================
// Bit Reader Helper
// ============================================================================

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,

    fn readBit(self: *BitReader) ?u1 {
        if (self.byte_pos >= self.data.len) return null;
        const bit: u1 = @truncate((self.data[self.byte_pos] >> (7 - @as(u3, self.bit_pos))) & 1);
        self.bit_pos +%= 1;
        if (self.bit_pos == 0) {
            self.byte_pos += 1;
        }
        return bit;
    }

    fn readUe(self: *BitReader) ?u32 {
        // Count leading zeros
        var leading_zeros: u5 = 0;
        while (true) {
            const bit = self.readBit() orelse return null;
            if (bit == 1) break;
            leading_zeros += 1;
            if (leading_zeros > 31) return null;
        }

        if (leading_zeros == 0) return 0;

        var value: u32 = 1;
        for (0..leading_zeros) |_| {
            const bit = self.readBit() orelse return null;
            value = (value << 1) | bit;
        }

        return value - 1;
    }
};

// ============================================================================
// Seek Target
// ============================================================================

pub const SeekTarget = union(enum) {
    /// Seek to specific frame number
    frame: u64,
    /// Seek to PTS value
    pts: i64,
    /// Seek to timestamp in seconds
    time_seconds: f64,
    /// Seek to percentage (0.0 - 1.0)
    percentage: f64,

    pub fn toPts(self: SeekTarget, frame_index: *const FrameIndex) i64 {
        return switch (self) {
            .pts => |p| p,
            .frame => |f| blk: {
                if (frame_index.findFrameByDisplayOrder(f)) |entry| {
                    break :blk entry.pts;
                }
                break :blk 0;
            },
            .time_seconds => |t| @intFromFloat(t * 90000), // 90kHz PTS
            .percentage => |p| @intFromFloat(p * @as(f64, @floatFromInt(frame_index.duration_pts))),
        };
    }
};

// ============================================================================
// Seek Result
// ============================================================================

pub const SeekResult = struct {
    /// The keyframe to start decoding from
    keyframe: FrameIndexEntry,
    /// The target frame we want to display
    target_frame: FrameIndexEntry,
    /// Number of frames to decode before reaching target
    frames_to_decode: u32,
    /// Byte offset to seek to
    byte_offset: u64,
};

// ============================================================================
// Frame Accurate Seeker
// ============================================================================

pub const FrameSeeker = struct {
    index: *const FrameIndex,

    pub fn init(index: *const FrameIndex) FrameSeeker {
        return .{ .index = index };
    }

    /// Seek to target, returning information needed for decoding
    pub fn seek(self: *const FrameSeeker, target: SeekTarget) ?SeekResult {
        const target_pts = target.toPts(self.index);

        // Find nearest keyframe
        const keyframe = self.index.findNearestKeyframe(target_pts) orelse return null;

        // Find target frame
        var target_frame = keyframe.*;
        var closest_diff: i64 = std.math.maxInt(i64);

        for (self.index.frames.items) |frame| {
            const diff = @abs(frame.pts - target_pts);
            if (diff < closest_diff) {
                closest_diff = diff;
                target_frame = frame;
            }
        }

        // Count frames to decode
        var frames_to_decode: u32 = 0;
        for (self.index.frames.items) |frame| {
            if (frame.decode_order >= keyframe.decode_order and
                frame.decode_order <= target_frame.decode_order)
            {
                frames_to_decode += 1;
            }
        }

        return SeekResult{
            .keyframe = keyframe.*,
            .target_frame = target_frame,
            .frames_to_decode = frames_to_decode,
            .byte_offset = keyframe.byte_offset,
        };
    }

    /// Get next keyframe after current position
    pub fn nextKeyframe(self: *const FrameSeeker, current_pts: i64) ?*const FrameIndexEntry {
        var best: ?*const FrameIndexEntry = null;

        for (self.index.frames.items) |*frame| {
            if (frame.isKeyframe() and frame.pts > current_pts) {
                if (best == null or frame.pts < best.?.pts) {
                    best = frame;
                }
            }
        }

        return best;
    }

    /// Get previous keyframe before current position
    pub fn prevKeyframe(self: *const FrameSeeker, current_pts: i64) ?*const FrameIndexEntry {
        var best: ?*const FrameIndexEntry = null;

        for (self.index.frames.items) |*frame| {
            if (frame.isKeyframe() and frame.pts < current_pts) {
                if (best == null or frame.pts > best.?.pts) {
                    best = frame;
                }
            }
        }

        return best;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Frame index basic operations" {
    const testing = std.testing;

    var index = FrameIndex.init(testing.allocator);
    defer index.deinit();

    // Add some frames
    try index.addFrame(.{
        .display_order = 0,
        .decode_order = 0,
        .byte_offset = 0,
        .frame_size = 1000,
        .pts = 0,
        .dts = 0,
        .frame_type = .idr_frame,
        .gop_index = 0,
    });

    try index.addFrame(.{
        .display_order = 1,
        .decode_order = 1,
        .byte_offset = 1000,
        .frame_size = 500,
        .pts = 3000,
        .dts = 3000,
        .frame_type = .p_frame,
        .gop_index = 0,
    });

    try index.addFrame(.{
        .display_order = 2,
        .decode_order = 2,
        .byte_offset = 1500,
        .frame_size = 300,
        .pts = 6000,
        .dts = 6000,
        .frame_type = .b_frame,
        .gop_index = 0,
    });

    try testing.expectEqual(@as(u64, 3), index.total_frames);
    try testing.expectEqual(@as(u64, 1), index.total_keyframes);

    // Find keyframe
    const kf = index.findNearestKeyframe(5000);
    try testing.expect(kf != null);
    try testing.expectEqual(@as(i64, 0), kf.?.pts);
}

test "AVC frame type detection" {
    const testing = std.testing;

    // IDR NAL unit
    const idr_data = [_]u8{0x65}; // NAL type 5
    try testing.expectEqual(FrameType.idr_frame, AvcFrameParser.getFrameType(&idr_data));
}

test "HEVC frame type detection" {
    const testing = std.testing;

    // IDR_W_RADL NAL unit (type 19)
    const idr_data = [_]u8{ 0x26, 0x01 }; // (19 << 1) | 0
    try testing.expectEqual(FrameType.idr_frame, HevcFrameParser.getFrameType(&idr_data));

    // CRA NAL unit (type 21)
    const cra_data = [_]u8{ 0x2A, 0x01 }; // (21 << 1) | 0
    try testing.expectEqual(FrameType.i_frame, HevcFrameParser.getFrameType(&cra_data));
}

test "Frame seeker" {
    const testing = std.testing;

    var index = FrameIndex.init(testing.allocator);
    defer index.deinit();

    // Build a simple index
    try index.addFrame(.{
        .display_order = 0,
        .decode_order = 0,
        .byte_offset = 0,
        .frame_size = 1000,
        .pts = 0,
        .dts = 0,
        .frame_type = .idr_frame,
        .gop_index = 0,
    });

    try index.addFrame(.{
        .display_order = 15,
        .decode_order = 15,
        .byte_offset = 15000,
        .frame_size = 1000,
        .pts = 45000,
        .dts = 45000,
        .frame_type = .idr_frame,
        .gop_index = 1,
    });

    const seeker = FrameSeeker.init(&index);

    // Seek to middle
    const result = seeker.seek(.{ .pts = 30000 });
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 0), result.?.keyframe.pts);
}

test "Keyframe statistics" {
    const testing = std.testing;

    var index = FrameIndex.init(testing.allocator);
    defer index.deinit();

    // Add keyframes at regular intervals
    for (0..4) |i| {
        try index.addFrame(.{
            .display_order = i * 15,
            .decode_order = i * 15,
            .byte_offset = i * 15000,
            .frame_size = 1000,
            .pts = @intCast(i * 45000),
            .dts = @intCast(i * 45000),
            .frame_type = .idr_frame,
            .gop_index = @intCast(i),
        });
    }

    const stats = index.getKeyframeStats();
    try testing.expectEqual(@as(u64, 15), stats.min_interval);
    try testing.expectEqual(@as(u64, 15), stats.max_interval);
    try testing.expectApproxEqAbs(@as(f64, 15.0), stats.avg_interval, 0.01);
}
