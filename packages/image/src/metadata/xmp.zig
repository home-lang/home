// XMP (Extensible Metadata Platform) Metadata Parser
// Adobe's XML-based metadata standard for images

const std = @import("std");

// ============================================================================
// XMP Namespaces
// ============================================================================

pub const Namespace = enum {
    // Core namespaces
    rdf, // Resource Description Framework
    xmp, // XMP Core
    xmpMM, // XMP Media Management
    xmpRights, // XMP Rights Management
    xmpDM, // XMP Dynamic Media

    // Dublin Core
    dc, // Dublin Core

    // Adobe-specific
    photoshop, // Photoshop
    camera_raw, // Camera Raw
    exif, // EXIF in XMP
    tiff, // TIFF in XMP
    aux, // Auxiliary EXIF

    // IPTC
    iptc4xmpCore, // IPTC Core
    iptc4xmpExt, // IPTC Extension

    // Custom/unknown
    unknown,

    pub fn uri(self: Namespace) []const u8 {
        return switch (self) {
            .rdf => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
            .xmp => "http://ns.adobe.com/xap/1.0/",
            .xmpMM => "http://ns.adobe.com/xap/1.0/mm/",
            .xmpRights => "http://ns.adobe.com/xap/1.0/rights/",
            .xmpDM => "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
            .dc => "http://purl.org/dc/elements/1.1/",
            .photoshop => "http://ns.adobe.com/photoshop/1.0/",
            .camera_raw => "http://ns.adobe.com/camera-raw-settings/1.0/",
            .exif => "http://ns.adobe.com/exif/1.0/",
            .tiff => "http://ns.adobe.com/tiff/1.0/",
            .aux => "http://ns.adobe.com/exif/1.0/aux/",
            .iptc4xmpCore => "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
            .iptc4xmpExt => "http://iptc.org/std/Iptc4xmpExt/2008-02-29/",
            .unknown => "",
        };
    }

    pub fn fromUri(uri_str: []const u8) Namespace {
        if (std.mem.indexOf(u8, uri_str, "22-rdf-syntax") != null) return .rdf;
        if (std.mem.indexOf(u8, uri_str, "xap/1.0/mm") != null) return .xmpMM;
        if (std.mem.indexOf(u8, uri_str, "xap/1.0/rights") != null) return .xmpRights;
        if (std.mem.indexOf(u8, uri_str, "xap/1.0") != null) return .xmp;
        if (std.mem.indexOf(u8, uri_str, "DynamicMedia") != null) return .xmpDM;
        if (std.mem.indexOf(u8, uri_str, "dc/elements") != null) return .dc;
        if (std.mem.indexOf(u8, uri_str, "photoshop") != null) return .photoshop;
        if (std.mem.indexOf(u8, uri_str, "camera-raw") != null) return .camera_raw;
        if (std.mem.indexOf(u8, uri_str, "exif/1.0/aux") != null) return .aux;
        if (std.mem.indexOf(u8, uri_str, "exif") != null) return .exif;
        if (std.mem.indexOf(u8, uri_str, "tiff") != null) return .tiff;
        if (std.mem.indexOf(u8, uri_str, "Iptc4xmpCore") != null) return .iptc4xmpCore;
        if (std.mem.indexOf(u8, uri_str, "Iptc4xmpExt") != null) return .iptc4xmpExt;
        return .unknown;
    }
};

// ============================================================================
// XMP Property Types
// ============================================================================

pub const PropertyType = enum {
    simple, // Simple text value
    uri, // URI reference
    date, // ISO 8601 date
    integer, // Integer value
    real, // Floating point
    boolean, // Boolean
    lang_alt, // Language alternative (multiple languages)
    bag, // Unordered array
    seq, // Ordered array
    alt, // Alternative array (first is default)
    struct_type, // Structured value
};

// ============================================================================
// XMP Data Structures
// ============================================================================

pub const XmpProperty = struct {
    namespace: Namespace,
    name: []const u8,
    value: []const u8,
    prop_type: PropertyType,
    lang: ?[]const u8, // Language tag for lang_alt

    pub fn deinit(self: *XmpProperty, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        if (self.lang) |l| allocator.free(l);
    }
};

