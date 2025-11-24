// Home Video Library - SSA/ASS Subtitle Parser
// SubStation Alpha / Advanced SubStation Alpha subtitle format

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// ASS Style
// ============================================================================

pub const Style = struct {
    name: []const u8,
    fontname: []const u8,
    fontsize: f32,
    primary_color: u32, // AABBGGRR format
    secondary_color: u32,
    outline_color: u32,
    back_color: u32,
    bold: bool,
    italic: bool,
    underline: bool,
    strikeout: bool,
    scale_x: f32,
    scale_y: f32,
    spacing: f32,
    angle: f32,
    border_style: u8,
    outline: f32,
    shadow: f32,
    alignment: Alignment,
    margin_l: i32,
    margin_r: i32,
    margin_v: i32,
    encoding: u8,
    allocator: std.mem.Allocator,

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

    pub fn deinit(self: *Style) void {
        self.allocator.free(self.name);
        self.allocator.free(self.fontname);
    }

    pub fn default(allocator: std.mem.Allocator) !Style {
        return Style{
            .name = try allocator.dupe(u8, "Default"),
            .fontname = try allocator.dupe(u8, "Arial"),
            .fontsize = 20,
            .primary_color = 0x00FFFFFF,
            .secondary_color = 0x000000FF,
            .outline_color = 0x00000000,
            .back_color = 0x00000000,
            .bold = false,
            .italic = false,
            .underline = false,
            .strikeout = false,
            .scale_x = 100,
            .scale_y = 100,
            .spacing = 0,
            .angle = 0,
            .border_style = 1,
            .outline = 2,
            .shadow = 2,
            .alignment = .bottom_center,
            .margin_l = 10,
            .margin_r = 10,
            .margin_v = 10,
            .encoding = 1,
            .allocator = allocator,
        };
    }
};

// ============================================================================
// ASS Dialogue Event
// ============================================================================

pub const Dialogue = struct {
    layer: i32,
    start_time: u64, // milliseconds
    end_time: u64, // milliseconds
    style: []const u8,
    name: []const u8, // Actor/character name
    margin_l: i32,
    margin_r: i32,
    margin_v: i32,
    effect: []const u8,
    text: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dialogue) void {
        self.allocator.free(self.style);
        self.allocator.free(self.name);
        self.allocator.free(self.effect);
        self.allocator.free(self.text);
    }

    /// Get duration in milliseconds
    pub fn getDuration(self: *const Dialogue) u64 {
        return self.end_time - self.start_time;
    }

    /// Check if dialogue is active at given time
    pub fn isActiveAt(self: *const Dialogue, time_ms: u64) bool {
        return time_ms >= self.start_time and time_ms < self.end_time;
    }

    /// Get plain text (strip override tags)
    pub fn getPlainText(self: *const Dialogue, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        var in_tag = false;

        while (i < self.text.len) {
            const c = self.text[i];

            if (c == '{') {
                in_tag = true;
            } else if (c == '}') {
                in_tag = false;
            } else if (!in_tag) {
                // Handle special sequences
                if (c == '\\' and i + 1 < self.text.len) {
                    const next = self.text[i + 1];
                    if (next == 'n' or next == 'N') {
                        try result.append(allocator, '\n');
                        i += 2;
                        continue;
                    } else if (next == 'h') {
                        try result.append(allocator, ' '); // Non-breaking space
                        i += 2;
                        continue;
                    }
                }
                try result.append(allocator, c);
            }
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// ASS Script Info
// ============================================================================

pub const ScriptInfo = struct {
    title: ?[]const u8,
    original_script: ?[]const u8,
    script_type: ?[]const u8,
    collisions: ?[]const u8,
    play_res_x: u32,
    play_res_y: u32,
    play_depth: u32,
    timer: f64,
    wrap_style: u8,
    scaled_border_and_shadow: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScriptInfo) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.original_script) |s| self.allocator.free(s);
        if (self.script_type) |t| self.allocator.free(t);
        if (self.collisions) |c| self.allocator.free(c);
    }

    pub fn default(allocator: std.mem.Allocator) ScriptInfo {
        return ScriptInfo{
            .title = null,
            .original_script = null,
            .script_type = null,
            .collisions = null,
            .play_res_x = 384,
            .play_res_y = 288,
            .play_depth = 0,
            .timer = 100.0,
            .wrap_style = 0,
            .scaled_border_and_shadow = true,
            .allocator = allocator,
        };
    }
};

