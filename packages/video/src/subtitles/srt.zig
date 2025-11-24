// Home Video Library - SRT Subtitle Parser
// SubRip subtitle format (.srt)

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// SRT Cue
// ============================================================================

pub const Cue = struct {
    index: u32,
    start_time: u64, // milliseconds
    end_time: u64, // milliseconds
    text: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cue) void {
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

    /// Format start time as string (HH:MM:SS,mmm)
    pub fn formatStartTime(self: *const Cue, buf: []u8) []u8 {
        return formatTimestamp(self.start_time, buf);
    }

    /// Format end time as string (HH:MM:SS,mmm)
    pub fn formatEndTime(self: *const Cue, buf: []u8) []u8 {
        return formatTimestamp(self.end_time, buf);
    }
};

// ============================================================================
// SRT Parser
// ============================================================================

pub const SrtParser = struct {
    cues: std.ArrayListUnmanaged(Cue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cues = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cues.items) |*cue| {
            cue.deinit();
        }
        self.cues.deinit(self.allocator);
    }

    /// Parse SRT content from string
    pub fn parse(self: *Self, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var state: enum { index, timing, text } = .index;
        var current_index: u32 = 0;
        var current_start: u64 = 0;
        var current_end: u64 = 0;
        var text_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer text_lines.deinit(self.allocator);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            switch (state) {
                .index => {
                    if (trimmed.len == 0) continue;
                    current_index = std.fmt.parseInt(u32, trimmed, 10) catch continue;
                    state = .timing;
                },
                .timing => {
                    if (trimmed.len == 0) {
                        state = .index;
                        continue;
                    }
                    const timing = parseTimingLine(trimmed) catch {
                        state = .index;
                        continue;
                    };
                    current_start = timing.start;
                    current_end = timing.end;
                    state = .text;
                },
                .text => {
                    if (trimmed.len == 0) {
                        // End of cue
                        if (text_lines.items.len > 0) {
                            const text = try joinLines(self.allocator, text_lines.items);
                            try self.cues.append(self.allocator, Cue{
                                .index = current_index,
                                .start_time = current_start,
                                .end_time = current_end,
                                .text = text,
                                .allocator = self.allocator,
                            });
                        }
                        text_lines.clearRetainingCapacity();
                        state = .index;
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
                .index = current_index,
                .start_time = current_start,
                .end_time = current_end,
                .text = text,
                .allocator = self.allocator,
            });
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
// SRT Writer
// ============================================================================

pub const SrtWriter = struct {
    cues: std.ArrayListUnmanaged(Cue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cues = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cues.items) |*cue| {
            cue.deinit();
        }
        self.cues.deinit(self.allocator);
    }

    /// Add a cue
    pub fn addCue(self: *Self, start_ms: u64, end_ms: u64, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        try self.cues.append(self.allocator, Cue{
            .index = @intCast(self.cues.items.len + 1),
            .start_time = start_ms,
            .end_time = end_ms,
            .text = text_copy,
            .allocator = self.allocator,
        });
    }

    /// Generate SRT content
    pub fn generate(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var time_buf: [24]u8 = undefined;

        for (self.cues.items, 0..) |cue, i| {
            // Index
            const index_str = try std.fmt.allocPrint(allocator, "{d}\n", .{i + 1});
            defer allocator.free(index_str);
            try result.appendSlice(allocator, index_str);

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
};

fn parseTimingLine(line: []const u8) !TimingResult {
    // Format: HH:MM:SS,mmm --> HH:MM:SS,mmm
    var parts = std.mem.splitSequence(u8, line, " --> ");

    const start_str = parts.next() orelse return VideoError.InvalidHeader;
    const end_str = parts.next() orelse return VideoError.InvalidHeader;

    return TimingResult{
        .start = try parseTimestamp(start_str),
        .end = try parseTimestamp(end_str),
    };
}

fn parseTimestamp(ts: []const u8) !u64 {
    // Format: HH:MM:SS,mmm or HH:MM:SS.mmm
    const trimmed = std.mem.trim(u8, ts, " \t");
    if (trimmed.len < 12) return VideoError.InvalidTimestamp;

    const hours = std.fmt.parseInt(u32, trimmed[0..2], 10) catch return VideoError.InvalidTimestamp;
    const minutes = std.fmt.parseInt(u32, trimmed[3..5], 10) catch return VideoError.InvalidTimestamp;
    const seconds = std.fmt.parseInt(u32, trimmed[6..8], 10) catch return VideoError.InvalidTimestamp;
    const millis = std.fmt.parseInt(u32, trimmed[9..12], 10) catch return VideoError.InvalidTimestamp;

    return @as(u64, hours) * 3600000 +
        @as(u64, minutes) * 60000 +
        @as(u64, seconds) * 1000 +
        @as(u64, millis);
}

fn formatTimestamp(ms: u64, buf: []u8) []u8 {
    const hours = ms / 3600000;
    const minutes = (ms % 3600000) / 60000;
    const seconds = (ms % 60000) / 1000;
    const millis = ms % 1000;

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2},{d:0>3}", .{
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

// ============================================================================
// Tests
// ============================================================================

test "parseTimestamp" {
    const ts1 = try parseTimestamp("00:00:01,000");
    try std.testing.expectEqual(@as(u64, 1000), ts1);

    const ts2 = try parseTimestamp("01:30:45,500");
    try std.testing.expectEqual(@as(u64, 5445500), ts2);

    const ts3 = try parseTimestamp("00:01:00,000");
    try std.testing.expectEqual(@as(u64, 60000), ts3);
}

test "formatTimestamp" {
    var buf: [24]u8 = undefined;

    const ts1 = formatTimestamp(1000, &buf);
    try std.testing.expectEqualStrings("00:00:01,000", ts1);

    const ts2 = formatTimestamp(5445500, &buf);
    try std.testing.expectEqualStrings("01:30:45,500", ts2);
}

test "Cue methods" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "Test");
    defer allocator.free(text);

    const cue = Cue{
        .index = 1,
        .start_time = 1000,
        .end_time = 5000,
        .text = text,
        .allocator = allocator,
    };

    try std.testing.expectEqual(@as(u64, 4000), cue.getDuration());
    try std.testing.expect(cue.isActiveAt(2000));
    try std.testing.expect(!cue.isActiveAt(0));
    try std.testing.expect(!cue.isActiveAt(5000));
}

test "SrtParser basic" {
    const allocator = std.testing.allocator;

    const srt_content =
        \\1
        \\00:00:01,000 --> 00:00:04,000
        \\Hello, world!
        \\
        \\2
        \\00:00:05,000 --> 00:00:08,000
        \\This is a test.
        \\
    ;

    var parser = SrtParser.init(allocator);
    defer parser.deinit();

    try parser.parse(srt_content);

    try std.testing.expectEqual(@as(usize, 2), parser.count());
    try std.testing.expectEqualStrings("Hello, world!", parser.cues.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), parser.cues.items[0].start_time);
}

test "SrtParser getCueAt" {
    const allocator = std.testing.allocator;

    const srt_content =
        \\1
        \\00:00:01,000 --> 00:00:04,000
        \\First cue
        \\
        \\2
        \\00:00:05,000 --> 00:00:08,000
        \\Second cue
        \\
    ;

    var parser = SrtParser.init(allocator);
    defer parser.deinit();

    try parser.parse(srt_content);

    const cue1 = parser.getCueAt(2000);
    try std.testing.expect(cue1 != null);
    try std.testing.expectEqualStrings("First cue", cue1.?.text);

    const cue2 = parser.getCueAt(6000);
    try std.testing.expect(cue2 != null);
    try std.testing.expectEqualStrings("Second cue", cue2.?.text);

    const no_cue = parser.getCueAt(4500);
    try std.testing.expect(no_cue == null);
}

test "SrtWriter" {
    const allocator = std.testing.allocator;

    var writer = SrtWriter.init(allocator);
    defer writer.deinit();

    try writer.addCue(1000, 4000, "Hello");
    try writer.addCue(5000, 8000, "World");

    const output = try writer.generate(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "00:00:01,000 --> 00:00:04,000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}
