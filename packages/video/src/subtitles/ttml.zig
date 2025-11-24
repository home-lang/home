// Home Video Library - TTML Subtitle Parser
// Timed Text Markup Language (W3C standard, used by Netflix, etc.)

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// TTML Cue
// ============================================================================

pub const Cue = struct {
    id: ?[]const u8,
    start_time: u64, // milliseconds
    end_time: u64, // milliseconds
    text: []const u8,
    region: ?[]const u8,
    style: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cue) void {
        if (self.id) |id| self.allocator.free(id);
        self.allocator.free(self.text);
        if (self.region) |r| self.allocator.free(r);
        if (self.style) |s| self.allocator.free(s);
    }

    pub fn getDuration(self: *const Cue) u64 {
        return self.end_time - self.start_time;
    }

    pub fn isActiveAt(self: *const Cue, time_ms: u64) bool {
        return time_ms >= self.start_time and time_ms < self.end_time;
    }
};

// ============================================================================
// TTML Style
// ============================================================================

pub const Style = struct {
    id: []const u8,
    font_family: ?[]const u8,
    font_size: ?[]const u8,
    color: ?[]const u8,
    background_color: ?[]const u8,
    font_weight: ?[]const u8,
    font_style: ?[]const u8,
    text_align: ?TextAlign,
    allocator: std.mem.Allocator,

    pub const TextAlign = enum { left, center, right, start, end };

    pub fn deinit(self: *Style) void {
        self.allocator.free(self.id);
        if (self.font_family) |f| self.allocator.free(f);
        if (self.font_size) |f| self.allocator.free(f);
        if (self.color) |c| self.allocator.free(c);
        if (self.background_color) |b| self.allocator.free(b);
        if (self.font_weight) |w| self.allocator.free(w);
        if (self.font_style) |s| self.allocator.free(s);
    }
};

// ============================================================================
// TTML Region
// ============================================================================

pub const Region = struct {
    id: []const u8,
    origin: ?[]const u8, // "x% y%"
    extent: ?[]const u8, // "w% h%"
    display_align: ?DisplayAlign,
    allocator: std.mem.Allocator,

    pub const DisplayAlign = enum { before, center, after };

    pub fn deinit(self: *Region) void {
        self.allocator.free(self.id);
        if (self.origin) |o| self.allocator.free(o);
        if (self.extent) |e| self.allocator.free(e);
    }
};

// ============================================================================
// TTML Document Info
// ============================================================================

pub const DocumentInfo = struct {
    language: ?[]const u8,
    frame_rate: ?f64,
    tick_rate: ?u64,
    time_base: TimeBase,
    allocator: std.mem.Allocator,

    pub const TimeBase = enum { media, smpte, clock };

    pub fn deinit(self: *DocumentInfo) void {
        if (self.language) |l| self.allocator.free(l);
    }

    pub fn default(allocator: std.mem.Allocator) DocumentInfo {
        return .{
            .language = null,
            .frame_rate = null,
            .tick_rate = null,
            .time_base = .media,
            .allocator = allocator,
        };
    }
};

// ============================================================================
// TTML Parser
// ============================================================================

