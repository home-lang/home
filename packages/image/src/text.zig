const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;
const font_8x8 = @import("font_8x8.zig");

// ============================================================================
// TrueType Font Loading
// ============================================================================

/// TrueType font
pub const Font = struct {
    data: []const u8,
    head: HeadTable,
    hhea: HheaTable,
    maxp: MaxpTable,
    cmap: CmapTable,
    loca: LocaTable,
    glyf_offset: u32,
    hmtx_offset: u32,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_glyphs: u16,
    allocator: std.mem.Allocator,

    const HeadTable = struct {
        units_per_em: u16,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,
        index_to_loc_format: i16,
    };

    const HheaTable = struct {
        ascender: i16,
        descender: i16,
        line_gap: i16,
        advance_width_max: u16,
        num_h_metrics: u16,
    };

    const MaxpTable = struct {
        num_glyphs: u16,
    };

    const CmapTable = struct {
        format: u16,
        offset: u32,
    };

    const LocaTable = struct {
        offsets: []u32,
    };

    /// Load font from memory
    pub fn load(allocator: std.mem.Allocator, data: []const u8) !Font {
        if (data.len < 12) return error.InvalidFont;

        // Parse offset table
        const num_tables = readU16BE(data, 4);
        var head_offset: u32 = 0;
        var hhea_offset: u32 = 0;
        var maxp_offset: u32 = 0;
        var cmap_offset: u32 = 0;
        var loca_offset: u32 = 0;
        var glyf_offset: u32 = 0;
        var hmtx_offset: u32 = 0;

        var i: u32 = 0;
        while (i < num_tables) : (i += 1) {
            const table_offset: u32 = 12 + i * 16;
            const tag = data[table_offset .. table_offset + 4];
            const offset = readU32BE(data, table_offset + 8);

            if (std.mem.eql(u8, tag, "head")) head_offset = offset;
            if (std.mem.eql(u8, tag, "hhea")) hhea_offset = offset;
            if (std.mem.eql(u8, tag, "maxp")) maxp_offset = offset;
            if (std.mem.eql(u8, tag, "cmap")) cmap_offset = offset;
            if (std.mem.eql(u8, tag, "loca")) loca_offset = offset;
            if (std.mem.eql(u8, tag, "glyf")) glyf_offset = offset;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx_offset = offset;
        }

        if (head_offset == 0 or hhea_offset == 0 or maxp_offset == 0) {
            return error.InvalidFont;
        }

        // Parse head table
        const head = HeadTable{
            .units_per_em = readU16BE(data, head_offset + 18),
            .x_min = @bitCast(readU16BE(data, head_offset + 36)),
            .y_min = @bitCast(readU16BE(data, head_offset + 38)),
            .x_max = @bitCast(readU16BE(data, head_offset + 40)),
            .y_max = @bitCast(readU16BE(data, head_offset + 42)),
            .index_to_loc_format = @bitCast(readU16BE(data, head_offset + 50)),
        };

        // Parse hhea table
        const hhea = HheaTable{
            .ascender = @bitCast(readU16BE(data, hhea_offset + 4)),
            .descender = @bitCast(readU16BE(data, hhea_offset + 6)),
            .line_gap = @bitCast(readU16BE(data, hhea_offset + 8)),
            .advance_width_max = readU16BE(data, hhea_offset + 10),
            .num_h_metrics = readU16BE(data, hhea_offset + 34),
        };

        // Parse maxp table
        const maxp = MaxpTable{
            .num_glyphs = readU16BE(data, maxp_offset + 4),
        };

        // Parse cmap table (find unicode mapping)
        var cmap = CmapTable{ .format = 0, .offset = 0 };
        if (cmap_offset > 0) {
            const num_subtables = readU16BE(data, cmap_offset + 2);
            var j: u32 = 0;
            while (j < num_subtables) : (j += 1) {
                const subtable_offset = cmap_offset + 4 + j * 8;
                const platform_id = readU16BE(data, subtable_offset);
                const encoding_id = readU16BE(data, subtable_offset + 2);
                const offset = readU32BE(data, subtable_offset + 4);

                // Prefer Unicode (platform 0 or 3/1)
                if (platform_id == 0 or (platform_id == 3 and encoding_id == 1)) {
                    cmap.offset = cmap_offset + offset;
                    cmap.format = readU16BE(data, cmap.offset);
                    break;
                }
            }
        }

        // Parse loca table
        const loca = blk: {
            const num_offsets = maxp.num_glyphs + 1;
            const offsets = try allocator.alloc(u32, num_offsets);

            if (head.index_to_loc_format == 0) {
                // Short format (16-bit offsets * 2)
                for (0..num_offsets) |idx| {
                    offsets[idx] = @as(u32, readU16BE(data, loca_offset + @as(u32, @intCast(idx)) * 2)) * 2;
                }
            } else {
                // Long format (32-bit offsets)
                for (0..num_offsets) |idx| {
                    offsets[idx] = readU32BE(data, loca_offset + @as(u32, @intCast(idx)) * 4);
                }
            }

            break :blk LocaTable{ .offsets = offsets };
        };

        return Font{
            .data = data,
            .head = head,
            .hhea = hhea,
            .maxp = maxp,
            .cmap = cmap,
            .loca = loca,
            .glyf_offset = glyf_offset,
            .hmtx_offset = hmtx_offset,
            .units_per_em = head.units_per_em,
            .ascender = hhea.ascender,
            .descender = hhea.descender,
            .line_gap = hhea.line_gap,
            .num_glyphs = maxp.num_glyphs,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Font) void {
        self.allocator.free(self.loca.offsets);
    }

    /// Get glyph index for unicode codepoint
    pub fn getGlyphIndex(self: *const Font, codepoint: u32) u16 {
        if (self.cmap.offset == 0) return 0;

        switch (self.cmap.format) {
            4 => {
                // Format 4: Segment mapping to delta values
                const seg_count_x2 = readU16BE(self.data, self.cmap.offset + 6);
                const seg_count = seg_count_x2 / 2;

                const end_code_offset = self.cmap.offset + 14;
                const start_code_offset = end_code_offset + seg_count_x2 + 2;
                const id_delta_offset = start_code_offset + seg_count_x2;
                const id_range_offset_offset = id_delta_offset + seg_count_x2;

                var seg: u16 = 0;
                while (seg < seg_count) : (seg += 1) {
                    const end_code = readU16BE(self.data, end_code_offset + seg * 2);
                    if (codepoint <= end_code) {
                        const start_code = readU16BE(self.data, start_code_offset + seg * 2);
                        if (codepoint >= start_code) {
                            const id_range_offset = readU16BE(self.data, id_range_offset_offset + seg * 2);
                            if (id_range_offset == 0) {
                                const id_delta: i16 = @bitCast(readU16BE(self.data, id_delta_offset + seg * 2));
                                return @intCast(@as(i32, @intCast(codepoint)) + id_delta);
                            } else {
                                const offset = id_range_offset_offset + seg * 2 + id_range_offset + (codepoint - start_code) * 2;
                                return readU16BE(self.data, offset);
                            }
                        }
                        break;
                    }
                }
            },
            12 => {
                // Format 12: Segmented coverage
                const num_groups = readU32BE(self.data, self.cmap.offset + 12);
                var g: u32 = 0;
                while (g < num_groups) : (g += 1) {
                    const group_offset = self.cmap.offset + 16 + g * 12;
                    const start_char = readU32BE(self.data, group_offset);
                    const end_char = readU32BE(self.data, group_offset + 4);
                    const start_glyph = readU32BE(self.data, group_offset + 8);

                    if (codepoint >= start_char and codepoint <= end_char) {
                        return @intCast(start_glyph + (codepoint - start_char));
                    }
                }
            },
            else => {},
        }

        return 0; // .notdef
    }

    /// Get advance width for glyph
    pub fn getAdvanceWidth(self: *const Font, glyph_index: u16) u16 {
        if (self.hmtx_offset == 0) return 0;

        if (glyph_index < self.hhea.num_h_metrics) {
            return readU16BE(self.data, self.hmtx_offset + glyph_index * 4);
        } else {
            // Use last metric's advance width
            return readU16BE(self.data, self.hmtx_offset + (self.hhea.num_h_metrics - 1) * 4);
        }
    }

    /// Get glyph outline
    pub fn getGlyphOutline(self: *const Font, glyph_index: u16, allocator: std.mem.Allocator) !GlyphOutline {
        if (glyph_index >= self.num_glyphs) return error.InvalidGlyph;

        const glyph_offset = self.glyf_offset + self.loca.offsets[glyph_index];
        const glyph_length = self.loca.offsets[glyph_index + 1] - self.loca.offsets[glyph_index];

        if (glyph_length == 0) {
            // Empty glyph (space, etc.)
            return GlyphOutline{
                .contours = &[_][]GlyphPoint{},
                .x_min = 0,
                .y_min = 0,
                .x_max = 0,
                .y_max = 0,
                .allocator = allocator,
            };
        }

        const num_contours: i16 = @bitCast(readU16BE(self.data, glyph_offset));
        const x_min: i16 = @bitCast(readU16BE(self.data, glyph_offset + 2));
        const y_min: i16 = @bitCast(readU16BE(self.data, glyph_offset + 4));
        const x_max: i16 = @bitCast(readU16BE(self.data, glyph_offset + 6));
        const y_max: i16 = @bitCast(readU16BE(self.data, glyph_offset + 8));

        if (num_contours < 0) {
            // Compound glyph - simplified handling
            return GlyphOutline{
                .contours = try allocator.alloc([]GlyphPoint, 0),
                .x_min = x_min,
                .y_min = y_min,
                .x_max = x_max,
                .y_max = y_max,
                .allocator = allocator,
            };
        }

        // Simple glyph
        const contour_ends = try allocator.alloc(u16, @intCast(num_contours));
        defer allocator.free(contour_ends);

        for (0..@intCast(num_contours)) |i| {
            contour_ends[i] = readU16BE(self.data, glyph_offset + 10 + @as(u32, @intCast(i)) * 2);
        }

        const num_points: u16 = if (num_contours > 0) contour_ends[@intCast(num_contours - 1)] + 1 else 0;
        const instructions_length = readU16BE(self.data, glyph_offset + 10 + @as(u32, @intCast(num_contours)) * 2);

        var flag_offset = glyph_offset + 12 + @as(u32, @intCast(num_contours)) * 2 + instructions_length;

        // Parse flags
        const flags = try allocator.alloc(u8, num_points);
        defer allocator.free(flags);

        var fi: u16 = 0;
        while (fi < num_points) {
            const flag = self.data[flag_offset];
            flag_offset += 1;
            flags[fi] = flag;
            fi += 1;

            if ((flag & 0x08) != 0) {
                const repeat = self.data[flag_offset];
                flag_offset += 1;
                for (0..repeat) |_| {
                    flags[fi] = flag;
                    fi += 1;
                }
            }
        }

        // Parse x coordinates
        const x_coords = try allocator.alloc(i16, num_points);
        defer allocator.free(x_coords);
        var x: i16 = 0;
        var coord_offset = flag_offset;

        for (0..num_points) |i| {
            const flag = flags[i];
            if ((flag & 0x02) != 0) {
                // 1 byte
                const dx = self.data[coord_offset];
                coord_offset += 1;
                x += if ((flag & 0x10) != 0) @as(i16, dx) else -@as(i16, dx);
            } else if ((flag & 0x10) == 0) {
                // 2 bytes
                x += @bitCast(readU16BE(self.data, coord_offset));
                coord_offset += 2;
            }
            // else: same as previous
            x_coords[i] = x;
        }

        // Parse y coordinates
        const y_coords = try allocator.alloc(i16, num_points);
        defer allocator.free(y_coords);
        var y: i16 = 0;

        for (0..num_points) |i| {
            const flag = flags[i];
            if ((flag & 0x04) != 0) {
                const dy = self.data[coord_offset];
                coord_offset += 1;
                y += if ((flag & 0x20) != 0) @as(i16, dy) else -@as(i16, dy);
            } else if ((flag & 0x20) == 0) {
                y += @bitCast(readU16BE(self.data, coord_offset));
                coord_offset += 2;
            }
            y_coords[i] = y;
        }

        // Build contours
        const contours = try allocator.alloc([]GlyphPoint, @intCast(num_contours));
        var start_point: u16 = 0;

        for (0..@intCast(num_contours)) |c| {
            const end_point = contour_ends[c];
            const contour_length = end_point - start_point + 1;
            contours[c] = try allocator.alloc(GlyphPoint, contour_length);

            for (0..contour_length) |p| {
                const pi = start_point + @as(u16, @intCast(p));
                contours[c][p] = GlyphPoint{
                    .x = x_coords[pi],
                    .y = y_coords[pi],
                    .on_curve = (flags[pi] & 0x01) != 0,
                };
            }

            start_point = end_point + 1;
        }

        return GlyphOutline{
            .contours = contours,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .allocator = allocator,
        };
    }
};

pub const GlyphPoint = struct {
    x: i16,
    y: i16,
    on_curve: bool,
};

pub const GlyphOutline = struct {
    contours: [][]GlyphPoint,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphOutline) void {
        for (self.contours) |contour| {
            self.allocator.free(contour);
        }
        self.allocator.free(self.contours);
    }
};