// ============================================================================
// ASS Parser
// ============================================================================

pub const AssParser = struct {
    script_info: ScriptInfo,
    styles: std.ArrayListUnmanaged(Style),
    dialogues: std.ArrayListUnmanaged(Dialogue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .script_info = ScriptInfo.default(allocator),
            .styles = .empty,
            .dialogues = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.script_info.deinit();
        for (self.styles.items) |*style| {
            style.deinit();
        }
        self.styles.deinit(self.allocator);
        for (self.dialogues.items) |*dialogue| {
            dialogue.deinit();
        }
        self.dialogues.deinit(self.allocator);
    }

    /// Parse ASS/SSA content
    pub fn parse(self: *Self, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_section: Section = .none;
        var format_order: std.ArrayListUnmanaged([]const u8) = .empty;
        defer format_order.deinit(self.allocator);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Check for section headers
            if (trimmed[0] == '[') {
                if (std.mem.indexOf(u8, trimmed, "]")) |end| {
                    const section_name = trimmed[1..end];
                    current_section = Section.fromString(section_name);
                    format_order.clearRetainingCapacity();
                }
                continue;
            }

            // Skip comments
            if (trimmed[0] == ';' or trimmed[0] == '!') continue;

            switch (current_section) {
                .script_info => try self.parseScriptInfoLine(trimmed),
                .styles => {
                    if (std.mem.startsWith(u8, trimmed, "Format:")) {
                        format_order.clearRetainingCapacity();
                        const format_str = std.mem.trim(u8, trimmed[7..], " \t");
                        var fields = std.mem.splitScalar(u8, format_str, ',');
                        while (fields.next()) |field| {
                            try format_order.append(self.allocator, std.mem.trim(u8, field, " \t"));
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "Style:")) {
                        try self.parseStyleLine(trimmed[6..], format_order.items);
                    }
                },
                .events => {
                    if (std.mem.startsWith(u8, trimmed, "Format:")) {
                        format_order.clearRetainingCapacity();
                        const format_str = std.mem.trim(u8, trimmed[7..], " \t");
                        var fields = std.mem.splitScalar(u8, format_str, ',');
                        while (fields.next()) |field| {
                            try format_order.append(self.allocator, std.mem.trim(u8, field, " \t"));
                        }
                    } else if (std.mem.startsWith(u8, trimmed, "Dialogue:")) {
                        try self.parseDialogueLine(trimmed[9..], format_order.items);
                    }
                },
                else => {},
            }
        }
    }

    fn parseScriptInfoLine(self: *Self, line: []const u8) !void {
        if (std.mem.indexOf(u8, line, ":")) |colon| {
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

            if (std.mem.eql(u8, key, "Title")) {
                if (self.script_info.title) |t| self.allocator.free(t);
                self.script_info.title = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "PlayResX")) {
                self.script_info.play_res_x = std.fmt.parseInt(u32, value, 10) catch 384;
            } else if (std.mem.eql(u8, key, "PlayResY")) {
                self.script_info.play_res_y = std.fmt.parseInt(u32, value, 10) catch 288;
            } else if (std.mem.eql(u8, key, "WrapStyle")) {
                self.script_info.wrap_style = std.fmt.parseInt(u8, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "ScaledBorderAndShadow")) {
                self.script_info.scaled_border_and_shadow = std.mem.eql(u8, value, "yes");
            }
        }
    }

    fn parseStyleLine(self: *Self, line: []const u8, format: []const []const u8) !void {
        var style = try Style.default(self.allocator);
        errdefer style.deinit();

        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t"), ',');
        var field_idx: usize = 0;

        while (fields.next()) |field| {
            if (field_idx >= format.len) break;
            const field_name = format[field_idx];
            const value = std.mem.trim(u8, field, " \t");

            if (std.mem.eql(u8, field_name, "Name")) {
                self.allocator.free(style.name);
                style.name = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, field_name, "Fontname")) {
                self.allocator.free(style.fontname);
                style.fontname = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, field_name, "Fontsize")) {
                style.fontsize = std.fmt.parseFloat(f32, value) catch 20;
            } else if (std.mem.eql(u8, field_name, "PrimaryColour")) {
                style.primary_color = parseColor(value);
            } else if (std.mem.eql(u8, field_name, "Bold")) {
                style.bold = !std.mem.eql(u8, value, "0");
            } else if (std.mem.eql(u8, field_name, "Italic")) {
                style.italic = !std.mem.eql(u8, value, "0");
            } else if (std.mem.eql(u8, field_name, "Alignment")) {
                const align_val = std.fmt.parseInt(u8, value, 10) catch 2;
                style.alignment = @enumFromInt(@min(9, @max(1, align_val)));
            }

            field_idx += 1;
        }

        try self.styles.append(self.allocator, style);
    }

    fn parseDialogueLine(self: *Self, line: []const u8, format: []const []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t");

        var dialogue = Dialogue{
            .layer = 0,
            .start_time = 0,
            .end_time = 0,
            .style = try self.allocator.dupe(u8, "Default"),
            .name = try self.allocator.dupe(u8, ""),
            .margin_l = 0,
            .margin_r = 0,
            .margin_v = 0,
            .effect = try self.allocator.dupe(u8, ""),
            .text = try self.allocator.dupe(u8, ""),
            .allocator = self.allocator,
        };
        errdefer dialogue.deinit();

        // Split by comma, but text field can contain commas
        var field_idx: usize = 0;
        var pos: usize = 0;

        while (field_idx < format.len and pos < trimmed.len) {
            const field_name = format[field_idx];

            // Text is always the last field and can contain commas
            if (std.mem.eql(u8, field_name, "Text")) {
                self.allocator.free(dialogue.text);
                dialogue.text = try self.allocator.dupe(u8, trimmed[pos..]);
                break;
            }

            // Find next comma
            const end_pos = std.mem.indexOfScalarPos(u8, trimmed, pos, ',') orelse trimmed.len;
            const value = std.mem.trim(u8, trimmed[pos..end_pos], " \t");

            if (std.mem.eql(u8, field_name, "Layer")) {
                dialogue.layer = std.fmt.parseInt(i32, value, 10) catch 0;
            } else if (std.mem.eql(u8, field_name, "Start")) {
                dialogue.start_time = parseTimestamp(value);
            } else if (std.mem.eql(u8, field_name, "End")) {
                dialogue.end_time = parseTimestamp(value);
            } else if (std.mem.eql(u8, field_name, "Style")) {
                self.allocator.free(dialogue.style);
                dialogue.style = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, field_name, "Name")) {
                self.allocator.free(dialogue.name);
                dialogue.name = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, field_name, "Effect")) {
                self.allocator.free(dialogue.effect);
                dialogue.effect = try self.allocator.dupe(u8, value);
            }

            pos = if (end_pos < trimmed.len) end_pos + 1 else trimmed.len;
            field_idx += 1;
        }

        try self.dialogues.append(self.allocator, dialogue);
    }

    /// Get dialogue active at given time
    pub fn getDialogueAt(self: *const Self, time_ms: u64) ?*const Dialogue {
        for (self.dialogues.items) |*d| {
            if (d.isActiveAt(time_ms)) {
                return d;
            }
        }
        return null;
    }

    /// Get all dialogues active at given time
    pub fn getDialoguesAt(self: *const Self, allocator: std.mem.Allocator, time_ms: u64, result: *std.ArrayListUnmanaged(*const Dialogue)) !void {
        for (self.dialogues.items) |*d| {
            if (d.isActiveAt(time_ms)) {
                try result.append(allocator, d);
            }
        }
    }

    /// Get style by name
    pub fn getStyle(self: *const Self, name: []const u8) ?*const Style {
        for (self.styles.items) |*style| {
            if (std.mem.eql(u8, style.name, name)) {
                return style;
            }
        }
        return null;
    }

    /// Get dialogue count
    pub fn count(self: *const Self) usize {
        return self.dialogues.items.len;
    }

    /// Get duration (end of last dialogue)
    pub fn getDuration(self: *const Self) u64 {
        var max_end: u64 = 0;
        for (self.dialogues.items) |d| {
            if (d.end_time > max_end) {
                max_end = d.end_time;
            }
        }
        return max_end;
    }

    const Section = enum {
        none,
        script_info,
        styles,
        events,
        fonts,
        graphics,

        pub fn fromString(s: []const u8) Section {
            if (std.mem.eql(u8, s, "Script Info")) return .script_info;
            if (std.mem.eql(u8, s, "V4 Styles") or std.mem.eql(u8, s, "V4+ Styles")) return .styles;
            if (std.mem.eql(u8, s, "Events")) return .events;
            if (std.mem.eql(u8, s, "Fonts")) return .fonts;
            if (std.mem.eql(u8, s, "Graphics")) return .graphics;
            return .none;
        }
    };
};

