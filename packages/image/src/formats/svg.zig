// SVG Decoder/Encoder
// Implements SVG (Scalable Vector Graphics) rasterization
// Based on: SVG 1.1 specification (simplified subset)

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// SVG Constants
// ============================================================================

const SVG_HEADER = "<?xml";
const SVG_TAG = "<svg";
const DEFAULT_DPI = 96.0;

// ============================================================================
// SVG Types
// ============================================================================

const Point = struct {
    x: f32,
    y: f32,
};

const Transform = struct {
    a: f32 = 1.0, // scale x
    b: f32 = 0.0, // skew y
    c: f32 = 0.0, // skew x
    d: f32 = 1.0, // scale y
    e: f32 = 0.0, // translate x
    f: f32 = 0.0, // translate y

    pub fn identity() Transform {
        return .{};
    }

    pub fn multiply(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }

    pub fn apply(self: Transform, p: Point) Point {
        return .{
            .x = self.a * p.x + self.c * p.y + self.e,
            .y = self.b * p.x + self.d * p.y + self.f,
        };
    }

    pub fn translate(tx: f32, ty: f32) Transform {
        return .{ .e = tx, .f = ty };
    }

    pub fn scale(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    pub fn rotate(angle: f32) Transform {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .a = c, .b = s, .c = -s, .d = c };
    }
};

const PathCommand = union(enum) {
    move_to: Point,
    line_to: Point,
    curve_to: struct { c1: Point, c2: Point, p: Point },
    quad_to: struct { c: Point, p: Point },
    arc_to: struct { rx: f32, ry: f32, rotation: f32, large_arc: bool, sweep: bool, p: Point },
    close,
};

const Shape = struct {
    fill: ?Color = null,
    stroke: ?Color = null,
    stroke_width: f32 = 1.0,
    opacity: f32 = 1.0,
    transform: Transform = Transform.identity(),

    // Shape-specific data
    shape_type: ShapeType,
};

const ShapeType = union(enum) {
    rect: struct { x: f32, y: f32, width: f32, height: f32, rx: f32 = 0, ry: f32 = 0 },
    circle: struct { cx: f32, cy: f32, r: f32 },
    ellipse: struct { cx: f32, cy: f32, rx: f32, ry: f32 },
    line: struct { x1: f32, y1: f32, x2: f32, y2: f32 },
    polyline: []Point,
    polygon: []Point,
    path: []PathCommand,
    text: struct { x: f32, y: f32, content: []const u8, font_size: f32 },
};

// ============================================================================
// SVG Parser
// ============================================================================

