const std = @import("std");

/// PGS (Presentation Graphics Stream) - Blu-ray subtitle format
/// HDMV/Blu-ray bitmap subtitles
pub const Pgs = struct {
    /// Segment types
    pub const SegmentType = enum(u8) {
        palette_definition = 0x14,
        object_definition = 0x15,
        presentation_composition = 0x16,
        window_definition = 0x17,
        display_definition = 0x80,
        end_of_display = 0xFF, // Non-standard but used for tracking
    };

    /// Composition state
    pub const CompositionState = enum(u8) {
        normal = 0x00,
        acquisition_point = 0x40,
        epoch_start = 0x80,
        epoch_continue = 0xC0,
    };

    /// Segment header (common to all segments)
    pub const SegmentHeader = struct {
        magic: [2]u8, // "PG"
        pts: u64, // Presentation timestamp (90kHz)
        dts: u64, // Decode timestamp (90kHz)
        segment_type: SegmentType,
        segment_size: u16,
    };

    /// Palette definition segment
    pub const PaletteDefinition = struct {
        palette_id: u8,
        palette_version: u8,
        entries: []PaletteEntry,
    };

    pub const PaletteEntry = struct {
        id: u8,
        y: u8, // Luminance
        cr: u8, // Chroma Red
        cb: u8, // Chroma Blue
        alpha: u8, // Transparency
    };

    /// Object definition segment
    pub const ObjectDefinition = struct {
        object_id: u16,
        object_version: u8,
        sequence_flag: u8, // 0x40 = last, 0x80 = first, 0xC0 = first and last
        width: u16,
        height: u16,
        rle_data: []const u8, // Run-length encoded pixel data
    };

    /// Presentation composition segment
    pub const PresentationComposition = struct {
        composition_number: u16,
        composition_state: CompositionState,
        palette_update_flag: bool,
        palette_id: u8,
        composition_objects: []CompositionObject,
    };

    pub const CompositionObject = struct {
        object_id: u16,
        window_id: u8,
        cropped: bool,
        x: u16,
        y: u16,
        crop_x: u16,
        crop_y: u16,
        crop_width: u16,
        crop_height: u16,
    };

    /// Window definition segment
    pub const WindowDefinition = struct {
        window_id: u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    /// Display definition segment
    pub const DisplayDefinition = struct {
        width: u16,
        height: u16,
        frame_rate: u8,
    };

    /// Complete PGS subtitle event
    pub const SubtitleEvent = struct {
        pts: u64,
        dts: u64,
        display: ?DisplayDefinition,
        palettes: std.ArrayList(PaletteDefinition),
        objects: std.ArrayList(ObjectDefinition),
        windows: std.ArrayList(WindowDefinition),
        composition: ?PresentationComposition,
    };
};

/// PGS subtitle parser
pub const PgsParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PgsParser {
        return .{ .allocator = allocator };
    }

    pub fn parseSegmentHeader(data: []const u8) !Pgs.SegmentHeader {
        if (data.len < 13) return error.InsufficientData;

        // Check magic bytes
        if (!std.mem.eql(u8, data[0..2], "PG")) {
            return error.InvalidMagic;
        }

        var header: Pgs.SegmentHeader = undefined;
        header.magic = data[0..2].*;

        // PTS (33 bits, extended to 64)
        header.pts = (@as(u64, data[2]) << 24) | (@as(u64, data[3]) << 16) | (@as(u64, data[4]) << 8) | data[5];

        // DTS (33 bits, extended to 64)
        header.dts = (@as(u64, data[6]) << 24) | (@as(u64, data[7]) << 16) | (@as(u64, data[8]) << 8) | data[9];

        header.segment_type = @enumFromInt(data[10]);
        header.segment_size = (@as(u16, data[11]) << 8) | data[12];

        return header;
    }

    pub fn parsePaletteDefinition(self: *PgsParser, data: []const u8) !Pgs.PaletteDefinition {
        if (data.len < 2) return error.InsufficientData;

        var palette: Pgs.PaletteDefinition = undefined;
        palette.palette_id = data[0];
        palette.palette_version = data[1];

        const entry_count = (data.len - 2) / 5;
        var entries = try self.allocator.alloc(Pgs.PaletteEntry, entry_count);

        for (0..entry_count) |i| {
            const offset = 2 + i * 5;
            entries[i] = .{
                .id = data[offset],
                .y = data[offset + 1],
                .cr = data[offset + 2],
                .cb = data[offset + 3],
                .alpha = data[offset + 4],
            };
        }

        palette.entries = entries;
        return palette;
    }

    pub fn parseObjectDefinition(data: []const u8) !Pgs.ObjectDefinition {
        if (data.len < 7) return error.InsufficientData;

        var object: Pgs.ObjectDefinition = undefined;

        object.object_id = (@as(u16, data[0]) << 8) | data[1];
        object.object_version = data[2];
        object.sequence_flag = data[3];

        const data_length = (@as(u32, data[4]) << 16) | (@as(u32, data[5]) << 8) | data[6];
        _ = data_length;

        if (object.sequence_flag & 0x80 != 0) {
            // First in sequence or only fragment - has dimensions
            if (data.len < 11) return error.InsufficientData;
            object.width = (@as(u16, data[7]) << 8) | data[8];
            object.height = (@as(u16, data[9]) << 8) | data[10];
            object.rle_data = data[11..];
        } else {
            // Continuation fragment
            object.width = 0;
            object.height = 0;
            object.rle_data = data[7..];
        }

        return object;
    }

    pub fn parsePresentationComposition(self: *PgsParser, data: []const u8) !Pgs.PresentationComposition {
        if (data.len < 11) return error.InsufficientData;

        var comp: Pgs.PresentationComposition = undefined;

        comp.composition_number = (@as(u16, data[0]) << 8) | data[1];
        comp.composition_state = @enumFromInt(data[2]);
        comp.palette_update_flag = (data[3] & 0x80) != 0;
        comp.palette_id = data[4];

        const object_count = data[5];
        var objects = try self.allocator.alloc(Pgs.CompositionObject, object_count);

        var offset: usize = 6;
        for (0..object_count) |i| {
            if (offset + 8 > data.len) return error.InsufficientData;

            objects[i].object_id = (@as(u16, data[offset]) << 8) | data[offset + 1];
            objects[i].window_id = data[offset + 2];
            objects[i].cropped = (data[offset + 3] & 0x80) != 0;
            objects[i].x = (@as(u16, data[offset + 4]) << 8) | data[offset + 5];
            objects[i].y = (@as(u16, data[offset + 6]) << 8) | data[offset + 7];

            offset += 8;

            if (objects[i].cropped) {
                if (offset + 8 > data.len) return error.InsufficientData;
                objects[i].crop_x = (@as(u16, data[offset]) << 8) | data[offset + 1];
                objects[i].crop_y = (@as(u16, data[offset + 2]) << 8) | data[offset + 3];
                objects[i].crop_width = (@as(u16, data[offset + 4]) << 8) | data[offset + 5];
                objects[i].crop_height = (@as(u16, data[offset + 6]) << 8) | data[offset + 7];
                offset += 8;
            } else {
                objects[i].crop_x = 0;
                objects[i].crop_y = 0;
                objects[i].crop_width = 0;
                objects[i].crop_height = 0;
            }
        }

        comp.composition_objects = objects;
        return comp;
    }

    pub fn parseWindowDefinition(self: *PgsParser, data: []const u8) ![]Pgs.WindowDefinition {
        if (data.len < 1) return error.InsufficientData;

        const window_count = data[0];
        var windows = try self.allocator.alloc(Pgs.WindowDefinition, window_count);

        for (0..window_count) |i| {
            const offset = 1 + i * 9;
            if (offset + 9 > data.len) return error.InsufficientData;

            windows[i] = .{
                .window_id = data[offset],
                .x = (@as(u16, data[offset + 1]) << 8) | data[offset + 2],
                .y = (@as(u16, data[offset + 3]) << 8) | data[offset + 4],
                .width = (@as(u16, data[offset + 5]) << 8) | data[offset + 6],
                .height = (@as(u16, data[offset + 7]) << 8) | data[offset + 8],
            };
        }

        return windows;
    }

    pub fn parseDisplayDefinition(data: []const u8) !Pgs.DisplayDefinition {
        if (data.len < 5) return error.InsufficientData;

        return Pgs.DisplayDefinition{
            .width = (@as(u16, data[0]) << 8) | data[1],
            .height = (@as(u16, data[2]) << 8) | data[3],
            .frame_rate = data[4],
        };
    }

    /// Decode RLE (Run-Length Encoded) pixel data
    pub fn decodeRle(self: *PgsParser, rle_data: []const u8, width: u16, height: u16) ![]u8 {
        const pixel_count = @as(usize, width) * height;
        var pixels = try self.allocator.alloc(u8, pixel_count);
        @memset(pixels, 0);

        var pixel_idx: usize = 0;
        var offset: usize = 0;

        while (offset < rle_data.len and pixel_idx < pixel_count) {
            const byte = rle_data[offset];
            offset += 1;

            if (byte == 0) {
                // Escape code
                if (offset >= rle_data.len) break;
                const flag = rle_data[offset];
                offset += 1;

                if (flag == 0) {
                    // End of line
                    continue;
                } else if (flag < 0x80) {
                    // Run of transparent pixels
                    const count = @as(usize, flag);
                    pixel_idx += count;
                } else {
                    // Run of specific color
                    if (offset >= rle_data.len) break;
                    const color = rle_data[offset];
                    offset += 1;

                    const count = @as(usize, flag & 0x7F);
                    for (0..count) |_| {
                        if (pixel_idx >= pixel_count) break;
                        pixels[pixel_idx] = color;
                        pixel_idx += 1;
                    }
                }
            } else {
                // Single pixel
                if (pixel_idx < pixel_count) {
                    pixels[pixel_idx] = byte;
                    pixel_idx += 1;
                }
            }
        }

        return pixels;
    }
};

