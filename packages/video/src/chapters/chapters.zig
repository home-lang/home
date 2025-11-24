// Home Video Library - Chapter Support
// Parse and write chapter markers for MP4, MKV, and Ogg containers

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Universal Chapter Types
// ============================================================================

/// A single chapter marker
pub const Chapter = struct {
    start_ms: u64, // Start time in milliseconds
    end_ms: ?u64 = null, // End time (optional, next chapter start or duration)
    title: []const u8,
    language: []const u8 = "und", // ISO 639-2 language code
    uid: ?u64 = null, // Unique identifier

    // Nested chapters (for hierarchical chapter structures)
    children: std.ArrayListUnmanaged(Chapter) = .empty,

    pub fn deinit(self: *Chapter, allocator: Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }

    /// Get duration in milliseconds
    pub fn getDuration(self: *const Chapter, total_duration_ms: ?u64) ?u64 {
        if (self.end_ms) |end| {
            return end - self.start_ms;
        }
        if (total_duration_ms) |total| {
            return total - self.start_ms;
        }
        return null;
    }
};

/// Chapter edition/collection
pub const ChapterEdition = struct {
    uid: ?u64 = null,
    is_hidden: bool = false,
    is_default: bool = true,
    is_ordered: bool = false, // Chapters must be played in order
    chapters: std.ArrayListUnmanaged(Chapter) = .empty,

    pub fn deinit(self: *ChapterEdition, allocator: Allocator) void {
        for (self.chapters.items) |*ch| {
            ch.deinit(allocator);
        }
        self.chapters.deinit(allocator);
    }

    /// Get chapter at time position
    pub fn getChapterAt(self: *const ChapterEdition, time_ms: u64) ?*const Chapter {
        for (self.chapters.items) |*chapter| {
            const end = chapter.end_ms orelse std.math.maxInt(u64);
            if (time_ms >= chapter.start_ms and time_ms < end) {
                return chapter;
            }
        }
        return null;
    }

    /// Get chapter by index
    pub fn getChapter(self: *const ChapterEdition, index: usize) ?*const Chapter {
        if (index >= self.chapters.items.len) return null;
        return &self.chapters.items[index];
    }

    /// Get total chapter count
    pub fn count(self: *const ChapterEdition) usize {
        return self.chapters.items.len;
    }
};

// ============================================================================
// MP4 Chapter Parser (chpl atom and text tracks)
// ============================================================================

pub const Mp4ChapterParser = struct {
    data: []const u8,
    allocator: Allocator,

    pub fn init(data: []const u8, allocator: Allocator) Mp4ChapterParser {
        return .{ .data = data, .allocator = allocator };
    }

    /// Parse chapters from MP4 file
    pub fn parse(self: *Mp4ChapterParser) !ChapterEdition {
        var edition = ChapterEdition{};
        errdefer edition.deinit(self.allocator);

        // Try to find chpl atom (Nero chapters)
        if (try self.parseNeroChapters()) |nero_chapters| {
            return nero_chapters;
        }

        // Try to find chapter text track
        if (try self.parseTextTrackChapters()) |text_chapters| {
            return text_chapters;
        }

        return edition;
    }

    fn parseNeroChapters(self: *Mp4ChapterParser) !?ChapterEdition {
        // Look for moov/udta/chpl
        const moov_offset = findAtom(self.data, 0, "moov") orelse return null;
        const moov_size = std.mem.readInt(u32, self.data[moov_offset..][0..4], .big);

        const udta_offset = findAtom(self.data, moov_offset + 8, "udta") orelse return null;
        const udta_size = std.mem.readInt(u32, self.data[udta_offset..][0..4], .big);
        _ = udta_size;

        const chpl_offset = findAtomIn(self.data, udta_offset + 8, moov_offset + moov_size, "chpl") orelse return null;
        const chpl_size = std.mem.readInt(u32, self.data[chpl_offset..][0..4], .big);

        if (chpl_size < 17) return null;

        var edition = ChapterEdition{};
        errdefer edition.deinit(self.allocator);

        // Skip: size(4) + type(4) + version(1) + flags(3) + reserved(1)
        var offset = chpl_offset + 13;

        // Read chapter count
        const chapter_count = std.mem.readInt(u8, self.data[offset..][0..1], .big);
        offset += 1;

        var i: u8 = 0;
        while (i < chapter_count) : (i += 1) {
            if (offset + 9 > chpl_offset + chpl_size) break;

            // Timestamp (100ns units)
            const timestamp_100ns = std.mem.readInt(u64, self.data[offset..][0..8], .big);
            const start_ms = timestamp_100ns / 10000;
            offset += 8;

            // Title length
            const title_len = self.data[offset];
            offset += 1;

            if (offset + title_len > self.data.len) break;

            const title = self.data[offset..][0..title_len];
            offset += title_len;

            try edition.chapters.append(self.allocator, .{
                .start_ms = start_ms,
                .title = title,
            });
        }

        // Set end times based on next chapter
        for (edition.chapters.items, 0..) |*chapter, idx| {
            if (idx + 1 < edition.chapters.items.len) {
                chapter.end_ms = edition.chapters.items[idx + 1].start_ms;
            }
        }

        return edition;
    }

    fn parseTextTrackChapters(self: *Mp4ChapterParser) !?ChapterEdition {
        _ = self;
        // Text track chapters require parsing trak atoms with chapter references
        // This is more complex and format-specific
        return null;
    }
};

