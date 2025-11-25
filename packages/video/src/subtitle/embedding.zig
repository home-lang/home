// Home Video Library - Subtitle Embedding
// Encode subtitles for container embedding (MP4, MKV, WebM)

const std = @import("std");
const subtitle = @import("subtitle.zig");
const types = @import("../core/types.zig");

pub const SubtitleTrack = subtitle.SubtitleTrack;
pub const SubtitleEntry = subtitle.SubtitleEntry;
pub const Timestamp = subtitle.Timestamp;

// ============================================================================
// Subtitle Codec
// ============================================================================

pub const SubtitleCodec = enum {
    mov_text, // MP4/MOV text tracks (3GPP Timed Text)
    srt, // SRT in container
    ass, // ASS/SSA in container
    webvtt, // WebVTT in WebM
    dvd_sub, // DVD bitmap subtitles
    pgs, // Blu-ray PGS subtitles
    subrip, // SubRip text

    pub fn toString(self: SubtitleCodec) []const u8 {
        return switch (self) {
            .mov_text => "mov_text",
            .srt => "srt",
            .ass => "ass",
            .webvtt => "webvtt",
            .dvd_sub => "dvdsub",
            .pgs => "hdmv_pgs_subtitle",
            .subrip => "subrip",
        };
    }

    pub fn isTextBased(self: SubtitleCodec) bool {
        return switch (self) {
            .mov_text, .srt, .ass, .webvtt, .subrip => true,
            .dvd_sub, .pgs => false,
        };
    }

    pub fn bestForContainer(container: types.VideoFormat) SubtitleCodec {
        return switch (container) {
            .mp4, .mov => .mov_text,
            .mkv => .ass,
            .webm => .webvtt,
            .avi => .srt,
            else => .srt,
        };
    }
};

// ============================================================================
// Subtitle Packet
// ============================================================================

pub const SubtitlePacket = struct {
    data: []const u8,
    pts: Timestamp,
    duration: ?Timestamp = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        data: []const u8,
        pts: Timestamp,
        duration: ?Timestamp,
    ) !Self {
        return .{
            .data = try allocator.dupe(u8, data),
            .pts = pts,
            .duration = duration,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }
};

// ============================================================================
// MP4 Text Track Encoder (3GPP Timed Text)
// ============================================================================

pub const MovTextEncoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Encode subtitle entry to mov_text packet
    pub fn encode(self: *Self, entry: *const SubtitleEntry) !SubtitlePacket {
        // mov_text format:
        // 2 bytes: text length
        // N bytes: UTF-8 text
        // Optional: modifier boxes for styling

        const text_len: u16 = @intCast(entry.text.len);
        var data = std.ArrayList(u8).init(self.allocator);
        errdefer data.deinit();

        // Write text length (big-endian)
        try data.append(@truncate(text_len >> 8));
        try data.append(@truncate(text_len & 0xFF));

        // Write text
        try data.appendSlice(entry.text);

        // TODO: Add style/formatting boxes if entry.style is set

        const duration = Timestamp.fromMicroseconds(
            entry.end.toMicroseconds() - entry.start.toMicroseconds(),
        );

        return SubtitlePacket{
            .data = try data.toOwnedSlice(),
            .pts = entry.start,
            .duration = duration,
            .allocator = self.allocator,
        };
    }

    /// Encode entire track
    pub fn encodeTrack(
        self: *Self,
        track: *const SubtitleTrack,
    ) !std.ArrayList(SubtitlePacket) {
        var packets = std.ArrayList(SubtitlePacket).init(self.allocator);
        errdefer {
            for (packets.items) |*pkt| pkt.deinit();
            packets.deinit();
        }

        for (track.entries.items) |*entry| {
            const packet = try self.encode(entry);
            try packets.append(packet);
        }

        return packets;
    }
};

// ============================================================================
// WebVTT Encoder (for WebM)
// ============================================================================