fn readU16BE(data: []const u8, offset: u32) u16 {
    if (offset + 2 > data.len) return 0;
    return (@as(u16, data[offset]) << 8) | @as(u16, data[offset + 1]);
}

fn readU32BE(data: []const u8, offset: u32) u32 {
    if (offset + 4 > data.len) return 0;
    return (@as(u32, data[offset]) << 24) |
        (@as(u32, data[offset + 1]) << 16) |
        (@as(u32, data[offset + 2]) << 8) |
        @as(u32, data[offset + 3]);
}

// ============================================================================
// Text Rendering
// ============================================================================

/// Text rendering options
pub const TextOptions = struct {
    font: ?*const Font = null,
    size: f32 = 16.0,
    color: Color = Color.BLACK,
    anti_alias: bool = true,
    line_height: f32 = 1.2,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    align: TextAlign = .left,
    baseline: Baseline = .alphabetic,
};

pub const TextAlign = enum {
    left,
    center,
    right,
    justify,
};

pub const Baseline = enum {
    top,
    middle,
    alphabetic,
    bottom,
};

/// Render text to image using TrueType font
pub fn renderText(
    image: *Image,
    text: []const u8,
    x: i32,
    y: i32,
    options: TextOptions,
    allocator: std.mem.Allocator,
) !void {
    if (options.font) |font| {
        try renderTrueTypeText(image, text, x, y, font, options, allocator);
    } else {
        // Fallback to 8x8 bitmap font
        renderBitmapText(image, text, x, y, options);
    }
}