const SvgParser = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    shapes: std.ArrayList(Shape),
    shape_data: std.ArrayList([]Point),
    path_data: std.ArrayList([]PathCommand),

    width: f32,
    height: f32,
    view_box: ?struct { x: f32, y: f32, w: f32, h: f32 },

    fn init(allocator: std.mem.Allocator, data: []const u8) SvgParser {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .shapes = std.ArrayList(Shape).init(allocator),
            .shape_data = std.ArrayList([]Point).init(allocator),
            .path_data = std.ArrayList([]PathCommand).init(allocator),
            .width = 300,
            .height = 150,
            .view_box = null,
        };
    }

    fn deinit(self: *SvgParser) void {
        for (self.shape_data.items) |pts| {
            self.allocator.free(pts);
        }
        self.shape_data.deinit();

        for (self.path_data.items) |cmds| {
            self.allocator.free(cmds);
        }
        self.path_data.deinit();

        self.shapes.deinit();
    }

    fn parse(self: *SvgParser) !void {
        // Find <svg> tag
        while (self.pos < self.data.len) {
            if (self.startsWith("<svg")) {
                try self.parseSvgElement();
                break;
            }
            self.pos += 1;
        }
    }

    fn parseSvgElement(self: *SvgParser) !void {
        self.pos += 4; // Skip "<svg"
        self.skipWhitespace();

        // Parse attributes
        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            const attr_name = self.parseIdentifier();
            if (attr_name.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr_name, "width")) {
                    self.width = parseLength(value);
                } else if (std.mem.eql(u8, attr_name, "height")) {
                    self.height = parseLength(value);
                } else if (std.mem.eql(u8, attr_name, "viewBox")) {
                    self.view_box = parseViewBox(value);
                }
            }
            self.skipWhitespace();
        }

        // Skip past ">" or "/>"
        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1;

        // Parse child elements
        try self.parseElements();
    }

    fn parseElements(self: *SvgParser) !void {
        while (self.pos < self.data.len) {
            self.skipWhitespace();

            if (self.startsWith("</svg")) {
                break;
            }

            if (self.startsWith("<!--")) {
                // Skip comment
                while (self.pos < self.data.len and !self.startsWith("-->")) {
                    self.pos += 1;
                }
                if (self.startsWith("-->")) self.pos += 3;
                continue;
            }

            if (self.data[self.pos] == '<') {
                try self.parseElement();
            } else {
                self.pos += 1;
            }
        }
    }

    fn parseElement(self: *SvgParser) !void {
        self.pos += 1; // Skip '<'
        self.skipWhitespace();

        const tag_name = self.parseIdentifier();

        if (std.mem.eql(u8, tag_name, "rect")) {
            try self.parseRect();
        } else if (std.mem.eql(u8, tag_name, "circle")) {
            try self.parseCircle();
        } else if (std.mem.eql(u8, tag_name, "ellipse")) {
            try self.parseEllipse();
        } else if (std.mem.eql(u8, tag_name, "line")) {
            try self.parseLine();
        } else if (std.mem.eql(u8, tag_name, "path")) {
            try self.parsePath();
        } else if (std.mem.eql(u8, tag_name, "polygon")) {
            try self.parsePolygon();
        } else if (std.mem.eql(u8, tag_name, "polyline")) {
            try self.parsePolyline();
        } else if (std.mem.eql(u8, tag_name, "g")) {
            try self.parseGroup();
        } else {
            // Skip unknown element
            self.skipElement();
        }
    }

    fn parseRect(self: *SvgParser) !void {
        var x: f32 = 0;
        var y: f32 = 0;
        var w: f32 = 0;
        var h: f32 = 0;
        var rx: f32 = 0;
        var ry: f32 = 0;
        var fill: ?Color = Color.BLACK;
        var stroke: ?Color = null;
        var stroke_width: f32 = 1.0;

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "x")) x = parseLength(value) else if (std.mem.eql(u8, attr, "y")) y = parseLength(value) else if (std.mem.eql(u8, attr, "width")) w = parseLength(value) else if (std.mem.eql(u8, attr, "height")) h = parseLength(value) else if (std.mem.eql(u8, attr, "rx")) rx = parseLength(value) else if (std.mem.eql(u8, attr, "ry")) ry = parseLength(value) else if (std.mem.eql(u8, attr, "fill")) fill = parseColor(value) else if (std.mem.eql(u8, attr, "stroke")) stroke = parseColor(value) else if (std.mem.eql(u8, attr, "stroke-width")) stroke_width = parseLength(value);
            }
        }

        self.skipElement();

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .rect = .{ .x = x, .y = y, .width = w, .height = h, .rx = rx, .ry = ry } },
        });
    }

    fn parseCircle(self: *SvgParser) !void {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var r: f32 = 0;
        var fill: ?Color = Color.BLACK;
        var stroke: ?Color = null;
        var stroke_width: f32 = 1.0;

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "cx")) cx = parseLength(value) else if (std.mem.eql(u8, attr, "cy")) cy = parseLength(value) else if (std.mem.eql(u8, attr, "r")) r = parseLength(value) else if (std.mem.eql(u8, attr, "fill")) fill = parseColor(value) else if (std.mem.eql(u8, attr, "stroke")) stroke = parseColor(value) else if (std.mem.eql(u8, attr, "stroke-width")) stroke_width = parseLength(value);
            }
        }

        self.skipElement();

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .circle = .{ .cx = cx, .cy = cy, .r = r } },
        });
    }

    fn parseEllipse(self: *SvgParser) !void {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var rx: f32 = 0;
        var ry: f32 = 0;
        var fill: ?Color = Color.BLACK;
        var stroke: ?Color = null;
        var stroke_width: f32 = 1.0;

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "cx")) cx = parseLength(value) else if (std.mem.eql(u8, attr, "cy")) cy = parseLength(value) else if (std.mem.eql(u8, attr, "rx")) rx = parseLength(value) else if (std.mem.eql(u8, attr, "ry")) ry = parseLength(value) else if (std.mem.eql(u8, attr, "fill")) fill = parseColor(value) else if (std.mem.eql(u8, attr, "stroke")) stroke = parseColor(value) else if (std.mem.eql(u8, attr, "stroke-width")) stroke_width = parseLength(value);
            }
        }

        self.skipElement();

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .ellipse = .{ .cx = cx, .cy = cy, .rx = rx, .ry = ry } },
        });
    }

    fn parseLine(self: *SvgParser) !void {
        var x1: f32 = 0;
        var y1: f32 = 0;
        var x2: f32 = 0;
        var y2: f32 = 0;
        var stroke: ?Color = Color.BLACK;
        var stroke_width: f32 = 1.0;

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "x1")) x1 = parseLength(value) else if (std.mem.eql(u8, attr, "y1")) y1 = parseLength(value) else if (std.mem.eql(u8, attr, "x2")) x2 = parseLength(value) else if (std.mem.eql(u8, attr, "y2")) y2 = parseLength(value) else if (std.mem.eql(u8, attr, "stroke")) stroke = parseColor(value) else if (std.mem.eql(u8, attr, "stroke-width")) stroke_width = parseLength(value);
            }
        }

        self.skipElement();

        try self.shapes.append(.{
            .fill = null,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } },
        });
    }

    fn parsePath(self: *SvgParser) !void {
        var fill: ?Color = Color.BLACK;
        var stroke: ?Color = null;
        var stroke_width: f32 = 1.0;
        var d_attr: []const u8 = "";

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "d")) {
                    d_attr = value;
                } else if (std.mem.eql(u8, attr, "fill")) {
                    fill = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke")) {
                    stroke = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke-width")) {
                    stroke_width = parseLength(value);
                }
            }
        }

        self.skipElement();

        const cmds = try parsePathData(self.allocator, d_attr);
        try self.path_data.append(cmds);

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .path = cmds },
        });
    }

    fn parsePolygon(self: *SvgParser) !void {
        var fill: ?Color = Color.BLACK;
        var stroke: ?Color = null;
        var stroke_width: f32 = 1.0;
        var points_attr: []const u8 = "";

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "points")) {
                    points_attr = value;
                } else if (std.mem.eql(u8, attr, "fill")) {
                    fill = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke")) {
                    stroke = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke-width")) {
                    stroke_width = parseLength(value);
                }
            }
        }

        self.skipElement();

        const pts = try parsePoints(self.allocator, points_attr);
        try self.shape_data.append(pts);

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .polygon = pts },
        });
    }

    fn parsePolyline(self: *SvgParser) !void {
        var fill: ?Color = null;
        var stroke: ?Color = Color.BLACK;
        var stroke_width: f32 = 1.0;
        var points_attr: []const u8 = "";

        while (self.pos < self.data.len and self.data[self.pos] != '>' and self.data[self.pos] != '/') {
            self.skipWhitespace();
            const attr = self.parseIdentifier();
            if (attr.len == 0) {
                self.pos += 1;
                continue;
            }

            self.skipWhitespace();
            if (self.pos < self.data.len and self.data[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                const value = self.parseQuotedString();

                if (std.mem.eql(u8, attr, "points")) {
                    points_attr = value;
                } else if (std.mem.eql(u8, attr, "fill")) {
                    fill = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke")) {
                    stroke = parseColor(value);
                } else if (std.mem.eql(u8, attr, "stroke-width")) {
                    stroke_width = parseLength(value);
                }
            }
        }

        self.skipElement();

        const pts = try parsePoints(self.allocator, points_attr);
        try self.shape_data.append(pts);

        try self.shapes.append(.{
            .fill = fill,
            .stroke = stroke,
            .stroke_width = stroke_width,
            .shape_type = .{ .polyline = pts },
        });
    }

    fn parseGroup(self: *SvgParser) !void {
        // Skip group attributes for now
        self.skipElement();

        // Parse child elements
        try self.parseElements();

        // Skip closing </g>
        while (self.pos < self.data.len and !self.startsWith("</g")) {
            self.pos += 1;
        }
        self.skipElement();
    }

    fn skipElement(self: *SvgParser) void {
        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.data.len) self.pos += 1;
    }

    fn skipWhitespace(self: *SvgParser) void {
        while (self.pos < self.data.len and std.ascii.isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }
    }

    fn parseIdentifier(self: *SvgParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':') {
                self.pos += 1;
            } else {
                break;
            }
        }
        return self.data[start..self.pos];
    }

    fn parseQuotedString(self: *SvgParser) []const u8 {
        if (self.pos >= self.data.len) return "";

        const quote = self.data[self.pos];
        if (quote != '"' and quote != '\'') return "";

        self.pos += 1;
        const start = self.pos;

        while (self.pos < self.data.len and self.data[self.pos] != quote) {
            self.pos += 1;
        }

        const result = self.data[start..self.pos];
        if (self.pos < self.data.len) self.pos += 1;

        return result;
    }

    fn startsWith(self: *SvgParser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.data.len) return false;
        return std.mem.eql(u8, self.data[self.pos..][0..prefix.len], prefix);
    }
};

