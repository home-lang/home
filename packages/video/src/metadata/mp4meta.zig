// Home Video Library - MP4/M4A Metadata (iTunes-style)
// Parse and write metadata in MP4 containers (moov/udta/meta/ilst)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// MP4 Metadata Atoms
// ============================================================================

/// Common iTunes metadata atom types
pub const AtomType = enum {
    title, // ©nam
    artist, // ©ART
    album_artist, // aART
    album, // ©alb
    genre, // ©gen or gnre
    year, // ©day
    track_number, // trkn
    disc_number, // disk
    composer, // ©wrt
    comment, // ©cmt
    description, // desc
    synopsis, // ldes
    copyright, // cprt
    encoder, // ©too
    cover_art, // covr
    lyrics, // ©lyr
    rating, // rtng
    tempo, // tmpo
    compilation, // cpil
    gapless, // pgap
    sort_name, // sonm
    sort_artist, // soar
    sort_album, // soal
    tv_show, // tvsh
    tv_season, // tvsn
    tv_episode, // tves
    media_type, // stik
    purchase_date, // purd
    account_type, // akID
    custom, // ----

    pub fn toFourCC(self: AtomType) [4]u8 {
        return switch (self) {
            .title => .{ 0xA9, 'n', 'a', 'm' },
            .artist => .{ 0xA9, 'A', 'R', 'T' },
            .album_artist => .{ 'a', 'A', 'R', 'T' },
            .album => .{ 0xA9, 'a', 'l', 'b' },
            .genre => .{ 0xA9, 'g', 'e', 'n' },
            .year => .{ 0xA9, 'd', 'a', 'y' },
            .track_number => .{ 't', 'r', 'k', 'n' },
            .disc_number => .{ 'd', 'i', 's', 'k' },
            .composer => .{ 0xA9, 'w', 'r', 't' },
            .comment => .{ 0xA9, 'c', 'm', 't' },
            .description => .{ 'd', 'e', 's', 'c' },
            .synopsis => .{ 'l', 'd', 'e', 's' },
            .copyright => .{ 'c', 'p', 'r', 't' },
            .encoder => .{ 0xA9, 't', 'o', 'o' },
            .cover_art => .{ 'c', 'o', 'v', 'r' },
            .lyrics => .{ 0xA9, 'l', 'y', 'r' },
            .rating => .{ 'r', 't', 'n', 'g' },
            .tempo => .{ 't', 'm', 'p', 'o' },
            .compilation => .{ 'c', 'p', 'i', 'l' },
            .gapless => .{ 'p', 'g', 'a', 'p' },
            .sort_name => .{ 's', 'o', 'n', 'm' },
            .sort_artist => .{ 's', 'o', 'a', 'r' },
            .sort_album => .{ 's', 'o', 'a', 'l' },
            .tv_show => .{ 't', 'v', 's', 'h' },
            .tv_season => .{ 't', 'v', 's', 'n' },
            .tv_episode => .{ 't', 'v', 'e', 's' },
            .media_type => .{ 's', 't', 'i', 'k' },
            .purchase_date => .{ 'p', 'u', 'r', 'd' },
            .account_type => .{ 'a', 'k', 'I', 'D' },
            .custom => .{ '-', '-', '-', '-' },
        };
    }

    pub fn fromFourCC(fourcc: [4]u8) ?AtomType {
        if (fourcc[0] == 0xA9) {
            if (std.mem.eql(u8, fourcc[1..], "nam")) return .title;
            if (std.mem.eql(u8, fourcc[1..], "ART")) return .artist;
            if (std.mem.eql(u8, fourcc[1..], "alb")) return .album;
            if (std.mem.eql(u8, fourcc[1..], "gen")) return .genre;
            if (std.mem.eql(u8, fourcc[1..], "day")) return .year;
            if (std.mem.eql(u8, fourcc[1..], "wrt")) return .composer;
            if (std.mem.eql(u8, fourcc[1..], "cmt")) return .comment;
            if (std.mem.eql(u8, fourcc[1..], "too")) return .encoder;
            if (std.mem.eql(u8, fourcc[1..], "lyr")) return .lyrics;
        }

        if (std.mem.eql(u8, &fourcc, "aART")) return .album_artist;
        if (std.mem.eql(u8, &fourcc, "trkn")) return .track_number;
        if (std.mem.eql(u8, &fourcc, "disk")) return .disc_number;
        if (std.mem.eql(u8, &fourcc, "desc")) return .description;
        if (std.mem.eql(u8, &fourcc, "ldes")) return .synopsis;
        if (std.mem.eql(u8, &fourcc, "cprt")) return .copyright;
        if (std.mem.eql(u8, &fourcc, "covr")) return .cover_art;
        if (std.mem.eql(u8, &fourcc, "rtng")) return .rating;
        if (std.mem.eql(u8, &fourcc, "tmpo")) return .tempo;
        if (std.mem.eql(u8, &fourcc, "cpil")) return .compilation;
        if (std.mem.eql(u8, &fourcc, "pgap")) return .gapless;
        if (std.mem.eql(u8, &fourcc, "sonm")) return .sort_name;
        if (std.mem.eql(u8, &fourcc, "soar")) return .sort_artist;
        if (std.mem.eql(u8, &fourcc, "soal")) return .sort_album;
        if (std.mem.eql(u8, &fourcc, "tvsh")) return .tv_show;
        if (std.mem.eql(u8, &fourcc, "tvsn")) return .tv_season;
        if (std.mem.eql(u8, &fourcc, "tves")) return .tv_episode;
        if (std.mem.eql(u8, &fourcc, "stik")) return .media_type;
        if (std.mem.eql(u8, &fourcc, "----")) return .custom;

        return null;
    }
};

