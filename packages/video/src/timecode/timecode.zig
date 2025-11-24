// Home Video Library - SMPTE Timecode Support
// SMPTE 12M timecode parsing, generation, and drop-frame handling

const std = @import("std");

// ============================================================================
// Timecode Types
// ============================================================================

/// Frame rate presets
pub const FrameRate = enum {
    fps_23_976, // 24000/1001 (film pulldown)
    fps_24, // Film
    fps_25, // PAL
    fps_29_97_df, // NTSC drop-frame
    fps_29_97_ndf, // NTSC non-drop-frame
    fps_30, // 30 fps
    fps_50, // PAL high frame rate
    fps_59_94_df, // HD drop-frame
    fps_59_94_ndf, // HD non-drop-frame
    fps_60, // HD

    pub fn nominal(self: FrameRate) u8 {
        return switch (self) {
            .fps_23_976, .fps_24 => 24,
            .fps_25 => 25,
            .fps_29_97_df, .fps_29_97_ndf, .fps_30 => 30,
            .fps_50 => 50,
            .fps_59_94_df, .fps_59_94_ndf, .fps_60 => 60,
        };
    }

    pub fn isDropFrame(self: FrameRate) bool {
        return self == .fps_29_97_df or self == .fps_59_94_df;
    }

    pub fn framesPerSecond(self: FrameRate) f64 {
        return switch (self) {
            .fps_23_976 => 24000.0 / 1001.0,
            .fps_24 => 24.0,
            .fps_25 => 25.0,
            .fps_29_97_df, .fps_29_97_ndf => 30000.0 / 1001.0,
            .fps_30 => 30.0,
            .fps_50 => 50.0,
            .fps_59_94_df, .fps_59_94_ndf => 60000.0 / 1001.0,
            .fps_60 => 60.0,
        };
    }

    /// Get timebase as fraction (num/den)
    pub fn timebase(self: FrameRate) struct { num: u32, den: u32 } {
        return switch (self) {
            .fps_23_976 => .{ .num = 1001, .den = 24000 },
            .fps_24 => .{ .num = 1, .den = 24 },
            .fps_25 => .{ .num = 1, .den = 25 },
            .fps_29_97_df, .fps_29_97_ndf => .{ .num = 1001, .den = 30000 },
            .fps_30 => .{ .num = 1, .den = 30 },
            .fps_50 => .{ .num = 1, .den = 50 },
            .fps_59_94_df, .fps_59_94_ndf => .{ .num = 1001, .den = 60000 },
            .fps_60 => .{ .num = 1, .den = 60 },
        };
    }
};