/// Render text using TrueType font with anti-aliasing
fn renderTrueTypeText(
    image: *Image,
    text: []const u8,
    x: i32,
    y: i32,
    font: *const Font,
    options: TextOptions,
    allocator: std.mem.Allocator,
) !void {
    const scale = options.size / @as(f32, @floatFromInt(font.units_per_em));
    var cursor_x: f32 = @floatFromInt(x);
    const baseline_y: f32 = @floatFromInt(y);

    for (text) |char| {
        const glyph_index = font.getGlyphIndex(char);
        var outline = try font.getGlyphOutline(glyph_index, allocator);
        defer outline.deinit();

        // Rasterize glyph
        if (outline.contours.len > 0) {
            try rasterizeGlyph(image, &outline, cursor_x, baseline_y, scale, options);
        }

        // Advance cursor
        const advance = font.getAdvanceWidth(glyph_index);
        cursor_x += @as(f32, @floatFromInt(advance)) * scale + options.letter_spacing;

        if (char == ' ') {
            cursor_x += options.word_spacing;
        }
    }
}

/// Rasterize a glyph outline to the image
fn rasterizeGlyph(
    image: *Image,
    outline: *const GlyphOutline,
    x_offset: f32,
    y_offset: f32,
    scale: f32,
    options: TextOptions,
) !void {
    // Simple scanline rasterization with anti-aliasing
    const glyph_width: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(outline.x_max - outline.x_min)) * scale) + 2);
    const glyph_height: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(outline.y_max - outline.y_min)) * scale) + 2);

    if (glyph_width == 0 or glyph_height == 0) return;

    // For each scanline, find intersections with the outline
    var gy: u32 = 0;
    while (gy < glyph_height) : (gy += 1) {
        const scan_y = @as(f32, @floatFromInt(outline.y_max)) - @as(f32, @floatFromInt(gy)) / scale;

        // Find x intersections for this scanline
        var intersections = std.ArrayList(f32).init(options.font.?.allocator);
        defer intersections.deinit();

        for (outline.contours) |contour| {
            if (contour.len < 2) continue;

            for (0..contour.len) |i| {
                const p0 = contour[i];
                const p1 = contour[(i + 1) % contour.len];

                const y0: f32 = @floatFromInt(p0.y);
                const y1: f32 = @floatFromInt(p1.y);

                if ((y0 <= scan_y and y1 > scan_y) or (y1 <= scan_y and y0 > scan_y)) {
                    const t = (scan_y - y0) / (y1 - y0);
                    const x0: f32 = @floatFromInt(p0.x);
                    const x1: f32 = @floatFromInt(p1.x);
                    const ix = x0 + t * (x1 - x0);
                    intersections.append(ix) catch {};
                }
            }
        }

        if (intersections.items.len < 2) continue;

        // Sort intersections
        std.mem.sort(f32, intersections.items, {}, std.sort.asc(f32));

        // Fill between pairs
        var i: usize = 0;
        while (i + 1 < intersections.items.len) : (i += 2) {
            const x_start = intersections.items[i];
            const x_end = intersections.items[i + 1];

            const px_start: i32 = @intFromFloat((x_start - @as(f32, @floatFromInt(outline.x_min))) * scale + x_offset);
            const px_end: i32 = @intFromFloat((x_end - @as(f32, @floatFromInt(outline.x_min))) * scale + x_offset);
            const py: i32 = @intFromFloat(y_offset - @as(f32, @floatFromInt(gy)));

            var px = px_start;
            while (px <= px_end) : (px += 1) {
                if (px >= 0 and px < @as(i32, @intCast(image.width)) and
                    py >= 0 and py < @as(i32, @intCast(image.height)))
                {
                    if (options.anti_alias) {
                        // Simple anti-aliasing at edges
                        var alpha: f32 = 1.0;
                        if (px == px_start or px == px_end) {
                            alpha = 0.5;
                        }

                        const existing = image.getPixel(@intCast(px), @intCast(py)) orelse Color.TRANSPARENT;
                        const blended = blendColor(existing, options.color, alpha);
                        image.setPixel(@intCast(px), @intCast(py), blended);
                    } else {
                        image.setPixel(@intCast(px), @intCast(py), options.color);
                    }
                }
            }
        }
    }
}

