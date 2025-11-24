// Home Video Library - DASH Manifest Parser
// Dynamic Adaptive Streaming over HTTP (MPEG-DASH) MPD parsing

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// DASH Manifest Types
// ============================================================================

pub const ManifestType = enum {
    static, // VOD content
    dynamic, // Live content
};

// ============================================================================
// DASH Period
// ============================================================================

pub const Period = struct {
    id: ?[]const u8,
    start: ?u64, // milliseconds
    duration: ?u64, // milliseconds
    adaptation_sets: std.ArrayListUnmanaged(AdaptationSet),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Period) void {
        if (self.id) |id| self.allocator.free(id);
        for (self.adaptation_sets.items) |*as| as.deinit();
        self.adaptation_sets.deinit(self.allocator);
    }
};

// ============================================================================
// DASH Adaptation Set
// ============================================================================

pub const AdaptationSet = struct {
    id: ?u32,
    content_type: ?ContentType,
    mime_type: ?[]const u8,
    codecs: ?[]const u8,
    lang: ?[]const u8,
    segment_alignment: bool,
    subsegment_alignment: bool,
    representations: std.ArrayListUnmanaged(Representation),
    segment_template: ?SegmentTemplate,
    allocator: std.mem.Allocator,

    pub const ContentType = enum { video, audio, text, image };

    pub fn deinit(self: *AdaptationSet) void {
        if (self.mime_type) |m| self.allocator.free(m);
        if (self.codecs) |c| self.allocator.free(c);
        if (self.lang) |l| self.allocator.free(l);
        for (self.representations.items) |*r| r.deinit();
        self.representations.deinit(self.allocator);
        if (self.segment_template) |*st| st.deinit();
    }
};

// ============================================================================
// DASH Representation
// ============================================================================

pub const Representation = struct {
    id: []const u8,
    bandwidth: u64,
    width: ?u32,
    height: ?u32,
    frame_rate: ?[]const u8,
    codecs: ?[]const u8,
    mime_type: ?[]const u8,
    audio_sampling_rate: ?u32,
    segment_template: ?SegmentTemplate,
    base_url: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Representation) void {
        self.allocator.free(self.id);
        if (self.frame_rate) |f| self.allocator.free(f);
        if (self.codecs) |c| self.allocator.free(c);
        if (self.mime_type) |m| self.allocator.free(m);
        if (self.segment_template) |*st| st.deinit();
        if (self.base_url) |b| self.allocator.free(b);
    }
};

// ============================================================================
// DASH Segment Template
// ============================================================================

