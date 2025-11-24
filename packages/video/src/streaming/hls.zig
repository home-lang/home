// Home Video Library - HLS Playlist Parser
// HTTP Live Streaming (Apple HLS) M3U8 playlist parsing

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// HLS Playlist Types
// ============================================================================

pub const PlaylistType = enum {
    master, // Master playlist with variants
    media, // Media playlist with segments
};

// ============================================================================
// HLS Variant Stream (for master playlists)
// ============================================================================

pub const VariantStream = struct {
    uri: []const u8,
    bandwidth: u64,
    average_bandwidth: ?u64,
    resolution: ?Resolution,
    frame_rate: ?f32,
    codecs: ?[]const u8,
    audio: ?[]const u8, // Audio group ID
    video: ?[]const u8, // Video group ID
    subtitles: ?[]const u8, // Subtitles group ID
    closed_captions: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const Resolution = struct {
        width: u32,
        height: u32,
    };

    pub fn deinit(self: *VariantStream) void {
        self.allocator.free(self.uri);
        if (self.codecs) |c| self.allocator.free(c);
        if (self.audio) |a| self.allocator.free(a);
        if (self.video) |v| self.allocator.free(v);
        if (self.subtitles) |s| self.allocator.free(s);
        if (self.closed_captions) |c| self.allocator.free(c);
    }
};

// ============================================================================
// HLS Media Segment
// ============================================================================

pub const Segment = struct {
    uri: []const u8,
    duration: f64, // seconds
    title: ?[]const u8,
    sequence: u64,
    discontinuity: bool,
    byte_range: ?ByteRange,
    key: ?EncryptionKey,
    program_date_time: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const ByteRange = struct {
        length: u64,
        offset: ?u64,
    };

    pub fn deinit(self: *Segment) void {
        self.allocator.free(self.uri);
        if (self.title) |t| self.allocator.free(t);
        if (self.program_date_time) |p| self.allocator.free(p);
        if (self.key) |*k| k.deinit();
    }
};

// ============================================================================
// HLS Encryption Key
// ============================================================================

pub const EncryptionKey = struct {
    method: Method,
    uri: ?[]const u8,
    iv: ?[]const u8,
    key_format: ?[]const u8,
    key_format_versions: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const Method = enum {
        none,
        aes_128,
        sample_aes,
        sample_aes_ctr,
    };

    pub fn deinit(self: *EncryptionKey) void {
        if (self.uri) |u| self.allocator.free(u);
        if (self.iv) |i| self.allocator.free(i);
        if (self.key_format) |k| self.allocator.free(k);
        if (self.key_format_versions) |k| self.allocator.free(k);
    }
};

// ============================================================================
// HLS Rendition (Alternative media)
// ============================================================================

pub const Rendition = struct {
    type_: RenditionType,
    uri: ?[]const u8,
    group_id: []const u8,
    language: ?[]const u8,
    name: []const u8,
    default: bool,
    autoselect: bool,
    forced: bool,
    channels: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const RenditionType = enum { audio, video, subtitles, closed_captions };

    pub fn deinit(self: *Rendition) void {
        if (self.uri) |u| self.allocator.free(u);
        self.allocator.free(self.group_id);
        if (self.language) |l| self.allocator.free(l);
        self.allocator.free(self.name);
        if (self.channels) |c| self.allocator.free(c);
    }
};

// ============================================================================
// HLS Playlist
// ============================================================================