pub const WebVTTContainerEncoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Encode subtitle entry to WebVTT packet
    pub fn encode(self: *Self, entry: *const SubtitleEntry) !SubtitlePacket {
        // WebVTT in WebM uses raw text without timestamps
        // Timestamps are handled by container

        const data = try self.allocator.dupe(u8, entry.text);

        const duration = Timestamp.fromMicroseconds(
            entry.end.toMicroseconds() - entry.start.toMicroseconds(),
        );

        return SubtitlePacket{
            .data = data,
            .pts = entry.start,
            .duration = duration,
            .allocator = self.allocator,
        };
    }

    pub fn encodeTrack(
        self: *Self,
        track: *const SubtitleTrack,
    ) !std.ArrayList(SubtitlePacket) {
        var packets = std.ArrayList(SubtitlePacket).init(self.allocator);
        errdefer {
            for (packets.items) |*pkt| pkt.deinit();
            packets.deinit();
        }

        for (track.entries.items) |*entry| {
            const packet = try self.encode(entry);
            try packets.append(packet);
        }

        return packets;
    }

    /// Generate WebVTT header for container
    pub fn generateHeader(self: *Self) ![]u8 {
        // WebVTT header for WebM
        return try self.allocator.dupe(u8, "WEBVTT\n\n");
    }
};

// ============================================================================
// ASS/SSA Encoder (for MKV)
// ============================================================================

pub const ASSEncoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Generate ASS header
    pub fn generateHeader(self: *Self, track: *const SubtitleTrack) ![]u8 {
        var header = std.ArrayList(u8).init(self.allocator);
        errdefer header.deinit();

        const writer = header.writer();

        // Script Info section
        try writer.writeAll("[Script Info]\n");
        try writer.writeAll("ScriptType: v4.00+\n");
        try writer.writeAll("PlayResX: 1920\n");
        try writer.writeAll("PlayResY: 1080\n");

        if (track.title) |title| {
            try writer.print("Title: {s}\n", .{title});
        }

        try writer.writeAll("\n[V4+ Styles]\n");
        try writer.writeAll("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n");

        // Default style
        const style = &track.default_style;
        const font = style.font_name orelse "Arial";

        try writer.print(
            "Style: Default,{s},{d},&H{X:0>8},&H{X:0>8},&H{X:0>8},&H{X:0>8},{d},{d},{d},{d},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d:.2},{d:.2},{d},{d},{d},{d},1\n",
            .{
                font,
                style.font_size,
                style.primary_color.toHex(),
                style.secondary_color.toHex(),
                style.outline_color.toHex(),
                style.back_color.toHex(),
                @as(i32, if (style.bold) -1 else 0),
                @as(i32, if (style.italic) -1 else 0),
                @as(i32, if (style.underline) -1 else 0),
                @as(i32, if (style.strikeout) -1 else 0),
                style.scale_x,
                style.scale_y,
                style.spacing,
                style.angle,
                @intFromEnum(style.border_style),
                style.outline,
                style.shadow,
                @intFromEnum(style.alignment),
                style.margin_left,
                style.margin_right,
                style.margin_vertical,
            },
        );

        try writer.writeAll("\n[Events]\n");
        try writer.writeAll("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n");

        return header.toOwnedSlice();
    }

    /// Encode subtitle entry to ASS dialogue line
    pub fn encode(self: *Self, entry: *const SubtitleEntry) !SubtitlePacket {
        var data = std.ArrayList(u8).init(self.allocator);
        errdefer data.deinit();

        const start_time = try self.formatASSTime(entry.start);
        defer self.allocator.free(start_time);
        const end_time = try self.formatASSTime(entry.end);
        defer self.allocator.free(end_time);

        const layer = if (entry.position) |pos| pos.layer else 0;

        try data.writer().print(
            "Dialogue: {d},{s},{s},Default,,0,0,0,,{s}",
            .{ layer, start_time, end_time, entry.text },
        );

        const duration = Timestamp.fromMicroseconds(
            entry.end.toMicroseconds() - entry.start.toMicroseconds(),
        );

        return SubtitlePacket{
            .data = try data.toOwnedSlice(),
            .pts = entry.start,
            .duration = duration,
            .allocator = self.allocator,
        };
    }

    fn formatASSTime(self: *Self, ts: Timestamp) ![]u8 {
        const us = ts.toMicroseconds();
        const hours = us / 3_600_000_000;
        const minutes = (us / 60_000_000) % 60;
        const seconds = (us / 1_000_000) % 60;
        const centiseconds = (us / 10_000) % 100;

        return try std.fmt.allocPrint(
            self.allocator,
            "{d}:{d:0>2}:{d:0>2}.{d:0>2}",
            .{ hours, minutes, seconds, centiseconds },
        );
    }

    pub fn encodeTrack(
        self: *Self,
        track: *const SubtitleTrack,
    ) !std.ArrayList(SubtitlePacket) {
        var packets = std.ArrayList(SubtitlePacket).init(self.allocator);
        errdefer {
            for (packets.items) |*pkt| pkt.deinit();
            packets.deinit();
        }

        for (track.entries.items) |*entry| {
            const packet = try self.encode(entry);
            try packets.append(packet);
        }

        return packets;
    }
};