// ============================================================================
// ASS Writer
// ============================================================================

pub const AssWriter = struct {
    script_info: ScriptInfo,
    styles: std.ArrayListUnmanaged(Style),
    dialogues: std.ArrayListUnmanaged(Dialogue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .script_info = ScriptInfo.default(allocator),
            .styles = .empty,
            .dialogues = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.script_info.deinit();
        for (self.styles.items) |*style| {
            style.deinit();
        }
        self.styles.deinit(self.allocator);
        for (self.dialogues.items) |*dialogue| {
            dialogue.deinit();
        }
        self.dialogues.deinit(self.allocator);
    }

    /// Set title
    pub fn setTitle(self: *Self, title: []const u8) !void {
        if (self.script_info.title) |t| self.allocator.free(t);
        self.script_info.title = try self.allocator.dupe(u8, title);
    }

    /// Set resolution
    pub fn setResolution(self: *Self, width: u32, height: u32) void {
        self.script_info.play_res_x = width;
        self.script_info.play_res_y = height;
    }

    /// Add a style
    pub fn addStyle(self: *Self, style: Style) !void {
        try self.styles.append(self.allocator, style);
    }

    /// Add a dialogue
    pub fn addDialogue(self: *Self, start_ms: u64, end_ms: u64, text: []const u8) !void {
        try self.dialogues.append(self.allocator, Dialogue{
            .layer = 0,
            .start_time = start_ms,
            .end_time = end_ms,
            .style = try self.allocator.dupe(u8, "Default"),
            .name = try self.allocator.dupe(u8, ""),
            .margin_l = 0,
            .margin_r = 0,
            .margin_v = 0,
            .effect = try self.allocator.dupe(u8, ""),
            .text = try self.allocator.dupe(u8, text),
            .allocator = self.allocator,
        });
    }

    /// Generate ASS content
    pub fn generate(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        // Script Info section
        try result.appendSlice(allocator, "[Script Info]\n");
        try result.appendSlice(allocator, "; Generated by Home Video Library\n");
        try result.appendSlice(allocator, "ScriptType: v4.00+\n");
        if (self.script_info.title) |title| {
            try result.appendSlice(allocator, "Title: ");
            try result.appendSlice(allocator, title);
            try result.append(allocator, '\n');
        }
        const res_x = try std.fmt.allocPrint(allocator, "PlayResX: {d}\n", .{self.script_info.play_res_x});
        defer allocator.free(res_x);
        try result.appendSlice(allocator, res_x);
        const res_y = try std.fmt.allocPrint(allocator, "PlayResY: {d}\n", .{self.script_info.play_res_y});
        defer allocator.free(res_y);
        try result.appendSlice(allocator, res_y);
        try result.append(allocator, '\n');

        // Styles section
        try result.appendSlice(allocator, "[V4+ Styles]\n");
        try result.appendSlice(allocator, "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n");

        if (self.styles.items.len == 0) {
            // Default style
            try result.appendSlice(allocator, "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n");
        } else {
            for (self.styles.items) |style| {
                const style_line = try std.fmt.allocPrint(allocator, "Style: {s},{s},{d},&H{X:0>8},&H{X:0>8},&H{X:0>8},&H{X:0>8},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                    style.name,
                    style.fontname,
                    @as(u32, @intFromFloat(style.fontsize)),
                    style.primary_color,
                    style.secondary_color,
                    style.outline_color,
                    style.back_color,
                    @as(u8, if (style.bold) 1 else 0),
                    @as(u8, if (style.italic) 1 else 0),
                    @as(u8, if (style.underline) 1 else 0),
                    @as(u8, if (style.strikeout) 1 else 0),
                    @as(u32, @intFromFloat(style.scale_x)),
                    @as(u32, @intFromFloat(style.scale_y)),
                    @as(u32, @intFromFloat(style.spacing)),
                    @as(u32, @intFromFloat(style.angle)),
                    style.border_style,
                    @as(u32, @intFromFloat(style.outline)),
                    @as(u32, @intFromFloat(style.shadow)),
                    @intFromEnum(style.alignment),
                    style.margin_l,
                    style.margin_r,
                    style.margin_v,
                    style.encoding,
                });
                defer allocator.free(style_line);
                try result.appendSlice(allocator, style_line);
            }
        }
        try result.append(allocator, '\n');

        // Events section
        try result.appendSlice(allocator, "[Events]\n");
        try result.appendSlice(allocator, "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n");

        for (self.dialogues.items) |dialogue| {
            var start_buf: [16]u8 = undefined;
            var end_buf: [16]u8 = undefined;
            const start_str = formatTimestamp(dialogue.start_time, &start_buf);
            const end_str = formatTimestamp(dialogue.end_time, &end_buf);

            const dialogue_line = try std.fmt.allocPrint(allocator, "Dialogue: {d},{s},{s},{s},{s},{d},{d},{d},{s},{s}\n", .{
                dialogue.layer,
                start_str,
                end_str,
                dialogue.style,
                dialogue.name,
                dialogue.margin_l,
                dialogue.margin_r,
                dialogue.margin_v,
                dialogue.effect,
                dialogue.text,
            });
            defer allocator.free(dialogue_line);
            try result.appendSlice(allocator, dialogue_line);
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn parseTimestamp(ts: []const u8) u64 {
    // Format: H:MM:SS.cc (centiseconds)
    var parts = std.mem.splitScalar(u8, ts, ':');

    const hours_str = parts.next() orelse return 0;
    const mins_str = parts.next() orelse return 0;
    const rest = parts.next() orelse return 0;

    var sec_parts = std.mem.splitScalar(u8, rest, '.');
    const secs_str = sec_parts.next() orelse return 0;
    const cs_str = sec_parts.next() orelse "00";

    const hours = std.fmt.parseInt(u32, hours_str, 10) catch return 0;
    const mins = std.fmt.parseInt(u32, mins_str, 10) catch return 0;
    const secs = std.fmt.parseInt(u32, secs_str, 10) catch return 0;
    const cs = std.fmt.parseInt(u32, cs_str, 10) catch return 0;

    return @as(u64, hours) * 3600000 +
        @as(u64, mins) * 60000 +
        @as(u64, secs) * 1000 +
        @as(u64, cs) * 10;
}

fn formatTimestamp(ms: u64, buf: []u8) []u8 {
    const hours = ms / 3600000;
    const mins = (ms % 3600000) / 60000;
    const secs = (ms % 60000) / 1000;
    const cs = (ms % 1000) / 10;

    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>2}", .{
        hours,
        mins,
        secs,
        cs,
    }) catch buf[0..0];
}