pub const TtmlParser = struct {
    doc_info: DocumentInfo,
    styles: std.ArrayListUnmanaged(Style),
    regions: std.ArrayListUnmanaged(Region),
    cues: std.ArrayListUnmanaged(Cue),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .doc_info = DocumentInfo.default(allocator),
            .styles = .empty,
            .regions = .empty,
            .cues = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.doc_info.deinit();
        for (self.styles.items) |*s| s.deinit();
        self.styles.deinit(self.allocator);
        for (self.regions.items) |*r| r.deinit();
        self.regions.deinit(self.allocator);
        for (self.cues.items) |*c| c.deinit();
        self.cues.deinit(self.allocator);
    }

    /// Parse TTML content (simplified XML parsing)
    pub fn parse(self: *Self, content: []const u8) !void {
        var pos: usize = 0;

        // Skip XML declaration and find <tt> element
        while (pos < content.len) {
            if (content[pos] == '<') {
                const tag_end = std.mem.indexOfScalarPos(u8, content, pos, '>') orelse break;
                const tag_content = content[pos + 1 .. tag_end];

                if (std.mem.startsWith(u8, tag_content, "?xml")) {
                    pos = tag_end + 1;
                    continue;
                }

                // Parse <tt> attributes
                if (std.mem.startsWith(u8, tag_content, "tt")) {
                    try self.parseTtAttributes(tag_content);
                }

                // Look for body content
                if (std.mem.indexOf(u8, content[pos..], "<body")) |body_start| {
                    const body_pos = pos + body_start;
                    if (std.mem.indexOf(u8, content[body_pos..], "</body>")) |body_end| {
                        try self.parseBody(content[body_pos .. body_pos + body_end + 7]);
                    }
                }

                // Look for styling
                if (std.mem.indexOf(u8, content[pos..], "<styling")) |style_start| {
                    const style_pos = pos + style_start;
                    if (std.mem.indexOf(u8, content[style_pos..], "</styling>")) |style_end| {
                        try self.parseStyling(content[style_pos .. style_pos + style_end + 10]);
                    }
                }

                // Look for layout
                if (std.mem.indexOf(u8, content[pos..], "<layout")) |layout_start| {
                    const layout_pos = pos + layout_start;
                    if (std.mem.indexOf(u8, content[layout_pos..], "</layout>")) |layout_end| {
                        try self.parseLayout(content[layout_pos .. layout_pos + layout_end + 9]);
                    }
                }

                break;
            }
            pos += 1;
        }
    }

    fn parseTtAttributes(self: *Self, tag: []const u8) !void {
        if (getAttributeValue(tag, "xml:lang")) |lang| {
            if (self.doc_info.language) |l| self.allocator.free(l);
            self.doc_info.language = try self.allocator.dupe(u8, lang);
        }
        if (getAttributeValue(tag, "ttp:frameRate")) |fr| {
            self.doc_info.frame_rate = std.fmt.parseFloat(f64, fr) catch null;
        }
        if (getAttributeValue(tag, "ttp:tickRate")) |tr| {
            self.doc_info.tick_rate = std.fmt.parseInt(u64, tr, 10) catch null;
        }
        if (getAttributeValue(tag, "ttp:timeBase")) |tb| {
            if (std.mem.eql(u8, tb, "smpte")) {
                self.doc_info.time_base = .smpte;
            } else if (std.mem.eql(u8, tb, "clock")) {
                self.doc_info.time_base = .clock;
            }
        }
    }

    fn parseStyling(self: *Self, content: []const u8) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<style")) |style_start| {
            const tag_end = std.mem.indexOfScalarPos(u8, content, style_start, '>') orelse break;
            const tag_content = content[style_start + 1 .. tag_end];

            if (getAttributeValue(tag_content, "xml:id")) |id| {
                var style = Style{
                    .id = try self.allocator.dupe(u8, id),
                    .font_family = null,
                    .font_size = null,
                    .color = null,
                    .background_color = null,
                    .font_weight = null,
                    .font_style = null,
                    .text_align = null,
                    .allocator = self.allocator,
                };
                errdefer style.deinit();

                if (getAttributeValue(tag_content, "tts:fontFamily")) |v| {
                    style.font_family = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:fontSize")) |v| {
                    style.font_size = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:color")) |v| {
                    style.color = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:backgroundColor")) |v| {
                    style.background_color = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:textAlign")) |v| {
                    if (std.mem.eql(u8, v, "left")) style.text_align = .left
                    else if (std.mem.eql(u8, v, "center")) style.text_align = .center
                    else if (std.mem.eql(u8, v, "right")) style.text_align = .right
                    else if (std.mem.eql(u8, v, "start")) style.text_align = .start
                    else if (std.mem.eql(u8, v, "end")) style.text_align = .end;
                }

                try self.styles.append(self.allocator, style);
            }

            pos = tag_end + 1;
        }
    }

    fn parseLayout(self: *Self, content: []const u8) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<region")) |region_start| {
            const tag_end = std.mem.indexOfScalarPos(u8, content, region_start, '>') orelse break;
            const tag_content = content[region_start + 1 .. tag_end];

            if (getAttributeValue(tag_content, "xml:id")) |id| {
                var region = Region{
                    .id = try self.allocator.dupe(u8, id),
                    .origin = null,
                    .extent = null,
                    .display_align = null,
                    .allocator = self.allocator,
                };
                errdefer region.deinit();

                if (getAttributeValue(tag_content, "tts:origin")) |v| {
                    region.origin = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:extent")) |v| {
                    region.extent = try self.allocator.dupe(u8, v);
                }
                if (getAttributeValue(tag_content, "tts:displayAlign")) |v| {
                    if (std.mem.eql(u8, v, "before")) region.display_align = .before
                    else if (std.mem.eql(u8, v, "center")) region.display_align = .center
                    else if (std.mem.eql(u8, v, "after")) region.display_align = .after;
                }

                try self.regions.append(self.allocator, region);
            }

            pos = tag_end + 1;
        }
    }

    fn parseBody(self: *Self, content: []const u8) !void {
        // Look for <p> elements
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<p")) |p_start| {
            const tag_end = std.mem.indexOfScalarPos(u8, content, p_start, '>') orelse break;

            // Check if it's self-closing or find </p>
            const is_self_closing = content[tag_end - 1] == '/';
            const tag_content = content[p_start + 2 .. if (is_self_closing) tag_end - 1 else tag_end];

            var text_content: []const u8 = "";
            var text_end_pos = tag_end + 1;

            if (!is_self_closing) {
                if (std.mem.indexOfPos(u8, content, tag_end, "</p>")) |p_end| {
                    text_content = content[tag_end + 1 .. p_end];
                    text_end_pos = p_end + 4;
                }
            }

            // Parse timing attributes
            var start_time: u64 = 0;
            var end_time: u64 = 0;

            if (getAttributeValue(tag_content, "begin")) |begin| {
                start_time = try self.parseTime(begin);
            }
            if (getAttributeValue(tag_content, "end")) |end| {
                end_time = try self.parseTime(end);
            }
            if (getAttributeValue(tag_content, "dur")) |dur| {
                end_time = start_time + try self.parseTime(dur);
            }

            // Strip XML tags from text
            const plain_text = try stripXmlTags(self.allocator, text_content);

            var cue = Cue{
                .id = null,
                .start_time = start_time,
                .end_time = end_time,
                .text = plain_text,
                .region = null,
                .style = null,
                .allocator = self.allocator,
            };
            errdefer cue.deinit();

            if (getAttributeValue(tag_content, "xml:id")) |id| {
                cue.id = try self.allocator.dupe(u8, id);
            }
            if (getAttributeValue(tag_content, "region")) |r| {
                cue.region = try self.allocator.dupe(u8, r);
            }
            if (getAttributeValue(tag_content, "style")) |s| {
                cue.style = try self.allocator.dupe(u8, s);
            }

            if (cue.text.len > 0) {
                try self.cues.append(self.allocator, cue);
            } else {
                cue.deinit();
            }

            pos = text_end_pos;
        }
    }

    fn parseTime(self: *const Self, time_str: []const u8) !u64 {
        // Handle different time formats:
        // - clock time: HH:MM:SS.mmm or HH:MM:SS:FF (SMPTE)
        // - offset time: 1.5s, 100ms, 10f, 100t
        const trimmed = std.mem.trim(u8, time_str, " \t");

        // Check for offset time
        if (std.mem.endsWith(u8, trimmed, "ms")) {
            const val = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 2]) catch return 0;
            return @intFromFloat(val);
        }
        if (std.mem.endsWith(u8, trimmed, "s")) {
            const val = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 1]) catch return 0;
            return @intFromFloat(val * 1000);
        }
        if (std.mem.endsWith(u8, trimmed, "f")) {
            const frames = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 1]) catch return 0;
            const fr = self.doc_info.frame_rate orelse 30.0;
            return @intFromFloat((frames / fr) * 1000);
        }
        if (std.mem.endsWith(u8, trimmed, "t")) {
            const ticks = std.fmt.parseInt(u64, trimmed[0 .. trimmed.len - 1], 10) catch return 0;
            const tr = self.doc_info.tick_rate orelse 1;
            if (tr == 0) return 0;
            return (ticks * 1000) / tr;
        }

        // Clock time format
        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const p1 = parts.next() orelse return 0;
        const p2 = parts.next() orelse return 0;
        const p3 = parts.next() orelse return 0;
        const p4 = parts.next();

        const hours = std.fmt.parseInt(u32, p1, 10) catch return 0;
        const mins = std.fmt.parseInt(u32, p2, 10) catch return 0;

        // p3 might contain fraction
        var sec_parts = std.mem.splitScalar(u8, p3, '.');
        const secs_str = sec_parts.next() orelse return 0;
        const frac_str = sec_parts.next();

        const secs = std.fmt.parseInt(u32, secs_str, 10) catch return 0;

        var ms: u64 = 0;
        if (frac_str) |frac| {
            // Convert fraction to ms (handle variable precision)
            const frac_val = std.fmt.parseInt(u32, frac, 10) catch 0;
            var divisor: u32 = 1;
            for (0..frac.len) |_| divisor *= 10;
            ms = (@as(u64, frac_val) * 1000) / divisor;
        } else if (p4) |frames_str| {
            // SMPTE format with frames
            const frames = std.fmt.parseInt(u32, frames_str, 10) catch 0;
            const fr = self.doc_info.frame_rate orelse 30.0;
            ms = @intFromFloat((@as(f64, @floatFromInt(frames)) / fr) * 1000);
        }

        return @as(u64, hours) * 3600000 +
            @as(u64, mins) * 60000 +
            @as(u64, secs) * 1000 + ms;
    }

    /// Get cue at time
    pub fn getCueAt(self: *const Self, time_ms: u64) ?*const Cue {
        for (self.cues.items) |*cue| {
            if (cue.isActiveAt(time_ms)) return cue;
        }
        return null;
    }

    /// Get style by ID
    pub fn getStyle(self: *const Self, id: []const u8) ?*const Style {
        for (self.styles.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    /// Get region by ID
    pub fn getRegion(self: *const Self, id: []const u8) ?*const Region {
        for (self.regions.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.cues.items.len;
    }

    pub fn getDuration(self: *const Self) u64 {
        var max_end: u64 = 0;
        for (self.cues.items) |c| {
            if (c.end_time > max_end) max_end = c.end_time;
        }
        return max_end;
    }
};

// ============================================================================
// TTML Writer
// ============================================================================

pub const TtmlWriter = struct {
    cues: std.ArrayListUnmanaged(Cue),
    language: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cues = .empty,
            .language = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.cues.items) |*c| c.deinit();
        self.cues.deinit(self.allocator);
        if (self.language) |l| self.allocator.free(l);
    }

    pub fn setLanguage(self: *Self, lang: []const u8) !void {
        if (self.language) |l| self.allocator.free(l);
        self.language = try self.allocator.dupe(u8, lang);
    }

    pub fn addCue(self: *Self, start_ms: u64, end_ms: u64, text: []const u8) !void {
        try self.cues.append(self.allocator, Cue{
            .id = null,
            .start_time = start_ms,
            .end_time = end_ms,
            .text = try self.allocator.dupe(u8, text),
            .region = null,
            .style = null,
            .allocator = self.allocator,
        });
    }

    pub fn generate(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try result.appendSlice(allocator, "<tt xmlns=\"http://www.w3.org/ns/ttml\"");
        if (self.language) |lang| {
            try result.appendSlice(allocator, " xml:lang=\"");
            try result.appendSlice(allocator, lang);
            try result.append(allocator, '"');
        }
        try result.appendSlice(allocator, ">\n");
        try result.appendSlice(allocator, "  <body>\n");
        try result.appendSlice(allocator, "    <div>\n");

        for (self.cues.items, 0..) |cue, i| {
            var time_buf: [32]u8 = undefined;
            const p_line = try std.fmt.allocPrint(allocator, "      <p xml:id=\"p{d}\" begin=\"{s}\" end=\"{s}\">{s}</p>\n", .{
                i + 1,
                formatTime(cue.start_time, &time_buf),
                formatTime(cue.end_time, &time_buf),
                cue.text,
            });
            defer allocator.free(p_line);
            try result.appendSlice(allocator, p_line);
        }

        try result.appendSlice(allocator, "    </div>\n");
        try result.appendSlice(allocator, "  </body>\n");
        try result.appendSlice(allocator, "</tt>\n");

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getAttributeValue(tag: []const u8, attr_name: []const u8) ?[]const u8 {
    // Find attribute="value" or attribute='value'
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search_pos, attr_name)) |attr_start| {
        const after_name = attr_start + attr_name.len;
        if (after_name >= tag.len) return null;

        // Skip whitespace and find =
        var pos = after_name;
        while (pos < tag.len and (tag[pos] == ' ' or tag[pos] == '\t')) pos += 1;
        if (pos >= tag.len or tag[pos] != '=') {
            search_pos = after_name;
            continue;
        }
        pos += 1;
        while (pos < tag.len and (tag[pos] == ' ' or tag[pos] == '\t')) pos += 1;

        if (pos >= tag.len) return null;
        const quote = tag[pos];
        if (quote != '"' and quote != '\'') {
            search_pos = after_name;
            continue;
        }
        pos += 1;

        const value_start = pos;
        while (pos < tag.len and tag[pos] != quote) pos += 1;
        if (pos >= tag.len) return null;

        return tag[value_start..pos];
    }
    return null;
}

