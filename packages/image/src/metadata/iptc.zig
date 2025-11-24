// IPTC-IIM (Information Interchange Model) Metadata Parser
// Standard metadata format for news and editorial images

const std = @import("std");

// ============================================================================
// IPTC Record Types
// ============================================================================

pub const Record = enum(u8) {
    envelope = 1, // Envelope record (1:xxx)
    application = 2, // Application record (2:xxx) - most common
    pre_object_data = 7,
    object_data = 8,
    post_object_data = 9,
    _,
};

// ============================================================================
// IPTC Dataset Tags (Record 2 - Application)
// ============================================================================

pub const Tag = enum(u8) {
    // Record 2 tags (Application Record)
    record_version = 0,
    object_type_reference = 3,
    object_attribute_reference = 4,
    object_name = 5, // Title
    edit_status = 7,
    editorial_update = 8,
    urgency = 10,
    subject_reference = 12,
    category = 15,
    supplemental_category = 20,
    fixture_identifier = 22,
    keywords = 25, // Repeatable
    content_location_code = 26,
    content_location_name = 27,
    release_date = 30,
    release_time = 35,
    expiration_date = 37,
    expiration_time = 38,
    special_instructions = 40,
    action_advised = 42,
    reference_service = 45,
    reference_date = 47,
    reference_number = 50,
    date_created = 55,
    time_created = 60,
    digital_creation_date = 62,
    digital_creation_time = 63,
    originating_program = 65,
    program_version = 70,
    object_cycle = 75,
    by_line = 80, // Author/Creator
    by_line_title = 85, // Author title
    city = 90,
    sub_location = 92,
    province_state = 95,
    country_code = 100,
    country_name = 101,
    original_transmission_reference = 103,
    headline = 105,
    credit = 110,
    source = 115,
    copyright_notice = 116,
    contact = 118,
    caption_abstract = 120, // Description
    writer_editor = 122, // Caption writer
    rasterized_caption = 125,
    image_type = 130,
    image_orientation = 131,
    language_identifier = 135,
    audio_type = 150,
    audio_sampling_rate = 151,
    audio_sampling_resolution = 152,
    audio_duration = 153,
    audio_outcue = 154,
    preview_format = 200,
    preview_version = 201,
    preview_data = 202,
    _,

    pub fn name(self: Tag) []const u8 {
        return switch (self) {
            .record_version => "Record Version",
            .object_type_reference => "Object Type Reference",
            .object_attribute_reference => "Object Attribute Reference",
            .object_name => "Title",
            .edit_status => "Edit Status",
            .editorial_update => "Editorial Update",
            .urgency => "Urgency",
            .subject_reference => "Subject Reference",
            .category => "Category",
            .supplemental_category => "Supplemental Category",
            .fixture_identifier => "Fixture Identifier",
            .keywords => "Keywords",
            .content_location_code => "Content Location Code",
            .content_location_name => "Content Location Name",
            .release_date => "Release Date",
            .release_time => "Release Time",
            .expiration_date => "Expiration Date",
            .expiration_time => "Expiration Time",
            .special_instructions => "Special Instructions",
            .action_advised => "Action Advised",
            .reference_service => "Reference Service",
            .reference_date => "Reference Date",
            .reference_number => "Reference Number",
            .date_created => "Date Created",
            .time_created => "Time Created",
            .digital_creation_date => "Digital Creation Date",
            .digital_creation_time => "Digital Creation Time",
            .originating_program => "Originating Program",
            .program_version => "Program Version",
            .object_cycle => "Object Cycle",
            .by_line => "By-line (Author)",
            .by_line_title => "By-line Title",
            .city => "City",
            .sub_location => "Sub-location",
            .province_state => "Province/State",
            .country_code => "Country Code",
            .country_name => "Country Name",
            .original_transmission_reference => "Original Transmission Reference",
            .headline => "Headline",
            .credit => "Credit",
            .source => "Source",
            .copyright_notice => "Copyright Notice",
            .contact => "Contact",
            .caption_abstract => "Caption/Abstract",
            .writer_editor => "Writer/Editor",
            .rasterized_caption => "Rasterized Caption",
            .image_type => "Image Type",
            .image_orientation => "Image Orientation",
            .language_identifier => "Language Identifier",
            .audio_type => "Audio Type",
            .audio_sampling_rate => "Audio Sampling Rate",
            .audio_sampling_resolution => "Audio Sampling Resolution",
            .audio_duration => "Audio Duration",
            .audio_outcue => "Audio Outcue",
            .preview_format => "Preview Format",
            .preview_version => "Preview Version",
            .preview_data => "Preview Data",
            else => "Unknown",
        };
    }

    pub fn isRepeatable(self: Tag) bool {
        return switch (self) {
            .keywords,
            .supplemental_category,
            .subject_reference,
            .content_location_code,
            .content_location_name,
            .reference_service,
            .reference_date,
            .reference_number,
            .by_line,
            .by_line_title,
            .contact,
            .writer_editor,
            => true,
            else => false,
        };
    }
};