/// SMPTE Timecode
pub const Timecode = struct {
    hours: u8,
    minutes: u8,
    seconds: u8,
    frames: u8,
    drop_frame: bool = false,

    /// Create timecode from components
    pub fn init(hours: u8, minutes: u8, seconds: u8, frames: u8, drop_frame: bool) Timecode {
        return .{
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
            .drop_frame = drop_frame,
        };
    }

    /// Create timecode from frame number
    pub fn fromFrameNumber(frame_number: u64, rate: FrameRate) Timecode {
        const nominal = rate.nominal();
        const is_df = rate.isDropFrame();

        if (is_df) {
            return fromFrameNumberDropFrame(frame_number, nominal);
        } else {
            return fromFrameNumberNonDropFrame(frame_number, nominal);
        }
    }

    fn fromFrameNumberNonDropFrame(frame_number: u64, fps: u8) Timecode {
        const fps64: u64 = fps;
        const total_seconds = frame_number / fps64;
        const frames = frame_number % fps64;

        const hours = total_seconds / 3600;
        const minutes = (total_seconds % 3600) / 60;
        const seconds = total_seconds % 60;

        return .{
            .hours = @intCast(hours % 24),
            .minutes = @intCast(minutes),
            .seconds = @intCast(seconds),
            .frames = @intCast(frames),
            .drop_frame = false,
        };
    }

    fn fromFrameNumberDropFrame(frame_number: u64, fps: u8) Timecode {
        // Drop frame skips frames 0 and 1 at the start of each minute,
        // except every 10th minute

        const drop_frames: u64 = if (fps == 30) 2 else 4; // 29.97 or 59.94
        const frames_per_10_min: u64 = if (fps == 30) 17982 else 35964;
        const frames_per_min: u64 = if (fps == 30) 1798 else 3596;

        var d = frame_number;

        // 10-minute blocks
        const d10 = d / frames_per_10_min;
        d = d % frames_per_10_min;

        // Handle first minute of 10-minute block (no drops)
        var extra_frames: u64 = 0;
        if (d >= @as(u64, fps) * 60) {
            d -= @as(u64, fps) * 60;
            extra_frames = 1;
            // Remaining minutes in block
            const minutes_in_block = d / frames_per_min;
            d = d % frames_per_min;
            extra_frames += minutes_in_block;
            // Add back dropped frames
            d += drop_frames * (extra_frames);
        }

        const total_frames = d10 * 10 * @as(u64, fps) * 60 + extra_frames * @as(u64, fps) * 60 + d;

        // Convert to timecode
        const total_seconds = total_frames / fps;
        const frames = total_frames % fps;

        return .{
            .hours = @intCast((total_seconds / 3600) % 24),
            .minutes = @intCast((total_seconds % 3600) / 60),
            .seconds = @intCast(total_seconds % 60),
            .frames = @intCast(frames),
            .drop_frame = true,
        };
    }

    /// Create timecode from seconds
    pub fn fromSeconds(secs: f64, rate: FrameRate) Timecode {
        const frame_number: u64 = @intFromFloat(secs * rate.framesPerSecond());
        return fromFrameNumber(frame_number, rate);
    }

    /// Create timecode from milliseconds
    pub fn fromMilliseconds(ms: u64, rate: FrameRate) Timecode {
        const frame_number = @as(u64, @intFromFloat(@as(f64, @floatFromInt(ms)) * rate.framesPerSecond() / 1000.0));
        return fromFrameNumber(frame_number, rate);
    }

    /// Convert to frame number
    pub fn toFrameNumber(self: *const Timecode, rate: FrameRate) u64 {
        const fps: u64 = rate.nominal();

        if (self.drop_frame) {
            return self.toFrameNumberDropFrame(fps);
        } else {
            return self.toFrameNumberNonDropFrame(fps);
        }
    }

    fn toFrameNumberNonDropFrame(self: *const Timecode, fps: u64) u64 {
        const total_seconds = @as(u64, self.hours) * 3600 +
            @as(u64, self.minutes) * 60 +
            self.seconds;
        return total_seconds * fps + self.frames;
    }

    fn toFrameNumberDropFrame(self: *const Timecode, fps: u64) u64 {
        const drop_frames: u64 = if (fps == 30) 2 else 4;

        const total_minutes = @as(u64, self.hours) * 60 + self.minutes;
        const ten_min_blocks = total_minutes / 10;
        const remaining_mins = total_minutes % 10;

        // Frames dropped = 2 per minute, except every 10th minute
        const dropped = drop_frames * (total_minutes - ten_min_blocks);

        const total_seconds = @as(u64, self.hours) * 3600 +
            @as(u64, self.minutes) * 60 +
            self.seconds;

        return total_seconds * fps + self.frames - dropped;
    }

    /// Convert to seconds
    pub fn toSeconds(self: *const Timecode, rate: FrameRate) f64 {
        const frames = self.toFrameNumber(rate);
        return @as(f64, @floatFromInt(frames)) / rate.framesPerSecond();
    }

    /// Convert to milliseconds
    pub fn toMilliseconds(self: *const Timecode, rate: FrameRate) u64 {
        return @intFromFloat(self.toSeconds(rate) * 1000.0);
    }

    /// Format as string (HH:MM:SS:FF or HH:MM:SS;FF for drop-frame)
    pub fn format(self: *const Timecode, buf: []u8) []u8 {
        const sep: u8 = if (self.drop_frame) ';' else ':';
        const len = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}", .{
            self.hours,
            self.minutes,
            self.seconds,
            sep,
            self.frames,
        }) catch return buf[0..0];
        return buf[0..len.len];
    }

    /// Parse timecode from string
    pub fn parse(str: []const u8) ?Timecode {
        if (str.len < 11) return null;

        // Check for drop-frame indicator
        const is_df = str[8] == ';';

        const hours = std.fmt.parseInt(u8, str[0..2], 10) catch return null;
        const minutes = std.fmt.parseInt(u8, str[3..5], 10) catch return null;
        const seconds = std.fmt.parseInt(u8, str[6..8], 10) catch return null;
        const frames = std.fmt.parseInt(u8, str[9..11], 10) catch return null;

        return .{
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
            .drop_frame = is_df,
        };
    }

    /// Add frames to timecode
    pub fn addFrames(self: *const Timecode, frames_to_add: i64, rate: FrameRate) Timecode {
        const current = self.toFrameNumber(rate);
        const new_frame: u64 = if (frames_to_add >= 0)
            current + @as(u64, @intCast(frames_to_add))
        else if (@as(u64, @intCast(-frames_to_add)) > current)
            0
        else
            current - @as(u64, @intCast(-frames_to_add));

        return Timecode.fromFrameNumber(new_frame, rate);
    }

    /// Add seconds to timecode
    pub fn addSeconds(self: *const Timecode, secs: f64, rate: FrameRate) Timecode {
        const frames_to_add: i64 = @intFromFloat(secs * rate.framesPerSecond());
        return self.addFrames(frames_to_add, rate);
    }

    /// Compare two timecodes
    pub fn compare(self: *const Timecode, other: *const Timecode, rate: FrameRate) i32 {
        const a = self.toFrameNumber(rate);
        const b = other.toFrameNumber(rate);
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
    }
};