fn parseColor(s: []const u8) u32 {
    // Format: &HAABBGGRR or &HBBGGRR
    var value = s;
    if (std.mem.startsWith(u8, value, "&H")) {
        value = value[2..];
    }
    return std.fmt.parseInt(u32, value, 16) catch 0x00FFFFFF;
}

/// Check if data looks like ASS/SSA
pub fn isAss(data: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, data, " \t\r\n\xef\xbb\xbf"); // Skip BOM
    return std.mem.startsWith(u8, trimmed, "[Script Info]");
}

// ============================================================================
// Tests
// ============================================================================

test "parseTimestamp" {
    const ts1 = parseTimestamp("0:00:01.00");
    try std.testing.expectEqual(@as(u64, 1000), ts1);

    const ts2 = parseTimestamp("1:30:45.50");
    try std.testing.expectEqual(@as(u64, 5445500), ts2);
}

test "formatTimestamp" {
    var buf: [16]u8 = undefined;

    const ts1 = formatTimestamp(1000, &buf);
    try std.testing.expectEqualStrings("0:00:01.00", ts1);

    const ts2 = formatTimestamp(5445500, &buf);
    try std.testing.expectEqualStrings("1:30:45.50", ts2);
}

test "AssParser basic" {
    const allocator = std.testing.allocator;

    const ass_content =
        \\[Script Info]
        \\Title: Test
        \\PlayResX: 1920
        \\PlayResY: 1080
        \\
        \\[V4+ Styles]
        \\Format: Name, Fontname, Fontsize, PrimaryColour
        \\Style: Default,Arial,20,&H00FFFFFF
        \\
        \\[Events]
        \\Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \\Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,Hello world!
        \\
    ;

    var parser = AssParser.init(allocator);
    defer parser.deinit();

    try parser.parse(ass_content);

    try std.testing.expectEqual(@as(usize, 1), parser.dialogues.items.len);
    try std.testing.expectEqualStrings("Hello world!", parser.dialogues.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), parser.dialogues.items[0].start_time);
    try std.testing.expectEqual(@as(u32, 1920), parser.script_info.play_res_x);
}