pub const Playlist = struct {
    playlist_type: PlaylistType,
    version: u8,
    target_duration: ?u32, // seconds
    media_sequence: u64,
    discontinuity_sequence: u64,
    end_list: bool,
    independent_segments: bool,
    // Master playlist data
    variants: std.ArrayListUnmanaged(VariantStream),
    renditions: std.ArrayListUnmanaged(Rendition),
    // Media playlist data
    segments: std.ArrayListUnmanaged(Segment),
    current_key: ?EncryptionKey,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .playlist_type = .media,
            .version = 3,
            .target_duration = null,
            .media_sequence = 0,
            .discontinuity_sequence = 0,
            .end_list = false,
            .independent_segments = false,
            .variants = .empty,
            .renditions = .empty,
            .segments = .empty,
            .current_key = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.variants.items) |*v| v.deinit();
        self.variants.deinit(self.allocator);
        for (self.renditions.items) |*r| r.deinit();
        self.renditions.deinit(self.allocator);
        for (self.segments.items) |*s| s.deinit();
        self.segments.deinit(self.allocator);
        if (self.current_key) |*k| k.deinit();
    }

    /// Parse M3U8 playlist content
    pub fn parse(self: *Self, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        // First line must be #EXTM3U
        const first_line = lines.next() orelse return VideoError.InvalidHeader;
        if (!std.mem.startsWith(u8, std.mem.trim(u8, first_line, " \t\r"), "#EXTM3U")) {
            return VideoError.InvalidHeader;
        }

        var current_duration: f64 = 0;
        var current_title: ?[]const u8 = null;
        var sequence: u64 = self.media_sequence;
        var pending_discontinuity = false;
        var pending_byte_range: ?Segment.ByteRange = null;
        var pending_program_date_time: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "#EXT-X-STREAM-INF:")) {
                // Master playlist variant
                self.playlist_type = .master;
                const attrs = trimmed[18..];
                const uri = lines.next() orelse continue;
                try self.parseVariant(attrs, std.mem.trim(u8, uri, " \t\r"));
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-MEDIA:")) {
                // Rendition
                self.playlist_type = .master;
                try self.parseRendition(trimmed[13..]);
            } else if (std.mem.startsWith(u8, trimmed, "#EXTINF:")) {
                // Media segment info
                const info = trimmed[8..];
                if (std.mem.indexOf(u8, info, ",")) |comma| {
                    current_duration = std.fmt.parseFloat(f64, info[0..comma]) catch 0;
                    if (comma + 1 < info.len) {
                        current_title = try self.allocator.dupe(u8, info[comma + 1 ..]);
                    }
                } else {
                    current_duration = std.fmt.parseFloat(f64, info) catch 0;
                }
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-VERSION:")) {
                self.version = std.fmt.parseInt(u8, trimmed[15..], 10) catch 3;
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-TARGETDURATION:")) {
                self.target_duration = std.fmt.parseInt(u32, trimmed[22..], 10) catch null;
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-MEDIA-SEQUENCE:")) {
                self.media_sequence = std.fmt.parseInt(u64, trimmed[22..], 10) catch 0;
                sequence = self.media_sequence;
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-DISCONTINUITY-SEQUENCE:")) {
                self.discontinuity_sequence = std.fmt.parseInt(u64, trimmed[30..], 10) catch 0;
            } else if (std.mem.eql(u8, trimmed, "#EXT-X-ENDLIST")) {
                self.end_list = true;
            } else if (std.mem.eql(u8, trimmed, "#EXT-X-DISCONTINUITY")) {
                pending_discontinuity = true;
            } else if (std.mem.eql(u8, trimmed, "#EXT-X-INDEPENDENT-SEGMENTS")) {
                self.independent_segments = true;
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-KEY:")) {
                try self.parseKey(trimmed[11..]);
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-BYTERANGE:")) {
                pending_byte_range = parseByteRange(trimmed[17..]);
            } else if (std.mem.startsWith(u8, trimmed, "#EXT-X-PROGRAM-DATE-TIME:")) {
                pending_program_date_time = try self.allocator.dupe(u8, trimmed[25..]);
            } else if (trimmed[0] != '#') {
                // Segment URI
                try self.segments.append(self.allocator, Segment{
                    .uri = try self.allocator.dupe(u8, trimmed),
                    .duration = current_duration,
                    .title = current_title,
                    .sequence = sequence,
                    .discontinuity = pending_discontinuity,
                    .byte_range = pending_byte_range,
                    .key = self.current_key,
                    .program_date_time = pending_program_date_time,
                    .allocator = self.allocator,
                });

                sequence += 1;
                current_duration = 0;
                current_title = null;
                pending_discontinuity = false;
                pending_byte_range = null;
                pending_program_date_time = null;
            }
        }
    }

    fn parseVariant(self: *Self, attrs: []const u8, uri: []const u8) !void {
        var variant = VariantStream{
            .uri = try self.allocator.dupe(u8, uri),
            .bandwidth = 0,
            .average_bandwidth = null,
            .resolution = null,
            .frame_rate = null,
            .codecs = null,
            .audio = null,
            .video = null,
            .subtitles = null,
            .closed_captions = null,
            .allocator = self.allocator,
        };
        errdefer variant.deinit();

        var attr_iter = AttributeIterator.init(attrs);
        while (attr_iter.next()) |attr| {
            if (std.mem.eql(u8, attr.key, "BANDWIDTH")) {
                variant.bandwidth = std.fmt.parseInt(u64, attr.value, 10) catch 0;
            } else if (std.mem.eql(u8, attr.key, "AVERAGE-BANDWIDTH")) {
                variant.average_bandwidth = std.fmt.parseInt(u64, attr.value, 10) catch null;
            } else if (std.mem.eql(u8, attr.key, "RESOLUTION")) {
                if (std.mem.indexOf(u8, attr.value, "x")) |x_pos| {
                    const w = std.fmt.parseInt(u32, attr.value[0..x_pos], 10) catch 0;
                    const h = std.fmt.parseInt(u32, attr.value[x_pos + 1 ..], 10) catch 0;
                    variant.resolution = .{ .width = w, .height = h };
                }
            } else if (std.mem.eql(u8, attr.key, "FRAME-RATE")) {
                variant.frame_rate = std.fmt.parseFloat(f32, attr.value) catch null;
            } else if (std.mem.eql(u8, attr.key, "CODECS")) {
                variant.codecs = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "AUDIO")) {
                variant.audio = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "VIDEO")) {
                variant.video = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "SUBTITLES")) {
                variant.subtitles = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "CLOSED-CAPTIONS")) {
                variant.closed_captions = try self.allocator.dupe(u8, attr.value);
            }
        }

        try self.variants.append(self.allocator, variant);
    }

    fn parseRendition(self: *Self, attrs: []const u8) !void {
        var rendition = Rendition{
            .type_ = .audio,
            .uri = null,
            .group_id = undefined,
            .language = null,
            .name = undefined,
            .default = false,
            .autoselect = false,
            .forced = false,
            .channels = null,
            .allocator = self.allocator,
        };

        var has_group_id = false;
        var has_name = false;

        var attr_iter = AttributeIterator.init(attrs);
        while (attr_iter.next()) |attr| {
            if (std.mem.eql(u8, attr.key, "TYPE")) {
                if (std.mem.eql(u8, attr.value, "AUDIO")) rendition.type_ = .audio
                else if (std.mem.eql(u8, attr.value, "VIDEO")) rendition.type_ = .video
                else if (std.mem.eql(u8, attr.value, "SUBTITLES")) rendition.type_ = .subtitles
                else if (std.mem.eql(u8, attr.value, "CLOSED-CAPTIONS")) rendition.type_ = .closed_captions;
            } else if (std.mem.eql(u8, attr.key, "URI")) {
                rendition.uri = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "GROUP-ID")) {
                rendition.group_id = try self.allocator.dupe(u8, attr.value);
                has_group_id = true;
            } else if (std.mem.eql(u8, attr.key, "LANGUAGE")) {
                rendition.language = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "NAME")) {
                rendition.name = try self.allocator.dupe(u8, attr.value);
                has_name = true;
            } else if (std.mem.eql(u8, attr.key, "DEFAULT")) {
                rendition.default = std.mem.eql(u8, attr.value, "YES");
            } else if (std.mem.eql(u8, attr.key, "AUTOSELECT")) {
                rendition.autoselect = std.mem.eql(u8, attr.value, "YES");
            } else if (std.mem.eql(u8, attr.key, "FORCED")) {
                rendition.forced = std.mem.eql(u8, attr.value, "YES");
            } else if (std.mem.eql(u8, attr.key, "CHANNELS")) {
                rendition.channels = try self.allocator.dupe(u8, attr.value);
            }
        }

        if (has_group_id and has_name) {
            try self.renditions.append(self.allocator, rendition);
        } else {
            if (rendition.uri) |u| self.allocator.free(u);
            if (has_group_id) self.allocator.free(rendition.group_id);
            if (rendition.language) |l| self.allocator.free(l);
            if (has_name) self.allocator.free(rendition.name);
            if (rendition.channels) |c| self.allocator.free(c);
        }
    }

    fn parseKey(self: *Self, attrs: []const u8) !void {
        var key = EncryptionKey{
            .method = .none,
            .uri = null,
            .iv = null,
            .key_format = null,
            .key_format_versions = null,
            .allocator = self.allocator,
        };

        var attr_iter = AttributeIterator.init(attrs);
        while (attr_iter.next()) |attr| {
            if (std.mem.eql(u8, attr.key, "METHOD")) {
                if (std.mem.eql(u8, attr.value, "NONE")) key.method = .none
                else if (std.mem.eql(u8, attr.value, "AES-128")) key.method = .aes_128
                else if (std.mem.eql(u8, attr.value, "SAMPLE-AES")) key.method = .sample_aes
                else if (std.mem.eql(u8, attr.value, "SAMPLE-AES-CTR")) key.method = .sample_aes_ctr;
            } else if (std.mem.eql(u8, attr.key, "URI")) {
                key.uri = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "IV")) {
                key.iv = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "KEYFORMAT")) {
                key.key_format = try self.allocator.dupe(u8, attr.value);
            } else if (std.mem.eql(u8, attr.key, "KEYFORMATVERSIONS")) {
                key.key_format_versions = try self.allocator.dupe(u8, attr.value);
            }
        }

        if (self.current_key) |*k| k.deinit();
        self.current_key = key;
    }

    /// Get total duration of media playlist
    pub fn getDuration(self: *const Self) f64 {
        var total: f64 = 0;
        for (self.segments.items) |seg| {
            total += seg.duration;
        }
        return total;
    }

    /// Get variant by bandwidth
    pub fn getVariantByBandwidth(self: *const Self, target_bandwidth: u64) ?*const VariantStream {
        var best: ?*const VariantStream = null;
        var best_diff: u64 = std.math.maxInt(u64);

        for (self.variants.items) |*v| {
            const diff = if (v.bandwidth > target_bandwidth)
                v.bandwidth - target_bandwidth
            else
                target_bandwidth - v.bandwidth;

            if (diff < best_diff) {
                best_diff = diff;
                best = v;
            }
        }
        return best;
    }

    /// Get best quality variant
    pub fn getBestVariant(self: *const Self) ?*const VariantStream {
        var best: ?*const VariantStream = null;
        var best_bandwidth: u64 = 0;

        for (self.variants.items) |*v| {
            if (v.bandwidth > best_bandwidth) {
                best_bandwidth = v.bandwidth;
                best = v;
            }
        }
        return best;
    }
};

