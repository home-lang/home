// Home Video Library - Matroska/WebM Tags Parser
// EBML-based metadata in MKV/WebM containers

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Matroska Tag Elements (EBML IDs)
// ============================================================================

pub const ElementId = enum(u32) {
    // Segment
    segment = 0x18538067,

    // Tags container
    tags = 0x1254C367,
    tag = 0x7373,

    // Tag targets
    targets = 0x63C0,
    target_type_value = 0x68CA,
    target_type = 0x63CA,
    tag_track_uid = 0x63C5,
    tag_edition_uid = 0x63C9,
    tag_chapter_uid = 0x63C4,
    tag_attachment_uid = 0x63C6,

    // Simple tag
    simple_tag = 0x67C8,
    tag_name = 0x45A3,
    tag_language = 0x447A,
    tag_language_ietf = 0x447B,
    tag_default = 0x4484,
    tag_string = 0x4487,
    tag_binary = 0x4485,

    // Info
    info = 0x1549A966,
    title = 0x7BA9,
    muxing_app = 0x4D80,
    writing_app = 0x5741,
    date_utc = 0x4461,
    duration = 0x4489,

    // Track
    tracks = 0x1654AE6B,
    track_entry = 0xAE,
    track_number = 0xD7,
    track_uid = 0x73C5,
    track_type = 0x83,
    name = 0x536E,
    language = 0x22B59C,
    codec_id = 0x86,

    unknown = 0,
};

/// Target type values
pub const TargetType = enum(u8) {
    collection = 70, // Album, Opera, Concert, etc.
    season = 60, // TV season
    album = 50, // Album, Concert
    part = 40, // Part of album
    track = 30, // Track, Song, Chapter
    subtrack = 20, // Movement, Scene
    shot = 10, // Shot

    pub fn fromValue(value: u64) ?TargetType {
        return switch (value) {
            70 => .collection,
            60 => .season,
            50 => .album,
            40 => .part,
            30 => .track,
            20 => .subtrack,
            10 => .shot,
            else => null,
        };
    }
};

// ============================================================================
// Common Tag Names (per Matroska spec)
// ============================================================================

pub const TagName = struct {
    // Nesting: Organization
    pub const TOTAL_PARTS = "TOTAL_PARTS";
    pub const PART_NUMBER = "PART_NUMBER";
    pub const PART_OFFSET = "PART_OFFSET";

    // Titles
    pub const TITLE = "TITLE";
    pub const SUBTITLE = "SUBTITLE";

    // Nested: Entities
    pub const ARTIST = "ARTIST";
    pub const LEAD_PERFORMER = "LEAD_PERFORMER";
    pub const ACCOMPANIMENT = "ACCOMPANIMENT";
    pub const COMPOSER = "COMPOSER";
    pub const ARRANGER = "ARRANGER";
    pub const LYRICS_WRITER = "LYRICS_WRITER";
    pub const CONDUCTOR = "CONDUCTOR";
    pub const DIRECTOR = "DIRECTOR";
    pub const PRODUCER = "PRODUCER";
    pub const CINEMATOGRAPHER = "CINEMATOGRAPHER";
    pub const ACTOR = "ACTOR";
    pub const CHARACTER = "CHARACTER";
    pub const WRITTEN_BY = "WRITTEN_BY";
    pub const SCREENPLAY_BY = "SCREENPLAY_BY";
    pub const EDITED_BY = "EDITED_BY";
    pub const PUBLISHER = "PUBLISHER";
    pub const LABEL = "LABEL";

    // Search/Classification
    pub const GENRE = "GENRE";
    pub const MOOD = "MOOD";
    pub const ORIGINAL_MEDIA_TYPE = "ORIGINAL_MEDIA_TYPE";
    pub const CONTENT_TYPE = "CONTENT_TYPE";
    pub const SUBJECT = "SUBJECT";
    pub const DESCRIPTION = "DESCRIPTION";
    pub const KEYWORDS = "KEYWORDS";
    pub const SYNOPSIS = "SYNOPSIS";
    pub const SUMMARY = "SUMMARY";

    // Temporal
    pub const DATE_RELEASED = "DATE_RELEASED";
    pub const DATE_RECORDED = "DATE_RECORDED";
    pub const DATE_ENCODED = "DATE_ENCODED";
    pub const DATE_TAGGED = "DATE_TAGGED";
    pub const DATE_PURCHASED = "DATE_PURCHASED";

    // Identifiers
    pub const ISRC = "ISRC";
    pub const ISBN = "ISBN";
    pub const BARCODE = "BARCODE";
    pub const CATALOG_NUMBER = "CATALOG_NUMBER";
    pub const IMDB = "IMDB";
    pub const TMDB = "TMDB";
    pub const TVDB = "TVDB";

    // Technical
    pub const ENCODER = "ENCODER";
    pub const ENCODER_SETTINGS = "ENCODER_SETTINGS";
    pub const BPS = "BPS";
    pub const FPS = "FPS";

    // Rating
    pub const RATING = "RATING";
    pub const LAW_RATING = "LAW_RATING";

    // Comments
    pub const COMMENT = "COMMENT";
};