fn blendColor(dst: Color, src: Color, alpha: f32) Color {
    const src_alpha = @as(f32, @floatFromInt(src.a)) / 255.0 * alpha;
    const dst_alpha = @as(f32, @floatFromInt(dst.a)) / 255.0;
    const out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);

    if (out_alpha == 0) return Color.TRANSPARENT;

    return Color{
        .r = @intFromFloat((@as(f32, @floatFromInt(src.r)) * src_alpha + @as(f32, @floatFromInt(dst.r)) * dst_alpha * (1.0 - src_alpha)) / out_alpha),
        .g = @intFromFloat((@as(f32, @floatFromInt(src.g)) * src_alpha + @as(f32, @floatFromInt(dst.g)) * dst_alpha * (1.0 - src_alpha)) / out_alpha),
        .b = @intFromFloat((@as(f32, @floatFromInt(src.b)) * src_alpha + @as(f32, @floatFromInt(dst.b)) * dst_alpha * (1.0 - src_alpha)) / out_alpha),
        .a = @intFromFloat(out_alpha * 255.0),
    };
}

/// Render text using 8x8 bitmap font (fallback)
fn renderBitmapText(image: *Image, text: []const u8, x: i32, y: i32, options: TextOptions) {
    const scale: u32 = @max(1, @as(u32, @intFromFloat(options.size / 8.0)));
    var cursor_x = x;

    for (text) |char| {
        if (char >= 32 and char < 127) {
            const glyph = font_8x8.FONT_8X8[char - 32];

            for (0..8) |row| {
                for (0..8) |col| {
                    if ((glyph[row] >> @intCast(7 - col)) & 1 == 1) {
                        // Draw scaled pixel
                        for (0..scale) |sy| {
                            for (0..scale) |sx| {
                                const px = cursor_x + @as(i32, @intCast(col * scale + sx));
                                const py = y + @as(i32, @intCast(row * scale + sy));

                                if (px >= 0 and px < @as(i32, @intCast(image.width)) and
                                    py >= 0 and py < @as(i32, @intCast(image.height)))
                                {
                                    image.setPixel(@intCast(px), @intCast(py), options.color);
                                }
                            }
                        }
                    }
                }
            }
        }

        cursor_x += @as(i32, @intCast(8 * scale)) + @as(i32, @intFromFloat(options.letter_spacing));
    }
}