// ============================================================================
// LTC (Linear Timecode) - SMPTE 12M
// ============================================================================

/// LTC bit pattern structure
pub const LtcFrame = struct {
    // User bits (32 bits total, 4 per group)
    user_bits: [8]u4 = [_]u4{0} ** 8,

    // Timecode
    timecode: Timecode = .{
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
        .frames = 0,
        .drop_frame = false,
    },

    // Flags
    color_frame_flag: bool = false,
    bgf0: bool = false, // Binary group flag 0
    bgf1: bool = false,
    bgf2: bool = false,
    polarity_correction: bool = false,

    /// Encode to 80-bit LTC word
    pub fn encode(self: *const LtcFrame) [10]u8 {
        var data: [10]u8 = [_]u8{0} ** 10;

        // Byte 0: Frame units (4 bits) + user bits 1
        data[0] = (self.timecode.frames % 10) | (@as(u8, self.user_bits[0]) << 4);

        // Byte 1: Frame tens (2 bits) + drop frame + color frame + user bits 2
        data[1] = ((self.timecode.frames / 10) & 0x03) |
            (@as(u8, if (self.timecode.drop_frame) 1 else 0) << 2) |
            (@as(u8, if (self.color_frame_flag) 1 else 0) << 3) |
            (@as(u8, self.user_bits[1]) << 4);

        // Byte 2: Seconds units + user bits 3
        data[2] = (self.timecode.seconds % 10) | (@as(u8, self.user_bits[2]) << 4);

        // Byte 3: Seconds tens + BGF0 + user bits 4
        data[3] = ((self.timecode.seconds / 10) & 0x07) |
            (@as(u8, if (self.bgf0) 1 else 0) << 3) |
            (@as(u8, self.user_bits[3]) << 4);

        // Byte 4: Minutes units + user bits 5
        data[4] = (self.timecode.minutes % 10) | (@as(u8, self.user_bits[4]) << 4);

        // Byte 5: Minutes tens + BGF1 + user bits 6
        data[5] = ((self.timecode.minutes / 10) & 0x07) |
            (@as(u8, if (self.bgf1) 1 else 0) << 3) |
            (@as(u8, self.user_bits[5]) << 4);

        // Byte 6: Hours units + user bits 7
        data[6] = (self.timecode.hours % 10) | (@as(u8, self.user_bits[6]) << 4);

        // Byte 7: Hours tens + BGF2 + polarity + user bits 8
        data[7] = ((self.timecode.hours / 10) & 0x03) |
            (@as(u8, if (self.bgf2) 1 else 0) << 2) |
            (@as(u8, if (self.polarity_correction) 1 else 0) << 3) |
            (@as(u8, self.user_bits[7]) << 4);

        // Bytes 8-9: Sync word (0x3FFD)
        data[8] = 0xFD;
        data[9] = 0x3F;

        return data;
    }

    /// Decode from 80-bit LTC word
    pub fn decode(data: []const u8) ?LtcFrame {
        if (data.len < 10) return null;

        // Verify sync word
        if (data[8] != 0xFD or data[9] != 0x3F) return null;

        var frame = LtcFrame{};

        // Decode timecode
        frame.timecode.frames = (data[0] & 0x0F) + ((data[1] & 0x03) * 10);
        frame.timecode.seconds = (data[2] & 0x0F) + ((data[3] & 0x07) * 10);
        frame.timecode.minutes = (data[4] & 0x0F) + ((data[5] & 0x07) * 10);
        frame.timecode.hours = (data[6] & 0x0F) + ((data[7] & 0x03) * 10);

        // Decode flags
        frame.timecode.drop_frame = (data[1] & 0x04) != 0;
        frame.color_frame_flag = (data[1] & 0x08) != 0;
        frame.bgf0 = (data[3] & 0x08) != 0;
        frame.bgf1 = (data[5] & 0x08) != 0;
        frame.bgf2 = (data[7] & 0x04) != 0;
        frame.polarity_correction = (data[7] & 0x08) != 0;

        // Decode user bits
        frame.user_bits[0] = @truncate(data[0] >> 4);
        frame.user_bits[1] = @truncate(data[1] >> 4);
        frame.user_bits[2] = @truncate(data[2] >> 4);
        frame.user_bits[3] = @truncate(data[3] >> 4);
        frame.user_bits[4] = @truncate(data[4] >> 4);
        frame.user_bits[5] = @truncate(data[5] >> 4);
        frame.user_bits[6] = @truncate(data[6] >> 4);
        frame.user_bits[7] = @truncate(data[7] >> 4);

        return frame;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Timecode format and parse" {
    const testing = std.testing;

    const tc = Timecode.init(1, 30, 45, 15, false);
    var buf: [12]u8 = undefined;
    const str = tc.format(&buf);

    try testing.expectEqualStrings("01:30:45:15", str);

    const parsed = Timecode.parse("01:30:45:15");
    try testing.expect(parsed != null);
    try testing.expectEqual(@as(u8, 1), parsed.?.hours);
    try testing.expectEqual(@as(u8, 30), parsed.?.minutes);
    try testing.expectEqual(@as(u8, 45), parsed.?.seconds);
    try testing.expectEqual(@as(u8, 15), parsed.?.frames);
}

test "Timecode drop-frame format" {
    const testing = std.testing;

    const tc = Timecode.init(1, 30, 45, 15, true);
    var buf: [12]u8 = undefined;
    const str = tc.format(&buf);

    try testing.expectEqualStrings("01:30:45;15", str);
}

test "Frame rate properties" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 30), FrameRate.fps_29_97_df.nominal());
    try testing.expect(FrameRate.fps_29_97_df.isDropFrame());
    try testing.expect(!FrameRate.fps_29_97_ndf.isDropFrame());
}