/// Data type flags for 'data' atom
pub const DataType = enum(u32) {
    binary = 0,
    utf8 = 1,
    utf16 = 2,
    sjis = 3,
    html = 6,
    xml = 7,
    uuid = 8,
    isrc = 9,
    mi3p = 10,
    gif = 12,
    jpeg = 13,
    png = 14,
    url = 15,
    duration = 16,
    datetime = 17,
    genre_id = 18,
    integer = 21,
    riaa = 24,
    upc = 25,
    bmp = 27,
};

// ============================================================================
// MP4 Metadata Item
// ============================================================================

pub const MetadataItem = struct {
    atom_type: AtomType,
    data_type: DataType,
    data: []const u8,

    /// Get string value (for text items)
    pub fn getString(self: *const MetadataItem, allocator: Allocator) ![]u8 {
        if (self.data_type != .utf8) return error.NotString;
        return allocator.dupe(u8, self.data);
    }

    /// Get integer value (for numeric items)
    pub fn getInteger(self: *const MetadataItem) ?i64 {
        if (self.data.len == 0) return null;

        return switch (self.data.len) {
            1 => self.data[0],
            2 => std.mem.readInt(i16, self.data[0..2], .big),
            4 => std.mem.readInt(i32, self.data[0..4], .big),
            8 => std.mem.readInt(i64, self.data[0..8], .big),
            else => null,
        };
    }

    /// Get track number (trkn format: 4 bytes padding, 2 bytes track, 2 bytes total)
    pub fn getTrackNumber(self: *const MetadataItem) ?struct { track: u16, total: u16 } {
        if (self.atom_type != .track_number or self.data.len < 8) return null;
        return .{
            .track = std.mem.readInt(u16, self.data[2..4], .big),
            .total = std.mem.readInt(u16, self.data[4..6], .big),
        };
    }

    /// Get disc number (disk format: same as track)
    pub fn getDiscNumber(self: *const MetadataItem) ?struct { disc: u16, total: u16 } {
        if (self.atom_type != .disc_number or self.data.len < 8) return null;
        return .{
            .disc = std.mem.readInt(u16, self.data[2..4], .big),
            .total = std.mem.readInt(u16, self.data[4..6], .big),
        };
    }
};

// ============================================================================
// MP4 Metadata Parser
// ============================================================================