// ============================================================================
// IPTC Dataset
// ============================================================================

pub const Dataset = struct {
    record: Record,
    tag: Tag,
    value: []const u8,

    pub fn deinit(self: *Dataset, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

// ============================================================================
// IPTC Data Structure
// ============================================================================

pub const IptcData = struct {
    allocator: std.mem.Allocator,

    // Core identification
    title: ?[]const u8 = null, // 2:5 Object Name
    headline: ?[]const u8 = null, // 2:105
    caption: ?[]const u8 = null, // 2:120 Caption/Abstract

    // Creator information
    by_line: ?[]const u8 = null, // 2:80 Author
    by_line_title: ?[]const u8 = null, // 2:85
    credit: ?[]const u8 = null, // 2:110
    source: ?[]const u8 = null, // 2:115
    copyright: ?[]const u8 = null, // 2:116

    // Keywords
    keywords: ?[][]const u8 = null, // 2:25 (repeatable)
    category: ?[]const u8 = null, // 2:15
    supplemental_categories: ?[][]const u8 = null, // 2:20 (repeatable)

    // Location
    city: ?[]const u8 = null, // 2:90
    sub_location: ?[]const u8 = null, // 2:92
    province_state: ?[]const u8 = null, // 2:95
    country_code: ?[]const u8 = null, // 2:100 (3-letter ISO)
    country_name: ?[]const u8 = null, // 2:101

    // Dates/Times
    date_created: ?[]const u8 = null, // 2:55 YYYYMMDD
    time_created: ?[]const u8 = null, // 2:60 HHMMSS±HHMM
    digital_creation_date: ?[]const u8 = null, // 2:62
    digital_creation_time: ?[]const u8 = null, // 2:63
    release_date: ?[]const u8 = null, // 2:30
    release_time: ?[]const u8 = null, // 2:35
    expiration_date: ?[]const u8 = null, // 2:37
    expiration_time: ?[]const u8 = null, // 2:38

    // Editorial
    urgency: ?u8 = null, // 2:10 (1-8, 1=most urgent)
    special_instructions: ?[]const u8 = null, // 2:40
    edit_status: ?[]const u8 = null, // 2:7

    // Technical
    originating_program: ?[]const u8 = null, // 2:65
    program_version: ?[]const u8 = null, // 2:70
    writer_editor: ?[]const u8 = null, // 2:122

    // Contact
    contact: ?[][]const u8 = null, // 2:118 (repeatable)

    // All datasets (for extended/custom data)
    datasets: std.ArrayList(Dataset),

    pub fn init(allocator: std.mem.Allocator) IptcData {
        return IptcData{
            .allocator = allocator,
            .datasets = std.ArrayList(Dataset).init(allocator),
        };
    }

    pub fn deinit(self: *IptcData) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.headline) |h| self.allocator.free(h);
        if (self.caption) |c| self.allocator.free(c);
        if (self.by_line) |b| self.allocator.free(b);
        if (self.by_line_title) |t| self.allocator.free(t);
        if (self.credit) |c| self.allocator.free(c);
        if (self.source) |s| self.allocator.free(s);
        if (self.copyright) |c| self.allocator.free(c);

        if (self.keywords) |kw| {
            for (kw) |k| self.allocator.free(k);
            self.allocator.free(kw);
        }
        if (self.category) |c| self.allocator.free(c);
        if (self.supplemental_categories) |sc| {
            for (sc) |c| self.allocator.free(c);
            self.allocator.free(sc);
        }

        if (self.city) |c| self.allocator.free(c);
        if (self.sub_location) |s| self.allocator.free(s);
        if (self.province_state) |p| self.allocator.free(p);
        if (self.country_code) |c| self.allocator.free(c);
        if (self.country_name) |c| self.allocator.free(c);

        if (self.date_created) |d| self.allocator.free(d);
        if (self.time_created) |t| self.allocator.free(t);
        if (self.digital_creation_date) |d| self.allocator.free(d);
        if (self.digital_creation_time) |t| self.allocator.free(t);
        if (self.release_date) |d| self.allocator.free(d);
        if (self.release_time) |t| self.allocator.free(t);
        if (self.expiration_date) |d| self.allocator.free(d);
        if (self.expiration_time) |t| self.allocator.free(t);

        if (self.special_instructions) |s| self.allocator.free(s);
        if (self.edit_status) |e| self.allocator.free(e);
        if (self.originating_program) |o| self.allocator.free(o);
        if (self.program_version) |p| self.allocator.free(p);
        if (self.writer_editor) |w| self.allocator.free(w);

        if (self.contact) |c| {
            for (c) |item| self.allocator.free(item);
            self.allocator.free(c);
        }

        for (self.datasets.items) |*ds| {
            ds.deinit(self.allocator);
        }
        self.datasets.deinit();
    }

    pub fn getDataset(self: *const IptcData, record: Record, tag: Tag) ?[]const u8 {
        for (self.datasets.items) |ds| {
            if (ds.record == record and ds.tag == tag) {
                return ds.value;
            }
        }
        return null;
    }

    pub fn getAllDatasets(self: *const IptcData, record: Record, tag: Tag, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        defer list.deinit();

        for (self.datasets.items) |ds| {
            if (ds.record == record and ds.tag == tag) {
                try list.append(ds.value);
            }
        }

        return list.toOwnedSlice();
    }

    /// Format creation date/time as ISO 8601
    pub fn getCreationDateTime(self: *const IptcData) ?[25]u8 {
        if (self.date_created == null) return null;
        const date = self.date_created.?;
        if (date.len < 8) return null;

        var result: [25]u8 = undefined;

        // Format: YYYY-MM-DDTHH:MM:SS±HH:MM
        result[0] = date[0];
        result[1] = date[1];
        result[2] = date[2];
        result[3] = date[3];
        result[4] = '-';
        result[5] = date[4];
        result[6] = date[5];
        result[7] = '-';
        result[8] = date[6];
        result[9] = date[7];

        if (self.time_created) |time| {
            if (time.len >= 6) {
                result[10] = 'T';
                result[11] = time[0];
                result[12] = time[1];
                result[13] = ':';
                result[14] = time[2];
                result[15] = time[3];
                result[16] = ':';
                result[17] = time[4];
                result[18] = time[5];

                if (time.len >= 11) {
                    // Timezone
                    result[19] = time[6];
                    result[20] = time[7];
                    result[21] = time[8];
                    result[22] = ':';
                    result[23] = time[9];
                    result[24] = time[10];
                } else {
                    result[19] = 'Z';
                    result[20] = 0;
                    result[21] = 0;
                    result[22] = 0;
                    result[23] = 0;
                    result[24] = 0;
                }
            }
        } else {
            result[10] = 'T';
            result[11] = '0';
            result[12] = '0';
            result[13] = ':';
            result[14] = '0';
            result[15] = '0';
            result[16] = ':';
            result[17] = '0';
            result[18] = '0';
            result[19] = 'Z';
            @memset(result[20..25], 0);
        }

        return result;
    }
};