test "Timecode to frame number roundtrip" {
    const testing = std.testing;

    const original = Timecode.init(1, 0, 0, 0, false);
    const frame_num = original.toFrameNumber(.fps_30);
    const back = Timecode.fromFrameNumber(frame_num, .fps_30);

    try testing.expectEqual(original.hours, back.hours);
    try testing.expectEqual(original.minutes, back.minutes);
    try testing.expectEqual(original.seconds, back.seconds);
    try testing.expectEqual(original.frames, back.frames);
}

test "Timecode from seconds" {
    const testing = std.testing;

    const tc = Timecode.fromSeconds(90.5, .fps_30);
    try testing.expectEqual(@as(u8, 0), tc.hours);
    try testing.expectEqual(@as(u8, 1), tc.minutes);
    try testing.expectEqual(@as(u8, 30), tc.seconds);
    try testing.expectEqual(@as(u8, 15), tc.frames);
}

test "LTC encode/decode" {
    const testing = std.testing;

    var frame = LtcFrame{};
    frame.timecode = Timecode.init(12, 34, 56, 20, true);
    frame.user_bits = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const encoded = frame.encode();
    const decoded = LtcFrame.decode(&encoded);

    try testing.expect(decoded != null);
    try testing.expectEqual(@as(u8, 12), decoded.?.timecode.hours);
    try testing.expectEqual(@as(u8, 34), decoded.?.timecode.minutes);
    try testing.expectEqual(@as(u8, 56), decoded.?.timecode.seconds);
    try testing.expectEqual(@as(u8, 20), decoded.?.timecode.frames);
    try testing.expect(decoded.?.timecode.drop_frame);
}