pub const XmpData = struct {
    allocator: std.mem.Allocator,

    // Dublin Core metadata
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    subject: ?[][]const u8 = null, // Keywords/tags
    rights: ?[]const u8 = null,
    format: ?[]const u8 = null,

    // XMP Core
    create_date: ?[]const u8 = null,
    modify_date: ?[]const u8 = null,
    metadata_date: ?[]const u8 = null,
    creator_tool: ?[]const u8 = null,
    rating: ?i32 = null,
    label: ?[]const u8 = null,

    // XMP Media Management
    document_id: ?[]const u8 = null,
    instance_id: ?[]const u8 = null,
    original_document_id: ?[]const u8 = null,

    // XMP Rights
    marked: ?bool = null, // Copyright marked
    web_statement: ?[]const u8 = null,
    usage_terms: ?[]const u8 = null,

    // Photoshop-specific
    headline: ?[]const u8 = null,
    city: ?[]const u8 = null,
    state: ?[]const u8 = null,
    country: ?[]const u8 = null,
    credit: ?[]const u8 = null,
    source: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    color_mode: ?u8 = null,

    // Camera Raw settings
    raw_file_name: ?[]const u8 = null,
    version: ?[]const u8 = null,

    // All properties (for custom/extended data)
    properties: std.ArrayList(XmpProperty),

    // Raw XMP packet
    raw_xmp: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) XmpData {
        return XmpData{
            .allocator = allocator,
            .properties = std.ArrayList(XmpProperty).init(allocator),
        };
    }

    pub fn deinit(self: *XmpData) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.description) |d| self.allocator.free(d);
        if (self.creator) |c| self.allocator.free(c);
        if (self.subject) |s| {
            for (s) |item| self.allocator.free(item);
            self.allocator.free(s);
        }
        if (self.rights) |r| self.allocator.free(r);
        if (self.format) |f| self.allocator.free(f);
        if (self.create_date) |d| self.allocator.free(d);
        if (self.modify_date) |d| self.allocator.free(d);
        if (self.metadata_date) |d| self.allocator.free(d);
        if (self.creator_tool) |t| self.allocator.free(t);
        if (self.label) |l| self.allocator.free(l);
        if (self.document_id) |d| self.allocator.free(d);
        if (self.instance_id) |i| self.allocator.free(i);
        if (self.original_document_id) |d| self.allocator.free(d);
        if (self.web_statement) |w| self.allocator.free(w);
        if (self.usage_terms) |u| self.allocator.free(u);
        if (self.headline) |h| self.allocator.free(h);
        if (self.city) |c| self.allocator.free(c);
        if (self.state) |s| self.allocator.free(s);
        if (self.country) |c| self.allocator.free(c);
        if (self.credit) |c| self.allocator.free(c);
        if (self.source) |s| self.allocator.free(s);
        if (self.instructions) |i| self.allocator.free(i);
        if (self.raw_file_name) |r| self.allocator.free(r);
        if (self.version) |v| self.allocator.free(v);
        if (self.raw_xmp) |r| self.allocator.free(r);

        for (self.properties.items) |*prop| {
            prop.deinit(self.allocator);
        }
        self.properties.deinit();
    }

    pub fn addProperty(self: *XmpData, prop: XmpProperty) !void {
        try self.properties.append(prop);
    }

    pub fn getProperty(self: *const XmpData, namespace: Namespace, name: []const u8) ?[]const u8 {
        for (self.properties.items) |prop| {
            if (prop.namespace == namespace and std.mem.eql(u8, prop.name, name)) {
                return prop.value;
            }
        }
        return null;
    }
};

// ============================================================================
// XMP Parser
// ============================================================================