// ============================================================================
// Helper Types
// ============================================================================

const AttributeIterator = struct {
    data: []const u8,
    pos: usize,

    const Attribute = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(data: []const u8) AttributeIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *AttributeIterator) ?Attribute {
        while (self.pos < self.data.len and (self.data[self.pos] == ',' or self.data[self.pos] == ' ')) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return null;

        const key_start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '=') {
            self.pos += 1;
        }
        if (self.pos >= self.data.len) return null;

        const key = self.data[key_start..self.pos];
        self.pos += 1; // Skip '='

        if (self.pos >= self.data.len) return null;

        var value_start = self.pos;
        var value_end: usize = undefined;

        if (self.data[self.pos] == '"') {
            // Quoted value
            self.pos += 1;
            value_start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != '"') {
                self.pos += 1;
            }
            value_end = self.pos;
            if (self.pos < self.data.len) self.pos += 1; // Skip closing quote
        } else {
            // Unquoted value
            while (self.pos < self.data.len and self.data[self.pos] != ',') {
                self.pos += 1;
            }
            value_end = self.pos;
        }

        return Attribute{
            .key = key,
            .value = self.data[value_start..value_end],
        };
    }
};

fn parseByteRange(s: []const u8) ?Segment.ByteRange {
    if (std.mem.indexOf(u8, s, "@")) |at_pos| {
        const length = std.fmt.parseInt(u64, s[0..at_pos], 10) catch return null;
        const offset = std.fmt.parseInt(u64, s[at_pos + 1 ..], 10) catch return null;
        return .{ .length = length, .offset = offset };
    } else {
        const length = std.fmt.parseInt(u64, s, 10) catch return null;
        return .{ .length = length, .offset = null };
    }
}