// ============================================================================
// SVG Value Parsers
// ============================================================================

fn parseLength(value: []const u8) f32 {
    var end: usize = 0;
    while (end < value.len and (std.ascii.isDigit(value[end]) or value[end] == '.' or value[end] == '-')) {
        end += 1;
    }

    const num_str = value[0..end];
    const num = std.fmt.parseFloat(f32, num_str) catch return 0;

    // Handle units
    if (end < value.len) {
        const unit = value[end..];
        if (std.mem.eql(u8, unit, "px")) {
            return num;
        } else if (std.mem.eql(u8, unit, "pt")) {
            return num * 1.333333;
        } else if (std.mem.eql(u8, unit, "pc")) {
            return num * 16;
        } else if (std.mem.eql(u8, unit, "mm")) {
            return num * 3.779528;
        } else if (std.mem.eql(u8, unit, "cm")) {
            return num * 37.79528;
        } else if (std.mem.eql(u8, unit, "in")) {
            return num * 96;
        }
    }

    return num;
}

fn parseColor(value: []const u8) ?Color {
    if (value.len == 0) return null;

    if (std.mem.eql(u8, value, "none")) {
        return null;
    }

    // Hex colors
    if (value[0] == '#') {
        if (value.len == 4) {
            // #RGB
            const r = parseHexDigit(value[1]) * 17;
            const g = parseHexDigit(value[2]) * 17;
            const b = parseHexDigit(value[3]) * 17;
            return Color{ .r = r, .g = g, .b = b, .a = 255 };
        } else if (value.len == 7) {
            // #RRGGBB
            const r = parseHexDigit(value[1]) * 16 + parseHexDigit(value[2]);
            const g = parseHexDigit(value[3]) * 16 + parseHexDigit(value[4]);
            const b = parseHexDigit(value[5]) * 16 + parseHexDigit(value[6]);
            return Color{ .r = r, .g = g, .b = b, .a = 255 };
        }
    }

    // Named colors
    if (std.mem.eql(u8, value, "black")) return Color.BLACK;
    if (std.mem.eql(u8, value, "white")) return Color.WHITE;
    if (std.mem.eql(u8, value, "red")) return Color.RED;
    if (std.mem.eql(u8, value, "green")) return Color.GREEN;
    if (std.mem.eql(u8, value, "blue")) return Color.BLUE;
    if (std.mem.eql(u8, value, "yellow")) return Color{ .r = 255, .g = 255, .b = 0, .a = 255 };
    if (std.mem.eql(u8, value, "cyan")) return Color{ .r = 0, .g = 255, .b = 255, .a = 255 };
    if (std.mem.eql(u8, value, "magenta")) return Color{ .r = 255, .g = 0, .b = 255, .a = 255 };
    if (std.mem.eql(u8, value, "orange")) return Color{ .r = 255, .g = 165, .b = 0, .a = 255 };
    if (std.mem.eql(u8, value, "purple")) return Color{ .r = 128, .g = 0, .b = 128, .a = 255 };
    if (std.mem.eql(u8, value, "gray") or std.mem.eql(u8, value, "grey")) return Color{ .r = 128, .g = 128, .b = 128, .a = 255 };

    return Color.BLACK;
}