pub const XmpParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,

    const XMP_HEADER = "<?xpacket begin";
    const XMP_FOOTER = "<?xpacket end";
    const RDF_START = "<rdf:RDF";
    const RDF_END = "</rdf:RDF>";
    const DESCRIPTION_START = "<rdf:Description";

    pub fn init(allocator: std.mem.Allocator, data: []const u8) XmpParser {
        return XmpParser{
            .allocator = allocator,
            .data = data,
            .pos = 0,
        };
    }

    pub fn parse(self: *XmpParser) !XmpData {
        var xmp = XmpData.init(self.allocator);
        errdefer xmp.deinit();

        // Store raw XMP
        xmp.raw_xmp = try self.allocator.dupe(u8, self.data);

        // Find RDF content
        const rdf_start = std.mem.indexOf(u8, self.data, RDF_START) orelse return xmp;
        const rdf_end = std.mem.indexOf(u8, self.data, RDF_END) orelse return xmp;

        if (rdf_start >= rdf_end) return xmp;

        // Parse rdf:Description elements
        var search_pos = rdf_start;
        while (std.mem.indexOfPos(u8, self.data, search_pos, DESCRIPTION_START)) |desc_start| {
            if (desc_start >= rdf_end) break;

            // Find end of this Description element
            const desc_content_start = std.mem.indexOfPos(u8, self.data, desc_start, ">") orelse break;

            // Check if self-closing
            if (self.data[desc_content_start - 1] == '/') {
                // Parse attributes from self-closing tag
                try self.parseDescriptionAttributes(&xmp, self.data[desc_start..desc_content_start]);
                search_pos = desc_content_start + 1;
                continue;
            }

            // Find closing tag
            const desc_end = std.mem.indexOfPos(u8, self.data, desc_content_start, "</rdf:Description>") orelse break;

            // Parse attributes
            try self.parseDescriptionAttributes(&xmp, self.data[desc_start .. desc_content_start + 1]);

            // Parse child elements
            try self.parseDescriptionContent(&xmp, self.data[desc_content_start + 1 .. desc_end]);

            search_pos = desc_end + 18; // len("</rdf:Description>")
        }

        return xmp;
    }

    fn parseDescriptionAttributes(self: *XmpParser, xmp: *XmpData, tag_content: []const u8) !void {
        // Parse namespace-prefixed attributes like dc:title="value"
        var i: usize = 0;
        while (i < tag_content.len) {
            // Skip whitespace
            while (i < tag_content.len and (tag_content[i] == ' ' or tag_content[i] == '\t' or tag_content[i] == '\n' or tag_content[i] == '\r')) {
                i += 1;
            }
            if (i >= tag_content.len) break;

            // Find attribute name
            const name_start = i;
            while (i < tag_content.len and tag_content[i] != '=' and tag_content[i] != ' ' and tag_content[i] != '>') {
                i += 1;
            }
            if (i >= tag_content.len or tag_content[i] != '=') {
                i += 1;
                continue;
            }

            const attr_name = tag_content[name_start..i];
            i += 1; // Skip '='

            // Skip quote
            if (i >= tag_content.len or (tag_content[i] != '"' and tag_content[i] != '\'')) continue;
            const quote = tag_content[i];
            i += 1;

            // Find value end
            const value_start = i;
            while (i < tag_content.len and tag_content[i] != quote) {
                i += 1;
            }
            if (i >= tag_content.len) break;

            const value = tag_content[value_start..i];
            i += 1; // Skip closing quote

            // Process known attributes
            try self.processAttribute(xmp, attr_name, value);
        }
    }

    fn processAttribute(self: *XmpParser, xmp: *XmpData, name: []const u8, value: []const u8) !void {
        // Skip namespace declarations
        if (std.mem.startsWith(u8, name, "xmlns")) return;

        // Parse prefix:localname
        if (std.mem.indexOf(u8, name, ":")) |colon_pos| {
            const prefix = name[0..colon_pos];
            const local_name = name[colon_pos + 1 ..];

            // Dublin Core
            if (std.mem.eql(u8, prefix, "dc")) {
                if (std.mem.eql(u8, local_name, "title")) {
                    xmp.title = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "description")) {
                    xmp.description = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "creator")) {
                    xmp.creator = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "rights")) {
                    xmp.rights = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "format")) {
                    xmp.format = try self.allocator.dupe(u8, value);
                }
            }
            // XMP Core
            else if (std.mem.eql(u8, prefix, "xmp")) {
                if (std.mem.eql(u8, local_name, "CreateDate")) {
                    xmp.create_date = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "ModifyDate")) {
                    xmp.modify_date = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "MetadataDate")) {
                    xmp.metadata_date = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "CreatorTool")) {
                    xmp.creator_tool = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "Rating")) {
                    xmp.rating = std.fmt.parseInt(i32, value, 10) catch null;
                } else if (std.mem.eql(u8, local_name, "Label")) {
                    xmp.label = try self.allocator.dupe(u8, value);
                }
            }
            // XMP Media Management
            else if (std.mem.eql(u8, prefix, "xmpMM")) {
                if (std.mem.eql(u8, local_name, "DocumentID")) {
                    xmp.document_id = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "InstanceID")) {
                    xmp.instance_id = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "OriginalDocumentID")) {
                    xmp.original_document_id = try self.allocator.dupe(u8, value);
                }
            }
            // XMP Rights
            else if (std.mem.eql(u8, prefix, "xmpRights")) {
                if (std.mem.eql(u8, local_name, "Marked")) {
                    xmp.marked = std.mem.eql(u8, value, "True") or std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, local_name, "WebStatement")) {
                    xmp.web_statement = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "UsageTerms")) {
                    xmp.usage_terms = try self.allocator.dupe(u8, value);
                }
            }
            // Photoshop
            else if (std.mem.eql(u8, prefix, "photoshop")) {
                if (std.mem.eql(u8, local_name, "Headline")) {
                    xmp.headline = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "City")) {
                    xmp.city = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "State")) {
                    xmp.state = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "Country")) {
                    xmp.country = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "Credit")) {
                    xmp.credit = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "Source")) {
                    xmp.source = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "Instructions")) {
                    xmp.instructions = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, local_name, "ColorMode")) {
                    xmp.color_mode = std.fmt.parseInt(u8, value, 10) catch null;
                }
            }
        }
    }

    fn parseDescriptionContent(self: *XmpParser, xmp: *XmpData, content: []const u8) !void {
        // Parse child elements within rdf:Description
        var i: usize = 0;

        while (i < content.len) {
            // Find next element start
            const elem_start = std.mem.indexOfPos(u8, content, i, "<") orelse break;
            if (elem_start + 1 >= content.len) break;

            // Skip comments and processing instructions
            if (content[elem_start + 1] == '!' or content[elem_start + 1] == '?') {
                i = elem_start + 2;
                continue;
            }

            // Find element name end
            var name_end = elem_start + 1;
            while (name_end < content.len and content[name_end] != ' ' and content[name_end] != '>' and content[name_end] != '/') {
                name_end += 1;
            }

            const elem_name = content[elem_start + 1 .. name_end];

            // Skip closing tags
            if (elem_name.len > 0 and elem_name[0] == '/') {
                i = name_end;
                continue;
            }

            // Find element end
            const tag_end = std.mem.indexOfPos(u8, content, name_end, ">") orelse break;

            // Check for self-closing
            if (content[tag_end - 1] == '/') {
                i = tag_end + 1;
                continue;
            }

            // Find content and closing tag
            const content_start = tag_end + 1;
            const close_tag_name = std.fmt.allocPrint(self.allocator, "</{s}>", .{elem_name}) catch {
                i = tag_end + 1;
                continue;
            };
            defer self.allocator.free(close_tag_name);

            const close_tag_pos = std.mem.indexOfPos(u8, content, content_start, close_tag_name) orelse {
                i = tag_end + 1;
                continue;
            };

            const elem_content = content[content_start..close_tag_pos];

            // Check if this contains rdf:Bag, rdf:Seq, or rdf:Alt
            if (std.mem.indexOf(u8, elem_content, "<rdf:li")) |_| {
                // Parse list items
                try self.parseRdfList(xmp, elem_name, elem_content);
            } else {
                // Simple text content
                const trimmed = std.mem.trim(u8, elem_content, " \t\n\r");
                if (trimmed.len > 0) {
                    try self.processAttribute(xmp, elem_name, trimmed);
                }
            }

            i = close_tag_pos + close_tag_name.len;
        }
    }

    fn parseRdfList(self: *XmpParser, xmp: *XmpData, elem_name: []const u8, content: []const u8) !void {
        var items = std.ArrayList([]const u8).init(self.allocator);
        defer items.deinit();

        var i: usize = 0;
        while (std.mem.indexOfPos(u8, content, i, "<rdf:li")) |li_start| {
            // Find content start
            const content_start = std.mem.indexOfPos(u8, content, li_start, ">") orelse break;

            // Find closing tag
            const close_pos = std.mem.indexOfPos(u8, content, content_start, "</rdf:li>") orelse break;

            const item_content = std.mem.trim(u8, content[content_start + 1 .. close_pos], " \t\n\r");
            if (item_content.len > 0) {
                try items.append(try self.allocator.dupe(u8, item_content));
            }

            i = close_pos + 9;
        }

        // Handle dc:subject (keywords)
        if (std.mem.indexOf(u8, elem_name, "subject") != null and items.items.len > 0) {
            xmp.subject = try items.toOwnedSlice();
        } else {
            // Free items we didn't use
            for (items.items) |item| {
                self.allocator.free(item);
            }
        }
    }
};

