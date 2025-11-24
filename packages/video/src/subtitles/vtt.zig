// Home Video Library - VTT Subtitle Parser
// WebVTT subtitle format (.vtt)

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// VTT Cue Settings
// ============================================================================

pub const CueSettings = struct {
    vertical: ?Vertical = null,
    line: ?Line = null,
    position: ?u8 = null, // 0-100 percentage
    size: ?u8 = null, // 0-100 percentage
    align_value: ?Align = null,

    pub const Vertical = enum { rl, lr };
    pub const Line = union(enum) { number: i32, percentage: u8 };
    pub const Align = enum { start, center, end, left, right };
};

// ============================================================================
// VTT Cue
// ============================================================================

pub const Cue = struct {
    id: ?[]const u8, // Optional cue identifier
    start_time: u64, // milliseconds
    end_time: u64, // milliseconds
    text: []const u8,
    settings: CueSettings,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cue) void {
        if (self.id) |id| {
            self.allocator.free(id);
        }
        self.allocator.free(self.text);
    }

    /// Get duration in milliseconds
    pub fn getDuration(self: *const Cue) u64 {
        return self.end_time - self.start_time;
    }

    /// Check if cue is active at given time (milliseconds)
    pub fn isActiveAt(self: *const Cue, time_ms: u64) bool {
        return time_ms >= self.start_time and time_ms < self.end_time;
    }

    /// Format start time as string (HH:MM:SS.mmm)
    pub fn formatStartTime(self: *const Cue, buf: []u8) []u8 {
        return formatTimestamp(self.start_time, buf);
    }

    /// Format end time as string (HH:MM:SS.mmm)
    pub fn formatEndTime(self: *const Cue, buf: []u8) []u8 {
        return formatTimestamp(self.end_time, buf);
    }
};

// ============================================================================
// VTT Parser
// ============================================================================