/// PGS subtitle decoder
pub const PgsDecoder = struct {
    allocator: std.mem.Allocator,
    parser: PgsParser,

    pub fn init(allocator: std.mem.Allocator) PgsDecoder {
        return .{
            .allocator = allocator,
            .parser = PgsParser.init(allocator),
        };
    }

    pub fn deinit(self: *PgsDecoder) void {
        _ = self;
    }

    /// Decode subtitle event from stream data
    pub fn decodeEvent(self: *PgsDecoder, data: []const u8) !Pgs.SubtitleEvent {
        var event = Pgs.SubtitleEvent{
            .pts = 0,
            .dts = 0,
            .display = null,
            .palettes = std.ArrayList(Pgs.PaletteDefinition).init(self.allocator),
            .objects = std.ArrayList(Pgs.ObjectDefinition).init(self.allocator),
            .windows = std.ArrayList(Pgs.WindowDefinition).init(self.allocator),
            .composition = null,
        };

        var offset: usize = 0;

        while (offset + 13 <= data.len) {
            const header = try self.parser.parseSegmentHeader(data[offset..]);
            offset += 13;

            if (offset + header.segment_size > data.len) break;

            const segment_data = data[offset .. offset + header.segment_size];

            switch (header.segment_type) {
                .palette_definition => {
                    const palette = try self.parser.parsePaletteDefinition(segment_data);
                    try event.palettes.append(palette);
                },
                .object_definition => {
                    const object = try PgsParser.parseObjectDefinition(segment_data);
                    try event.objects.append(object);
                },
                .presentation_composition => {
                    event.composition = try self.parser.parsePresentationComposition(segment_data);
                    event.pts = header.pts;
                    event.dts = header.dts;
                },
                .window_definition => {
                    const windows = try self.parser.parseWindowDefinition(segment_data);
                    for (windows) |window| {
                        try event.windows.append(window);
                    }
                },
                .display_definition => {
                    event.display = try PgsParser.parseDisplayDefinition(segment_data);
                },
                else => {},
            }

            offset += header.segment_size;
        }

        return event;
    }

    /// Render subtitle to RGBA bitmap
    pub fn renderToRgba(self: *PgsDecoder, event: Pgs.SubtitleEvent) ![]u8 {
        if (event.display == null) return error.NoDisplayDefinition;
        const display = event.display.?;

        const width = display.width;
        const height = display.height;
        const pixel_count = @as(usize, width) * height * 4; // RGBA

        var rgba = try self.allocator.alloc(u8, pixel_count);
        @memset(rgba, 0); // Transparent background

        // Get palette
        if (event.palettes.items.len == 0) return rgba;
        const palette = event.palettes.items[0];

        // Render each object
        for (event.objects.items) |object| {
            if (object.width == 0 or object.height == 0) continue;

            // Decode RLE
            const pixels = try self.parser.decodeRle(object.rle_data, object.width, object.height);
            defer self.allocator.free(pixels);

            // Find composition info
            if (event.composition) |comp| {
                for (comp.composition_objects) |comp_obj| {
                    if (comp_obj.object_id == object.object_id) {
                        // Blit pixels to RGBA buffer
                        for (0..object.height) |y| {
                            for (0..object.width) |x| {
                                const src_idx = y * object.width + x;
                                const palette_idx = pixels[src_idx];

                                // Find palette entry
                                var entry: ?Pgs.PaletteEntry = null;
                                for (palette.entries) |pe| {
                                    if (pe.id == palette_idx) {
                                        entry = pe;
                                        break;
                                    }
                                }

                                if (entry) |e| {
                                    const dst_x = comp_obj.x + @as(u16, @intCast(x));
                                    const dst_y = comp_obj.y + @as(u16, @intCast(y));

                                    if (dst_x < width and dst_y < height) {
                                        const dst_idx = (@as(usize, dst_y) * width + dst_x) * 4;

                                        // YCrCb to RGB conversion (simplified)
                                        const r = @min(255, @max(0, @as(i32, e.y) + @as(i32, @intCast(@as(u32, e.cr) -% 128)) * 1436 / 1024));
                                        const g = @min(255, @max(0, @as(i32, e.y) - @as(i32, @intCast(@as(u32, e.cb) -% 128)) * 352 / 1024 - @as(i32, @intCast(@as(u32, e.cr) -% 128)) * 731 / 1024));
                                        const b = @min(255, @max(0, @as(i32, e.y) + @as(i32, @intCast(@as(u32, e.cb) -% 128)) * 1814 / 1024));

                                        rgba[dst_idx] = @intCast(r);
                                        rgba[dst_idx + 1] = @intCast(g);
                                        rgba[dst_idx + 2] = @intCast(b);
                                        rgba[dst_idx + 3] = e.alpha;
                                    }
                                }
                            }
                        }
                        break;
                    }
                }
            }
        }

        return rgba;
    }
};

/// Check if data is PGS subtitle stream
pub fn isPgs(data: []const u8) bool {
    if (data.len < 2) return false;
    return std.mem.eql(u8, data[0..2], "PG");
}
