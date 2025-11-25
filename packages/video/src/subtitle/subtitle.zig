// Home Video Library - Subtitle Support
// Subtitle parsing, timing, and format conversion

const std = @import("std");
const types = @import("../core/types.zig");

pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;

// ============================================================================
// Subtitle Entry
// ============================================================================

pub const SubtitleEntry = struct {
    index: u32,
    start: Timestamp,
    end: Timestamp,
    text: []const u8,
    style: ?SubtitleStyle = null,
    position: ?SubtitlePosition = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        index: u32,
        start: Timestamp,
        end: Timestamp,
        text: []const u8,
    ) !Self {
        return .{
            .index = index,
            .start = start,
            .end = end,
            .text = try allocator.dupe(u8, text),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.text);
        if (self.style) |*style| {
            style.deinit();
        }
    }

    pub fn getDuration(self: *const Self) Duration {
        return Duration.fromMicroseconds(
            self.end.toMicroseconds() - self.start.toMicroseconds(),
        );
    }

    pub fn setText(self: *Self, text: []const u8) !void {
        self.allocator.free(self.text);
        self.text = try self.allocator.dupe(u8, text);
    }

    pub fn adjustTiming(self: *Self, offset: i64) void {
        const offset_us = offset;
        self.start = Timestamp.fromMicroseconds(@intCast(
            @as(i64, @intCast(self.start.toMicroseconds())) + offset_us
        ));
        self.end = Timestamp.fromMicroseconds(@intCast(
            @as(i64, @intCast(self.end.toMicroseconds())) + offset_us
        ));
    }

    pub fn scale(self: *Self, factor: f64) void {
        const start_us = @as(i64, @intCast(self.start.toMicroseconds()));
        const end_us = @as(i64, @intCast(self.end.toMicroseconds()));

        self.start = Timestamp.fromMicroseconds(@intCast(@as(i64, @intFromFloat(@as(f64, @floatFromInt(start_us)) * factor))));
        self.end = Timestamp.fromMicroseconds(@intCast(@as(i64, @intFromFloat(@as(f64, @floatFromInt(end_us)) * factor))));
    }
};

// ============================================================================
// Subtitle Style
// ============================================================================