// ============================================================================
// SRT Encoder (for MKV/AVI)
// ============================================================================

pub const SRTContainerEncoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Encode subtitle entry to SRT packet (just the text)
    pub fn encode(self: *Self, entry: *const SubtitleEntry) !SubtitlePacket {
        // When embedded in container, SRT just stores the text
        // The container handles timing
        const data = try self.allocator.dupe(u8, entry.text);

        const duration = Timestamp.fromMicroseconds(
            entry.end.toMicroseconds() - entry.start.toMicroseconds(),
        );

        return SubtitlePacket{
            .data = data,
            .pts = entry.start,
            .duration = duration,
            .allocator = self.allocator,
        };
    }

    pub fn encodeTrack(
        self: *Self,
        track: *const SubtitleTrack,
    ) !std.ArrayList(SubtitlePacket) {
        var packets = std.ArrayList(SubtitlePacket).init(self.allocator);
        errdefer {
            for (packets.items) |*pkt| pkt.deinit();
            packets.deinit();
        }

        for (track.entries.items) |*entry| {
            const packet = try self.encode(entry);
            try packets.append(packet);
        }

        return packets;
    }
};

// ============================================================================
// Subtitle Embedder
// ============================================================================

pub const SubtitleEmbedder = struct {
    allocator: std.mem.Allocator,
    codec: SubtitleCodec,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, codec: SubtitleCodec) Self {
        return .{
            .allocator = allocator,
            .codec = codec,
        };
    }

    pub fn encodeTrack(
        self: *Self,
        track: *const SubtitleTrack,
    ) !std.ArrayList(SubtitlePacket) {
        return switch (self.codec) {
            .mov_text => blk: {
                var encoder = MovTextEncoder.init(self.allocator);
                break :blk try encoder.encodeTrack(track);
            },
            .webvtt => blk: {
                var encoder = WebVTTContainerEncoder.init(self.allocator);
                break :blk try encoder.encodeTrack(track);
            },
            .ass, .ssa => blk: {
                var encoder = ASSEncoder.init(self.allocator);
                break :blk try encoder.encodeTrack(track);
            },
            .srt, .subrip => blk: {
                var encoder = SRTContainerEncoder.init(self.allocator);
                break :blk try encoder.encodeTrack(track);
            },
            else => error.UnsupportedCodec,
        };
    }

    pub fn generateHeader(self: *Self, track: *const SubtitleTrack) !?[]u8 {
        return switch (self.codec) {
            .webvtt => blk: {
                var encoder = WebVTTContainerEncoder.init(self.allocator);
                break :blk try encoder.generateHeader();
            },
            .ass, .ssa => blk: {
                var encoder = ASSEncoder.init(self.allocator);
                break :blk try encoder.generateHeader(track);
            },
            else => null,
        };
    }
};

// ============================================================================
// Subtitle Track Info
// ============================================================================

pub const SubtitleTrackInfo = struct {
    codec: SubtitleCodec,
    language: ?[]const u8 = null,
    title: ?[]const u8 = null,
    default: bool = false,
    forced: bool = false,
    hearing_impaired: bool = false,

    pub fn format(self: *const SubtitleTrackInfo, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try result.writer().print("Codec: {s}\n", .{self.codec.toString()});

        if (self.language) |lang| {
            try result.writer().print("Language: {s}\n", .{lang});
        }

        if (self.title) |title| {
            try result.writer().print("Title: {s}\n", .{title});
        }

        if (self.default) {
            try result.appendSlice("Default: yes\n");
        }

        if (self.forced) {
            try result.appendSlice("Forced: yes\n");
        }

        if (self.hearing_impaired) {
            try result.appendSlice("Hearing Impaired: yes\n");
        }

        return result.toOwnedSlice();
    }
};