// ============================================================================
// IPTC Parser
// ============================================================================

pub const IptcParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,

    const IPTC_MARKER = 0x1C; // Tag marker

    pub fn init(allocator: std.mem.Allocator, data: []const u8) IptcParser {
        return IptcParser{
            .allocator = allocator,
            .data = data,
            .pos = 0,
        };
    }

    pub fn parse(self: *IptcParser) !IptcData {
        var iptc = IptcData.init(self.allocator);
        errdefer iptc.deinit();

        var keywords_list = std.ArrayList([]const u8).init(self.allocator);
        defer keywords_list.deinit();

        var supp_cat_list = std.ArrayList([]const u8).init(self.allocator);
        defer supp_cat_list.deinit();

        var contact_list = std.ArrayList([]const u8).init(self.allocator);
        defer contact_list.deinit();

        while (self.pos + 5 <= self.data.len) {
            // Each dataset starts with 0x1C
            if (self.data[self.pos] != IPTC_MARKER) {
                self.pos += 1;
                continue;
            }

            const record: Record = @enumFromInt(self.data[self.pos + 1]);
            const tag: Tag = @enumFromInt(self.data[self.pos + 2]);

            // Get data length
            var data_len: usize = undefined;
            var header_len: usize = 5;

            const len_byte1 = self.data[self.pos + 3];
            const len_byte2 = self.data[self.pos + 4];

            if ((len_byte1 & 0x80) != 0) {
                // Extended dataset
                const ext_len = ((len_byte1 & 0x7F) << 8) | len_byte2;
                if (self.pos + 5 + ext_len > self.data.len) break;

                // Read extended length
                data_len = 0;
                for (0..ext_len) |i| {
                    data_len = (data_len << 8) | self.data[self.pos + 5 + i];
                }
                header_len = 5 + ext_len;
            } else {
                // Standard dataset
                data_len = (@as(usize, len_byte1) << 8) | len_byte2;
            }

            if (self.pos + header_len + data_len > self.data.len) break;

            const value = self.data[self.pos + header_len .. self.pos + header_len + data_len];

            // Store in datasets list
            const ds = Dataset{
                .record = record,
                .tag = tag,
                .value = try self.allocator.dupe(u8, value),
            };
            try iptc.datasets.append(ds);

            // Process known tags (Record 2 - Application)
            if (record == .application) {
                switch (tag) {
                    .object_name => iptc.title = try self.allocator.dupe(u8, value),
                    .headline => iptc.headline = try self.allocator.dupe(u8, value),
                    .caption_abstract => iptc.caption = try self.allocator.dupe(u8, value),
                    .by_line => iptc.by_line = try self.allocator.dupe(u8, value),
                    .by_line_title => iptc.by_line_title = try self.allocator.dupe(u8, value),
                    .credit => iptc.credit = try self.allocator.dupe(u8, value),
                    .source => iptc.source = try self.allocator.dupe(u8, value),
                    .copyright_notice => iptc.copyright = try self.allocator.dupe(u8, value),
                    .keywords => try keywords_list.append(try self.allocator.dupe(u8, value)),
                    .category => iptc.category = try self.allocator.dupe(u8, value),
                    .supplemental_category => try supp_cat_list.append(try self.allocator.dupe(u8, value)),
                    .city => iptc.city = try self.allocator.dupe(u8, value),
                    .sub_location => iptc.sub_location = try self.allocator.dupe(u8, value),
                    .province_state => iptc.province_state = try self.allocator.dupe(u8, value),
                    .country_code => iptc.country_code = try self.allocator.dupe(u8, value),
                    .country_name => iptc.country_name = try self.allocator.dupe(u8, value),
                    .date_created => iptc.date_created = try self.allocator.dupe(u8, value),
                    .time_created => iptc.time_created = try self.allocator.dupe(u8, value),
                    .digital_creation_date => iptc.digital_creation_date = try self.allocator.dupe(u8, value),
                    .digital_creation_time => iptc.digital_creation_time = try self.allocator.dupe(u8, value),
                    .release_date => iptc.release_date = try self.allocator.dupe(u8, value),
                    .release_time => iptc.release_time = try self.allocator.dupe(u8, value),
                    .expiration_date => iptc.expiration_date = try self.allocator.dupe(u8, value),
                    .expiration_time => iptc.expiration_time = try self.allocator.dupe(u8, value),
                    .urgency => {
                        if (value.len > 0) {
                            iptc.urgency = value[0] - '0';
                        }
                    },
                    .special_instructions => iptc.special_instructions = try self.allocator.dupe(u8, value),
                    .edit_status => iptc.edit_status = try self.allocator.dupe(u8, value),
                    .originating_program => iptc.originating_program = try self.allocator.dupe(u8, value),
                    .program_version => iptc.program_version = try self.allocator.dupe(u8, value),
                    .writer_editor => iptc.writer_editor = try self.allocator.dupe(u8, value),
                    .contact => try contact_list.append(try self.allocator.dupe(u8, value)),
                    else => {},
                }
            }

            self.pos += header_len + data_len;
        }

        // Convert lists to slices
        if (keywords_list.items.len > 0) {
            iptc.keywords = try keywords_list.toOwnedSlice();
        }
        if (supp_cat_list.items.len > 0) {
            iptc.supplemental_categories = try supp_cat_list.toOwnedSlice();
        }
        if (contact_list.items.len > 0) {
            iptc.contact = try contact_list.toOwnedSlice();
        }

        return iptc;
    }
};