// ============================================================================
// Matroska/WebM Chapter Parser
// ============================================================================

const MkvElementId = enum(u32) {
    chapters = 0x1043A770,
    edition_entry = 0x45B9,
    edition_uid = 0x45BC,
    edition_flag_hidden = 0x45BD,
    edition_flag_default = 0x45DB,
    edition_flag_ordered = 0x45DD,
    chapter_atom = 0xB6,
    chapter_uid = 0x73C4,
    chapter_time_start = 0x91,
    chapter_time_end = 0x92,
    chapter_flag_hidden = 0x98,
    chapter_flag_enabled = 0x4598,
    chapter_display = 0x80,
    chap_string = 0x85,
    chap_language = 0x437C,
    chap_country = 0x437E,
};

pub const MkvChapterParser = struct {
    data: []const u8,
    offset: usize,
    allocator: Allocator,

    pub fn init(data: []const u8, allocator: Allocator) MkvChapterParser {
        return .{
            .data = data,
            .offset = 0,
            .allocator = allocator,
        };
    }

    /// Parse chapters from Matroska file
    pub fn parse(self: *MkvChapterParser) !std.ArrayListUnmanaged(ChapterEdition) {
        var editions: std.ArrayListUnmanaged(ChapterEdition) = .empty;
        errdefer {
            for (editions.items) |*e| e.deinit(self.allocator);
            editions.deinit(self.allocator);
        }

        // Find Chapters element
        while (self.offset < self.data.len) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(MkvElementId.chapters)) {
                try self.parseChaptersElement(&editions, element.data_offset, element.data_offset + element.size);
            }

            self.offset = element.data_offset + element.size;
        }

        return editions;
    }

    fn parseChaptersElement(
        self: *MkvChapterParser,
        editions: *std.ArrayListUnmanaged(ChapterEdition),
        start: usize,
        end: usize,
    ) !void {
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            if (element.id == @intFromEnum(MkvElementId.edition_entry)) {
                const edition = try self.parseEdition(element.data_offset, element.data_offset + element.size);
                try editions.append(self.allocator, edition);
            }

            self.offset = element.data_offset + element.size;
        }
    }

    fn parseEdition(self: *MkvChapterParser, start: usize, end: usize) !ChapterEdition {
        var edition = ChapterEdition{};
        errdefer edition.deinit(self.allocator);

        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            switch (@as(MkvElementId, @enumFromInt(element.id))) {
                .edition_uid => edition.uid = self.readUint(element.data_offset, element.size),
                .edition_flag_hidden => edition.is_hidden = self.readUint(element.data_offset, element.size) != 0,
                .edition_flag_default => edition.is_default = self.readUint(element.data_offset, element.size) != 0,
                .edition_flag_ordered => edition.is_ordered = self.readUint(element.data_offset, element.size) != 0,
                .chapter_atom => {
                    const chapter = try self.parseChapterAtom(element.data_offset, element.data_offset + element.size);
                    try edition.chapters.append(self.allocator, chapter);
                },
                else => {},
            }

            self.offset = element.data_offset + element.size;
        }

        return edition;
    }

    fn parseChapterAtom(self: *MkvChapterParser, start: usize, end: usize) !Chapter {
        var chapter = Chapter{
            .start_ms = 0,
            .title = "",
        };

        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            switch (@as(MkvElementId, @enumFromInt(element.id))) {
                .chapter_uid => chapter.uid = self.readUint(element.data_offset, element.size),
                .chapter_time_start => {
                    // Nanoseconds to milliseconds
                    chapter.start_ms = self.readUint(element.data_offset, element.size) / 1_000_000;
                },
                .chapter_time_end => {
                    chapter.end_ms = self.readUint(element.data_offset, element.size) / 1_000_000;
                },
                .chapter_display => {
                    try self.parseChapterDisplay(&chapter, element.data_offset, element.data_offset + element.size);
                },
                .chapter_atom => {
                    // Nested chapter
                    const child = try self.parseChapterAtom(element.data_offset, element.data_offset + element.size);
                    try chapter.children.append(self.allocator, child);
                },
                else => {},
            }

            self.offset = element.data_offset + element.size;
        }

        return chapter;
    }

    fn parseChapterDisplay(self: *MkvChapterParser, chapter: *Chapter, start: usize, end: usize) !void {
        self.offset = start;

        while (self.offset < end) {
            const element = self.readElement() orelse break;

            switch (@as(MkvElementId, @enumFromInt(element.id))) {
                .chap_string => chapter.title = self.data[element.data_offset..][0..element.size],
                .chap_language => chapter.language = self.data[element.data_offset..][0..element.size],
                else => {},
            }

            self.offset = element.data_offset + element.size;
        }
    }

    const Element = struct { id: u32, size: usize, data_offset: usize };

    fn readElement(self: *MkvChapterParser) ?Element {
        if (self.offset >= self.data.len) return null;

        const id_result = readVint(self.data[self.offset..]) orelse return null;
        self.offset += id_result.length;

        if (self.offset >= self.data.len) return null;
        const size_result = readVint(self.data[self.offset..]) orelse return null;
        self.offset += size_result.length;

        return Element{
            .id = @intCast(id_result.value),
            .size = @intCast(size_result.value),
            .data_offset = self.offset,
        };
    }

    fn readUint(self: *MkvChapterParser, offset: usize, size: usize) u64 {
        if (offset + size > self.data.len) return 0;
        var value: u64 = 0;
        for (0..size) |i| {
            value = (value << 8) | self.data[offset + i];
        }
        return value;
    }
};

