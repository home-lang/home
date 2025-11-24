// Home Audio Library - Cue Sheet Parser
// Parse .cue files for CD track information

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Cue sheet track
pub const CueTrack = struct {
    /// Track number (1-99)
    number: u8,
    /// Track title
    title: ?[]const u8,
    /// Track performer
    performer: ?[]const u8,
    /// ISRC code
    isrc: ?[]const u8,
    /// Track type
    track_type: TrackType,
    /// Index 00 (pregap start)
    pregap: ?Timestamp,
    /// Index 01 (track start)
    start: Timestamp,
    /// Index 02+ (other indices)
    indices: std.ArrayList(Timestamp),
    /// File this track belongs to
    file_index: usize,

    pub const TrackType = enum {
        audio,
        mode1_2048,
        mode1_2352,
        mode2_2336,
        mode2_2352,
        cdi_2336,
        cdi_2352,

        pub fn fromString(s: []const u8) ?TrackType {
            if (std.mem.eql(u8, s, "AUDIO")) return .audio;
            if (std.mem.eql(u8, s, "MODE1/2048")) return .mode1_2048;
            if (std.mem.eql(u8, s, "MODE1/2352")) return .mode1_2352;
            if (std.mem.eql(u8, s, "MODE2/2336")) return .mode2_2336;
            if (std.mem.eql(u8, s, "MODE2/2352")) return .mode2_2352;
            if (std.mem.eql(u8, s, "CDI/2336")) return .cdi_2336;
            if (std.mem.eql(u8, s, "CDI/2352")) return .cdi_2352;
            return null;
        }
    };

    pub fn init(_: Allocator, number: u8, track_type: TrackType) CueTrack {
        return CueTrack{
            .number = number,
            .title = null,
            .performer = null,
            .isrc = null,
            .track_type = track_type,
            .pregap = null,
            .start = Timestamp.ZERO,
            .indices = .{},
            .file_index = 0,
        };
    }

    pub fn deinit(self: *CueTrack, allocator: Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.performer) |p| allocator.free(p);
        if (self.isrc) |i| allocator.free(i);
        self.indices.deinit(allocator);
    }
};

/// CD timestamp (MM:SS:FF where FF = frames, 75 frames/sec)
pub const Timestamp = struct {
    /// Minutes
    minutes: u8,
    /// Seconds (0-59)
    seconds: u8,
    /// Frames (0-74, 75 frames per second)
    frames: u8,

    pub const ZERO = Timestamp{ .minutes = 0, .seconds = 0, .frames = 0 };
    pub const FRAMES_PER_SECOND = 75;

    /// Parse from "MM:SS:FF" string
    pub fn parse(s: []const u8) ?Timestamp {
        // Find colons
        var parts: [3][]const u8 = undefined;
        var part_count: usize = 0;
        var start: usize = 0;

        for (s, 0..) |c, i| {
            if (c == ':') {
                if (part_count >= 2) return null;
                parts[part_count] = s[start..i];
                part_count += 1;
                start = i + 1;
            }
        }

        if (part_count != 2) return null;
        parts[2] = s[start..];

        const minutes = std.fmt.parseInt(u8, parts[0], 10) catch return null;
        const seconds = std.fmt.parseInt(u8, parts[1], 10) catch return null;
        const frames = std.fmt.parseInt(u8, parts[2], 10) catch return null;

        if (seconds >= 60 or frames >= 75) return null;

        return Timestamp{
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
        };
    }

    /// Convert to total frames
    pub fn toFrames(self: Timestamp) u32 {
        return @as(u32, self.minutes) * 60 * 75 +
            @as(u32, self.seconds) * 75 +
            @as(u32, self.frames);
    }

    /// Convert to seconds (float)
    pub fn toSeconds(self: Timestamp) f64 {
        return @as(f64, @floatFromInt(self.toFrames())) / 75.0;
    }

    /// Convert to samples at given sample rate
    pub fn toSamples(self: Timestamp, sample_rate: u32) u64 {
        return @as(u64, @intFromFloat(self.toSeconds() * @as(f64, @floatFromInt(sample_rate))));
    }

    /// Create from total frames
    pub fn fromFrames(total: u32) Timestamp {
        const frames = total % 75;
        const total_seconds = total / 75;
        const seconds = total_seconds % 60;
        const minutes = total_seconds / 60;

        return Timestamp{
            .minutes = @intCast(minutes),
            .seconds = @intCast(seconds),
            .frames = @intCast(frames),
        };
    }

    /// Format as string
    pub fn format(self: Timestamp) [8]u8 {
        var buf: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
            self.minutes,
            self.seconds,
            self.frames,
        }) catch {};
        return buf;
    }
};