pub const SubtitleStyle = struct {
    font_name: ?[]const u8 = null,
    font_size: u16 = 48,
    primary_color: Color = Color.white(),
    secondary_color: Color = Color.white(),
    outline_color: Color = Color.black(),
    back_color: Color = Color.black(),
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikeout: bool = false,
    scale_x: f32 = 100.0,
    scale_y: f32 = 100.0,
    spacing: f32 = 0.0,
    angle: f32 = 0.0,
    border_style: BorderStyle = .outline_with_shadow,
    outline: f32 = 2.0,
    shadow: f32 = 2.0,
    alignment: Alignment = .bottom_center,
    margin_left: u16 = 10,
    margin_right: u16 = 10,
    margin_vertical: u16 = 10,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const BorderStyle = enum(u8) {
        outline_with_shadow = 1,
        opaque_box = 3,
    };

    pub const Alignment = enum(u8) {
        bottom_left = 1,
        bottom_center = 2,
        bottom_right = 3,
        middle_left = 4,
        middle_center = 5,
        middle_right = 6,
        top_left = 7,
        top_center = 8,
        top_right = 9,
    };

    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,

        pub fn white() Color {
            return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        pub fn black() Color {
            return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        }

        pub fn toHex(self: *const Color) u32 {
            return (@as(u32, self.a) << 24) |
                (@as(u32, self.b) << 16) |
                (@as(u32, self.g) << 8) |
                @as(u32, self.r);
        }

        pub fn fromHex(hex: u32) Color {
            return .{
                .r = @truncate(hex & 0xFF),
                .g = @truncate((hex >> 8) & 0xFF),
                .b = @truncate((hex >> 16) & 0xFF),
                .a = @truncate((hex >> 24) & 0xFF),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.font_name) |name| {
            self.allocator.free(name);
        }
    }

    pub fn setFontName(self: *Self, name: []const u8) !void {
        if (self.font_name) |old_name| {
            self.allocator.free(old_name);
        }
        self.font_name = try self.allocator.dupe(u8, name);
    }
};

// ============================================================================
// Subtitle Position
// ============================================================================

pub const SubtitlePosition = struct {
    x: i32 = 0,
    y: i32 = 0,
    layer: u8 = 0,
};

// ============================================================================
// Subtitle Track
// ============================================================================

pub const SubtitleTrack = struct {
    entries: std.ArrayList(SubtitleEntry),
    default_style: SubtitleStyle,
    language: ?[]const u8 = null,
    title: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entries = std.ArrayList(SubtitleEntry).init(allocator),
            .default_style = SubtitleStyle.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit();
        self.default_style.deinit();

        if (self.language) |lang| {
            self.allocator.free(lang);
        }
        if (self.title) |title| {
            self.allocator.free(title);
        }
    }

    pub fn addEntry(self: *Self, entry: SubtitleEntry) !void {
        try self.entries.append(entry);
    }

    pub fn getEntryAt(self: *const Self, timestamp: Timestamp) ?*const SubtitleEntry {
        for (self.entries.items) |*entry| {
            if (timestamp.compare(entry.start) != .lt and
                timestamp.compare(entry.end) == .lt) {
                return entry;
            }
        }
        return null;
    }

    pub fn sortByTime(self: *Self) void {
        std.mem.sort(SubtitleEntry, self.entries.items, {}, compareEntries);
    }

    fn compareEntries(_: void, a: SubtitleEntry, b: SubtitleEntry) bool {
        return a.start.compare(b.start) == .lt;
    }

    pub fn adjustAllTiming(self: *Self, offset: i64) void {
        for (self.entries.items) |*entry| {
            entry.adjustTiming(offset);
        }
    }

    pub fn scaleAllTiming(self: *Self, factor: f64) void {
        for (self.entries.items) |*entry| {
            entry.scale(factor);
        }
    }

    pub fn setLanguage(self: *Self, lang: []const u8) !void {
        if (self.language) |old| {
            self.allocator.free(old);
        }
        self.language = try self.allocator.dupe(u8, lang);
    }

    pub fn setTitle(self: *Self, title: []const u8) !void {
        if (self.title) |old| {
            self.allocator.free(old);
        }
        self.title = try self.allocator.dupe(u8, title);
    }

    pub fn getDuration(self: *const Self) Duration {
        if (self.entries.items.len == 0) {
            return Duration.fromMicroseconds(0);
        }
        const last = self.entries.items[self.entries.items.len - 1];
        return Duration.fromMicroseconds(last.end.toMicroseconds());
    }

    pub fn getEntryCount(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Merge overlapping entries
    pub fn mergeOverlapping(self: *Self) !void {
        self.sortByTime();

        var i: usize = 0;
        while (i < self.entries.items.len - 1) {
            var current = &self.entries.items[i];
            const next = &self.entries.items[i + 1];

            if (current.end.compare(next.start) != .lt) {
                // Overlapping, merge text
                const merged_text = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}\n{s}",
                    .{ current.text, next.text },
                );
                self.allocator.free(current.text);
                current.text = merged_text;

                // Extend end time
                if (next.end.compare(current.end) == .gt) {
                    current.end = next.end;
                }

                // Remove next
                var removed = self.entries.orderedRemove(i + 1);
                self.allocator.free(removed.text);
            } else {
                i += 1;
            }
        }
    }

    /// Split entries longer than duration
    pub fn splitLongEntries(self: *Self, max_duration: Duration) !void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            const duration = entry.getDuration();

            if (duration.toMicroseconds() > max_duration.toMicroseconds()) {
                // Split the entry
                const mid_time = Timestamp.fromMicroseconds(
                    entry.start.toMicroseconds() + max_duration.toMicroseconds(),
                );

                const new_entry = try SubtitleEntry.init(
                    self.allocator,
                    entry.index,
                    mid_time,
                    entry.end,
                    entry.text,
                );

                entry.end = mid_time;

                try self.entries.insert(i + 1, new_entry);
                i += 1; // Skip the newly inserted entry
            }

            i += 1;
        }
    }
};