pub const VttParser = struct {
    cues: std.ArrayListUnmanaged(Cue),
    allocator: std.mem.Allocator,
    // Metadata
    title: ?[]const u8,
    regions: std.ArrayListUnmanaged(Region),

    const Self = @This();

    pub const Region = struct {
        id: []const u8,
        width: u8, // percentage
        lines: u8,
        region_anchor: struct { x: u8, y: u8 },
        viewport_anchor: struct { x: u8, y: u8 },
        scroll: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cues = .empty,
            .allocator = allocator,
            .title = null,
            .regions = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cues.items) |*cue| {
            cue.deinit();
        }
        self.cues.deinit(self.allocator);
        if (self.title) |t| {
            self.allocator.free(t);
        }
        self.regions.deinit(self.allocator);
    }

    /// Parse VTT content from string
    pub fn parse(self: *Self, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        // Check for WEBVTT header
        const first_line = lines.next() orelse return VideoError.InvalidHeader;
        const trimmed_first = std.mem.trim(u8, first_line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed_first, "WEBVTT")) {
            return VideoError.InvalidHeader;
        }

        // Parse optional title after WEBVTT
        if (trimmed_first.len > 6) {
            const after_webvtt = std.mem.trim(u8, trimmed_first[6..], " \t");
            if (after_webvtt.len > 0 and after_webvtt[0] == '-') {
                // Skip the dash and any spaces
                const title_text = std.mem.trim(u8, after_webvtt[1..], " \t");
                if (title_text.len > 0) {
                    self.title = try self.allocator.dupe(u8, title_text);
                }
            }
        }

        var state: enum { header, cue_id_or_timing, timing, text } = .header;
        var current_id: ?[]const u8 = null;
        var current_start: u64 = 0;
        var current_end: u64 = 0;
        var current_settings: CueSettings = .{};
        var text_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer text_lines.deinit(self.allocator);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            switch (state) {
                .header => {
                    // Skip empty lines and NOTE blocks in header
                    if (trimmed.len == 0) continue;
                    if (std.mem.startsWith(u8, trimmed, "NOTE")) {
                        // Skip note until empty line
                        while (lines.next()) |note_line| {
                            if (std.mem.trim(u8, note_line, " \t\r").len == 0) break;
                        }
                        continue;
                    }
                    if (std.mem.startsWith(u8, trimmed, "REGION")) {
                        // Skip region definitions for now
                        while (lines.next()) |region_line| {
                            if (std.mem.trim(u8, region_line, " \t\r").len == 0) break;
                        }
                        continue;
                    }
                    if (std.mem.startsWith(u8, trimmed, "STYLE")) {
                        // Skip style blocks
                        while (lines.next()) |style_line| {
                            if (std.mem.trim(u8, style_line, " \t\r").len == 0) break;
                        }
                        continue;
                    }
                    state = .cue_id_or_timing;
                    // Fall through to process this line
                    if (std.mem.indexOf(u8, trimmed, "-->") != null) {
                        // This is a timing line
                        const timing_result = parseTimingLine(trimmed) catch {
                            continue;
                        };
                        current_start = timing_result.start;
                        current_end = timing_result.end;
                        current_settings = timing_result.settings;
                        state = .text;
                    } else if (trimmed.len > 0) {
                        // This is a cue identifier
                        current_id = try self.allocator.dupe(u8, trimmed);
                        state = .timing;
                    }
                },
                .cue_id_or_timing => {
                    if (trimmed.len == 0) continue;
                    if (std.mem.startsWith(u8, trimmed, "NOTE")) {
                        while (lines.next()) |note_line| {
                            if (std.mem.trim(u8, note_line, " \t\r").len == 0) break;
                        }
                        continue;
                    }
                    if (std.mem.indexOf(u8, trimmed, "-->") != null) {
                        // This is a timing line
                        const timing_result = parseTimingLine(trimmed) catch {
                            continue;
                        };
                        current_start = timing_result.start;
                        current_end = timing_result.end;
                        current_settings = timing_result.settings;
                        state = .text;
                    } else {
                        // This is a cue identifier
                        current_id = try self.allocator.dupe(u8, trimmed);
                        state = .timing;
                    }
                },
                .timing => {
                    if (trimmed.len == 0) {
                        // Invalid - expected timing line
                        if (current_id) |id| {
                            self.allocator.free(id);
                            current_id = null;
                        }
                        state = .cue_id_or_timing;
                        continue;
                    }
                    const timing_result = parseTimingLine(trimmed) catch {
                        if (current_id) |id| {
                            self.allocator.free(id);
                            current_id = null;
                        }
                        state = .cue_id_or_timing;
                        continue;
                    };
                    current_start = timing_result.start;
                    current_end = timing_result.end;
                    current_settings = timing_result.settings;
                    state = .text;
                },
                .text => {
                    if (trimmed.len == 0) {
                        // End of cue
                        if (text_lines.items.len > 0) {
                            const text = try joinLines(self.allocator, text_lines.items);
                            try self.cues.append(self.allocator, Cue{
                                .id = current_id,
                                .start_time = current_start,
                                .end_time = current_end,
                                .text = text,
                                .settings = current_settings,
                                .allocator = self.allocator,
                            });
                            current_id = null;
                        } else if (current_id) |id| {
                            self.allocator.free(id);
                            current_id = null;
                        }
                        text_lines.clearRetainingCapacity();
                        current_settings = .{};
                        state = .cue_id_or_timing;
                    } else {
                        try text_lines.append(self.allocator, trimmed);
                    }
                },
            }
        }

        // Handle last cue if no trailing newline
        if (state == .text and text_lines.items.len > 0) {
            const text = try joinLines(self.allocator, text_lines.items);
            try self.cues.append(self.allocator, Cue{
                .id = current_id,
                .start_time = current_start,
                .end_time = current_end,
                .text = text,
                .settings = current_settings,
                .allocator = self.allocator,
            });
        } else if (current_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Get cue active at given time (milliseconds)
    pub fn getCueAt(self: *const Self, time_ms: u64) ?*const Cue {
        for (self.cues.items) |*cue| {
            if (cue.isActiveAt(time_ms)) {
                return cue;
            }
        }
        return null;
    }

    /// Get all cues in a time range
    pub fn getCuesInRange(self: *const Self, allocator: std.mem.Allocator, start_ms: u64, end_ms: u64, result: *std.ArrayListUnmanaged(*const Cue)) !void {
        for (self.cues.items) |*cue| {
            if (cue.end_time > start_ms and cue.start_time < end_ms) {
                try result.append(allocator, cue);
            }
        }
    }

    /// Get total duration (end of last cue)
    pub fn getDuration(self: *const Self) u64 {
        if (self.cues.items.len == 0) return 0;
        var max_end: u64 = 0;
        for (self.cues.items) |cue| {
            if (cue.end_time > max_end) {
                max_end = cue.end_time;
            }
        }
        return max_end;
    }

    /// Get number of cues
    pub fn count(self: *const Self) usize {
        return self.cues.items.len;
    }
};

