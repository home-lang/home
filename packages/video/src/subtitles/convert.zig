// Home Video Library - Subtitle Format Conversion
// Convert between SRT, VTT, ASS, and TTML subtitle formats

const std = @import("std");
const Allocator = std.mem.Allocator;

const srt = @import("srt.zig");
const vtt = @import("vtt.zig");
const ass = @import("ass.zig");
const ttml = @import("ttml.zig");

// ============================================================================
// Universal Subtitle Cue
// ============================================================================

/// Universal cue format that can represent any subtitle format
pub const UniversalCue = struct {
    start_ms: u64,
    end_ms: u64,
    text: []const u8,

    // Optional styling (from ASS/TTML)
    style_name: ?[]const u8 = null,
    font_name: ?[]const u8 = null,
    font_size: ?u16 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    primary_color: ?u32 = null, // RGBA

    // Optional positioning (from VTT/TTML)
    position_x: ?f32 = null, // 0-100%
    position_y: ?f32 = null, // 0-100%
    align_h: HorizontalAlign = .center,
    align_v: VerticalAlign = .bottom,

    pub const HorizontalAlign = enum { left, center, right };
    pub const VerticalAlign = enum { top, middle, bottom };
};

/// Universal subtitle document
pub const UniversalSubtitle = struct {
    title: ?[]const u8 = null,
    language: ?[]const u8 = null,
    cues: std.ArrayListUnmanaged(UniversalCue) = .empty,

    // Style definitions (from ASS/TTML)
    styles: std.ArrayListUnmanaged(UniversalStyle) = .empty,

    pub fn deinit(self: *UniversalSubtitle, allocator: Allocator) void {
        self.cues.deinit(allocator);
        self.styles.deinit(allocator);
    }
};

pub const UniversalStyle = struct {
    name: []const u8,
    font_name: ?[]const u8 = null,
    font_size: u16 = 20,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    primary_color: u32 = 0xFFFFFFFF, // White
    outline_color: u32 = 0x000000FF, // Black
    shadow_color: u32 = 0x00000080, // Semi-transparent black
};

// ============================================================================
// Format Detection
// ============================================================================

pub const SubtitleFormat = enum {
    srt,
    vtt,
    ass,
    ttml,
    unknown,
};

/// Detect subtitle format from data
pub fn detectFormat(data: []const u8) SubtitleFormat {
    if (data.len == 0) return .unknown;

    // Check for VTT header
    if (vtt.isVtt(data)) return .vtt;

    // Check for ASS/SSA header
    if (ass.isAss(data)) return .ass;

    // Check for TTML (XML with tt namespace)
    if (ttml.isTtml(data)) return .ttml;

    // Check for SRT (starts with digit, usually "1")
    var i: usize = 0;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) {
        i += 1;
    }
    if (i < data.len and data[i] >= '0' and data[i] <= '9') {
        return .srt;
    }

    return .unknown;
}

// ============================================================================
// Import Functions (Format -> Universal)
// ============================================================================

/// Import SRT to universal format
pub fn importSrt(data: []const u8, allocator: Allocator) !UniversalSubtitle {
    var parser = srt.SrtParser.init(data, allocator);
    var result = UniversalSubtitle{};

    while (try parser.next()) |cue| {
        try result.cues.append(allocator, .{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
        });
    }

    return result;
}

/// Import VTT to universal format
pub fn importVtt(data: []const u8, allocator: Allocator) !UniversalSubtitle {
    var parser = vtt.VttParser.init(data, allocator);
    var result = UniversalSubtitle{};

    while (try parser.next()) |cue| {
        var ucue = UniversalCue{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
        };

        // Convert VTT settings
        if (cue.settings) |settings| {
            if (settings.position) |pos| {
                ucue.position_x = @as(f32, @floatFromInt(pos));
            }
            if (settings.line) |line| {
                ucue.position_y = @as(f32, @floatFromInt(line));
            }
            if (settings.align_value) |a| {
                ucue.align_h = switch (a) {
                    .left, .start => .left,
                    .center, .middle => .center,
                    .right, .end => .right,
                };
            }
        }

        try result.cues.append(allocator, ucue);
    }

    return result;
}