pub const Mp4MetadataParser = struct {
    data: []const u8,
    offset: usize,
    allocator: Allocator,
    items: std.ArrayListUnmanaged(MetadataItem) = .empty,

    pub fn init(data: []const u8, allocator: Allocator) Mp4MetadataParser {
        return .{
            .data = data,
            .offset = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mp4MetadataParser) void {
        self.items.deinit(self.allocator);
    }

    /// Find and parse metadata from MP4 file
    pub fn parse(self: *Mp4MetadataParser) !void {
        // Find moov atom
        const moov_offset = self.findAtom(0, self.data.len, "moov") orelse return;
        const moov_size = std.mem.readInt(u32, self.data[moov_offset..][0..4], .big);

        // Find udta within moov
        const udta_offset = self.findAtom(moov_offset + 8, moov_offset + moov_size, "udta") orelse return;
        const udta_size = std.mem.readInt(u32, self.data[udta_offset..][0..4], .big);

        // Find meta within udta
        const meta_offset = self.findAtom(udta_offset + 8, udta_offset + udta_size, "meta") orelse return;
        const meta_size = std.mem.readInt(u32, self.data[meta_offset..][0..4], .big);

        // meta has 4 extra bytes (version/flags) before children
        const meta_data_start = meta_offset + 12;

        // Find ilst within meta
        const ilst_offset = self.findAtom(meta_data_start, meta_offset + meta_size, "ilst") orelse return;
        const ilst_size = std.mem.readInt(u32, self.data[ilst_offset..][0..4], .big);

        // Parse ilst items
        try self.parseIlst(ilst_offset + 8, ilst_offset + ilst_size);
    }

    fn findAtom(self: *Mp4MetadataParser, start: usize, end: usize, atom_type: *const [4]u8) ?usize {
        var offset = start;
        while (offset + 8 <= end) {
            const size = std.mem.readInt(u32, self.data[offset..][0..4], .big);
            if (size < 8) break;

            if (std.mem.eql(u8, self.data[offset + 4 ..][0..4], atom_type)) {
                return offset;
            }

            offset += size;
        }
        return null;
    }

    fn parseIlst(self: *Mp4MetadataParser, start: usize, end: usize) !void {
        var offset = start;

        while (offset + 8 <= end) {
            const size = std.mem.readInt(u32, self.data[offset..][0..4], .big);
            if (size < 8) break;

            var fourcc: [4]u8 = undefined;
            @memcpy(&fourcc, self.data[offset + 4 ..][0..4]);

            const atom_type = AtomType.fromFourCC(fourcc);

            // Parse data atom within this item
            if (self.findAtom(offset + 8, offset + size, "data")) |data_offset| {
                const data_size = std.mem.readInt(u32, self.data[data_offset..][0..4], .big);
                if (data_size >= 16 and data_offset + data_size <= self.data.len) {
                    const data_type_raw = std.mem.readInt(u32, self.data[data_offset + 8 ..][0..4], .big);
                    const data_type: DataType = @enumFromInt(data_type_raw & 0xFF);

                    const value_start = data_offset + 16;
                    const value_end = data_offset + data_size;

                    if (value_end <= self.data.len) {
                        try self.items.append(self.allocator, .{
                            .atom_type = atom_type orelse .custom,
                            .data_type = data_type,
                            .data = self.data[value_start..value_end],
                        });
                    }
                }
            }

            offset += size;
        }
    }

    /// Get metadata item by type
    pub fn get(self: *const Mp4MetadataParser, atom_type: AtomType) ?*const MetadataItem {
        for (self.items.items) |*item| {
            if (item.atom_type == atom_type) {
                return item;
            }
        }
        return null;
    }

    /// Get title
    pub fn getTitle(self: *const Mp4MetadataParser) ?[]const u8 {
        if (self.get(.title)) |item| {
            if (item.data_type == .utf8) return item.data;
        }
        return null;
    }

    /// Get artist
    pub fn getArtist(self: *const Mp4MetadataParser) ?[]const u8 {
        if (self.get(.artist)) |item| {
            if (item.data_type == .utf8) return item.data;
        }
        return null;
    }

    /// Get album
    pub fn getAlbum(self: *const Mp4MetadataParser) ?[]const u8 {
        if (self.get(.album)) |item| {
            if (item.data_type == .utf8) return item.data;
        }
        return null;
    }

    /// Get year
    pub fn getYear(self: *const Mp4MetadataParser) ?[]const u8 {
        if (self.get(.year)) |item| {
            if (item.data_type == .utf8) return item.data;
        }
        return null;
    }

    /// Get cover art data
    pub fn getCoverArt(self: *const Mp4MetadataParser) ?struct { data: []const u8, format: DataType } {
        if (self.get(.cover_art)) |item| {
            return .{ .data = item.data, .format = item.data_type };
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AtomType fourCC conversion" {
    const testing = std.testing;

    const title_fourcc = AtomType.title.toFourCC();
    try testing.expectEqual(@as(u8, 0xA9), title_fourcc[0]);
    try testing.expectEqualStrings("nam", title_fourcc[1..4]);

    const back = AtomType.fromFourCC(title_fourcc);
    try testing.expectEqual(AtomType.title, back.?);
}

test "Track number parsing" {
    const testing = std.testing;

    // trkn format: 00 00 00 05 00 12 00 00 (track 5 of 18)
    const data = [_]u8{ 0, 0, 0, 5, 0, 18, 0, 0 };
    const item = MetadataItem{
        .atom_type = .track_number,
        .data_type = .binary,
        .data = &data,
    };

    const track = item.getTrackNumber();
    try testing.expect(track != null);
    try testing.expectEqual(@as(u16, 5), track.?.track);
    try testing.expectEqual(@as(u16, 18), track.?.total);
}

test "DataType values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 1), @intFromEnum(DataType.utf8));
    try testing.expectEqual(@as(u32, 13), @intFromEnum(DataType.jpeg));
    try testing.expectEqual(@as(u32, 14), @intFromEnum(DataType.png));
}