// ============================================================================
// VTT Writer
// ============================================================================

pub const VttWriter = struct {
    cues: std.ArrayListUnmanaged(Cue),
    allocator: std.mem.Allocator,
    title: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cues = .empty,
            .allocator = allocator,
            .title = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cues.items) |*cue| {
            cue.deinit();
        }
        self.cues.deinit(self.allocator);
        if (self.title) |t| {
            self.allocator.free(t);
        }
    }

    /// Set title
    pub fn setTitle(self: *Self, title: []const u8) !void {
        if (self.title) |t| {
            self.allocator.free(t);
        }
        self.title = try self.allocator.dupe(u8, title);
    }

    /// Add a cue
    pub fn addCue(self: *Self, start_ms: u64, end_ms: u64, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        try self.cues.append(self.allocator, Cue{
            .id = null,
            .start_time = start_ms,
            .end_time = end_ms,
            .text = text_copy,
            .settings = .{},
            .allocator = self.allocator,
        });
    }

    /// Add a cue with identifier
    pub fn addCueWithId(self: *Self, id: []const u8, start_ms: u64, end_ms: u64, text: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, id);
        const text_copy = try self.allocator.dupe(u8, text);
        try self.cues.append(self.allocator, Cue{
            .id = id_copy,
            .start_time = start_ms,
            .end_time = end_ms,
            .text = text_copy,
            .settings = .{},
            .allocator = self.allocator,
        });
    }

    /// Generate VTT content
    pub fn generate(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        // Header
        try result.appendSlice(allocator, "WEBVTT");
        if (self.title) |t| {
            try result.appendSlice(allocator, " - ");
            try result.appendSlice(allocator, t);
        }
        try result.appendSlice(allocator, "\n\n");

        var time_buf: [24]u8 = undefined;

        for (self.cues.items) |cue| {
            // Optional cue ID
            if (cue.id) |id| {
                try result.appendSlice(allocator, id);
                try result.append(allocator, '\n');
            }

            // Timing
            const start_str = formatTimestamp(cue.start_time, &time_buf);
            try result.appendSlice(allocator, start_str);
            try result.appendSlice(allocator, " --> ");
            const end_str = formatTimestamp(cue.end_time, &time_buf);
            try result.appendSlice(allocator, end_str);
            try result.append(allocator, '\n');

            // Text
            try result.appendSlice(allocator, cue.text);
            try result.appendSlice(allocator, "\n\n");
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

const TimingResult = struct {
    start: u64,
    end: u64,
    settings: CueSettings,
};

fn parseTimingLine(line: []const u8) !TimingResult {
    // Format: HH:MM:SS.mmm --> HH:MM:SS.mmm [settings]
    var parts = std.mem.splitSequence(u8, line, " --> ");

    const start_str = parts.next() orelse return VideoError.InvalidHeader;
    const rest = parts.next() orelse return VideoError.InvalidHeader;

    // Split rest into end time and optional settings
    var rest_parts = std.mem.splitScalar(u8, rest, ' ');
    const end_str = rest_parts.next() orelse return VideoError.InvalidHeader;

    var settings: CueSettings = .{};

    // Parse optional settings
    while (rest_parts.next()) |setting| {
        const trimmed = std.mem.trim(u8, setting, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const key = trimmed[0..colon_pos];
            const value = trimmed[colon_pos + 1 ..];

            if (std.mem.eql(u8, key, "vertical")) {
                if (std.mem.eql(u8, value, "rl")) {
                    settings.vertical = .rl;
                } else if (std.mem.eql(u8, value, "lr")) {
                    settings.vertical = .lr;
                }
            } else if (std.mem.eql(u8, key, "align")) {
                if (std.mem.eql(u8, value, "start")) {
                    settings.align_value = .start;
                } else if (std.mem.eql(u8, value, "center")) {
                    settings.align_value = .center;
                } else if (std.mem.eql(u8, value, "end")) {
                    settings.align_value = .end;
                } else if (std.mem.eql(u8, value, "left")) {
                    settings.align_value = .left;
                } else if (std.mem.eql(u8, value, "right")) {
                    settings.align_value = .right;
                }
            } else if (std.mem.eql(u8, key, "position")) {
                // Parse percentage
                if (std.mem.endsWith(u8, value, "%")) {
                    settings.position = std.fmt.parseInt(u8, value[0 .. value.len - 1], 10) catch null;
                }
            } else if (std.mem.eql(u8, key, "size")) {
                if (std.mem.endsWith(u8, value, "%")) {
                    settings.size = std.fmt.parseInt(u8, value[0 .. value.len - 1], 10) catch null;
                }
            }
        }
    }

    return TimingResult{
        .start = try parseTimestamp(start_str),
        .end = try parseTimestamp(end_str),
        .settings = settings,
    };
}

fn parseTimestamp(ts: []const u8) !u64 {
    // Format: HH:MM:SS.mmm or MM:SS.mmm
    const trimmed = std.mem.trim(u8, ts, " \t");
    if (trimmed.len < 9) return VideoError.InvalidTimestamp;

    // Find the dot separating seconds from milliseconds
    const dot_pos = std.mem.lastIndexOf(u8, trimmed, ".") orelse return VideoError.InvalidTimestamp;
    if (dot_pos < 5) return VideoError.InvalidTimestamp;

    const millis = std.fmt.parseInt(u32, trimmed[dot_pos + 1 ..], 10) catch return VideoError.InvalidTimestamp;

    // Parse time before the dot
    const time_part = trimmed[0..dot_pos];
    var colon_count: usize = 0;
    for (time_part) |c| {
        if (c == ':') colon_count += 1;
    }

    var time_parts = std.mem.splitScalar(u8, time_part, ':');

    if (colon_count == 2) {
        // HH:MM:SS format
        const hours = std.fmt.parseInt(u32, time_parts.next() orelse return VideoError.InvalidTimestamp, 10) catch return VideoError.InvalidTimestamp;
        const minutes = std.fmt.parseInt(u32, time_parts.next() orelse return VideoError.InvalidTimestamp, 10) catch return VideoError.InvalidTimestamp;
        const seconds = std.fmt.parseInt(u32, time_parts.next() orelse return VideoError.InvalidTimestamp, 10) catch return VideoError.InvalidTimestamp;

        return @as(u64, hours) * 3600000 +
            @as(u64, minutes) * 60000 +
            @as(u64, seconds) * 1000 +
            @as(u64, millis);
    } else if (colon_count == 1) {
        // MM:SS format
        const minutes = std.fmt.parseInt(u32, time_parts.next() orelse return VideoError.InvalidTimestamp, 10) catch return VideoError.InvalidTimestamp;
        const seconds = std.fmt.parseInt(u32, time_parts.next() orelse return VideoError.InvalidTimestamp, 10) catch return VideoError.InvalidTimestamp;

        return @as(u64, minutes) * 60000 +
            @as(u64, seconds) * 1000 +
            @as(u64, millis);
    }

    return VideoError.InvalidTimestamp;
}

fn formatTimestamp(ms: u64, buf: []u8) []u8 {
    const hours = ms / 3600000;
    const minutes = (ms % 3600000) / 60000;
    const seconds = (ms % 60000) / 1000;
    const millis = ms % 1000;

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        hours,
        minutes,
        seconds,
        millis,
    }) catch buf[0..0];
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (lines) |line| {
        total_len += line.len + 1; // +1 for newline
    }
    if (total_len > 0) total_len -= 1; // No trailing newline

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (lines, 0..) |line, i| {
        @memcpy(result[pos..][0..line.len], line);
        pos += line.len;
        if (i < lines.len - 1) {
            result[pos] = '\n';
            pos += 1;
        }
    }

    return result;
}

