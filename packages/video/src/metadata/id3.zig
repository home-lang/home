// Home Video Library - ID3 Tag Parser/Writer
// ID3v1, ID3v2.3, ID3v2.4 support for MP3 and other formats

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// ID3v1 Tag (128 bytes at end of file)
// ============================================================================

pub const Id3v1Tag = struct {
    title: [30]u8 = [_]u8{0} ** 30,
    artist: [30]u8 = [_]u8{0} ** 30,
    album: [30]u8 = [_]u8{0} ** 30,
    year: [4]u8 = [_]u8{0} ** 4,
    comment: [30]u8 = [_]u8{0} ** 30,
    track: ?u8 = null, // ID3v1.1
    genre: u8 = 255,

    pub fn getTitle(self: *const Id3v1Tag) []const u8 {
        return trimNull(&self.title);
    }

    pub fn getArtist(self: *const Id3v1Tag) []const u8 {
        return trimNull(&self.artist);
    }

    pub fn getAlbum(self: *const Id3v1Tag) []const u8 {
        return trimNull(&self.album);
    }

    pub fn getYear(self: *const Id3v1Tag) []const u8 {
        return trimNull(&self.year);
    }

    pub fn getGenreName(self: *const Id3v1Tag) ?[]const u8 {
        if (self.genre < ID3V1_GENRES.len) {
            return ID3V1_GENRES[self.genre];
        }
        return null;
    }
};

fn trimNull(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == 0 or data[end - 1] == ' ')) {
        end -= 1;
    }
    return data[0..end];
}

/// Parse ID3v1 tag from last 128 bytes
pub fn parseId3v1(data: []const u8) ?Id3v1Tag {
    if (data.len < 128) return null;
    const tag_data = data[data.len - 128 ..];

    if (tag_data[0] != 'T' or tag_data[1] != 'A' or tag_data[2] != 'G') {
        return null;
    }

    var tag = Id3v1Tag{};
    @memcpy(&tag.title, tag_data[3..33]);
    @memcpy(&tag.artist, tag_data[33..63]);
    @memcpy(&tag.album, tag_data[63..93]);
    @memcpy(&tag.year, tag_data[93..97]);

    // Check for ID3v1.1 (track number in comment field)
    if (tag_data[125] == 0 and tag_data[126] != 0) {
        @memcpy(tag.comment[0..28], tag_data[97..125]);
        tag.track = tag_data[126];
    } else {
        @memcpy(&tag.comment, tag_data[97..127]);
    }

    tag.genre = tag_data[127];
    return tag;
}

/// Write ID3v1 tag (returns 128 bytes)
pub fn writeId3v1(tag: *const Id3v1Tag) [128]u8 {
    var data: [128]u8 = undefined;
    data[0] = 'T';
    data[1] = 'A';
    data[2] = 'G';
    @memcpy(data[3..33], &tag.title);
    @memcpy(data[33..63], &tag.artist);
    @memcpy(data[63..93], &tag.album);
    @memcpy(data[93..97], &tag.year);

    if (tag.track) |track| {
        @memcpy(data[97..125], tag.comment[0..28]);
        data[125] = 0;
        data[126] = track;
    } else {
        @memcpy(data[97..127], &tag.comment);
    }

    data[127] = tag.genre;
    return data;
}

// ============================================================================
// ID3v2 Tag
// ============================================================================

pub const Id3v2Header = struct {
    version_major: u8,
    version_minor: u8,
    flags: u8,
    size: u32, // Syncsafe integer

    pub fn hasUnsynchronisation(self: *const Id3v2Header) bool {
        return (self.flags & 0x80) != 0;
    }

    pub fn hasExtendedHeader(self: *const Id3v2Header) bool {
        return (self.flags & 0x40) != 0;
    }

    pub fn isExperimental(self: *const Id3v2Header) bool {
        return (self.flags & 0x20) != 0;
    }

    pub fn hasFooter(self: *const Id3v2Header) bool {
        return (self.flags & 0x10) != 0;
    }
};

pub const Id3v2Frame = struct {
    id: [4]u8,
    size: u32,
    flags: u16,
    data: []const u8,

    pub fn getId(self: *const Id3v2Frame) []const u8 {
        return &self.id;
    }

    /// Get text content (for text frames starting with 'T')
    pub fn getTextContent(self: *const Id3v2Frame, allocator: Allocator) ![]u8 {
        if (self.data.len == 0) return error.EmptyFrame;

        const encoding = self.data[0];
        const text_data = self.data[1..];

        return switch (encoding) {
            0 => try allocator.dupe(u8, trimNull(text_data)), // ISO-8859-1
            1 => decodeUtf16(text_data, allocator), // UTF-16 with BOM
            2 => decodeUtf16Be(text_data, allocator), // UTF-16BE
            3 => try allocator.dupe(u8, trimNull(text_data)), // UTF-8
            else => error.UnsupportedEncoding,
        };
    }
};