fn parseHexDigit(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

fn parseViewBox(value: []const u8) ?struct { x: f32, y: f32, w: f32, h: f32 } {
    var parts: [4]f32 = .{ 0, 0, 0, 0 };
    var part_idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i <= value.len and part_idx < 4) {
        const is_sep = i == value.len or value[i] == ' ' or value[i] == ',' or value[i] == '\t';
        if (is_sep) {
            if (i > start) {
                parts[part_idx] = std.fmt.parseFloat(f32, value[start..i]) catch 0;
                part_idx += 1;
            }
            start = i + 1;
        }
        i += 1;
    }

    if (part_idx < 4) return null;
    return .{ .x = parts[0], .y = parts[1], .w = parts[2], .h = parts[3] };
}

fn parsePoints(allocator: std.mem.Allocator, value: []const u8) ![]Point {
    var points = std.ArrayList(Point).init(allocator);
    errdefer points.deinit();

    var i: usize = 0;
    while (i < value.len) {
        // Skip whitespace and commas
        while (i < value.len and (std.ascii.isWhitespace(value[i]) or value[i] == ',')) {
            i += 1;
        }

        // Parse x
        const x_start = i;
        while (i < value.len and (std.ascii.isDigit(value[i]) or value[i] == '.' or value[i] == '-')) {
            i += 1;
        }
        if (i == x_start) break;
        const x = std.fmt.parseFloat(f32, value[x_start..i]) catch break;

        // Skip separator
        while (i < value.len and (std.ascii.isWhitespace(value[i]) or value[i] == ',')) {
            i += 1;
        }

        // Parse y
        const y_start = i;
        while (i < value.len and (std.ascii.isDigit(value[i]) or value[i] == '.' or value[i] == '-')) {
            i += 1;
        }
        if (i == y_start) break;
        const y = std.fmt.parseFloat(f32, value[y_start..i]) catch break;

        try points.append(.{ .x = x, .y = y });
    }

    return points.toOwnedSlice();
}

fn parsePathData(allocator: std.mem.Allocator, d: []const u8) ![]PathCommand {
    var cmds = std.ArrayList(PathCommand).init(allocator);
    errdefer cmds.deinit();

    var i: usize = 0;
    var current_x: f32 = 0;
    var current_y: f32 = 0;
    var last_cmd: u8 = 'M';

    while (i < d.len) {
        // Skip whitespace
        while (i < d.len and std.ascii.isWhitespace(d[i])) {
            i += 1;
        }
        if (i >= d.len) break;

        var cmd = d[i];
        const is_cmd = std.ascii.isAlphabetic(cmd);
        if (is_cmd) {
            i += 1;
            last_cmd = cmd;
        } else {
            cmd = last_cmd;
        }

        const is_relative = std.ascii.isLower(cmd);
        const upper_cmd = std.ascii.toUpper(cmd);

        switch (upper_cmd) {
            'M' => {
                const x = parseNextNumber(d, &i) orelse break;
                const y = parseNextNumber(d, &i) orelse break;
                const abs_x = if (is_relative) current_x + x else x;
                const abs_y = if (is_relative) current_y + y else y;
                try cmds.append(.{ .move_to = .{ .x = abs_x, .y = abs_y } });
                current_x = abs_x;
                current_y = abs_y;
                last_cmd = if (is_relative) 'l' else 'L';
            },
            'L' => {
                const x = parseNextNumber(d, &i) orelse break;
                const y = parseNextNumber(d, &i) orelse break;
                const abs_x = if (is_relative) current_x + x else x;
                const abs_y = if (is_relative) current_y + y else y;
                try cmds.append(.{ .line_to = .{ .x = abs_x, .y = abs_y } });
                current_x = abs_x;
                current_y = abs_y;
            },
            'H' => {
                const x = parseNextNumber(d, &i) orelse break;
                const abs_x = if (is_relative) current_x + x else x;
                try cmds.append(.{ .line_to = .{ .x = abs_x, .y = current_y } });
                current_x = abs_x;
            },
            'V' => {
                const y = parseNextNumber(d, &i) orelse break;
                const abs_y = if (is_relative) current_y + y else y;
                try cmds.append(.{ .line_to = .{ .x = current_x, .y = abs_y } });
                current_y = abs_y;
            },
            'C' => {
                const x1 = parseNextNumber(d, &i) orelse break;
                const y1 = parseNextNumber(d, &i) orelse break;
                const x2 = parseNextNumber(d, &i) orelse break;
                const y2 = parseNextNumber(d, &i) orelse break;
                const x = parseNextNumber(d, &i) orelse break;
                const y = parseNextNumber(d, &i) orelse break;

                const offset_x = if (is_relative) current_x else 0;
                const offset_y = if (is_relative) current_y else 0;

                try cmds.append(.{ .curve_to = .{
                    .c1 = .{ .x = x1 + offset_x, .y = y1 + offset_y },
                    .c2 = .{ .x = x2 + offset_x, .y = y2 + offset_y },
                    .p = .{ .x = x + offset_x, .y = y + offset_y },
                } });

                current_x = x + offset_x;
                current_y = y + offset_y;
            },
            'Q' => {
                const x1 = parseNextNumber(d, &i) orelse break;
                const y1 = parseNextNumber(d, &i) orelse break;
                const x = parseNextNumber(d, &i) orelse break;
                const y = parseNextNumber(d, &i) orelse break;

                const offset_x = if (is_relative) current_x else 0;
                const offset_y = if (is_relative) current_y else 0;

                try cmds.append(.{ .quad_to = .{
                    .c = .{ .x = x1 + offset_x, .y = y1 + offset_y },
                    .p = .{ .x = x + offset_x, .y = y + offset_y },
                } });

                current_x = x + offset_x;
                current_y = y + offset_y;
            },
            'Z' => {
                try cmds.append(.close);
            },
            else => {},
        }
    }

    return cmds.toOwnedSlice();
}

