// Home Video Library - Metadata Module
// Re-exports all metadata format modules

pub const id3 = @import("id3.zig");
pub const mp4meta = @import("mp4meta.zig");
pub const matroska_tags = @import("matroska_tags.zig");

// ID3 types
pub const Id3v1Tag = id3.Id3v1Tag;
pub const Id3v2Header = id3.Id3v2Header;
pub const Id3v2Frame = id3.Id3v2Frame;
pub const Id3v2Parser = id3.Id3v2Parser;
pub const parseId3v1 = id3.parseId3v1;
pub const writeId3v1 = id3.writeId3v1;
pub const hasId3v1 = id3.hasId3v1;
pub const hasId3v2 = id3.hasId3v2;
pub const Id3FrameId = id3.FrameId;

// MP4 metadata types
pub const Mp4AtomType = mp4meta.AtomType;
pub const Mp4DataType = mp4meta.DataType;
pub const Mp4MetadataItem = mp4meta.MetadataItem;
pub const Mp4MetadataParser = mp4meta.Mp4MetadataParser;

// Matroska tags types
pub const MkvElementId = matroska_tags.ElementId;
pub const MkvTargetType = matroska_tags.TargetType;
pub const MkvTagName = matroska_tags.TagName;
pub const MkvSimpleTag = matroska_tags.SimpleTag;
pub const MkvTagTarget = matroska_tags.TagTarget;
pub const MkvTag = matroska_tags.Tag;
pub const MatroskaTagsParser = matroska_tags.MatroskaTagsParser;

// ============================================================================
// Universal Metadata Interface
// ============================================================================

/// Universal metadata container
pub const Metadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    year: ?[]const u8 = null,
    track_number: ?u16 = null,
    track_total: ?u16 = null,
    disc_number: ?u16 = null,
    disc_total: ?u16 = null,
    comment: ?[]const u8 = null,
    description: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    encoder: ?[]const u8 = null,
    duration_ms: ?u64 = null,

    // Cover art
    cover_art: ?[]const u8 = null,
    cover_art_mime: ?[]const u8 = null,

    /// Import from ID3v1 tag
    pub fn fromId3v1(tag: *const Id3v1Tag) Metadata {
        return .{
            .title = if (tag.getTitle().len > 0) tag.getTitle() else null,
            .artist = if (tag.getArtist().len > 0) tag.getArtist() else null,
            .album = if (tag.getAlbum().len > 0) tag.getAlbum() else null,
            .year = if (tag.getYear().len > 0) tag.getYear() else null,
            .genre = tag.getGenreName(),
            .track_number = tag.track,
        };
    }

    /// Import from MP4 metadata parser
    pub fn fromMp4(parser: *const Mp4MetadataParser) Metadata {
        var meta = Metadata{
            .title = parser.getTitle(),
            .artist = parser.getArtist(),
            .album = parser.getAlbum(),
            .year = parser.getYear(),
        };

        if (parser.get(.track_number)) |item| {
            if (item.getTrackNumber()) |tn| {
                meta.track_number = tn.track;
                meta.track_total = if (tn.total > 0) tn.total else null;
            }
        }

        if (parser.get(.disc_number)) |item| {
            if (item.getDiscNumber()) |dn| {
                meta.disc_number = dn.disc;
                meta.disc_total = if (dn.total > 0) dn.total else null;
            }
        }

        if (parser.getCoverArt()) |cover| {
            meta.cover_art = cover.data;
            meta.cover_art_mime = switch (cover.format) {
                .jpeg => "image/jpeg",
                .png => "image/png",
                .gif => "image/gif",
                .bmp => "image/bmp",
                else => null,
            };
        }

        return meta;
    }

    /// Import from Matroska tags
    pub fn fromMatroska(parser: *const MatroskaTagsParser) Metadata {
        return .{
            .title = parser.getTitle(),
            .artist = parser.getArtist(),
            .genre = parser.getGenre(),
            .composer = parser.getValue(MkvTagName.COMPOSER),
            .description = parser.getValue(MkvTagName.DESCRIPTION),
            .comment = parser.getValue(MkvTagName.COMMENT),
            .year = parser.getValue(MkvTagName.DATE_RELEASED),
            .encoder = parser.getValue(MkvTagName.ENCODER),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Metadata imports" {
    _ = id3;
    _ = mp4meta;
    _ = matroska_tags;
}

test "Universal metadata from ID3v1" {
    const testing = std.testing;

    var tag = Id3v1Tag{};
    @memcpy(tag.title[0..5], "Title");
    @memcpy(tag.artist[0..6], "Artist");
    tag.genre = 17; // Rock

    const meta = Metadata.fromId3v1(&tag);
    try testing.expectEqualStrings("Title", meta.title.?);
    try testing.expectEqualStrings("Artist", meta.artist.?);
    try testing.expectEqualStrings("Rock", meta.genre.?);
}