/// Check if data starts with WebVTT signature
pub fn isVtt(data: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, data, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "WEBVTT");
}

// ============================================================================
// Tests
// ============================================================================

test "parseTimestamp VTT format" {
    const ts1 = try parseTimestamp("00:00:01.000");
    try std.testing.expectEqual(@as(u64, 1000), ts1);

    const ts2 = try parseTimestamp("01:30:45.500");
    try std.testing.expectEqual(@as(u64, 5445500), ts2);

    // Short format (MM:SS.mmm)
    const ts3 = try parseTimestamp("01:30.500");
    try std.testing.expectEqual(@as(u64, 90500), ts3);
}

test "formatTimestamp VTT format" {
    var buf: [24]u8 = undefined;

    const ts1 = formatTimestamp(1000, &buf);
    try std.testing.expectEqualStrings("00:00:01.000", ts1);

    const ts2 = formatTimestamp(5445500, &buf);
    try std.testing.expectEqualStrings("01:30:45.500", ts2);
}

test "VttParser basic" {
    const allocator = std.testing.allocator;

    const vtt_content =
        \\WEBVTT
        \\
        \\00:00:01.000 --> 00:00:04.000
        \\Hello, world!
        \\
        \\00:00:05.000 --> 00:00:08.000
        \\This is a test.
        \\
    ;

    var parser = VttParser.init(allocator);
    defer parser.deinit();

    try parser.parse(vtt_content);

    try std.testing.expectEqual(@as(usize, 2), parser.count());
    try std.testing.expectEqualStrings("Hello, world!", parser.cues.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), parser.cues.items[0].start_time);
}