fn parseNextNumber(d: []const u8, i: *usize) ?f32 {
    // Skip whitespace and commas
    while (i.* < d.len and (std.ascii.isWhitespace(d[i.*]) or d[i.*] == ',')) {
        i.* += 1;
    }

    if (i.* >= d.len) return null;

    const start = i.*;
    if (d[i.*] == '-' or d[i.*] == '+') i.* += 1;

    var has_dot = false;
    while (i.* < d.len) {
        const c = d[i.*];
        if (std.ascii.isDigit(c)) {
            i.* += 1;
        } else if (c == '.' and !has_dot) {
            has_dot = true;
            i.* += 1;
        } else {
            break;
        }
    }

    if (i.* == start) return null;
    return std.fmt.parseFloat(f32, d[start..i.*]) catch null;
}

// ============================================================================
// SVG Rasterizer
// ============================================================================

fn rasterize(allocator: std.mem.Allocator, parser: *SvgParser, target_width: u32, target_height: u32) !Image {
    var img = try Image.init(allocator, target_width, target_height, .rgba8);
    errdefer img.deinit();

    // Fill with transparent
    @memset(img.pixels, 0);

    // Calculate scale from viewBox/dimensions to target size
    const view_w = if (parser.view_box) |vb| vb.w else parser.width;
    const view_h = if (parser.view_box) |vb| vb.h else parser.height;
    const scale_x = @as(f32, @floatFromInt(target_width)) / view_w;
    const scale_y = @as(f32, @floatFromInt(target_height)) / view_h;

    const view_transform = Transform.scale(scale_x, scale_y);

    // Render each shape
    for (parser.shapes.items) |shape| {
        const combined_transform = view_transform.multiply(shape.transform);
        try renderShape(&img, shape, combined_transform);
    }

    return img;
}

fn renderShape(img: *Image, shape: Shape, transform: Transform) !void {
    switch (shape.shape_type) {
        .rect => |r| {
            if (shape.fill) |fill| {
                fillRect(img, r.x, r.y, r.width, r.height, fill, transform);
            }
            if (shape.stroke) |stroke| {
                strokeRect(img, r.x, r.y, r.width, r.height, stroke, shape.stroke_width, transform);
            }
        },
        .circle => |c| {
            if (shape.fill) |fill| {
                fillEllipse(img, c.cx, c.cy, c.r, c.r, fill, transform);
            }
            if (shape.stroke) |stroke| {
                strokeEllipse(img, c.cx, c.cy, c.r, c.r, stroke, shape.stroke_width, transform);
            }
        },
        .ellipse => |e| {
            if (shape.fill) |fill| {
                fillEllipse(img, e.cx, e.cy, e.rx, e.ry, fill, transform);
            }
            if (shape.stroke) |stroke| {
                strokeEllipse(img, e.cx, e.cy, e.rx, e.ry, stroke, shape.stroke_width, transform);
            }
        },
        .line => |l| {
            if (shape.stroke) |stroke| {
                drawLine(img, l.x1, l.y1, l.x2, l.y2, stroke, shape.stroke_width, transform);
            }
        },
        .polygon => |pts| {
            if (shape.fill) |fill| {
                fillPolygon(img, pts, fill, transform);
            }
            if (shape.stroke) |stroke| {
                strokePolygon(img, pts, stroke, shape.stroke_width, transform, true);
            }
        },
        .polyline => |pts| {
            if (shape.stroke) |stroke| {
                strokePolygon(img, pts, stroke, shape.stroke_width, transform, false);
            }
        },
        .path => |cmds| {
            if (shape.fill) |fill| {
                fillPath(img, cmds, fill, transform);
            }
            if (shape.stroke) |stroke| {
                strokePath(img, cmds, stroke, shape.stroke_width, transform);
            }
        },
        .text => {},
    }
}