// ============================================================================
// Ogg Chapter Parser (VorbisComment CHAPTER tags)
// ============================================================================

pub const OggChapterParser = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) OggChapterParser {
        return .{ .allocator = allocator };
    }

    /// Parse chapters from Vorbis comments
    pub fn parseFromComments(self: *OggChapterParser, comments: []const []const u8) !ChapterEdition {
        var edition = ChapterEdition{};
        errdefer edition.deinit(self.allocator);

        var chapter_times = std.StringHashMap(u64).init(self.allocator);
        defer chapter_times.deinit();

        var chapter_names = std.StringHashMap([]const u8).init(self.allocator);
        defer chapter_names.deinit();

        for (comments) |comment| {
            // Parse CHAPTERxxx=HH:MM:SS.mmm
            if (std.mem.startsWith(u8, comment, "CHAPTER") and !std.mem.startsWith(u8, comment, "CHAPTERNAME")) {
                if (std.mem.indexOf(u8, comment, "=")) |eq_pos| {
                    const num_str = comment[7..eq_pos];
                    const time_str = comment[eq_pos + 1 ..];
                    const time_ms = parseTimeString(time_str) orelse continue;
                    try chapter_times.put(num_str, time_ms);
                }
            }
            // Parse CHAPTERNAMExxx=Title
            else if (std.mem.startsWith(u8, comment, "CHAPTERNAME")) {
                if (std.mem.indexOf(u8, comment, "=")) |eq_pos| {
                    const num_str = comment[11..eq_pos];
                    const title = comment[eq_pos + 1 ..];
                    try chapter_names.put(num_str, title);
                }
            }
        }

        // Combine times and names
        var it = chapter_times.iterator();
        while (it.next()) |entry| {
            const title = chapter_names.get(entry.key_ptr.*) orelse "Chapter";
            try edition.chapters.append(self.allocator, .{
                .start_ms = entry.value_ptr.*,
                .title = title,
            });
        }

        // Sort by start time
        std.mem.sort(Chapter, edition.chapters.items, {}, struct {
            fn lessThan(_: void, a: Chapter, b: Chapter) bool {
                return a.start_ms < b.start_ms;
            }
        }.lessThan);

        return edition;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn findAtom(data: []const u8, start: usize, atom_type: *const [4]u8) ?usize {
    return findAtomIn(data, start, data.len, atom_type);
}

fn findAtomIn(data: []const u8, start: usize, end: usize, atom_type: *const [4]u8) ?usize {
    var offset = start;
    while (offset + 8 <= end) {
        const size = std.mem.readInt(u32, data[offset..][0..4], .big);
        if (size < 8) break;
        if (std.mem.eql(u8, data[offset + 4 ..][0..4], atom_type)) {
            return offset;
        }
        offset += size;
    }
    return null;
}

fn readVint(data: []const u8) ?struct { value: u64, length: usize } {
    if (data.len == 0) return null;
    const first = data[0];
    if (first == 0) return null;

    var length: usize = 1;
    var mask: u8 = 0x80;
    while (mask > 0 and (first & mask) == 0) {
        length += 1;
        mask >>= 1;
    }

    if (length > 8 or length > data.len) return null;

    var value: u64 = first & (mask - 1);
    for (1..length) |i| {
        value = (value << 8) | data[i];
    }

    return .{ .value = value, .length = length };
}

fn parseTimeString(time_str: []const u8) ?u64 {
    // Parse HH:MM:SS.mmm or HH:MM:SS
    var parts = std.mem.splitScalar(u8, time_str, ':');

    const hours_str = parts.next() orelse return null;
    const mins_str = parts.next() orelse return null;
    const secs_str = parts.next() orelse return null;

    const hours = std.fmt.parseInt(u64, hours_str, 10) catch return null;
    const mins = std.fmt.parseInt(u64, mins_str, 10) catch return null;

    // Seconds may have decimal
    var secs_parts = std.mem.splitScalar(u8, secs_str, '.');
    const secs_whole = secs_parts.next() orelse return null;
    const secs = std.fmt.parseInt(u64, secs_whole, 10) catch return null;

    var ms: u64 = 0;
    if (secs_parts.next()) |ms_str| {
        ms = std.fmt.parseInt(u64, ms_str, 10) catch 0;
        // Normalize to milliseconds
        if (ms_str.len == 1) ms *= 100;
        if (ms_str.len == 2) ms *= 10;
    }

    return hours * 3600000 + mins * 60000 + secs * 1000 + ms;
}

// ============================================================================
// Tests
// ============================================================================

test "Chapter basic operations" {
    const testing = std.testing;

    const chapter = Chapter{
        .start_ms = 60000,
        .end_ms = 120000,
        .title = "Chapter 1",
    };

    try testing.expectEqual(@as(u64, 60000), chapter.getDuration(null).?);
}

test "ChapterEdition getChapterAt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var edition = ChapterEdition{};
    defer edition.deinit(allocator);

    try edition.chapters.append(allocator, .{ .start_ms = 0, .end_ms = 60000, .title = "Intro" });
    try edition.chapters.append(allocator, .{ .start_ms = 60000, .end_ms = 180000, .title = "Main" });

    const ch1 = edition.getChapterAt(30000);
    try testing.expect(ch1 != null);
    try testing.expectEqualStrings("Intro", ch1.?.title);

    const ch2 = edition.getChapterAt(90000);
    try testing.expect(ch2 != null);
    try testing.expectEqualStrings("Main", ch2.?.title);
}

test "Parse time string" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 3661500), parseTimeString("01:01:01.500").?);
    try testing.expectEqual(@as(u64, 0), parseTimeString("00:00:00.000").?);
    try testing.expectEqual(@as(u64, 3600000), parseTimeString("01:00:00").?);
}
