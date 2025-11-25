// Home Video Library - Subtitle Format Conversion
// Parse and convert between subtitle formats (SRT, ASS, WebVTT, etc.)

const std = @import("std");
const subtitle = @import("subtitle.zig");

pub const SubtitleTrack = subtitle.SubtitleTrack;
pub const SubtitleEntry = subtitle.SubtitleEntry;
pub const SubtitleStyle = subtitle.SubtitleStyle;
pub const Timestamp = subtitle.Timestamp;
pub const Duration = subtitle.Duration;

// ============================================================================
// Subtitle Format Detection
// ============================================================================

pub const SubtitleFormat = enum {
    srt, // SubRip
    ass, // Advanced SubStation Alpha
    ssa, // SubStation Alpha
    vtt, // WebVTT
    sub, // MicroDVD
    sbv, // YouTube
    unknown,

    pub fn detect(data: []const u8) SubtitleFormat {
        if (std.mem.startsWith(u8, data, "WEBVTT")) {
            return .vtt;
        }
        if (std.mem.indexOf(u8, data, "[Script Info]") != null) {
            if (std.mem.indexOf(u8, data, "ScriptType: v4.00+") != null) {
                return .ass;
            }
            return .ssa;
        }
        if (std.mem.indexOf(u8, data, "0:00:00.000,0:00:00.000") != null) {
            return .sbv;
        }

        // Check for SRT format (numeric index followed by timestamp)
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        if (lines.next()) |first_line| {
            // Check if first line is a number
            const trimmed = std.mem.trim(u8, first_line, &std.ascii.whitespace);
            if (std.fmt.parseInt(u32, trimmed, 10)) |_| {
                if (lines.next()) |second_line| {
                    if (std.mem.indexOf(u8, second_line, "-->") != null) {
                        return .srt;
                    }
                }
            } else |_| {}

            // Check for MicroDVD (frame-based)
            if (std.mem.startsWith(u8, trimmed, "{") and
                std.mem.indexOf(u8, trimmed, "}{") != null) {
                return .sub;
            }
        }

        return .unknown;
    }

    pub fn getExtension(self: SubtitleFormat) []const u8 {
        return switch (self) {
            .srt => ".srt",
            .ass => ".ass",
            .ssa => ".ssa",
            .vtt => ".vtt",
            .sub => ".sub",
            .sbv => ".sbv",
            .unknown => ".txt",
        };
    }
};

// ============================================================================
// SRT Parser
// ============================================================================

pub const SRTParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *Self, data: []const u8) !SubtitleTrack {
        var track = SubtitleTrack.init(self.allocator);
        errdefer track.deinit();

        var lines = std.mem.split(u8, data, "\n");
        var current_index: ?u32 = null;
        var current_start: ?Timestamp = null;
        var current_end: ?Timestamp = null;
        var current_text = std.ArrayList(u8).init(self.allocator);
        defer current_text.deinit();

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (trimmed.len == 0) {
                // Empty line marks end of entry
                if (current_index != null and current_start != null and current_end != null) {
                    const entry = try SubtitleEntry.init(
                        self.allocator,
                        current_index.?,
                        current_start.?,
                        current_end.?,
                        current_text.items,
                    );
                    try track.addEntry(entry);

                    current_index = null;
                    current_start = null;
                    current_end = null;
                    current_text.clearRetainingCapacity();
                }
                continue;
            }

            if (current_index == null) {
                // Try to parse as index
                if (std.fmt.parseInt(u32, trimmed, 10)) |index| {
                    current_index = index;
                    continue;
                } else |_| {
                    // Not a valid index, skip
                    continue;
                }
            } else if (current_start == null) {
                // Parse timestamp line: 00:00:01,000 --> 00:00:04,000
                if (std.mem.indexOf(u8, trimmed, "-->")) |arrow_pos| {
                    const start_str = std.mem.trim(u8, trimmed[0..arrow_pos], &std.ascii.whitespace);
                    const end_str = std.mem.trim(u8, trimmed[arrow_pos + 3 ..], &std.ascii.whitespace);

                    current_start = try self.parseSRTTimestamp(start_str);
                    current_end = try self.parseSRTTimestamp(end_str);
                }
            } else {
                // Text content
                if (current_text.items.len > 0) {
                    try current_text.append('\n');
                }
                try current_text.appendSlice(trimmed);
            }
        }

        // Handle last entry if no trailing newline
        if (current_index != null and current_start != null and current_end != null and
            current_text.items.len > 0) {
            const entry = try SubtitleEntry.init(
                self.allocator,
                current_index.?,
                current_start.?,
                current_end.?,
                current_text.items,
            );
            try track.addEntry(entry);
        }

        return track;
    }

    fn parseSRTTimestamp(self: *Self, str: []const u8) !Timestamp {
        _ = self;

        // Format: HH:MM:SS,mmm
        if (str.len < 12) return error.InvalidTimestamp;

        const hours = try std.fmt.parseInt(u32, str[0..2], 10);
        const minutes = try std.fmt.parseInt(u32, str[3..5], 10);
        const seconds = try std.fmt.parseInt(u32, str[6..8], 10);
        const milliseconds = try std.fmt.parseInt(u32, str[9..12], 10);

        const total_us = @as(u64, hours) * 3600 * 1_000_000 +
            @as(u64, minutes) * 60 * 1_000_000 +
            @as(u64, seconds) * 1_000_000 +
            @as(u64, milliseconds) * 1000;

        return Timestamp.fromMicroseconds(total_us);
    }
};