/// Check if content is an HLS playlist
pub fn isHls(data: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, data, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "#EXTM3U");
}

// ============================================================================
// Tests
// ============================================================================

test "Playlist parse master" {
    const allocator = std.testing.allocator;

    const master_content =
        \\#EXTM3U
        \\#EXT-X-VERSION:3
        \\#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        \\low/index.m3u8
        \\#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720
        \\mid/index.m3u8
        \\#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080
        \\high/index.m3u8
    ;

    var playlist = Playlist.init(allocator);
    defer playlist.deinit();

    try playlist.parse(master_content);

    try std.testing.expectEqual(PlaylistType.master, playlist.playlist_type);
    try std.testing.expectEqual(@as(usize, 3), playlist.variants.items.len);
    try std.testing.expectEqual(@as(u64, 800000), playlist.variants.items[0].bandwidth);
    try std.testing.expectEqual(@as(u32, 1920), playlist.variants.items[2].resolution.?.width);
}

test "Playlist parse media" {
    const allocator = std.testing.allocator;

    const media_content =
        \\#EXTM3U
        \\#EXT-X-VERSION:3
        \\#EXT-X-TARGETDURATION:10
        \\#EXT-X-MEDIA-SEQUENCE:0
        \\#EXTINF:10.0,
        \\segment0.ts
        \\#EXTINF:10.0,
        \\segment1.ts
        \\#EXTINF:5.0,
        \\segment2.ts
        \\#EXT-X-ENDLIST
    ;

    var playlist = Playlist.init(allocator);
    defer playlist.deinit();

    try playlist.parse(media_content);

    try std.testing.expectEqual(PlaylistType.media, playlist.playlist_type);
    try std.testing.expectEqual(@as(usize, 3), playlist.segments.items.len);
    try std.testing.expectEqual(@as(f64, 10.0), playlist.segments.items[0].duration);
    try std.testing.expect(playlist.end_list);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), playlist.getDuration(), 0.01);
}

test "isHls" {
    try std.testing.expect(isHls("#EXTM3U\n#EXT-X-VERSION:3"));
    try std.testing.expect(isHls("  #EXTM3U\n"));
    try std.testing.expect(!isHls("<?xml version=\"1.0\"?>"));
}

test "AttributeIterator" {
    var iter = AttributeIterator.init("BANDWIDTH=800000,RESOLUTION=640x360,CODECS=\"avc1.4d401e\"");

    const attr1 = iter.next().?;
    try std.testing.expectEqualStrings("BANDWIDTH", attr1.key);
    try std.testing.expectEqualStrings("800000", attr1.value);

    const attr2 = iter.next().?;
    try std.testing.expectEqualStrings("RESOLUTION", attr2.key);
    try std.testing.expectEqualStrings("640x360", attr2.value);

    const attr3 = iter.next().?;
    try std.testing.expectEqualStrings("CODECS", attr3.key);
    try std.testing.expectEqualStrings("avc1.4d401e", attr3.value);

    try std.testing.expect(iter.next() == null);
}