fn fillRect(img: *Image, x: f32, y: f32, w: f32, h: f32, color: Color, transform: Transform) void {
    const p1 = transform.apply(.{ .x = x, .y = y });
    const p2 = transform.apply(.{ .x = x + w, .y = y + h });

    const min_x = @max(0, @as(i32, @intFromFloat(@min(p1.x, p2.x))));
    const min_y = @max(0, @as(i32, @intFromFloat(@min(p1.y, p2.y))));
    const max_x = @min(@as(i32, @intCast(img.width)), @as(i32, @intFromFloat(@max(p1.x, p2.x))));
    const max_y = @min(@as(i32, @intCast(img.height)), @as(i32, @intFromFloat(@max(p1.y, p2.y))));

    var py = min_y;
    while (py < max_y) : (py += 1) {
        var px = min_x;
        while (px < max_x) : (px += 1) {
            blendPixel(img, @intCast(px), @intCast(py), color);
        }
    }
}

fn strokeRect(img: *Image, x: f32, y: f32, w: f32, h: f32, color: Color, stroke_width: f32, transform: Transform) void {
    drawLine(img, x, y, x + w, y, color, stroke_width, transform);
    drawLine(img, x + w, y, x + w, y + h, color, stroke_width, transform);
    drawLine(img, x + w, y + h, x, y + h, color, stroke_width, transform);
    drawLine(img, x, y + h, x, y, color, stroke_width, transform);
}

fn fillEllipse(img: *Image, cx: f32, cy: f32, rx: f32, ry: f32, color: Color, transform: Transform) void {
    const center = transform.apply(.{ .x = cx, .y = cy });
    const scaled_rx = rx * transform.a;
    const scaled_ry = ry * transform.d;

    const min_x = @max(0, @as(i32, @intFromFloat(center.x - scaled_rx)));
    const min_y = @max(0, @as(i32, @intFromFloat(center.y - scaled_ry)));
    const max_x = @min(@as(i32, @intCast(img.width)), @as(i32, @intFromFloat(center.x + scaled_rx + 1)));
    const max_y = @min(@as(i32, @intCast(img.height)), @as(i32, @intFromFloat(center.y + scaled_ry + 1)));

    var py = min_y;
    while (py < max_y) : (py += 1) {
        var px = min_x;
        while (px < max_x) : (px += 1) {
            const dx = (@as(f32, @floatFromInt(px)) - center.x) / scaled_rx;
            const dy = (@as(f32, @floatFromInt(py)) - center.y) / scaled_ry;
            if (dx * dx + dy * dy <= 1.0) {
                blendPixel(img, @intCast(px), @intCast(py), color);
            }
        }
    }
}

fn strokeEllipse(img: *Image, cx: f32, cy: f32, rx: f32, ry: f32, color: Color, stroke_width: f32, transform: Transform) void {
    _ = stroke_width;

    const center = transform.apply(.{ .x = cx, .y = cy });
    const scaled_rx = rx * transform.a;
    const scaled_ry = ry * transform.d;

    // Draw ellipse using parametric approach
    const segments = 64;
    var prev_px: f32 = center.x + scaled_rx;
    var prev_py: f32 = center.y;

    var i: usize = 1;
    while (i <= segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / @as(f32, @floatFromInt(segments));
        const px = center.x + @cos(angle) * scaled_rx;
        const py = center.y + @sin(angle) * scaled_ry;

        drawLineSimple(img, prev_px, prev_py, px, py, color);

        prev_px = px;
        prev_py = py;
    }
}

fn drawLine(img: *Image, x1: f32, y1: f32, x2: f32, y2: f32, color: Color, stroke_width: f32, transform: Transform) void {
    _ = stroke_width;

    const p1 = transform.apply(.{ .x = x1, .y = y1 });
    const p2 = transform.apply(.{ .x = x2, .y = y2 });

    drawLineSimple(img, p1.x, p1.y, p2.x, p2.y, color);
}

fn drawLineSimple(img: *Image, x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
    // Bresenham's line algorithm
    const dx = @abs(x2 - x1);
    const dy = @abs(y2 - y1);
    const steps: usize = @intFromFloat(@max(dx, dy) + 1);

    if (steps == 0) return;

    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const px: i32 = @intFromFloat(x1 + (x2 - x1) * t);
        const py: i32 = @intFromFloat(y1 + (y2 - y1) * t);

        if (px >= 0 and py >= 0 and px < @as(i32, @intCast(img.width)) and py < @as(i32, @intCast(img.height))) {
            blendPixel(img, @intCast(px), @intCast(py), color);
        }
    }
}

fn fillPolygon(img: *Image, pts: []Point, color: Color, transform: Transform) void {
    if (pts.len < 3) return;

    // Transform all points
    var transformed: [256]Point = undefined;
    const n = @min(pts.len, 256);
    for (pts[0..n], 0..) |p, idx| {
        transformed[idx] = transform.apply(p);
    }

    // Find bounding box
    var min_y: f32 = transformed[0].y;
    var max_y: f32 = transformed[0].y;
    for (transformed[0..n]) |p| {
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }

    // Scanline fill
    var y: i32 = @max(0, @as(i32, @intFromFloat(min_y)));
    while (y < @min(@as(i32, @intCast(img.height)), @as(i32, @intFromFloat(max_y + 1)))) : (y += 1) {
        var intersections: [64]f32 = undefined;
        var num_intersections: usize = 0;

        const fy: f32 = @floatFromInt(y);

        for (0..n) |i| {
            const p1 = transformed[i];
            const p2 = transformed[(i + 1) % n];

            if ((p1.y <= fy and p2.y > fy) or (p2.y <= fy and p1.y > fy)) {
                if (num_intersections < 64) {
                    const t = (fy - p1.y) / (p2.y - p1.y);
                    intersections[num_intersections] = p1.x + t * (p2.x - p1.x);
                    num_intersections += 1;
                }
            }
        }

        // Sort intersections
        var j: usize = 0;
        while (j < num_intersections) : (j += 1) {
            var k = j + 1;
            while (k < num_intersections) : (k += 1) {
                if (intersections[k] < intersections[j]) {
                    const tmp = intersections[j];
                    intersections[j] = intersections[k];
                    intersections[k] = tmp;
                }
            }
        }

        // Fill between pairs
        var p: usize = 0;
        while (p + 1 < num_intersections) : (p += 2) {
            var x: i32 = @max(0, @as(i32, @intFromFloat(intersections[p])));
            const x_end: i32 = @min(@as(i32, @intCast(img.width)), @as(i32, @intFromFloat(intersections[p + 1])));
            while (x < x_end) : (x += 1) {
                blendPixel(img, @intCast(x), @intCast(y), color);
            }
        }
    }
}