// ============================================================================
// SRT Writer
// ============================================================================

pub const SRTWriter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *Self, track: *const SubtitleTrack, writer: anytype) !void {
        for (track.entries.items, 1..) |*entry, index| {
            // Index
            try writer.print("{d}\n", .{index});

            // Timestamps
            const start = try self.formatSRTTimestamp(entry.start);
            const end = try self.formatSRTTimestamp(entry.end);
            try writer.print("{s} --> {s}\n", .{ start, end });

            // Text
            try writer.print("{s}\n\n", .{entry.text});
        }
    }

    fn formatSRTTimestamp(self: *Self, ts: Timestamp) ![]const u8 {
        const us = ts.toMicroseconds();
        const hours = us / 3_600_000_000;
        const minutes = (us / 60_000_000) % 60;
        const seconds = (us / 1_000_000) % 60;
        const milliseconds = (us / 1000) % 1000;

        return try std.fmt.allocPrint(
            self.allocator,
            "{d:0>2}:{d:0>2}:{d:0>2},{d:0>3}",
            .{ hours, minutes, seconds, milliseconds },
        );
    }
};

// ============================================================================
// WebVTT Parser
// ============================================================================

pub const WebVTTParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *Self, data: []const u8) !SubtitleTrack {
        var track = SubtitleTrack.init(self.allocator);
        errdefer track.deinit();

        var lines = std.mem.split(u8, data, "\n");

        // Skip WEBVTT header
        if (lines.next()) |header| {
            if (!std.mem.startsWith(u8, header, "WEBVTT")) {
                return error.InvalidWebVTT;
            }
        }

        var index: u32 = 1;
        var current_start: ?Timestamp = null;
        var current_end: ?Timestamp = null;
        var current_text = std.ArrayList(u8).init(self.allocator);
        defer current_text.deinit();

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (trimmed.len == 0) {
                // Empty line marks end of cue
                if (current_start != null and current_end != null and current_text.items.len > 0) {
                    const entry = try SubtitleEntry.init(
                        self.allocator,
                        index,
                        current_start.?,
                        current_end.?,
                        current_text.items,
                    );
                    try track.addEntry(entry);
                    index += 1;

                    current_start = null;
                    current_end = null;
                    current_text.clearRetainingCapacity();
                }
                continue;
            }

            // Skip NOTE and STYLE blocks
            if (std.mem.startsWith(u8, trimmed, "NOTE") or
                std.mem.startsWith(u8, trimmed, "STYLE")) {
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "-->")) |arrow_pos| {
                // Timestamp line
                const start_str = std.mem.trim(u8, trimmed[0..arrow_pos], &std.ascii.whitespace);
                const end_part = std.mem.trim(u8, trimmed[arrow_pos + 3 ..], &std.ascii.whitespace);

                // End part may contain settings, extract just the timestamp
                var end_str = end_part;
                if (std.mem.indexOfScalar(u8, end_part, ' ')) |space_pos| {
                    end_str = end_part[0..space_pos];
                }

                current_start = try self.parseWebVTTTimestamp(start_str);
                current_end = try self.parseWebVTTTimestamp(end_str);
            } else if (current_start != null) {
                // Text content
                if (current_text.items.len > 0) {
                    try current_text.append('\n');
                }
                try current_text.appendSlice(trimmed);
            }
        }

        // Handle last cue
        if (current_start != null and current_end != null and current_text.items.len > 0) {
            const entry = try SubtitleEntry.init(
                self.allocator,
                index,
                current_start.?,
                current_end.?,
                current_text.items,
            );
            try track.addEntry(entry);
        }

        return track;
    }

    fn parseWebVTTTimestamp(self: *Self, str: []const u8) !Timestamp {
        _ = self;

        // Format: HH:MM:SS.mmm or MM:SS.mmm
        var hours: u32 = 0;
        var minutes: u32 = 0;
        var seconds: u32 = 0;
        var milliseconds: u32 = 0;

        var parts = std.mem.split(u8, str, ":");
        const p1 = parts.next() orelse return error.InvalidTimestamp;
        const p2 = parts.next() orelse return error.InvalidTimestamp;
        const p3_opt = parts.next();

        if (p3_opt) |p3| {
            // HH:MM:SS.mmm
            hours = try std.fmt.parseInt(u32, p1, 10);
            minutes = try std.fmt.parseInt(u32, p2, 10);

            var sec_parts = std.mem.split(u8, p3, ".");
            const sec_str = sec_parts.next() orelse return error.InvalidTimestamp;
            const ms_str = sec_parts.next() orelse return error.InvalidTimestamp;

            seconds = try std.fmt.parseInt(u32, sec_str, 10);
            milliseconds = try std.fmt.parseInt(u32, ms_str, 10);
        } else {
            // MM:SS.mmm
            minutes = try std.fmt.parseInt(u32, p1, 10);

            var sec_parts = std.mem.split(u8, p2, ".");
            const sec_str = sec_parts.next() orelse return error.InvalidTimestamp;
            const ms_str = sec_parts.next() orelse return error.InvalidTimestamp;

            seconds = try std.fmt.parseInt(u32, sec_str, 10);
            milliseconds = try std.fmt.parseInt(u32, ms_str, 10);
        }

        const total_us = @as(u64, hours) * 3600 * 1_000_000 +
            @as(u64, minutes) * 60 * 1_000_000 +
            @as(u64, seconds) * 1_000_000 +
            @as(u64, milliseconds) * 1000;

        return Timestamp.fromMicroseconds(total_us);
    }
};