// ============================================================================
// IPTC Writer
// ============================================================================

pub const IptcWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) IptcWriter {
        return IptcWriter{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *IptcWriter) void {
        self.buffer.deinit();
    }

    pub fn write(self: *IptcWriter, iptc: *const IptcData) ![]const u8 {
        self.buffer.clearRetainingCapacity();

        // Write Record 2 version (2:0)
        try self.writeDataset(.application, .record_version, &[_]u8{ 0, 4 });

        // Core identification
        if (iptc.title) |t| try self.writeDataset(.application, .object_name, t);
        if (iptc.headline) |h| try self.writeDataset(.application, .headline, h);
        if (iptc.caption) |c| try self.writeDataset(.application, .caption_abstract, c);

        // Creator information
        if (iptc.by_line) |b| try self.writeDataset(.application, .by_line, b);
        if (iptc.by_line_title) |t| try self.writeDataset(.application, .by_line_title, t);
        if (iptc.credit) |c| try self.writeDataset(.application, .credit, c);
        if (iptc.source) |s| try self.writeDataset(.application, .source, s);
        if (iptc.copyright) |c| try self.writeDataset(.application, .copyright_notice, c);

        // Keywords
        if (iptc.keywords) |kw| {
            for (kw) |k| {
                try self.writeDataset(.application, .keywords, k);
            }
        }

        // Category
        if (iptc.category) |c| try self.writeDataset(.application, .category, c);
        if (iptc.supplemental_categories) |sc| {
            for (sc) |c| {
                try self.writeDataset(.application, .supplemental_category, c);
            }
        }

        // Location
        if (iptc.city) |c| try self.writeDataset(.application, .city, c);
        if (iptc.sub_location) |s| try self.writeDataset(.application, .sub_location, s);
        if (iptc.province_state) |p| try self.writeDataset(.application, .province_state, p);
        if (iptc.country_code) |c| try self.writeDataset(.application, .country_code, c);
        if (iptc.country_name) |c| try self.writeDataset(.application, .country_name, c);

        // Dates
        if (iptc.date_created) |d| try self.writeDataset(.application, .date_created, d);
        if (iptc.time_created) |t| try self.writeDataset(.application, .time_created, t);
        if (iptc.digital_creation_date) |d| try self.writeDataset(.application, .digital_creation_date, d);
        if (iptc.digital_creation_time) |t| try self.writeDataset(.application, .digital_creation_time, t);

        // Editorial
        if (iptc.urgency) |u| {
            try self.writeDataset(.application, .urgency, &[_]u8{'0' + u});
        }
        if (iptc.special_instructions) |s| try self.writeDataset(.application, .special_instructions, s);

        // Technical
        if (iptc.originating_program) |o| try self.writeDataset(.application, .originating_program, o);
        if (iptc.program_version) |p| try self.writeDataset(.application, .program_version, p);
        if (iptc.writer_editor) |w| try self.writeDataset(.application, .writer_editor, w);

        // Contact
        if (iptc.contact) |contacts| {
            for (contacts) |c| {
                try self.writeDataset(.application, .contact, c);
            }
        }

        return self.buffer.items;
    }

    fn writeDataset(self: *IptcWriter, record: Record, tag: Tag, value: []const u8) !void {
        try self.buffer.append(0x1C); // Tag marker
        try self.buffer.append(@intFromEnum(record));
        try self.buffer.append(@intFromEnum(tag));

        // Write length
        if (value.len > 32767) {
            // Extended dataset (not common, but supported)
            const len_bytes: u16 = 4;
            try self.buffer.append(0x80 | @as(u8, @intCast(len_bytes >> 8)));
            try self.buffer.append(@truncate(len_bytes));

            // Write 4-byte length
            try self.buffer.append(@intCast((value.len >> 24) & 0xFF));
            try self.buffer.append(@intCast((value.len >> 16) & 0xFF));
            try self.buffer.append(@intCast((value.len >> 8) & 0xFF));
            try self.buffer.append(@intCast(value.len & 0xFF));
        } else {
            // Standard dataset
            try self.buffer.append(@intCast((value.len >> 8) & 0xFF));
            try self.buffer.append(@intCast(value.len & 0xFF));
        }

        try self.buffer.appendSlice(value);
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Parse IPTC from raw bytes
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !IptcData {
    var parser = IptcParser.init(allocator, data);
    return parser.parse();
}

/// Find IPTC in JPEG APP13 segment
pub fn findInJpeg(data: []const u8) ?[]const u8 {
    const PHOTOSHOP_HEADER = "Photoshop 3.0";
    const IPTC_RESOURCE_ID = [_]u8{ 0x04, 0x04 }; // 8BIM resource 0x0404

    var i: usize = 2; // Skip SOI
    while (i + 4 < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }

        const marker = data[i + 1];

        // APP13 marker
        if (marker == 0xED) {
            const length = (@as(u16, data[i + 2]) << 8) | data[i + 3];
            if (i + 2 + length > data.len) break;

            const segment_data = data[i + 4 .. i + 2 + length];

            // Check for Photoshop header
            if (std.mem.startsWith(u8, segment_data, PHOTOSHOP_HEADER)) {
                // Search for IPTC resource (8BIM 0x0404)
                var j: usize = PHOTOSHOP_HEADER.len + 1;
                while (j + 12 < segment_data.len) {
                    if (std.mem.eql(u8, segment_data[j .. j + 4], "8BIM")) {
                        const resource_id = (@as(u16, segment_data[j + 4]) << 8) | segment_data[j + 5];
                        if (resource_id == 0x0404) {
                            // Skip pascal string name
                            const name_len = segment_data[j + 6];
                            const padded_name_len = if ((name_len + 1) % 2 == 0) name_len + 1 else name_len + 2;

                            const data_offset = j + 6 + padded_name_len;
                            if (data_offset + 4 > segment_data.len) break;

                            const iptc_len = (@as(u32, segment_data[data_offset]) << 24) |
                                (@as(u32, segment_data[data_offset + 1]) << 16) |
                                (@as(u32, segment_data[data_offset + 2]) << 8) |
                                segment_data[data_offset + 3];

                            const iptc_start = data_offset + 4;
                            if (iptc_start + iptc_len <= segment_data.len) {
                                return segment_data[iptc_start .. iptc_start + iptc_len];
                            }
                        }

                        // Skip to next resource
                        const res_name_len = segment_data[j + 6];
                        const res_padded_name_len = if ((res_name_len + 1) % 2 == 0) res_name_len + 1 else res_name_len + 2;
                        const res_data_offset = j + 6 + res_padded_name_len;
                        if (res_data_offset + 4 > segment_data.len) break;

                        const res_len = (@as(u32, segment_data[res_data_offset]) << 24) |
                            (@as(u32, segment_data[res_data_offset + 1]) << 16) |
                            (@as(u32, segment_data[res_data_offset + 2]) << 8) |
                            segment_data[res_data_offset + 3];

                        j = res_data_offset + 4 + res_len;
                        if (res_len % 2 != 0) j += 1; // Pad to even
                    } else {
                        j += 1;
                    }
                }
            }

            i += 2 + length;
        } else if (marker >= 0xE0 and marker <= 0xEF) {
            // Other APP markers
            const length = (@as(u16, data[i + 2]) << 8) | data[i + 3];
            i += 2 + length;
        } else if (marker == 0xDA) {
            // Start of scan - end of headers
            break;
        } else {
            i += 2;
        }
    }

    return null;
}

/// Check if data contains IPTC
pub fn containsIptc(data: []const u8) bool {
    // Look for IPTC tag marker followed by record 2
    var i: usize = 0;
    while (i + 3 < data.len) {
        if (data[i] == 0x1C and data[i + 1] == 0x02) {
            return true;
        }
        i += 1;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "IPTC tag names" {
    try std.testing.expectEqualStrings("Title", Tag.object_name.name());
    try std.testing.expectEqualStrings("Headline", Tag.headline.name());
    try std.testing.expectEqualStrings("Keywords", Tag.keywords.name());
}

test "IPTC tag repeatability" {
    try std.testing.expect(Tag.keywords.isRepeatable());
    try std.testing.expect(!Tag.headline.isRepeatable());
}

test "IPTC writer basic" {
    var iptc = IptcData.init(std.testing.allocator);
    defer iptc.deinit();

    iptc.title = try std.testing.allocator.dupe(u8, "Test Title");
    iptc.headline = try std.testing.allocator.dupe(u8, "Test Headline");

    var writer = IptcWriter.init(std.testing.allocator);
    defer writer.deinit();

    const output = try writer.write(&iptc);
    try std.testing.expect(output.len > 0);

    // Verify marker bytes
    try std.testing.expect(output[0] == 0x1C);
}

test "IPTC contains detection" {
    const sample_iptc = [_]u8{ 0x1C, 0x02, 0x05, 0x00, 0x04, 'T', 'e', 's', 't' };
    try std.testing.expect(containsIptc(&sample_iptc));
    try std.testing.expect(!containsIptc("not iptc data"));
}