/// Import ASS to universal format
pub fn importAss(data: []const u8, allocator: Allocator) !UniversalSubtitle {
    var parser = ass.AssParser.init(data, allocator);
    var result = UniversalSubtitle{};

    // Parse and convert styles
    while (try parser.nextStyle()) |style| {
        try result.styles.append(allocator, .{
            .name = style.name,
            .font_name = style.fontname,
            .font_size = @intCast(style.fontsize),
            .bold = style.bold,
            .italic = style.italic,
            .underline = style.underline,
            .primary_color = style.primary_color,
            .outline_color = style.outline_color,
            .shadow_color = style.back_color,
        });
    }

    // Get script info
    if (parser.getScriptInfo()) |info| {
        result.title = info.title;
    }

    // Parse dialogues
    while (try parser.nextDialogue()) |dialogue| {
        try result.cues.append(allocator, .{
            .start_ms = dialogue.start_ms,
            .end_ms = dialogue.end_ms,
            .text = dialogue.text,
            .style_name = dialogue.style,
        });
    }

    return result;
}

/// Import TTML to universal format
pub fn importTtml(data: []const u8, allocator: Allocator) !UniversalSubtitle {
    var parser = ttml.TtmlParser.init(data, allocator);
    var result = UniversalSubtitle{};

    // Parse styles
    while (try parser.nextStyle()) |style| {
        try result.styles.append(allocator, .{
            .name = style.id,
            .font_name = style.font_family,
            .font_size = style.font_size orelse 20,
            .bold = if (style.font_weight) |w| std.mem.eql(u8, w, "bold") else false,
            .italic = if (style.font_style) |s| std.mem.eql(u8, s, "italic") else false,
            .primary_color = if (style.color) |c| parseColor(c) else 0xFFFFFFFF,
        });
    }

    // Parse cues
    while (try parser.next()) |cue| {
        try result.cues.append(allocator, .{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
            .style_name = cue.style,
        });
    }

    return result;
}

/// Auto-detect and import any subtitle format
pub fn importAuto(data: []const u8, allocator: Allocator) !UniversalSubtitle {
    return switch (detectFormat(data)) {
        .srt => importSrt(data, allocator),
        .vtt => importVtt(data, allocator),
        .ass => importAss(data, allocator),
        .ttml => importTtml(data, allocator),
        .unknown => error.UnsupportedFormat,
    };
}

// ============================================================================
// Export Functions (Universal -> Format)
// ============================================================================

/// Export universal format to SRT
pub fn exportSrt(subtitle: *const UniversalSubtitle, allocator: Allocator) ![]u8 {
    var writer = srt.SrtWriter.init(allocator);
    defer writer.deinit();

    for (subtitle.cues.items) |cue| {
        try writer.addCue(.{
            .index = 0, // Will be auto-assigned
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
        });
    }

    return writer.finalize();
}

/// Export universal format to VTT
pub fn exportVtt(subtitle: *const UniversalSubtitle, allocator: Allocator) ![]u8 {
    var writer = vtt.VttWriter.init(allocator);
    defer writer.deinit();

    for (subtitle.cues.items) |cue| {
        var settings: ?vtt.CueSettings = null;
        if (cue.position_x != null or cue.align_h != .center) {
            settings = .{
                .position = if (cue.position_x) |p| @intFromFloat(p) else null,
                .align_value = switch (cue.align_h) {
                    .left => .left,
                    .center => .center,
                    .right => .right,
                },
            };
        }

        try writer.addCue(.{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
            .settings = settings,
        });
    }

    return writer.finalize();
}