// ============================================================================
// WebVTT Writer
// ============================================================================

pub const WebVTTWriter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *Self, track: *const SubtitleTrack, writer: anytype) !void {
        // Write header
        try writer.writeAll("WEBVTT\n\n");

        for (track.entries.items) |*entry| {
            // Timestamps
            const start = try self.formatWebVTTTimestamp(entry.start);
            defer self.allocator.free(start);
            const end = try self.formatWebVTTTimestamp(entry.end);
            defer self.allocator.free(end);

            try writer.print("{s} --> {s}\n", .{ start, end });

            // Text
            try writer.print("{s}\n\n", .{entry.text});
        }
    }

    fn formatWebVTTTimestamp(self: *Self, ts: Timestamp) ![]const u8 {
        const us = ts.toMicroseconds();
        const hours = us / 3_600_000_000;
        const minutes = (us / 60_000_000) % 60;
        const seconds = (us / 1_000_000) % 60;
        const milliseconds = (us / 1000) % 1000;

        return try std.fmt.allocPrint(
            self.allocator,
            "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
            .{ hours, minutes, seconds, milliseconds },
        );
    }
};

// ============================================================================
// Format Converter
// ============================================================================

pub const SubtitleConverter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn convert(
        self: *Self,
        input_data: []const u8,
        input_format: SubtitleFormat,
        output_format: SubtitleFormat,
    ) ![]u8 {
        // Parse input
        var track = switch (input_format) {
            .srt => blk: {
                var parser = SRTParser.init(self.allocator);
                break :blk try parser.parse(input_data);
            },
            .vtt => blk: {
                var parser = WebVTTParser.init(self.allocator);
                break :blk try parser.parse(input_data);
            },
            else => return error.UnsupportedFormat,
        };
        defer track.deinit();

        // Write output
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const writer = output.writer();

        switch (output_format) {
            .srt => {
                var srt_writer = SRTWriter.init(self.allocator);
                try srt_writer.write(&track, writer);
            },
            .vtt => {
                var vtt_writer = WebVTTWriter.init(self.allocator);
                try vtt_writer.write(&track, writer);
            },
            else => return error.UnsupportedFormat,
        }

        return output.toOwnedSlice();
    }

    pub fn detectAndConvert(
        self: *Self,
        input_data: []const u8,
        output_format: SubtitleFormat,
    ) ![]u8 {
        const detected = SubtitleFormat.detect(input_data);
        if (detected == .unknown) {
            return error.UnknownFormat;
        }
        return try self.convert(input_data, detected, output_format);
    }
};