// ============================================================================
// Timing Utilities
// ============================================================================

pub const TimingUtils = struct {
    /// Synchronize subtitles to match video
    pub fn synchronize(
        track: *SubtitleTrack,
        ref_time: Timestamp,
        actual_time: Timestamp,
    ) void {
        const offset = @as(i64, @intCast(actual_time.toMicroseconds())) -
            @as(i64, @intCast(ref_time.toMicroseconds()));
        track.adjustAllTiming(offset);
    }

    /// Linear timing correction between two points
    pub fn linearCorrection(
        track: *SubtitleTrack,
        ref1: Timestamp,
        actual1: Timestamp,
        ref2: Timestamp,
        actual2: Timestamp,
    ) void {
        // Calculate scaling factor
        const ref_duration = @as(f64, @floatFromInt(
            ref2.toMicroseconds() - ref1.toMicroseconds(),
        ));
        const actual_duration = @as(f64, @floatFromInt(
            actual2.toMicroseconds() - actual1.toMicroseconds(),
        ));

        const scale_factor = actual_duration / ref_duration;

        // Apply offset to align first point
        const offset = @as(i64, @intCast(actual1.toMicroseconds())) -
            @as(i64, @intCast(ref1.toMicroseconds()));

        for (track.entries.items) |*entry| {
            // Apply scaling
            entry.scale(scale_factor);
            // Then apply offset
            entry.adjustTiming(offset);
        }
    }

    /// Remove entries outside time range
    pub fn trimToRange(
        track: *SubtitleTrack,
        start: Timestamp,
        end: Timestamp,
    ) void {
        var i: usize = 0;
        while (i < track.entries.items.len) {
            const entry = &track.entries.items[i];

            if (entry.end.compare(start) == .lt or
                entry.start.compare(end) != .lt) {
                var removed = track.entries.orderedRemove(i);
                removed.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Shift all timings by offset
    pub fn shift(track: *SubtitleTrack, offset: i64) void {
        track.adjustAllTiming(offset);
    }

    /// Scale all timings by factor
    pub fn scale(track: *SubtitleTrack, factor: f64) void {
        track.scaleAllTiming(factor);
    }

    /// Fix frame rate mismatch
    pub fn fixFrameRate(
        track: *SubtitleTrack,
        original_fps: f64,
        target_fps: f64,
    ) void {
        const factor = target_fps / original_fps;
        track.scaleAllTiming(factor);
    }
};

// ============================================================================
// Text Processing
// ============================================================================

pub const TextProcessor = struct {
    /// Strip HTML tags
    pub fn stripHTML(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var in_tag = false;
        for (text) |c| {
            if (c == '<') {
                in_tag = true;
            } else if (c == '>') {
                in_tag = false;
            } else if (!in_tag) {
                try result.append(c);
            }
        }

        return result.toOwnedSlice();
    }

    /// Convert line breaks
    pub fn normalizeLineBreaks(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]u8 {
        // Replace \r\n and \r with \n
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\r') {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    try result.append('\n');
                    i += 2;
                } else {
                    try result.append('\n');
                    i += 1;
                }
            } else {
                try result.append(text[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// Remove formatting codes
    pub fn stripFormatting(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]u8 {
        // Remove {tags} used in SSA/ASS
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var in_brace = false;
        for (text) |c| {
            if (c == '{') {
                in_brace = true;
            } else if (c == '}') {
                in_brace = false;
            } else if (!in_brace) {
                try result.append(c);
            }
        }

        return result.toOwnedSlice();
    }

    /// Word wrap text to fit width
    pub fn wordWrap(
        allocator: std.mem.Allocator,
        text: []const u8,
        max_chars: usize,
    ) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var words = std.mem.tokenizeScalar(u8, text, ' ');
        var line_len: usize = 0;

        while (words.next()) |word| {
            if (line_len + word.len + 1 > max_chars and line_len > 0) {
                try result.append('\n');
                line_len = 0;
            }

            if (line_len > 0) {
                try result.append(' ');
                line_len += 1;
            }

            try result.appendSlice(word);
            line_len += word.len;
        }

        return result.toOwnedSlice();
    }
};