// ============================================================================
// Text Along Path
// ============================================================================

/// Render text along a bezier path
pub fn renderTextAlongPath(
    image: *Image,
    text: []const u8,
    path: []const PathPoint,
    options: TextOptions,
    allocator: std.mem.Allocator,
) !void {
    if (path.len < 2) return;

    // Calculate total path length
    var total_length: f32 = 0;
    for (1..path.len) |i| {
        const dx = path[i].x - path[i - 1].x;
        const dy = path[i].y - path[i - 1].y;
        total_length += @sqrt(dx * dx + dy * dy);
    }

    // Calculate character widths
    var char_widths = try allocator.alloc(f32, text.len);
    defer allocator.free(char_widths);

    const scale = if (options.font) |font| options.size / @as(f32, @floatFromInt(font.units_per_em)) else options.size / 8.0;

    for (text, 0..) |char, i| {
        if (options.font) |font| {
            const glyph_index = font.getGlyphIndex(char);
            char_widths[i] = @as(f32, @floatFromInt(font.getAdvanceWidth(glyph_index))) * scale;
        } else {
            char_widths[i] = 8.0 * scale;
        }
    }

    // Render each character
    var distance: f32 = 0;
    var segment_idx: usize = 1;
    var segment_start: f32 = 0;

    for (text, 0..) |char, i| {
        // Find position on path
        const char_center = distance + char_widths[i] / 2;

        // Find the right segment
        var seg_length: f32 = 0;
        while (segment_idx < path.len) {
            const dx = path[segment_idx].x - path[segment_idx - 1].x;
            const dy = path[segment_idx].y - path[segment_idx - 1].y;
            seg_length = @sqrt(dx * dx + dy * dy);

            if (segment_start + seg_length >= char_center) break;
            segment_start += seg_length;
            segment_idx += 1;
        }

        if (segment_idx >= path.len) break;

        // Interpolate position
        const t = (char_center - segment_start) / seg_length;
        const px = path[segment_idx - 1].x + t * (path[segment_idx].x - path[segment_idx - 1].x);
        const py = path[segment_idx - 1].y + t * (path[segment_idx].y - path[segment_idx - 1].y);

        // Calculate rotation
        const dx = path[segment_idx].x - path[segment_idx - 1].x;
        const dy = path[segment_idx].y - path[segment_idx - 1].y;
        const angle = std.math.atan2(dy, dx);

        // Render character with rotation
        try renderRotatedChar(image, char, px, py, angle, options);

        distance += char_widths[i] + options.letter_spacing;
    }
}