/// Audio file reference
pub const CueFile = struct {
    /// Filename
    filename: []const u8,
    /// File type
    file_type: FileType,

    pub const FileType = enum {
        wave,
        mp3,
        aiff,
        binary,
        motorola,

        pub fn fromString(s: []const u8) ?FileType {
            if (std.mem.eql(u8, s, "WAVE")) return .wave;
            if (std.mem.eql(u8, s, "MP3")) return .mp3;
            if (std.mem.eql(u8, s, "AIFF")) return .aiff;
            if (std.mem.eql(u8, s, "BINARY")) return .binary;
            if (std.mem.eql(u8, s, "MOTOROLA")) return .motorola;
            return null;
        }
    };
};

/// Cue sheet
pub const CueSheet = struct {
    allocator: Allocator,

    /// Album title
    title: ?[]const u8,
    /// Album performer
    performer: ?[]const u8,
    /// Album songwriter
    songwriter: ?[]const u8,
    /// Catalog number (MCN/UPC/EAN)
    catalog: ?[]const u8,
    /// CD-TEXT file
    cdtextfile: ?[]const u8,

    /// Audio files
    files: std.ArrayList(CueFile),
    /// Tracks
    tracks: std.ArrayList(CueTrack),

    /// REM comments
    comments: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .title = null,
            .performer = null,
            .songwriter = null,
            .catalog = null,
            .cdtextfile = null,
            .files = .{},
            .tracks = .{},
            .comments = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.performer) |p| self.allocator.free(p);
        if (self.songwriter) |s| self.allocator.free(s);
        if (self.catalog) |c| self.allocator.free(c);
        if (self.cdtextfile) |c| self.allocator.free(c);

        for (self.files.items) |f| {
            self.allocator.free(f.filename);
        }
        self.files.deinit(self.allocator);

        for (self.tracks.items) |*t| {
            t.deinit(self.allocator);
        }
        self.tracks.deinit(self.allocator);

        for (self.comments.items) |c| {
            self.allocator.free(c);
        }
        self.comments.deinit(self.allocator);
    }

    /// Parse cue sheet from string
    pub fn parse(allocator: Allocator, data: []const u8) !Self {
        var sheet = Self.init(allocator);
        errdefer sheet.deinit();

        var current_file_index: usize = 0;
        var current_track: ?*CueTrack = null;

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            // Parse command
            if (std.mem.startsWith(u8, line, "REM ")) {
                const comment = try allocator.dupe(u8, line[4..]);
                try sheet.comments.append(allocator, comment);
            } else if (std.mem.startsWith(u8, line, "TITLE ")) {
                const value = parseQuoted(line[6..]);
                if (current_track) |t| {
                    t.title = try allocator.dupe(u8, value);
                } else {
                    sheet.title = try allocator.dupe(u8, value);
                }
            } else if (std.mem.startsWith(u8, line, "PERFORMER ")) {
                const value = parseQuoted(line[10..]);
                if (current_track) |t| {
                    t.performer = try allocator.dupe(u8, value);
                } else {
                    sheet.performer = try allocator.dupe(u8, value);
                }
            } else if (std.mem.startsWith(u8, line, "SONGWRITER ")) {
                const value = parseQuoted(line[11..]);
                sheet.songwriter = try allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "CATALOG ")) {
                sheet.catalog = try allocator.dupe(u8, line[8..]);
            } else if (std.mem.startsWith(u8, line, "CDTEXTFILE ")) {
                sheet.cdtextfile = try allocator.dupe(u8, parseQuoted(line[11..]));
            } else if (std.mem.startsWith(u8, line, "FILE ")) {
                // Parse FILE "filename" TYPE
                const rest = line[5..];
                var end: usize = 0;
                const filename = parseQuotedWithEnd(rest, &end);

                const type_start = std.mem.indexOfScalar(u8, rest[end..], ' ') orelse continue;
                const type_str = std.mem.trim(u8, rest[end + type_start..], " ");

                const file_type = CueFile.FileType.fromString(type_str) orelse continue;
                try sheet.files.append(allocator, .{
                    .filename = try allocator.dupe(u8, filename),
                    .file_type = file_type,
                });
                current_file_index = sheet.files.items.len - 1;
            } else if (std.mem.startsWith(u8, line, "TRACK ")) {
                // Parse TRACK NN TYPE
                const rest = line[6..];
                const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;

                const num_str = rest[0..space];
                const type_str = std.mem.trim(u8, rest[space + 1 ..], " ");

                const number = std.fmt.parseInt(u8, num_str, 10) catch continue;
                const track_type = CueTrack.TrackType.fromString(type_str) orelse continue;

                var track = CueTrack.init(allocator, number, track_type);
                track.file_index = current_file_index;
                try sheet.tracks.append(allocator, track);
                current_track = &sheet.tracks.items[sheet.tracks.items.len - 1];
            } else if (std.mem.startsWith(u8, line, "INDEX ")) {
                const t = current_track orelse continue;

                // Parse INDEX NN MM:SS:FF
                const rest = line[6..];
                const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;

                const idx_str = rest[0..space];
                const time_str = std.mem.trim(u8, rest[space + 1 ..], " ");

                const idx_num = std.fmt.parseInt(u8, idx_str, 10) catch continue;
                const timestamp = Timestamp.parse(time_str) orelse continue;

                if (idx_num == 0) {
                    t.pregap = timestamp;
                } else if (idx_num == 1) {
                    t.start = timestamp;
                } else {
                    try t.indices.append(allocator, timestamp);
                }
            } else if (std.mem.startsWith(u8, line, "ISRC ")) {
                if (current_track) |t| {
                    t.isrc = try allocator.dupe(u8, line[5..]);
                }
            }
        }

        return sheet;
    }

    /// Get total duration
    pub fn getTotalDuration(self: *const Self) Timestamp {
        if (self.tracks.items.len == 0) return Timestamp.ZERO;
        const last = self.tracks.items[self.tracks.items.len - 1];
        return last.start;
    }

    /// Get track count
    pub fn getTrackCount(self: *const Self) usize {
        return self.tracks.items.len;
    }

    /// Get track by number
    pub fn getTrack(self: *const Self, number: u8) ?*const CueTrack {
        for (self.tracks.items) |*t| {
            if (t.number == number) return t;
        }
        return null;
    }
};

