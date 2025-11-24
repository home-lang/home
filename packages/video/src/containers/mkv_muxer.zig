// Home Video Library - Matroska MKV Muxer
// Full Matroska container with chapters, attachments, multiple subtitle tracks

const std = @import("std");
const core = @import("../core.zig");
const webm = @import("webm_muxer.zig");

/// Matroska-specific element IDs (beyond WebM)
const Matroska = struct {
    const SeekHead = 0x114D9B74;
    const Seek = 0x4DBB;
    const SeekID = 0x53AB;
    const SeekPosition = 0x53AC;
    const Chapters = 0x1043A770;
    const EditionEntry = 0x45B9;
    const ChapterAtom = 0xB6;
    const ChapterUID = 0x73C4;
    const ChapterTimeStart = 0x91;
    const ChapterTimeEnd = 0x92;
    const ChapterDisplay = 0x80;
    const ChapString = 0x85;
    const ChapLanguage = 0x437C;
    const Attachments = 0x1941A469;
    const AttachedFile = 0x61A7;
    const FileDescription = 0x467E;
    const FileName = 0x466E;
    const FileMimeType = 0x4660;
    const FileData = 0x465C;
    const FileUID = 0x46AE;
    const Tags = 0x1254C367;
    const Tag = 0x7373;
    const Targets = 0x63C0;
    const SimpleTag = 0x67C8;
    const TagName = 0x45A3;
    const TagString = 0x4487;
};

/// Chapter entry
pub const Chapter = struct {
    uid: u64,
    time_start: u64,  // in nanoseconds
    time_end: u64,
    title: []const u8,
    language: []const u8 = "eng",
};

/// Attachment entry (for fonts, cover art, etc.)
pub const Attachment = struct {
    uid: u64,
    filename: []const u8,
    mime_type: []const u8,
    description: ?[]const u8 = null,
    data: []const u8,
};

/// Matroska tag
pub const Tag = struct {
    target_type_value: u64 = 50, // 50 = album/movie/episode
    target_track_uid: ?u64 = null,
    tags: std.StringHashMap([]const u8),
};