pub const PathPoint = struct {
    x: f32,
    y: f32,
};

fn renderRotatedChar(
    image: *Image,
    char: u8,
    cx: f32,
    cy: f32,
    angle: f32,
    options: TextOptions,
) !void {
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    const size = options.size;

    // Simple rotation-based rendering for 8x8 font
    if (char >= 32 and char < 127) {
        const glyph = font_8x8.FONT_8X8[char - 32];
        const scale = size / 8.0;

        for (0..8) |row| {
            for (0..8) |col| {
                if ((glyph[row] >> @intCast(7 - col)) & 1 == 1) {
                    // Calculate local position
                    const lx = (@as(f32, @floatFromInt(col)) - 4.0) * scale;
                    const ly = (@as(f32, @floatFromInt(row)) - 4.0) * scale;

                    // Rotate and translate
                    const rx = lx * cos_a - ly * sin_a + cx;
                    const ry = lx * sin_a + ly * cos_a + cy;

                    const px: i32 = @intFromFloat(rx);
                    const py: i32 = @intFromFloat(ry);

                    if (px >= 0 and px < @as(i32, @intCast(image.width)) and
                        py >= 0 and py < @as(i32, @intCast(image.height)))
                    {
                        image.setPixel(@intCast(px), @intCast(py), options.color);
                    }
                }
            }
        }
    }
}