// ============================================================================
// XMP Writer
// ============================================================================

pub const XmpWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) XmpWriter {
        return XmpWriter{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *XmpWriter) void {
        self.buffer.deinit();
    }

    pub fn write(self: *XmpWriter, xmp: *const XmpData) ![]const u8 {
        self.buffer.clearRetainingCapacity();

        // XMP packet header
        try self.buffer.appendSlice("<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
        try self.buffer.appendSlice("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
        try self.buffer.appendSlice("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");

        // Main description with namespaces
        try self.buffer.appendSlice("<rdf:Description rdf:about=\"\"\n");
        try self.buffer.appendSlice("    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n");
        try self.buffer.appendSlice("    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n");
        try self.buffer.appendSlice("    xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"\n");
        try self.buffer.appendSlice("    xmlns:xmpRights=\"http://ns.adobe.com/xap/1.0/rights/\"\n");
        try self.buffer.appendSlice("    xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"");

        // Write simple attributes
        if (xmp.title) |t| {
            try self.buffer.appendSlice("\n    dc:title=\"");
            try self.writeEscaped(t);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.description) |d| {
            try self.buffer.appendSlice("\n    dc:description=\"");
            try self.writeEscaped(d);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.creator) |c| {
            try self.buffer.appendSlice("\n    dc:creator=\"");
            try self.writeEscaped(c);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.rights) |r| {
            try self.buffer.appendSlice("\n    dc:rights=\"");
            try self.writeEscaped(r);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.create_date) |d| {
            try self.buffer.appendSlice("\n    xmp:CreateDate=\"");
            try self.writeEscaped(d);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.modify_date) |d| {
            try self.buffer.appendSlice("\n    xmp:ModifyDate=\"");
            try self.writeEscaped(d);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.creator_tool) |t| {
            try self.buffer.appendSlice("\n    xmp:CreatorTool=\"");
            try self.writeEscaped(t);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.rating) |r| {
            try self.buffer.appendSlice("\n    xmp:Rating=\"");
            var buf: [16]u8 = undefined;
            const rating_str = std.fmt.bufPrint(&buf, "{d}", .{r}) catch "0";
            try self.buffer.appendSlice(rating_str);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.document_id) |d| {
            try self.buffer.appendSlice("\n    xmpMM:DocumentID=\"");
            try self.writeEscaped(d);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.instance_id) |i| {
            try self.buffer.appendSlice("\n    xmpMM:InstanceID=\"");
            try self.writeEscaped(i);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.marked) |m| {
            try self.buffer.appendSlice("\n    xmpRights:Marked=\"");
            try self.buffer.appendSlice(if (m) "True" else "False");
            try self.buffer.appendSlice("\"");
        }
        if (xmp.headline) |h| {
            try self.buffer.appendSlice("\n    photoshop:Headline=\"");
            try self.writeEscaped(h);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.city) |c| {
            try self.buffer.appendSlice("\n    photoshop:City=\"");
            try self.writeEscaped(c);
            try self.buffer.appendSlice("\"");
        }
        if (xmp.country) |c| {
            try self.buffer.appendSlice("\n    photoshop:Country=\"");
            try self.writeEscaped(c);
            try self.buffer.appendSlice("\"");
        }

        // Check if we need child elements
        if (xmp.subject != null) {
            try self.buffer.appendSlice(">\n");

            // Write subject/keywords as rdf:Bag
            if (xmp.subject) |subjects| {
                try self.buffer.appendSlice("  <dc:subject>\n");
                try self.buffer.appendSlice("    <rdf:Bag>\n");
                for (subjects) |subject| {
                    try self.buffer.appendSlice("      <rdf:li>");
                    try self.writeEscaped(subject);
                    try self.buffer.appendSlice("</rdf:li>\n");
                }
                try self.buffer.appendSlice("    </rdf:Bag>\n");
                try self.buffer.appendSlice("  </dc:subject>\n");
            }

            try self.buffer.appendSlice("</rdf:Description>\n");
        } else {
            try self.buffer.appendSlice("/>\n");
        }

        try self.buffer.appendSlice("</rdf:RDF>\n");
        try self.buffer.appendSlice("</x:xmpmeta>\n");
        try self.buffer.appendSlice("<?xpacket end=\"w\"?>");

        return self.buffer.items;
    }

    fn writeEscaped(self: *XmpWriter, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '<' => try self.buffer.appendSlice("&lt;"),
                '>' => try self.buffer.appendSlice("&gt;"),
                '&' => try self.buffer.appendSlice("&amp;"),
                '"' => try self.buffer.appendSlice("&quot;"),
                '\'' => try self.buffer.appendSlice("&apos;"),
                else => try self.buffer.append(c),
            }
        }
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Parse XMP from raw bytes
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !XmpData {
    var parser = XmpParser.init(allocator, data);
    return parser.parse();
}

/// Find XMP in JPEG APP1 segment
pub fn findInJpeg(data: []const u8) ?[]const u8 {
    const XMP_NAMESPACE = "http://ns.adobe.com/xap/1.0/";

    var i: usize = 2; // Skip SOI
    while (i + 4 < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }

        const marker = data[i + 1];

        // APP1 marker
        if (marker == 0xE1) {
            const length = (@as(u16, data[i + 2]) << 8) | data[i + 3];
            const segment_data = data[i + 4 .. i + 2 + length];

            // Check for XMP namespace
            if (std.mem.indexOf(u8, segment_data, XMP_NAMESPACE)) |ns_pos| {
                // XMP data starts after null terminator following namespace
                const xmp_start = ns_pos + XMP_NAMESPACE.len + 1;
                if (xmp_start < segment_data.len) {
                    return segment_data[xmp_start..];
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

/// Check if data contains XMP
pub fn containsXmp(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "<?xpacket") != null or
        std.mem.indexOf(u8, data, "<x:xmpmeta") != null or
        std.mem.indexOf(u8, data, "<rdf:RDF") != null;
}

// ============================================================================
// Tests
// ============================================================================

test "XMP namespace detection" {
    try std.testing.expectEqual(Namespace.dc, Namespace.fromUri("http://purl.org/dc/elements/1.1/"));
    try std.testing.expectEqual(Namespace.xmp, Namespace.fromUri("http://ns.adobe.com/xap/1.0/"));
    try std.testing.expectEqual(Namespace.photoshop, Namespace.fromUri("http://ns.adobe.com/photoshop/1.0/"));
}

test "XMP contains detection" {
    const sample_xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>";
    try std.testing.expect(containsXmp(sample_xmp));
    try std.testing.expect(!containsXmp("not xmp data"));
}

test "XMP writer basic" {
    var xmp = XmpData.init(std.testing.allocator);
    defer xmp.deinit();

    xmp.title = try std.testing.allocator.dupe(u8, "Test Image");
    xmp.creator = try std.testing.allocator.dupe(u8, "Test Author");

    var writer = XmpWriter.init(std.testing.allocator);
    defer writer.deinit();

    const output = try writer.write(&xmp);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Author") != null);
}