// ============================================================================
// Matroska Tag Structures
// ============================================================================

pub const SimpleTag = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    language: []const u8 = "und",
    is_default: bool = true,
    nested_tags: std.ArrayListUnmanaged(SimpleTag) = .empty,

    pub fn deinit(self: *SimpleTag, allocator: Allocator) void {
        self.nested_tags.deinit(allocator);
    }
};

pub const TagTarget = struct {
    target_type_value: u64 = 50,
    target_type: ?[]const u8 = null,
    track_uids: std.ArrayListUnmanaged(u64) = .empty,
    chapter_uids: std.ArrayListUnmanaged(u64) = .empty,
    edition_uids: std.ArrayListUnmanaged(u64) = .empty,
    attachment_uids: std.ArrayListUnmanaged(u64) = .empty,

    pub fn deinit(self: *TagTarget, allocator: Allocator) void {
        self.track_uids.deinit(allocator);
        self.chapter_uids.deinit(allocator);
        self.edition_uids.deinit(allocator);
        self.attachment_uids.deinit(allocator);
    }
};

pub const Tag = struct {
    targets: TagTarget = .{},
    simple_tags: std.ArrayListUnmanaged(SimpleTag) = .empty,

    pub fn deinit(self: *Tag, allocator: Allocator) void {
        self.targets.deinit(allocator);
        for (self.simple_tags.items) |*st| {
            st.deinit(allocator);
        }
        self.simple_tags.deinit(allocator);
    }
};

// ============================================================================
// Matroska Tags Parser
// ============================================================================

pub const MatroskaTagsParser = struct {
    data: []const u8,
    offset: usize,
    allocator: Allocator,
    tags: std.ArrayListUnmanaged(Tag) = .empty,

    pub fn init(data: []const u8, allocator: Allocator) MatroskaTagsParser {
        return .{
            .data = data,
            .offset = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatroskaTagsParser) void {
        for (self.tags.items) |*tag| {
            tag.deinit(self.allocator);
        }
        self.tags.deinit(self.allocator);
    }

    /// Parse tags from data
    pub fn parse(self: *MatroskaTagsParser) !void {
        while (self.offset < self.data.len) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(ElementId.tags)) {
                try self.parseTags(element.data_offset, element.data_offset + element.size);
            } else if (element.id == @intFromEnum(ElementId.segment)) {
                // Continue into segment
                continue;
            }

            self.offset = element.data_offset + element.size;
        }
    }

    fn parseTags(self: *MatroskaTagsParser, start: usize, end: usize) !void {
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(ElementId.tag)) {
                const tag = try self.parseTag(element.data_offset, element.data_offset + element.size);
                try self.tags.append(self.allocator, tag);
            }

            self.offset = element.data_offset + element.size;
        }
    }

    fn parseTag(self: *MatroskaTagsParser, start: usize, end: usize) !Tag {
        var tag = Tag{};
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(ElementId.targets)) {
                tag.targets = try self.parseTargets(element.data_offset, element.data_offset + element.size);
            } else if (element.id == @intFromEnum(ElementId.simple_tag)) {
                const st = try self.parseSimpleTag(element.data_offset, element.data_offset + element.size);
                try tag.simple_tags.append(self.allocator, st);
            }

            self.offset = element.data_offset + element.size;
        }

        return tag;
    }

    fn parseTargets(self: *MatroskaTagsParser, start: usize, end: usize) !TagTarget {
        var targets = TagTarget{};
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(ElementId.target_type_value)) {
                targets.target_type_value = self.readUint(element.data_offset, element.size);
            } else if (element.id == @intFromEnum(ElementId.target_type)) {
                targets.target_type = self.data[element.data_offset..][0..element.size];
            } else if (element.id == @intFromEnum(ElementId.tag_track_uid)) {
                try targets.track_uids.append(self.allocator, self.readUint(element.data_offset, element.size));
            } else if (element.id == @intFromEnum(ElementId.tag_chapter_uid)) {
                try targets.chapter_uids.append(self.allocator, self.readUint(element.data_offset, element.size));
            }

            self.offset = element.data_offset + element.size;
        }

        return targets;
    }

    fn parseSimpleTag(self: *MatroskaTagsParser, start: usize, end: usize) !SimpleTag {
        var st = SimpleTag{ .name = "" };
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(ElementId.tag_name)) {
                st.name = self.data[element.data_offset..][0..element.size];
            } else if (element.id == @intFromEnum(ElementId.tag_string)) {
                st.value = self.data[element.data_offset..][0..element.size];
            } else if (element.id == @intFromEnum(ElementId.tag_binary)) {
                st.binary = self.data[element.data_offset..][0..element.size];
            } else if (element.id == @intFromEnum(ElementId.tag_language)) {
                st.language = self.data[element.data_offset..][0..element.size];
            } else if (element.id == @intFromEnum(ElementId.tag_default)) {
                st.is_default = self.readUint(element.data_offset, element.size) != 0;
            } else if (element.id == @intFromEnum(ElementId.simple_tag)) {
                const nested = try self.parseSimpleTag(element.data_offset, element.data_offset + element.size);
                try st.nested_tags.append(self.allocator, nested);
            }

            self.offset = element.data_offset + element.size;
        }

        return st;
    }

    const Element = struct {
        id: u32,
        size: usize,
        data_offset: usize,
    };

    fn readElement(self: *MatroskaTagsParser) ?Element {
        if (self.offset >= self.data.len) return null;

        // Read EBML ID (variable length, 1-4 bytes)
        const id_result = readVint(self.data[self.offset..]) orelse return null;
        const id = id_result.value;
        self.offset += id_result.length;

        // Read size (variable length)
        if (self.offset >= self.data.len) return null;
        const size_result = readVint(self.data[self.offset..]) orelse return null;

        // Handle unknown size
        var size = size_result.value;
        if (size == (@as(u64, 1) << @intCast(size_result.length * 7)) - 1) {
            size = self.data.len - self.offset - size_result.length;
        }

        self.offset += size_result.length;

        return Element{
            .id = @intCast(id),
            .size = @intCast(size),
            .data_offset = self.offset,
        };
    }

    fn readUint(self: *MatroskaTagsParser, offset: usize, size: usize) u64 {
        if (offset + size > self.data.len) return 0;

        var value: u64 = 0;
        var i: usize = 0;
        while (i < size) : (i += 1) {
            value = (value << 8) | self.data[offset + i];
        }
        return value;
    }

    /// Get tag value by name (searches all tags)
    pub fn getValue(self: *const MatroskaTagsParser, name: []const u8) ?[]const u8 {
        for (self.tags.items) |*tag| {
            for (tag.simple_tags.items) |*st| {
                if (std.mem.eql(u8, st.name, name)) {
                    return st.value;
                }
            }
        }
        return null;
    }

    /// Get title
    pub fn getTitle(self: *const MatroskaTagsParser) ?[]const u8 {
        return self.getValue(TagName.TITLE);
    }

    /// Get artist
    pub fn getArtist(self: *const MatroskaTagsParser) ?[]const u8 {
        return self.getValue(TagName.ARTIST);
    }

    /// Get genre
    pub fn getGenre(self: *const MatroskaTagsParser) ?[]const u8 {
        return self.getValue(TagName.GENRE);
    }
};