// ============================================================================
// Text Measurement
// ============================================================================

/// Measured text dimensions
pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,
};

/// Measure text dimensions
pub fn measureText(text: []const u8, options: TextOptions) TextMetrics {
    var width: f32 = 0;

    if (options.font) |font| {
        const scale = options.size / @as(f32, @floatFromInt(font.units_per_em));

        for (text) |char| {
            const glyph_index = font.getGlyphIndex(char);
            width += @as(f32, @floatFromInt(font.getAdvanceWidth(glyph_index))) * scale;
            width += options.letter_spacing;
        }

        return TextMetrics{
            .width = width,
            .height = options.size * options.line_height,
            .ascent = @as(f32, @floatFromInt(font.ascender)) * scale,
            .descent = @as(f32, @floatFromInt(-font.descender)) * scale,
            .line_height = options.size * options.line_height,
        };
    } else {
        const scale = options.size / 8.0;
        width = @as(f32, @floatFromInt(text.len)) * 8.0 * scale;
        width += @as(f32, @floatFromInt(text.len - 1)) * options.letter_spacing;

        return TextMetrics{
            .width = width,
            .height = options.size,
            .ascent = options.size * 0.8,
            .descent = options.size * 0.2,
            .line_height = options.size * options.line_height,
        };
    }
}

/// Wrap text to fit within max width
pub fn wrapText(
    text: []const u8,
    max_width: f32,
    options: TextOptions,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    var lines = std.ArrayList([]const u8).init(allocator);
    var line_start: usize = 0;
    var last_space: usize = 0;
    var current_width: f32 = 0;

    const char_width = if (options.font) |font| blk: {
        const scale = options.size / @as(f32, @floatFromInt(font.units_per_em));
        break :blk @as(f32, @floatFromInt(font.getAdvanceWidth(font.getGlyphIndex('m')))) * scale;
    } else options.size;

    for (text, 0..) |char, i| {
        if (char == ' ') {
            last_space = i;
        }

        current_width += char_width + options.letter_spacing;

        if (current_width > max_width and last_space > line_start) {
            try lines.append(text[line_start..last_space]);
            line_start = last_space + 1;
            current_width = @as(f32, @floatFromInt(i - last_space)) * (char_width + options.letter_spacing);
        }

        if (char == '\n') {
            try lines.append(text[line_start..i]);
            line_start = i + 1;
            current_width = 0;
            last_space = line_start;
        }
    }

    if (line_start < text.len) {
        try lines.append(text[line_start..]);
    }

    return lines.toOwnedSlice();
}