/// Export universal format to ASS
pub fn exportAss(subtitle: *const UniversalSubtitle, allocator: Allocator) ![]u8 {
    var writer = ass.AssWriter.init(allocator);
    defer writer.deinit();

    // Set script info
    try writer.setScriptInfo(.{
        .title = subtitle.title,
    });

    // Add styles
    if (subtitle.styles.items.len > 0) {
        for (subtitle.styles.items) |style| {
            try writer.addStyle(.{
                .name = style.name,
                .fontname = style.font_name orelse "Arial",
                .fontsize = style.font_size,
                .bold = style.bold,
                .italic = style.italic,
                .underline = style.underline,
                .primary_color = style.primary_color,
                .outline_color = style.outline_color,
                .back_color = style.shadow_color,
            });
        }
    } else {
        // Add default style
        try writer.addStyle(.{
            .name = "Default",
            .fontname = "Arial",
            .fontsize = 20,
        });
    }

    // Add dialogues
    for (subtitle.cues.items) |cue| {
        try writer.addDialogue(.{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
            .style = cue.style_name orelse "Default",
        });
    }

    return writer.finalize();
}

/// Export universal format to TTML
pub fn exportTtml(subtitle: *const UniversalSubtitle, allocator: Allocator) ![]u8 {
    var writer = ttml.TtmlWriter.init(allocator);
    defer writer.deinit();

    // Add styles
    for (subtitle.styles.items) |style| {
        try writer.addStyle(.{
            .id = style.name,
            .font_family = style.font_name,
            .font_size = style.font_size,
            .font_weight = if (style.bold) "bold" else null,
            .font_style = if (style.italic) "italic" else null,
            .color = formatColor(style.primary_color, allocator) catch null,
        });
    }

    // Add cues
    for (subtitle.cues.items) |cue| {
        try writer.addCue(.{
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = cue.text,
            .style = cue.style_name,
        });
    }

    return writer.finalize();
}

// ============================================================================
// Direct Conversion Functions
// ============================================================================

/// Convert SRT to VTT
pub fn srtToVtt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importSrt(data, allocator);
    defer universal.deinit(allocator);
    return exportVtt(&universal, allocator);
}

/// Convert VTT to SRT
pub fn vttToSrt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importVtt(data, allocator);
    defer universal.deinit(allocator);
    return exportSrt(&universal, allocator);
}

/// Convert SRT to ASS
pub fn srtToAss(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importSrt(data, allocator);
    defer universal.deinit(allocator);
    return exportAss(&universal, allocator);
}

/// Convert ASS to SRT
pub fn assToSrt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importAss(data, allocator);
    defer universal.deinit(allocator);
    return exportSrt(&universal, allocator);
}

/// Convert SRT to TTML
pub fn srtToTtml(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importSrt(data, allocator);
    defer universal.deinit(allocator);
    return exportTtml(&universal, allocator);
}

/// Convert TTML to SRT
pub fn ttmlToSrt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importTtml(data, allocator);
    defer universal.deinit(allocator);
    return exportSrt(&universal, allocator);
}

/// Convert VTT to ASS
pub fn vttToAss(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importVtt(data, allocator);
    defer universal.deinit(allocator);
    return exportAss(&universal, allocator);
}

/// Convert ASS to VTT
pub fn assToVtt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importAss(data, allocator);
    defer universal.deinit(allocator);
    return exportVtt(&universal, allocator);
}

/// Convert VTT to TTML
pub fn vttToTtml(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importVtt(data, allocator);
    defer universal.deinit(allocator);
    return exportTtml(&universal, allocator);
}

/// Convert TTML to VTT
pub fn ttmlToVtt(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importTtml(data, allocator);
    defer universal.deinit(allocator);
    return exportVtt(&universal, allocator);
}

/// Convert ASS to TTML
pub fn assToTtml(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importAss(data, allocator);
    defer universal.deinit(allocator);
    return exportTtml(&universal, allocator);
}

/// Convert TTML to ASS
pub fn ttmlToAss(data: []const u8, allocator: Allocator) ![]u8 {
    var universal = try importTtml(data, allocator);
    defer universal.deinit(allocator);
    return exportAss(&universal, allocator);
}