/// Read variable-length integer (EBML VINT)
fn readVint(data: []const u8) ?struct { value: u64, length: usize } {
    if (data.len == 0) return null;

    const first = data[0];
    if (first == 0) return null;

    // Determine length from leading bits
    var length: usize = 1;
    var mask: u8 = 0x80;
    while (mask > 0 and (first & mask) == 0) {
        length += 1;
        mask >>= 1;
    }

    if (length > 8 or length > data.len) return null;

    // Read value
    var value: u64 = first & (mask - 1);
    var i: usize = 1;
    while (i < length) : (i += 1) {
        value = (value << 8) | data[i];
    }

    return .{ .value = value, .length = length };
}

// ============================================================================
// Tests
// ============================================================================

test "VINT reading" {
    const testing = std.testing;

    // 1-byte: 0x81 = 1
    const vint1 = readVint(&[_]u8{0x81});
    try testing.expect(vint1 != null);
    try testing.expectEqual(@as(u64, 1), vint1.?.value);
    try testing.expectEqual(@as(usize, 1), vint1.?.length);

    // 2-byte: 0x40 0x01 = 1
    const vint2 = readVint(&[_]u8{ 0x40, 0x01 });
    try testing.expect(vint2 != null);
    try testing.expectEqual(@as(u64, 1), vint2.?.value);
    try testing.expectEqual(@as(usize, 2), vint2.?.length);
}

test "Target type values" {
    const testing = std.testing;

    try testing.expectEqual(TargetType.album, TargetType.fromValue(50).?);
    try testing.expectEqual(TargetType.track, TargetType.fromValue(30).?);
    try testing.expect(TargetType.fromValue(999) == null);
}

test "Tag name constants" {
    const testing = std.testing;

    try testing.expectEqualStrings("TITLE", TagName.TITLE);
    try testing.expectEqualStrings("ARTIST", TagName.ARTIST);
    try testing.expectEqualStrings("GENRE", TagName.GENRE);
}