fn strokePolygon(img: *Image, pts: []Point, color: Color, stroke_width: f32, transform: Transform, closed: bool) void {
    if (pts.len < 2) return;

    for (0..pts.len) |i| {
        if (i + 1 < pts.len or closed) {
            const j = if (i + 1 < pts.len) i + 1 else 0;
            drawLine(img, pts[i].x, pts[i].y, pts[j].x, pts[j].y, color, stroke_width, transform);
        }
    }
}

fn fillPath(img: *Image, cmds: []PathCommand, color: Color, transform: Transform) void {
    // Convert path to polygon and fill
    var pts = std.ArrayList(Point).init(std.heap.page_allocator);
    defer pts.deinit();

    var current = Point{ .x = 0, .y = 0 };

    for (cmds) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                current = p;
                pts.append(p) catch {};
            },
            .line_to => |p| {
                current = p;
                pts.append(p) catch {};
            },
            .curve_to => |c| {
                // Approximate bezier with line segments
                const steps: usize = 10;
                var i: usize = 0;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = cubicBezier(current, c.c1, c.c2, c.p, t);
                    pts.append(p) catch {};
                }
                current = c.p;
            },
            .quad_to => |q| {
                const steps: usize = 8;
                var i: usize = 0;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = quadBezier(current, q.c, q.p, t);
                    pts.append(p) catch {};
                }
                current = q.p;
            },
            .arc_to => |a| {
                current = a.p;
                pts.append(a.p) catch {};
            },
            .close => {},
        }
    }

    if (pts.items.len >= 3) {
        fillPolygon(img, pts.items, color, transform);
    }
}

fn strokePath(img: *Image, cmds: []PathCommand, color: Color, stroke_width: f32, transform: Transform) void {
    var current = Point{ .x = 0, .y = 0 };
    var start = current;

    for (cmds) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                current = p;
                start = p;
            },
            .line_to => |p| {
                drawLine(img, current.x, current.y, p.x, p.y, color, stroke_width, transform);
                current = p;
            },
            .curve_to => |c| {
                const steps: usize = 10;
                var prev = current;
                var i: usize = 1;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = cubicBezier(current, c.c1, c.c2, c.p, t);
                    drawLine(img, prev.x, prev.y, p.x, p.y, color, stroke_width, transform);
                    prev = p;
                }
                current = c.p;
            },
            .quad_to => |q| {
                const steps: usize = 8;
                var prev = current;
                var i: usize = 1;
                while (i <= steps) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                    const p = quadBezier(current, q.c, q.p, t);
                    drawLine(img, prev.x, prev.y, p.x, p.y, color, stroke_width, transform);
                    prev = p;
                }
                current = q.p;
            },
            .arc_to => |a| {
                drawLine(img, current.x, current.y, a.p.x, a.p.y, color, stroke_width, transform);
                current = a.p;
            },
            .close => {
                drawLine(img, current.x, current.y, start.x, start.y, color, stroke_width, transform);
                current = start;
            },
        }
    }
}

fn cubicBezier(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    const t2 = t * t;
    const t3 = t2 * t;
    const mt = 1.0 - t;
    const mt2 = mt * mt;
    const mt3 = mt2 * mt;

    return .{
        .x = mt3 * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t3 * p3.x,
        .y = mt3 * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t3 * p3.y,
    };
}

fn quadBezier(p0: Point, p1: Point, p2: Point, t: f32) Point {
    const mt = 1.0 - t;
    return .{
        .x = mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
        .y = mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y,
    };
}

fn blendPixel(img: *Image, x: u32, y: u32, color: Color) void {
    if (color.a == 0) return;

    const existing = img.getPixel(x, y) orelse return;

    if (color.a == 255) {
        img.setPixel(x, y, color);
    } else {
        img.setPixel(x, y, existing.blend(color));
    }
}

// ============================================================================
// SVG Decoder
// ============================================================================

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    return decodeWithSize(allocator, data, null, null);
}

pub fn decodeWithSize(allocator: std.mem.Allocator, data: []const u8, target_width: ?u32, target_height: ?u32) !Image {
    if (data.len < 5) return error.TruncatedData;

    // Verify it's SVG
    if (!isSvg(data)) {
        return error.InvalidFormat;
    }

    var parser = SvgParser.init(allocator, data);
    defer parser.deinit();

    try parser.parse();

    // Determine output size
    const width = target_width orelse @as(u32, @intFromFloat(parser.width));
    const height = target_height orelse @as(u32, @intFromFloat(parser.height));

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    return rasterize(allocator, &parser, width, height);
}