fn stripXmlTags(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_tag = false;

    while (i < content.len) {
        const c = content[i];
        if (c == '<') {
            // Check for <br/> or <br>
            if (std.mem.startsWith(u8, content[i..], "<br")) {
                try result.append(allocator, '\n');
            }
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            // Handle common entities
            if (c == '&') {
                if (std.mem.startsWith(u8, content[i..], "&amp;")) {
                    try result.append(allocator, '&');
                    i += 5;
                    continue;
                } else if (std.mem.startsWith(u8, content[i..], "&lt;")) {
                    try result.append(allocator, '<');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, content[i..], "&gt;")) {
                    try result.append(allocator, '>');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, content[i..], "&apos;")) {
                    try result.append(allocator, '\'');
                    i += 6;
                    continue;
                } else if (std.mem.startsWith(u8, content[i..], "&quot;")) {
                    try result.append(allocator, '"');
                    i += 6;
                    continue;
                }
            }
            try result.append(allocator, c);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn formatTime(ms: u64, buf: []u8) []u8 {
    const hours = ms / 3600000;
    const mins = (ms % 3600000) / 60000;
    const secs = (ms % 60000) / 1000;
    const millis = ms % 1000;

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        hours, mins, secs, millis,
    }) catch buf[0..0];
}

/// Check if content is TTML
pub fn isTtml(data: []const u8) bool {
    const lower = data;
    return std.mem.indexOf(u8, lower, "<tt") != null and
        (std.mem.indexOf(u8, lower, "http://www.w3.org/ns/ttml") != null or
        std.mem.indexOf(u8, lower, "ttml") != null);
}