/// Matroska MKV muxer (full container support)
pub const MKVMuxer = struct {
    allocator: std.mem.Allocator,
    base_muxer: webm.WebMMuxer,

    // Matroska-specific features
    chapters: std.ArrayList(Chapter),
    attachments: std.ArrayList(Attachment),
    tags: std.ArrayList(Tag),

    // Options
    enable_cues: bool = true,
    cue_interval: u64 = 5000, // ms

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, media: *const core.MediaFile) !Self {
        return .{
            .allocator = allocator,
            .base_muxer = try webm.WebMMuxer.init(allocator, media),
            .chapters = std.ArrayList(Chapter).init(allocator),
            .attachments = std.ArrayList(Attachment).init(allocator),
            .tags = std.ArrayList(Tag).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.base_muxer.deinit();
        self.chapters.deinit();

        for (self.attachments.items) |attachment| {
            self.allocator.free(attachment.data);
        }
        self.attachments.deinit();

        for (self.tags.items) |tag| {
            tag.tags.deinit();
        }
        self.tags.deinit();
    }

    pub fn addChapter(self: *Self, chapter: Chapter) !void {
        try self.chapters.append(chapter);
    }

    pub fn addAttachment(self: *Self, attachment: Attachment) !void {
        try self.attachments.append(attachment);
    }

    pub fn addTag(self: *Self, tag: Tag) !void {
        try self.tags.append(tag);
    }

    pub fn addFrame(self: *Self, track_number: u32, timestamp: u64, data: []const u8, is_keyframe: bool) !void {
        try self.base_muxer.addFrame(track_number, timestamp, data, is_keyframe);
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // Write EBML header (matroska instead of webm)
        try self.writeEBMLHeader(&output);

        // Write Segment
        const segment_start = output.items.len;
        try webm.WebMMuxer.writeElementID(&output, webm.Segment.ID);
        try webm.WebMMuxer.writeVInt(&output, 0); // Unknown size

        // SeekHead (index of main elements)
        if (self.enable_cues) {
            try self.writeSeekHead(&output);
        }

        // Segment Info
        try self.base_muxer.writeSegmentInfo(&output);

        // Tracks
        try self.base_muxer.writeTracks(&output);

        // Chapters (if any)
        if (self.chapters.items.len > 0) {
            try self.writeChapters(&output);
        }

        // Attachments (if any)
        if (self.attachments.items.len > 0) {
            try self.writeAttachments(&output);
        }

        // Tags (if any)
        if (self.tags.items.len > 0) {
            try self.writeTags(&output);
        }

        // Clusters
        for (self.base_muxer.clusters.items) |*cluster| {
            try self.base_muxer.writeCluster(&output, cluster);
        }

        // Cues (seeking index)
        if (self.enable_cues) {
            try self.writeCues(&output);
        }

        return output.toOwnedSlice();
    }

    fn writeEBMLHeader(self: *Self, output: *std.ArrayList(u8)) !void {
        _ = self;

        try webm.WebMMuxer.writeElementID(output, webm.EBML.Header);

        var header_data = std.ArrayList(u8).init(output.allocator);
        defer header_data.deinit();

        // Version
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.Version);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(1);

        // ReadVersion
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.ReadVersion);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(1);

        // MaxIDLength
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.MaxIDLength);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(4);

        // MaxSizeLength
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.MaxSizeLength);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(8);

        // DocType = "matroska"
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.DocType);
        const doctype = "matroska";
        try webm.WebMMuxer.writeVInt(&header_data, doctype.len);
        try header_data.appendSlice(doctype);

        // DocTypeVersion
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.DocTypeVersion);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(4);

        // DocTypeReadVersion
        try webm.WebMMuxer.writeElementID(&header_data, webm.EBML.DocTypeReadVersion);
        try webm.WebMMuxer.writeVInt(&header_data, 1);
        try header_data.writer().writeByte(2);

        try webm.WebMMuxer.writeVInt(output, header_data.items.len);
        try output.appendSlice(header_data.items);
    }

    fn writeSeekHead(self: *Self, output: *std.ArrayList(u8)) !void {
        _ = self;
        _ = output;
        // Simplified - would contain index of Tracks, Chapters, Attachments, Cues positions
    }

    fn writeChapters(self: *Self, output: *std.ArrayList(u8)) !void {
        try webm.WebMMuxer.writeElementID(output, Matroska.Chapters);

        var chapters_data = std.ArrayList(u8).init(output.allocator);
        defer chapters_data.deinit();

        // EditionEntry (one edition containing all chapters)
        try webm.WebMMuxer.writeElementID(&chapters_data, Matroska.EditionEntry);

        var edition_data = std.ArrayList(u8).init(output.allocator);
        defer edition_data.deinit();

        for (self.chapters.items) |chapter| {
            try self.writeChapterAtom(&edition_data, &chapter);
        }

        try webm.WebMMuxer.writeVInt(&chapters_data, edition_data.items.len);
        try chapters_data.appendSlice(edition_data.items);

        try webm.WebMMuxer.writeVInt(output, chapters_data.items.len);
        try output.appendSlice(chapters_data.items);
    }

    fn writeChapterAtom(self: *Self, output: *std.ArrayList(u8), chapter: *const Chapter) !void {
        _ = self;

        try webm.WebMMuxer.writeElementID(output, Matroska.ChapterAtom);

        var atom_data = std.ArrayList(u8).init(output.allocator);
        defer atom_data.deinit();

        // ChapterUID
        try webm.WebMMuxer.writeElementID(&atom_data, Matroska.ChapterUID);
        try webm.WebMMuxer.writeVInt(&atom_data, 8);
        try atom_data.writer().writeInt(u64, chapter.uid, .big);

        // ChapterTimeStart
        try webm.WebMMuxer.writeElementID(&atom_data, Matroska.ChapterTimeStart);
        try webm.WebMMuxer.writeVInt(&atom_data, 8);
        try atom_data.writer().writeInt(u64, chapter.time_start, .big);

        // ChapterTimeEnd
        try webm.WebMMuxer.writeElementID(&atom_data, Matroska.ChapterTimeEnd);
        try webm.WebMMuxer.writeVInt(&atom_data, 8);
        try atom_data.writer().writeInt(u64, chapter.time_end, .big);

        // ChapterDisplay
        try webm.WebMMuxer.writeElementID(&atom_data, Matroska.ChapterDisplay);

        var display_data = std.ArrayList(u8).init(output.allocator);
        defer display_data.deinit();

        // ChapString (title)
        try webm.WebMMuxer.writeElementID(&display_data, Matroska.ChapString);
        try webm.WebMMuxer.writeVInt(&display_data, chapter.title.len);
        try display_data.appendSlice(chapter.title);

        // ChapLanguage
        try webm.WebMMuxer.writeElementID(&display_data, Matroska.ChapLanguage);
        try webm.WebMMuxer.writeVInt(&display_data, chapter.language.len);
        try display_data.appendSlice(chapter.language);

        try webm.WebMMuxer.writeVInt(&atom_data, display_data.items.len);
        try atom_data.appendSlice(display_data.items);

        try webm.WebMMuxer.writeVInt(output, atom_data.items.len);
        try output.appendSlice(atom_data.items);
    }

    fn writeAttachments(self: *Self, output: *std.ArrayList(u8)) !void {
        try webm.WebMMuxer.writeElementID(output, Matroska.Attachments);

        var attachments_data = std.ArrayList(u8).init(output.allocator);
        defer attachments_data.deinit();

        for (self.attachments.items) |*attachment| {
            try self.writeAttachedFile(&attachments_data, attachment);
        }

        try webm.WebMMuxer.writeVInt(output, attachments_data.items.len);
        try output.appendSlice(attachments_data.items);
    }

    fn writeAttachedFile(self: *Self, output: *std.ArrayList(u8), attachment: *const Attachment) !void {
        _ = self;

        try webm.WebMMuxer.writeElementID(output, Matroska.AttachedFile);

        var file_data = std.ArrayList(u8).init(output.allocator);
        defer file_data.deinit();

        // FileDescription (optional)
        if (attachment.description) |desc| {
            try webm.WebMMuxer.writeElementID(&file_data, Matroska.FileDescription);
            try webm.WebMMuxer.writeVInt(&file_data, desc.len);
            try file_data.appendSlice(desc);
        }

        // FileName
        try webm.WebMMuxer.writeElementID(&file_data, Matroska.FileName);
        try webm.WebMMuxer.writeVInt(&file_data, attachment.filename.len);
        try file_data.appendSlice(attachment.filename);

        // FileMimeType
        try webm.WebMMuxer.writeElementID(&file_data, Matroska.FileMimeType);
        try webm.WebMMuxer.writeVInt(&file_data, attachment.mime_type.len);
        try file_data.appendSlice(attachment.mime_type);

        // FileData
        try webm.WebMMuxer.writeElementID(&file_data, Matroska.FileData);
        try webm.WebMMuxer.writeVInt(&file_data, attachment.data.len);
        try file_data.appendSlice(attachment.data);

        // FileUID
        try webm.WebMMuxer.writeElementID(&file_data, Matroska.FileUID);
        try webm.WebMMuxer.writeVInt(&file_data, 8);
        try file_data.writer().writeInt(u64, attachment.uid, .big);

        try webm.WebMMuxer.writeVInt(output, file_data.items.len);
        try output.appendSlice(file_data.items);
    }

    fn writeTags(self: *Self, output: *std.ArrayList(u8)) !void {
        try webm.WebMMuxer.writeElementID(output, Matroska.Tags);

        var tags_data = std.ArrayList(u8).init(output.allocator);
        defer tags_data.deinit();

        for (self.tags.items) |*tag| {
            try self.writeTag(&tags_data, tag);
        }

        try webm.WebMMuxer.writeVInt(output, tags_data.items.len);
        try output.appendSlice(tags_data.items);
    }

    fn writeTag(self: *Self, output: *std.ArrayList(u8), tag: *const Tag) !void {
        _ = self;

        try webm.WebMMuxer.writeElementID(output, Matroska.Tag);

        var tag_data = std.ArrayList(u8).init(output.allocator);
        defer tag_data.deinit();

        // Targets
        try webm.WebMMuxer.writeElementID(&tag_data, Matroska.Targets);

        var targets_data = std.ArrayList(u8).init(output.allocator);
        defer targets_data.deinit();

        // TargetTypeValue
        try webm.WebMMuxer.writeElementID(&targets_data, 0x68CA); // TargetTypeValue
        try webm.WebMMuxer.writeVInt(&targets_data, 8);
        try targets_data.writer().writeInt(u64, tag.target_type_value, .big);

        try webm.WebMMuxer.writeVInt(&tag_data, targets_data.items.len);
        try tag_data.appendSlice(targets_data.items);

        // SimpleTags
        var iter = tag.tags.iterator();
        while (iter.next()) |entry| {
            try self.writeSimpleTag(&tag_data, entry.key_ptr.*, entry.value_ptr.*);
        }

        try webm.WebMMuxer.writeVInt(output, tag_data.items.len);
        try output.appendSlice(tag_data.items);
    }

    fn writeSimpleTag(self: *Self, output: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
        _ = self;

        try webm.WebMMuxer.writeElementID(output, Matroska.SimpleTag);

        var simple_tag_data = std.ArrayList(u8).init(output.allocator);
        defer simple_tag_data.deinit();

        // TagName
        try webm.WebMMuxer.writeElementID(&simple_tag_data, Matroska.TagName);
        try webm.WebMMuxer.writeVInt(&simple_tag_data, name.len);
        try simple_tag_data.appendSlice(name);

        // TagString
        try webm.WebMMuxer.writeElementID(&simple_tag_data, Matroska.TagString);
        try webm.WebMMuxer.writeVInt(&simple_tag_data, value.len);
        try simple_tag_data.appendSlice(value);

        try webm.WebMMuxer.writeVInt(output, simple_tag_data.items.len);
        try output.appendSlice(simple_tag_data.items);
    }

    fn writeCues(self: *Self, output: *std.ArrayList(u8)) !void {
        _ = self;
        _ = output;
        // Simplified - would write CuePoint entries for seeking
        // Each CuePoint contains CueTime and CueTrackPositions
    }
};