fn isSvg(data: []const u8) bool {
    // Check for XML declaration or <svg tag
    var i: usize = 0;

    // Skip whitespace
    while (i < data.len and std.ascii.isWhitespace(data[i])) {
        i += 1;
    }

    if (i + 5 <= data.len and std.mem.eql(u8, data[i..][0..5], "<?xml")) {
        return true;
    }

    if (i + 4 <= data.len and std.mem.eql(u8, data[i..][0..4], "<svg")) {
        return true;
    }

    // Search for <svg in first 1KB
    const search_len = @min(data.len, 1024);
    if (std.mem.indexOf(u8, data[0..search_len], "<svg") != null) {
        return true;
    }

    return false;
}

// ============================================================================
// SVG Encoder
// ============================================================================

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // Write SVG header
    try output.appendSlice("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try output.appendSlice("<svg xmlns=\"http://www.w3.org/2000/svg\" ");

    // Width and height
    var buf: [32]u8 = undefined;
    var len = std.fmt.formatIntBuf(&buf, img.width, 10, .lower, .{});
    try output.appendSlice("width=\"");
    try output.appendSlice(buf[0..len]);
    try output.appendSlice("\" ");

    len = std.fmt.formatIntBuf(&buf, img.height, 10, .lower, .{});
    try output.appendSlice("height=\"");
    try output.appendSlice(buf[0..len]);
    try output.appendSlice("\">\n");

    // Encode image as embedded base64 PNG or as pixel rectangles
    // For simplicity, we'll create a single image element referencing the raster data
    try output.appendSlice("  <!-- Rasterized from image data -->\n");

    // Create a simple representation using rectangles (inefficient but works)
    // For production, you'd want to embed as base64 PNG in an <image> element

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        var run_start: u32 = 0;
        var run_color: ?Color = null;

        while (x <= img.width) : (x += 1) {
            const color = if (x < img.width) img.getPixel(x, y) else null;

            if (run_color == null and color != null) {
                run_start = x;
                run_color = color;
            } else if (run_color != null and (color == null or !colorsEqual(run_color.?, color.?))) {
                // End of run - write rectangle
                const c = run_color.?;
                if (c.a > 0) {
                    try output.appendSlice("  <rect x=\"");
                    len = std.fmt.formatIntBuf(&buf, run_start, 10, .lower, .{});
                    try output.appendSlice(buf[0..len]);
                    try output.appendSlice("\" y=\"");
                    len = std.fmt.formatIntBuf(&buf, y, 10, .lower, .{});
                    try output.appendSlice(buf[0..len]);
                    try output.appendSlice("\" width=\"");
                    len = std.fmt.formatIntBuf(&buf, x - run_start, 10, .lower, .{});
                    try output.appendSlice(buf[0..len]);
                    try output.appendSlice("\" height=\"1\" fill=\"");
                    try appendColorHex(&output, c);
                    try output.appendSlice("\"/>\n");
                }

                run_color = color;
                run_start = x;
            }
        }
    }

    try output.appendSlice("</svg>\n");

    return output.toOwnedSlice();
}

fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn appendColorHex(output: *std.ArrayList(u8), c: Color) !void {
    const hex = "0123456789abcdef";
    try output.append('#');
    try output.append(hex[c.r >> 4]);
    try output.append(hex[c.r & 0xF]);
    try output.append(hex[c.g >> 4]);
    try output.append(hex[c.g & 0xF]);
    try output.append(hex[c.b >> 4]);
    try output.append(hex[c.b & 0xF]);
}

// ============================================================================
// Tests
// ============================================================================

test "SVG detection" {
    try std.testing.expect(isSvg("<?xml version=\"1.0\"?>"));
    try std.testing.expect(isSvg("<svg xmlns=\"http://www.w3.org/2000/svg\">"));
    try std.testing.expect(isSvg("  <svg>"));
    try std.testing.expect(!isSvg("PNG image data"));
}

test "Color parsing" {
    const black = parseColor("#000000");
    try std.testing.expect(black != null);
    try std.testing.expectEqual(@as(u8, 0), black.?.r);

    const red = parseColor("#ff0000");
    try std.testing.expect(red != null);
    try std.testing.expectEqual(@as(u8, 255), red.?.r);

    const short_green = parseColor("#0f0");
    try std.testing.expect(short_green != null);
    try std.testing.expectEqual(@as(u8, 255), short_green.?.g);
}

test "Length parsing" {
    try std.testing.expectEqual(@as(f32, 100), parseLength("100"));
    try std.testing.expectEqual(@as(f32, 100), parseLength("100px"));
    try std.testing.expectApproxEqAbs(@as(f32, 96), parseLength("1in"), 0.1);
}

test "Transform operations" {
    const t1 = Transform.translate(10, 20);
    const p1 = t1.apply(.{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(f32, 10), p1.x);
    try std.testing.expectEqual(@as(f32, 20), p1.y);

    const t2 = Transform.scale(2, 3);
    const p2 = t2.apply(.{ .x = 5, .y = 10 });
    try std.testing.expectEqual(@as(f32, 10), p2.x);
    try std.testing.expectEqual(@as(f32, 30), p2.y);
}