test "VttParser with cue IDs" {
    const allocator = std.testing.allocator;

    const vtt_content =
        \\WEBVTT - Test Title
        \\
        \\cue1
        \\00:00:01.000 --> 00:00:04.000
        \\First cue
        \\
        \\cue2
        \\00:00:05.000 --> 00:00:08.000
        \\Second cue
        \\
    ;

    var parser = VttParser.init(allocator);
    defer parser.deinit();

    try parser.parse(vtt_content);

    try std.testing.expectEqual(@as(usize, 2), parser.count());
    try std.testing.expectEqualStrings("cue1", parser.cues.items[0].id.?);
    try std.testing.expectEqualStrings("cue2", parser.cues.items[1].id.?);
    try std.testing.expectEqualStrings("Test Title", parser.title.?);
}

test "VttParser getCueAt" {
    const allocator = std.testing.allocator;

    const vtt_content =
        \\WEBVTT
        \\
        \\00:00:01.000 --> 00:00:04.000
        \\First cue
        \\
        \\00:00:05.000 --> 00:00:08.000
        \\Second cue
        \\
    ;

    var parser = VttParser.init(allocator);
    defer parser.deinit();

    try parser.parse(vtt_content);

    const cue1 = parser.getCueAt(2000);
    try std.testing.expect(cue1 != null);
    try std.testing.expectEqualStrings("First cue", cue1.?.text);

    const cue2 = parser.getCueAt(6000);
    try std.testing.expect(cue2 != null);
    try std.testing.expectEqualStrings("Second cue", cue2.?.text);

    const no_cue = parser.getCueAt(4500);
    try std.testing.expect(no_cue == null);
}

test "VttWriter" {
    const allocator = std.testing.allocator;

    var writer = VttWriter.init(allocator);
    defer writer.deinit();

    try writer.setTitle("My Subtitles");
    try writer.addCue(1000, 4000, "Hello");
    try writer.addCueWithId("second", 5000, 8000, "World");

    const output = try writer.generate(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "WEBVTT - My Subtitles") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "00:00:01.000 --> 00:00:04.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "second") != null);
}

test "isVtt" {
    try std.testing.expect(isVtt("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello"));
    try std.testing.expect(isVtt("  \nWEBVTT - Title\n"));
    try std.testing.expect(!isVtt("1\n00:00:01,000 --> 00:00:04,000\nHello"));
}