/// Convert between any formats
pub fn convert(data: []const u8, target: SubtitleFormat, allocator: Allocator) ![]u8 {
    var universal = try importAuto(data, allocator);
    defer universal.deinit(allocator);

    return switch (target) {
        .srt => exportSrt(&universal, allocator),
        .vtt => exportVtt(&universal, allocator),
        .ass => exportAss(&universal, allocator),
        .ttml => exportTtml(&universal, allocator),
        .unknown => error.UnsupportedFormat,
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

fn parseColor(color_str: []const u8) u32 {
    // Handle common color formats
    if (color_str.len == 0) return 0xFFFFFFFF;

    // Named colors
    if (std.mem.eql(u8, color_str, "white")) return 0xFFFFFFFF;
    if (std.mem.eql(u8, color_str, "black")) return 0x000000FF;
    if (std.mem.eql(u8, color_str, "red")) return 0xFF0000FF;
    if (std.mem.eql(u8, color_str, "green")) return 0x00FF00FF;
    if (std.mem.eql(u8, color_str, "blue")) return 0x0000FFFF;
    if (std.mem.eql(u8, color_str, "yellow")) return 0xFFFF00FF;
    if (std.mem.eql(u8, color_str, "cyan")) return 0x00FFFFFF;
    if (std.mem.eql(u8, color_str, "magenta")) return 0xFF00FFFF;

    // #RRGGBB format
    if (color_str[0] == '#' and color_str.len == 7) {
        const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch 255;
        const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch 255;
        const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch 255;
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | 0xFF;
    }

    // #RRGGBBAA format
    if (color_str[0] == '#' and color_str.len == 9) {
        const r = std.fmt.parseInt(u8, color_str[1..3], 16) catch 255;
        const g = std.fmt.parseInt(u8, color_str[3..5], 16) catch 255;
        const b = std.fmt.parseInt(u8, color_str[5..7], 16) catch 255;
        const a = std.fmt.parseInt(u8, color_str[7..9], 16) catch 255;
        return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | a;
    }

    return 0xFFFFFFFF;
}

fn formatColor(color: u32, allocator: Allocator) ![]const u8 {
    const r: u8 = @intCast((color >> 24) & 0xFF);
    const g: u8 = @intCast((color >> 16) & 0xFF);
    const b: u8 = @intCast((color >> 8) & 0xFF);

    return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b });
}

// ============================================================================
// Tests
// ============================================================================

test "Format detection" {
    const testing = std.testing;

    // SRT detection
    try testing.expectEqual(SubtitleFormat.srt, detectFormat("1\n00:00:00,000 --> 00:00:01,000\nHello"));

    // VTT detection
    try testing.expectEqual(SubtitleFormat.vtt, detectFormat("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello"));

    // ASS detection
    try testing.expectEqual(SubtitleFormat.ass, detectFormat("[Script Info]\nTitle: Test"));

    // TTML detection
    try testing.expectEqual(SubtitleFormat.ttml, detectFormat("<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">"));
}

test "Color parsing" {
    const testing = std.testing;

    // Named colors
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), parseColor("white"));
    try testing.expectEqual(@as(u32, 0x000000FF), parseColor("black"));
    try testing.expectEqual(@as(u32, 0xFF0000FF), parseColor("red"));

    // Hex colors
    try testing.expectEqual(@as(u32, 0xFF0000FF), parseColor("#FF0000"));
    try testing.expectEqual(@as(u32, 0x00FF00FF), parseColor("#00FF00"));
    try testing.expectEqual(@as(u32, 0x0000FFFF), parseColor("#0000FF"));
}

test "Universal cue structure" {
    const cue = UniversalCue{
        .start_ms = 1000,
        .end_ms = 2000,
        .text = "Hello, world!",
        .bold = true,
        .align_h = .center,
    };

    const testing = std.testing;
    try testing.expectEqual(@as(u64, 1000), cue.start_ms);
    try testing.expectEqual(@as(u64, 2000), cue.end_ms);
    try testing.expect(cue.bold);
    try testing.expectEqual(UniversalCue.HorizontalAlign.center, cue.align_h);
}