test "AssWriter" {
    const allocator = std.testing.allocator;

    var writer = AssWriter.init(allocator);
    defer writer.deinit();

    try writer.setTitle("Test");
    writer.setResolution(1920, 1080);
    try writer.addDialogue(1000, 4000, "Hello");

    const output = try writer.generate(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[Script Info]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Title: Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}

test "isAss" {
    try std.testing.expect(isAss("[Script Info]\nTitle: Test"));
    try std.testing.expect(isAss("\xef\xbb\xbf[Script Info]")); // With BOM
    try std.testing.expect(!isAss("WEBVTT"));
}

test "Dialogue.getPlainText" {
    const allocator = std.testing.allocator;

    var dialogue = Dialogue{
        .layer = 0,
        .start_time = 0,
        .end_time = 1000,
        .style = try allocator.dupe(u8, "Default"),
        .name = try allocator.dupe(u8, ""),
        .margin_l = 0,
        .margin_r = 0,
        .margin_v = 0,
        .effect = try allocator.dupe(u8, ""),
        .text = try allocator.dupe(u8, "{\\b1}Bold{\\b0} and {\\i1}italic{\\i0}\\Nnewline"),
        .allocator = allocator,
    };
    defer dialogue.deinit();

    const plain = try dialogue.getPlainText(allocator);
    defer allocator.free(plain);

    try std.testing.expectEqualStrings("Bold and italic\nnewline", plain);
}