/// Parse quoted string (removes quotes)
fn parseQuoted(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

/// Parse quoted string and return end position
fn parseQuotedWithEnd(s: []const u8, end: *usize) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");

    if (trimmed.len >= 1 and trimmed[0] == '"') {
        // Find closing quote
        for (1..trimmed.len) |i| {
            if (trimmed[i] == '"') {
                end.* = i + 1;
                return trimmed[1..i];
            }
        }
    }

    // No quotes, find first space
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    end.* = space;
    return trimmed[0..space];
}

/// Detect if data looks like a cue sheet
pub fn isCueSheet(data: []const u8) bool {
    // Look for common cue sheet commands
    return std.mem.indexOf(u8, data, "FILE ") != null or
        std.mem.indexOf(u8, data, "TRACK ") != null or
        std.mem.indexOf(u8, data, "INDEX ") != null;
}

// ============================================================================
// Tests
// ============================================================================

test "Timestamp parse" {
    const ts = Timestamp.parse("02:30:50").?;
    try std.testing.expectEqual(@as(u8, 2), ts.minutes);
    try std.testing.expectEqual(@as(u8, 30), ts.seconds);
    try std.testing.expectEqual(@as(u8, 50), ts.frames);
}

test "Timestamp to frames" {
    const ts = Timestamp{ .minutes = 1, .seconds = 0, .frames = 0 };
    try std.testing.expectEqual(@as(u32, 4500), ts.toFrames()); // 60 * 75
}

test "Timestamp to seconds" {
    const ts = Timestamp{ .minutes = 0, .seconds = 1, .frames = 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), ts.toSeconds(), 0.001);
}

test "Timestamp format" {
    const ts = Timestamp{ .minutes = 5, .seconds = 30, .frames = 25 };
    const formatted = ts.format();
    try std.testing.expectEqualStrings("05:30:25", formatted[0..8]);
}

test "Parse cue sheet" {
    const allocator = std.testing.allocator;

    const cue_data =
        \\REM GENRE Rock
        \\REM DATE 2023
        \\PERFORMER "Test Artist"
        \\TITLE "Test Album"
        \\FILE "test.wav" WAVE
        \\  TRACK 01 AUDIO
        \\    TITLE "Track One"
        \\    PERFORMER "Test Artist"
        \\    INDEX 01 00:00:00
        \\  TRACK 02 AUDIO
        \\    TITLE "Track Two"
        \\    INDEX 00 03:45:00
        \\    INDEX 01 03:47:00
    ;

    var sheet = try CueSheet.parse(allocator, cue_data);
    defer sheet.deinit();

    try std.testing.expectEqualStrings("Test Album", sheet.title.?);
    try std.testing.expectEqualStrings("Test Artist", sheet.performer.?);
    try std.testing.expectEqual(@as(usize, 1), sheet.files.items.len);
    try std.testing.expectEqual(@as(usize, 2), sheet.tracks.items.len);
    try std.testing.expectEqualStrings("Track One", sheet.tracks.items[0].title.?);
}

test "isCueSheet detection" {
    try std.testing.expect(isCueSheet("FILE \"test.wav\" WAVE\nTRACK 01 AUDIO"));
    try std.testing.expect(!isCueSheet("This is not a cue sheet"));
}