fn decodeUtf16(data: []const u8, allocator: Allocator) ![]u8 {
    if (data.len < 2) return error.InvalidUtf16;

    // Check BOM
    const is_le = data[0] == 0xFF and data[1] == 0xFE;
    const text_data = data[2..];

    return decodeUtf16Data(text_data, is_le, allocator);
}

fn decodeUtf16Be(data: []const u8, allocator: Allocator) ![]u8 {
    return decodeUtf16Data(data, false, allocator);
}

fn decodeUtf16Data(data: []const u8, little_endian: bool, allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i + 1 < data.len) {
        const code_unit = if (little_endian)
            @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8)
        else
            (@as(u16, data[i]) << 8) | data[i + 1];

        if (code_unit == 0) break;

        // Convert to UTF-8
        if (code_unit < 0x80) {
            try result.append(@intCast(code_unit));
        } else if (code_unit < 0x800) {
            try result.append(@intCast(0xC0 | (code_unit >> 6)));
            try result.append(@intCast(0x80 | (code_unit & 0x3F)));
        } else {
            try result.append(@intCast(0xE0 | (code_unit >> 12)));
            try result.append(@intCast(0x80 | ((code_unit >> 6) & 0x3F)));
            try result.append(@intCast(0x80 | (code_unit & 0x3F)));
        }

        i += 2;
    }

    return result.toOwnedSlice();
}

/// Parse syncsafe integer (7 bits per byte)
fn parseSyncsafe(data: *const [4]u8) u32 {
    return (@as(u32, data[0] & 0x7F) << 21) |
        (@as(u32, data[1] & 0x7F) << 14) |
        (@as(u32, data[2] & 0x7F) << 7) |
        (data[3] & 0x7F);
}

/// Write syncsafe integer
fn writeSyncsafe(value: u32) [4]u8 {
    return .{
        @intCast((value >> 21) & 0x7F),
        @intCast((value >> 14) & 0x7F),
        @intCast((value >> 7) & 0x7F),
        @intCast(value & 0x7F),
    };
}

// ============================================================================
// ID3v2 Parser
// ============================================================================

pub const Id3v2Parser = struct {
    data: []const u8,
    header: Id3v2Header,
    offset: usize,
    allocator: Allocator,

    pub fn init(data: []const u8, allocator: Allocator) !Id3v2Parser {
        if (data.len < 10) return error.InvalidId3v2;
        if (data[0] != 'I' or data[1] != 'D' or data[2] != '3') {
            return error.InvalidId3v2;
        }

        const header = Id3v2Header{
            .version_major = data[3],
            .version_minor = data[4],
            .flags = data[5],
            .size = parseSyncsafe(data[6..10]),
        };

        var offset: usize = 10;

        // Skip extended header if present
        if (header.hasExtendedHeader() and offset + 4 <= data.len) {
            const ext_size = if (header.version_major == 4)
                parseSyncsafe(data[offset..][0..4])
            else
                std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += ext_size;
        }

        return Id3v2Parser{
            .data = data,
            .header = header,
            .offset = offset,
            .allocator = allocator,
        };
    }

    /// Get total tag size including header
    pub fn totalSize(self: *const Id3v2Parser) usize {
        var size: usize = 10 + self.header.size;
        if (self.header.hasFooter()) {
            size += 10;
        }
        return size;
    }

    /// Parse next frame
    pub fn nextFrame(self: *Id3v2Parser) ?Id3v2Frame {
        const tag_end = 10 + self.header.size;

        if (self.offset + 10 > tag_end or self.offset + 10 > self.data.len) {
            return null;
        }

        // Check for padding
        if (self.data[self.offset] == 0) {
            return null;
        }

        var frame = Id3v2Frame{
            .id = undefined,
            .size = 0,
            .flags = 0,
            .data = &.{},
        };

        @memcpy(&frame.id, self.data[self.offset..][0..4]);

        // Parse size based on version
        if (self.header.version_major == 4) {
            frame.size = parseSyncsafe(self.data[self.offset + 4 ..][0..4]);
        } else {
            frame.size = std.mem.readInt(u32, self.data[self.offset + 4 ..][0..4], .big);
        }

        frame.flags = std.mem.readInt(u16, self.data[self.offset + 8 ..][0..2], .big);

        const data_start = self.offset + 10;
        const data_end = data_start + frame.size;

        if (data_end > self.data.len) {
            return null;
        }

        frame.data = self.data[data_start..data_end];
        self.offset = data_end;

        return frame;
    }

    /// Get all frames as a map
    pub fn getAllFrames(self: *Id3v2Parser) !std.StringHashMap([]u8) {
        var frames = std.StringHashMap([]u8).init(self.allocator);
        errdefer {
            var it = frames.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            frames.deinit();
        }

        while (self.nextFrame()) |frame| {
            if (frame.id[0] == 'T') {
                const content = frame.getTextContent(self.allocator) catch continue;
                const key = try self.allocator.dupe(u8, &frame.id);
                try frames.put(key, content);
            }
        }

        return frames;
    }
};