pub const SegmentTemplate = struct {
    media: ?[]const u8, // URL template with $variables$
    initialization: ?[]const u8,
    timescale: u64,
    duration: ?u64,
    start_number: u64,
    timeline: std.ArrayListUnmanaged(SegmentTimeline),
    allocator: std.mem.Allocator,

    pub const SegmentTimeline = struct {
        start: ?u64,
        duration: u64,
        repeat: i32, // -1 means repeat indefinitely
    };

    pub fn deinit(self: *SegmentTemplate) void {
        if (self.media) |m| self.allocator.free(m);
        if (self.initialization) |i| self.allocator.free(i);
        self.timeline.deinit(self.allocator);
    }

    /// Get segment URL for given segment number and representation
    pub fn getSegmentUrl(self: *const SegmentTemplate, allocator: std.mem.Allocator, segment_number: u64, repr_id: []const u8, bandwidth: u64) ![]u8 {
        const template = self.media orelse return VideoError.InvalidHeader;

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '$') {
                const var_start = i + 1;
                i += 1;
                while (i < template.len and template[i] != '$') i += 1;
                const var_name = template[var_start..i];
                i += 1; // Skip closing $

                // Replace variable
                if (std.mem.startsWith(u8, var_name, "Number")) {
                    // Handle format specifier like $Number%05d$
                    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{segment_number});
                    defer allocator.free(num_str);
                    try result.appendSlice(allocator, num_str);
                } else if (std.mem.eql(u8, var_name, "RepresentationID")) {
                    try result.appendSlice(allocator, repr_id);
                } else if (std.mem.eql(u8, var_name, "Bandwidth")) {
                    const bw_str = try std.fmt.allocPrint(allocator, "{d}", .{bandwidth});
                    defer allocator.free(bw_str);
                    try result.appendSlice(allocator, bw_str);
                } else if (std.mem.startsWith(u8, var_name, "Time")) {
                    // Calculate time based on segment number
                    const time = (segment_number - self.start_number) * (self.duration orelse 0);
                    const time_str = try std.fmt.allocPrint(allocator, "{d}", .{time});
                    defer allocator.free(time_str);
                    try result.appendSlice(allocator, time_str);
                }
            } else {
                try result.append(allocator, template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// DASH Manifest
// ============================================================================

pub const Manifest = struct {
    manifest_type: ManifestType,
    min_buffer_time: ?u64, // milliseconds
    media_presentation_duration: ?u64, // milliseconds
    min_update_period: ?u64, // milliseconds (for live)
    availability_start_time: ?[]const u8,
    publish_time: ?[]const u8,
    periods: std.ArrayListUnmanaged(Period),
    base_url: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .manifest_type = .static,
            .min_buffer_time = null,
            .media_presentation_duration = null,
            .min_update_period = null,
            .availability_start_time = null,
            .publish_time = null,
            .periods = .empty,
            .base_url = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.availability_start_time) |a| self.allocator.free(a);
        if (self.publish_time) |p| self.allocator.free(p);
        if (self.base_url) |b| self.allocator.free(b);
        for (self.periods.items) |*p| p.deinit();
        self.periods.deinit(self.allocator);
    }

    /// Parse DASH MPD manifest
    pub fn parse(self: *Self, content: []const u8) !void {
        // Find <MPD> element
        const mpd_start = std.mem.indexOf(u8, content, "<MPD") orelse return VideoError.InvalidHeader;
        const mpd_tag_end = std.mem.indexOfScalarPos(u8, content, mpd_start, '>') orelse return VideoError.InvalidHeader;
        const mpd_attrs = content[mpd_start + 4 .. mpd_tag_end];

        // Parse MPD attributes
        if (getAttributeValue(mpd_attrs, "type")) |t| {
            if (std.mem.eql(u8, t, "dynamic")) {
                self.manifest_type = .dynamic;
            }
        }
        if (getAttributeValue(mpd_attrs, "minBufferTime")) |mbt| {
            self.min_buffer_time = parseDuration(mbt);
        }
        if (getAttributeValue(mpd_attrs, "mediaPresentationDuration")) |mpd| {
            self.media_presentation_duration = parseDuration(mpd);
        }
        if (getAttributeValue(mpd_attrs, "minimumUpdatePeriod")) |mup| {
            self.min_update_period = parseDuration(mup);
        }
        if (getAttributeValue(mpd_attrs, "availabilityStartTime")) |ast| {
            self.availability_start_time = try self.allocator.dupe(u8, ast);
        }

        // Find BaseURL
        if (std.mem.indexOf(u8, content, "<BaseURL>")) |base_start| {
            if (std.mem.indexOfPos(u8, content, base_start, "</BaseURL>")) |base_end| {
                const url = content[base_start + 9 .. base_end];
                self.base_url = try self.allocator.dupe(u8, std.mem.trim(u8, url, " \t\r\n"));
            }
        }

        // Parse Periods
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<Period")) |period_start| {
            const period_end = findClosingTag(content, period_start, "Period") orelse break;
            try self.parsePeriod(content[period_start..period_end]);
            pos = period_end;
        }
    }

    fn parsePeriod(self: *Self, content: []const u8) !void {
        var period = Period{
            .id = null,
            .start = null,
            .duration = null,
            .adaptation_sets = .empty,
            .allocator = self.allocator,
        };
        errdefer period.deinit();

        // Parse Period attributes
        const tag_end = std.mem.indexOfScalar(u8, content, '>') orelse return;
        const attrs = content[7..tag_end];

        if (getAttributeValue(attrs, "id")) |id| {
            period.id = try self.allocator.dupe(u8, id);
        }
        if (getAttributeValue(attrs, "start")) |start| {
            period.start = parseDuration(start);
        }
        if (getAttributeValue(attrs, "duration")) |dur| {
            period.duration = parseDuration(dur);
        }

        // Parse AdaptationSets
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<AdaptationSet")) |as_start| {
            const as_end = findClosingTag(content, as_start, "AdaptationSet") orelse break;
            try self.parseAdaptationSet(content[as_start..as_end], &period);
            pos = as_end;
        }

        try self.periods.append(self.allocator, period);
    }

    fn parseAdaptationSet(self: *Self, content: []const u8, period: *Period) !void {
        var adaptation_set = AdaptationSet{
            .id = null,
            .content_type = null,
            .mime_type = null,
            .codecs = null,
            .lang = null,
            .segment_alignment = false,
            .subsegment_alignment = false,
            .representations = .empty,
            .segment_template = null,
            .allocator = self.allocator,
        };
        errdefer adaptation_set.deinit();

        // Parse attributes
        const tag_end = std.mem.indexOfScalar(u8, content, '>') orelse return;
        const attrs = content[14..tag_end];

        if (getAttributeValue(attrs, "id")) |id| {
            adaptation_set.id = std.fmt.parseInt(u32, id, 10) catch null;
        }
        if (getAttributeValue(attrs, "contentType")) |ct| {
            if (std.mem.eql(u8, ct, "video")) adaptation_set.content_type = .video
            else if (std.mem.eql(u8, ct, "audio")) adaptation_set.content_type = .audio
            else if (std.mem.eql(u8, ct, "text")) adaptation_set.content_type = .text;
        }
        if (getAttributeValue(attrs, "mimeType")) |mt| {
            adaptation_set.mime_type = try self.allocator.dupe(u8, mt);
            // Infer content type from mime type
            if (adaptation_set.content_type == null) {
                if (std.mem.startsWith(u8, mt, "video/")) adaptation_set.content_type = .video
                else if (std.mem.startsWith(u8, mt, "audio/")) adaptation_set.content_type = .audio
                else if (std.mem.startsWith(u8, mt, "text/")) adaptation_set.content_type = .text;
            }
        }
        if (getAttributeValue(attrs, "codecs")) |c| {
            adaptation_set.codecs = try self.allocator.dupe(u8, c);
        }
        if (getAttributeValue(attrs, "lang")) |l| {
            adaptation_set.lang = try self.allocator.dupe(u8, l);
        }
        if (getAttributeValue(attrs, "segmentAlignment")) |sa| {
            adaptation_set.segment_alignment = std.mem.eql(u8, sa, "true");
        }

        // Parse SegmentTemplate at AdaptationSet level
        if (std.mem.indexOf(u8, content, "<SegmentTemplate")) |st_start| {
            const st_end = findClosingTagOrSelfClose(content, st_start, "SegmentTemplate") orelse st_start;
            adaptation_set.segment_template = try self.parseSegmentTemplate(content[st_start..st_end]);
        }

        // Parse Representations
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "<Representation")) |rep_start| {
            const rep_end = findClosingTag(content, rep_start, "Representation") orelse
                (std.mem.indexOfPos(u8, content, rep_start, "/>") orelse break) + 2;
            try self.parseRepresentation(content[rep_start..rep_end], &adaptation_set);
            pos = rep_end;
        }

        try period.adaptation_sets.append(self.allocator, adaptation_set);
    }

    fn parseRepresentation(self: *Self, content: []const u8, as: *AdaptationSet) !void {
        const tag_end = std.mem.indexOfScalar(u8, content, '>') orelse
            std.mem.indexOf(u8, content, "/>") orelse return;
        const attrs = content[15..tag_end];

        const id = getAttributeValue(attrs, "id") orelse return;

        var repr = Representation{
            .id = try self.allocator.dupe(u8, id),
            .bandwidth = 0,
            .width = null,
            .height = null,
            .frame_rate = null,
            .codecs = null,
            .mime_type = null,
            .audio_sampling_rate = null,
            .segment_template = null,
            .base_url = null,
            .allocator = self.allocator,
        };
        errdefer repr.deinit();

        if (getAttributeValue(attrs, "bandwidth")) |bw| {
            repr.bandwidth = std.fmt.parseInt(u64, bw, 10) catch 0;
        }
        if (getAttributeValue(attrs, "width")) |w| {
            repr.width = std.fmt.parseInt(u32, w, 10) catch null;
        }
        if (getAttributeValue(attrs, "height")) |h| {
            repr.height = std.fmt.parseInt(u32, h, 10) catch null;
        }
        if (getAttributeValue(attrs, "frameRate")) |fr| {
            repr.frame_rate = try self.allocator.dupe(u8, fr);
        }
        if (getAttributeValue(attrs, "codecs")) |c| {
            repr.codecs = try self.allocator.dupe(u8, c);
        }
        if (getAttributeValue(attrs, "mimeType")) |mt| {
            repr.mime_type = try self.allocator.dupe(u8, mt);
        }
        if (getAttributeValue(attrs, "audioSamplingRate")) |asr| {
            repr.audio_sampling_rate = std.fmt.parseInt(u32, asr, 10) catch null;
        }

        // Check for BaseURL
        if (std.mem.indexOf(u8, content, "<BaseURL>")) |base_start| {
            if (std.mem.indexOfPos(u8, content, base_start, "</BaseURL>")) |base_end| {
                repr.base_url = try self.allocator.dupe(u8, std.mem.trim(u8, content[base_start + 9 .. base_end], " \t\r\n"));
            }
        }

        try as.representations.append(self.allocator, repr);
    }

    fn parseSegmentTemplate(self: *Self, content: []const u8) !SegmentTemplate {
        const tag_end = std.mem.indexOfScalar(u8, content, '>') orelse content.len;
        const attrs = content[16..tag_end];

        var st = SegmentTemplate{
            .media = null,
            .initialization = null,
            .timescale = 1,
            .duration = null,
            .start_number = 1,
            .timeline = .empty,
            .allocator = self.allocator,
        };

        if (getAttributeValue(attrs, "media")) |m| {
            st.media = try self.allocator.dupe(u8, m);
        }
        if (getAttributeValue(attrs, "initialization")) |i| {
            st.initialization = try self.allocator.dupe(u8, i);
        }
        if (getAttributeValue(attrs, "timescale")) |ts| {
            st.timescale = std.fmt.parseInt(u64, ts, 10) catch 1;
        }
        if (getAttributeValue(attrs, "duration")) |d| {
            st.duration = std.fmt.parseInt(u64, d, 10) catch null;
        }
        if (getAttributeValue(attrs, "startNumber")) |sn| {
            st.start_number = std.fmt.parseInt(u64, sn, 10) catch 1;
        }

        // Parse SegmentTimeline if present
        if (std.mem.indexOf(u8, content, "<SegmentTimeline>")) |tl_start| {
            if (std.mem.indexOfPos(u8, content, tl_start, "</SegmentTimeline>")) |tl_end| {
                const timeline_content = content[tl_start..tl_end];
                var pos: usize = 0;

                while (std.mem.indexOfPos(u8, timeline_content, pos, "<S ")) |s_start| {
                    const s_end = std.mem.indexOfPos(u8, timeline_content, s_start, "/>") orelse break;
                    const s_attrs = timeline_content[s_start + 3 .. s_end];

                    var seg = SegmentTemplate.SegmentTimeline{
                        .start = null,
                        .duration = 0,
                        .repeat = 0,
                    };

                    if (getAttributeValue(s_attrs, "t")) |t| {
                        seg.start = std.fmt.parseInt(u64, t, 10) catch null;
                    }
                    if (getAttributeValue(s_attrs, "d")) |d| {
                        seg.duration = std.fmt.parseInt(u64, d, 10) catch 0;
                    }
                    if (getAttributeValue(s_attrs, "r")) |r| {
                        seg.repeat = std.fmt.parseInt(i32, r, 10) catch 0;
                    }

                    try st.timeline.append(self.allocator, seg);
                    pos = s_end + 2;
                }
            }
        }

        return st;
    }

    /// Get total duration in milliseconds
    pub fn getDuration(self: *const Self) u64 {
        if (self.media_presentation_duration) |d| return d;

        var total: u64 = 0;
        for (self.periods.items) |p| {
            if (p.duration) |d| total += d;
        }
        return total;
    }

    /// Get video adaptation sets
    pub fn getVideoAdaptationSets(self: *const Self, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(*const AdaptationSet) {
        var result: std.ArrayListUnmanaged(*const AdaptationSet) = .empty;
        for (self.periods.items) |*p| {
            for (p.adaptation_sets.items) |*as| {
                if (as.content_type == .video) {
                    try result.append(allocator, as);
                }
            }
        }
        return result;
    }

    /// Get audio adaptation sets
    pub fn getAudioAdaptationSets(self: *const Self, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(*const AdaptationSet) {
        var result: std.ArrayListUnmanaged(*const AdaptationSet) = .empty;
        for (self.periods.items) |*p| {
            for (p.adaptation_sets.items) |*as| {
                if (as.content_type == .audio) {
                    try result.append(allocator, as);
                }
            }
        }
        return result;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getAttributeValue(tag: []const u8, attr_name: []const u8) ?[]const u8 {
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search_pos, attr_name)) |attr_start| {
        const after_name = attr_start + attr_name.len;
        if (after_name >= tag.len) return null;

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

fn findClosingTag(content: []const u8, start: usize, tag_name: []const u8) ?usize {
    var search_str: [32]u8 = undefined;
    const close_tag = std.fmt.bufPrint(&search_str, "</{s}>", .{tag_name}) catch return null;
    if (std.mem.indexOfPos(u8, content, start, close_tag)) |pos| {
        return pos + close_tag.len;
    }
    return null;
}

fn findClosingTagOrSelfClose(content: []const u8, start: usize, tag_name: []const u8) ?usize {
    // Check for self-closing first
    const tag_end = std.mem.indexOfScalarPos(u8, content, start, '>') orelse return null;
    if (tag_end > 0 and content[tag_end - 1] == '/') {
        return tag_end + 1;
    }
    return findClosingTag(content, start, tag_name);
}

fn parseDuration(iso_duration: []const u8) ?u64 {
    // Parse ISO 8601 duration: PT1H30M45.5S
    if (!std.mem.startsWith(u8, iso_duration, "PT")) return null;

    var pos: usize = 2;
    var total_ms: u64 = 0;
    var num_start: usize = 2;

    while (pos < iso_duration.len) {
        const c = iso_duration[pos];
        if (c == 'H') {
            const hours = std.fmt.parseFloat(f64, iso_duration[num_start..pos]) catch 0;
            total_ms += @intFromFloat(hours * 3600000);
            num_start = pos + 1;
        } else if (c == 'M') {
            const mins = std.fmt.parseFloat(f64, iso_duration[num_start..pos]) catch 0;
            total_ms += @intFromFloat(mins * 60000);
            num_start = pos + 1;
        } else if (c == 'S') {
            const secs = std.fmt.parseFloat(f64, iso_duration[num_start..pos]) catch 0;
            total_ms += @intFromFloat(secs * 1000);
            num_start = pos + 1;
        }
        pos += 1;
    }

    return total_ms;
}

/// Check if content is a DASH manifest
pub fn isDash(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "<MPD") != null and
        (std.mem.indexOf(u8, data, "urn:mpeg:dash:schema:mpd") != null or
        std.mem.indexOf(u8, data, "xmlns") != null);
}

// ============================================================================
// Tests
// ============================================================================

test "Manifest parse basic" {
    const allocator = std.testing.allocator;

    const mpd_content =
        \\<?xml version="1.0"?>
        \\<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1H30M0S">
        \\  <Period id="1">
        \\    <AdaptationSet contentType="video" mimeType="video/mp4">
        \\      <Representation id="720p" bandwidth="2000000" width="1280" height="720"/>
        \\      <Representation id="1080p" bandwidth="4000000" width="1920" height="1080"/>
        \\    </AdaptationSet>
        \\    <AdaptationSet contentType="audio" mimeType="audio/mp4" lang="en">
        \\      <Representation id="audio" bandwidth="128000"/>
        \\    </AdaptationSet>
        \\  </Period>
        \\</MPD>
    ;

    var manifest = Manifest.init(allocator);
    defer manifest.deinit();

    try manifest.parse(mpd_content);

    try std.testing.expectEqual(ManifestType.static, manifest.manifest_type);
    try std.testing.expectEqual(@as(u64, 5400000), manifest.media_presentation_duration.?);
    try std.testing.expectEqual(@as(usize, 1), manifest.periods.items.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.periods.items[0].adaptation_sets.items.len);

    const video_as = manifest.periods.items[0].adaptation_sets.items[0];
    try std.testing.expectEqual(AdaptationSet.ContentType.video, video_as.content_type.?);
    try std.testing.expectEqual(@as(usize, 2), video_as.representations.items.len);
}

test "parseDuration" {
    try std.testing.expectEqual(@as(u64, 5400000), parseDuration("PT1H30M0S").?);
    try std.testing.expectEqual(@as(u64, 45500), parseDuration("PT45.5S").?);
    try std.testing.expectEqual(@as(u64, 60000), parseDuration("PT1M").?);
    try std.testing.expect(parseDuration("invalid") == null);
}

test "isDash" {
    try std.testing.expect(isDash("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">"));
    try std.testing.expect(!isDash("#EXTM3U"));
}