// ============================================================================
// Tests
// ============================================================================

test "TtmlParser basic" {
    const allocator = std.testing.allocator;

    const ttml_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
        \\  <body>
        \\    <div>
        \\      <p begin="00:00:01.000" end="00:00:04.000">Hello world!</p>
        \\      <p begin="00:00:05.000" end="00:00:08.000">Second line</p>
        \\    </div>
        \\  </body>
        \\</tt>
    ;

    var parser = TtmlParser.init(allocator);
    defer parser.deinit();

    try parser.parse(ttml_content);

    try std.testing.expectEqual(@as(usize, 2), parser.count());
    try std.testing.expectEqualStrings("Hello world!", parser.cues.items[0].text);
    try std.testing.expectEqual(@as(u64, 1000), parser.cues.items[0].start_time);
}

test "TtmlParser offset time" {
    const allocator = std.testing.allocator;

    const ttml_content =
        \\<tt xmlns="http://www.w3.org/ns/ttml">
        \\  <body>
        \\    <p begin="1s" dur="3s">One second</p>
        \\    <p begin="5000ms" end="8000ms">Five seconds</p>
        \\  </body>
        \\</tt>
    ;

    var parser = TtmlParser.init(allocator);
    defer parser.deinit();

    try parser.parse(ttml_content);

    try std.testing.expectEqual(@as(u64, 1000), parser.cues.items[0].start_time);
    try std.testing.expectEqual(@as(u64, 4000), parser.cues.items[0].end_time);
    try std.testing.expectEqual(@as(u64, 5000), parser.cues.items[1].start_time);
}

test "TtmlWriter" {
    const allocator = std.testing.allocator;

    var writer = TtmlWriter.init(allocator);
    defer writer.deinit();

    try writer.setLanguage("en");
    try writer.addCue(1000, 4000, "Hello");

    const output = try writer.generate(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "xml:lang=\"en\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}

test "isTtml" {
    try std.testing.expect(isTtml("<tt xmlns=\"http://www.w3.org/ns/ttml\">"));
    try std.testing.expect(!isTtml("WEBVTT"));
}

test "getAttributeValue" {
    const tag = "p begin=\"00:00:01.000\" end=\"00:00:04.000\" style='default'";
    try std.testing.expectEqualStrings("00:00:01.000", getAttributeValue(tag, "begin").?);
    try std.testing.expectEqualStrings("00:00:04.000", getAttributeValue(tag, "end").?);
    try std.testing.expectEqualStrings("default", getAttributeValue(tag, "style").?);
    try std.testing.expect(getAttributeValue(tag, "nonexistent") == null);
}