/// Check if data starts with ID3v2 tag
pub fn hasId3v2(data: []const u8) bool {
    return data.len >= 3 and data[0] == 'I' and data[1] == 'D' and data[2] == '3';
}

/// Check if data ends with ID3v1 tag
pub fn hasId3v1(data: []const u8) bool {
    if (data.len < 128) return false;
    const tag_start = data.len - 128;
    return data[tag_start] == 'T' and data[tag_start + 1] == 'A' and data[tag_start + 2] == 'G';
}

// ============================================================================
// Common Frame IDs
// ============================================================================

pub const FrameId = struct {
    pub const TITLE = "TIT2";
    pub const ARTIST = "TPE1";
    pub const ALBUM = "TALB";
    pub const YEAR = "TYER"; // ID3v2.3
    pub const RECORDING_TIME = "TDRC"; // ID3v2.4
    pub const TRACK = "TRCK";
    pub const GENRE = "TCON";
    pub const COMMENT = "COMM";
    pub const ALBUM_ARTIST = "TPE2";
    pub const COMPOSER = "TCOM";
    pub const DISC_NUMBER = "TPOS";
    pub const BPM = "TBPM";
    pub const ENCODER = "TENC";
    pub const COPYRIGHT = "TCOP";
    pub const PICTURE = "APIC";
    pub const LYRICS = "USLT";
    pub const DURATION = "TLEN";
};

// ============================================================================
// Genre List
// ============================================================================

const ID3V1_GENRES = [_][]const u8{
    "Blues",        "Classic Rock",   "Country",        "Dance",
    "Disco",        "Funk",           "Grunge",         "Hip-Hop",
    "Jazz",         "Metal",          "New Age",        "Oldies",
    "Other",        "Pop",            "R&B",            "Rap",
    "Reggae",       "Rock",           "Techno",         "Industrial",
    "Alternative",  "Ska",            "Death Metal",    "Pranks",
    "Soundtrack",   "Euro-Techno",    "Ambient",        "Trip-Hop",
    "Vocal",        "Jazz+Funk",      "Fusion",         "Trance",
    "Classical",    "Instrumental",   "Acid",           "House",
    "Game",         "Sound Clip",     "Gospel",         "Noise",
    "AlternRock",   "Bass",           "Soul",           "Punk",
    "Space",        "Meditative",     "Instrumental Pop", "Instrumental Rock",
    "Ethnic",       "Gothic",         "Darkwave",       "Techno-Industrial",
    "Electronic",   "Pop-Folk",       "Eurodance",      "Dream",
    "Southern Rock", "Comedy",        "Cult",           "Gangsta",
    "Top 40",       "Christian Rap",  "Pop/Funk",       "Jungle",
    "Native American", "Cabaret",     "New Wave",       "Psychedelic",
    "Rave",         "Showtunes",      "Trailer",        "Lo-Fi",
    "Tribal",       "Acid Punk",      "Acid Jazz",      "Polka",
    "Retro",        "Musical",        "Rock & Roll",    "Hard Rock",
};

// ============================================================================
// Tests
// ============================================================================

test "ID3v1 parsing" {
    const testing = std.testing;

    var data: [128]u8 = undefined;
    @memset(&data, 0);
    data[0] = 'T';
    data[1] = 'A';
    data[2] = 'G';
    @memcpy(data[3..8], "Title");
    @memcpy(data[33..39], "Artist");
    data[127] = 17; // Genre: Rock

    const tag = parseId3v1(&data);
    try testing.expect(tag != null);
    try testing.expectEqualStrings("Title", tag.?.getTitle());
    try testing.expectEqualStrings("Artist", tag.?.getArtist());
    try testing.expectEqualStrings("Rock", tag.?.getGenreName().?);
}

test "Syncsafe integer" {
    const testing = std.testing;

    // 0x7F7F7F7F = 268435455 in syncsafe
    const data = [_]u8{ 0x7F, 0x7F, 0x7F, 0x7F };
    try testing.expectEqual(@as(u32, 0x0FFFFFFF), parseSyncsafe(&data));

    // Roundtrip
    const value: u32 = 12345;
    const encoded = writeSyncsafe(value);
    try testing.expectEqual(value, parseSyncsafe(&encoded));
}

test "ID3v2 detection" {
    const testing = std.testing;

    const valid = [_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 0, 0 };
    try testing.expect(hasId3v2(&valid));

    const invalid = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try testing.expect(!hasId3v2(&invalid));
}
