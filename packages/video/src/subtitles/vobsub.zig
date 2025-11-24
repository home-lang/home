const std = @import("std");

/// VobSub (DVD subtitles) - Image-based subtitle format from DVDs
pub const VobSub = struct {
    /// Subtitle packet
    pub const SubPacket = struct {
        stream_id: u8,
        pts: u64, // Presentation timestamp (90kHz)
        control_offset: u16,
        data: []const u8,
    };

    /// Control sequence command
    pub const ControlCommand = enum(u8) {
        force_display = 0x00,
        start_display = 0x01,
        stop_display = 0x02,
        set_palette = 0x03,
        set_alpha = 0x04,
        set_display_area = 0x05,
        set_pixel_data_address = 0x06,
        change_color_contrast = 0x07,
        end_of_control = 0xFF,
    };

    /// Control sequence
    pub const ControlSequence = struct {
        date: u16, // Control sequence start time offset
        next: u16, // Offset to next control sequence
        commands: std.ArrayList(Command),
    };

    pub const Command = union(ControlCommand) {
        force_display: void,
        start_display: void,
        stop_display: void,
        set_palette: [4]u8,
        set_alpha: [4]u8,
        set_display_area: DisplayArea,
        set_pixel_data_address: PixelDataAddress,
        change_color_contrast: [4]u8,
        end_of_control: void,
    };

    pub const DisplayArea = struct {
        x_start: u16,
        x_end: u16,
        y_start: u16,
        y_end: u16,
    };

    pub const PixelDataAddress = struct {
        top_field_offset: u16,
        bottom_field_offset: u16,
    };

    /// Subtitle image
    pub const SubImage = struct {
        pts: u64,
        duration_us: u64,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        palette: [4]u8,
        alpha: [4]u8,
        pixels: []u8, // Indexed color (0-3)
    };
};

/// VobSub IDX file parser (metadata)
pub const VobSubIdx = struct {
    allocator: std.mem.Allocator,
    size: struct { width: u16, height: u16 } = .{ .width = 720, .height = 480 },
    palette: [16]u32 = undefined, // RGB palette
    language: []const u8 = "en",
    timestamps: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) VobSubIdx {
        return .{
            .allocator = allocator,
            .timestamps = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *VobSubIdx) void {
        self.timestamps.deinit();
    }

    pub fn parse(self: *VobSubIdx, data: []const u8) !void {
        var lines = std.mem.split(u8, data, "\n");

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.startsWith(u8, trimmed, "size:")) {
                try self.parseSize(trimmed[5..]);
            } else if (std.mem.startsWith(u8, trimmed, "palette:")) {
                try self.parsePalette(trimmed[8..]);
            } else if (std.mem.startsWith(u8, trimmed, "timestamp:")) {
                try self.parseTimestamp(trimmed[10..]);
            }
        }
    }

    fn parseSize(self: *VobSubIdx, line: []const u8) !void {
        _ = self;
        var parts = std.mem.split(u8, std.mem.trim(u8, line, " "), "x");
        if (parts.next()) |width_str| {
            const width = try std.fmt.parseInt(u16, std.mem.trim(u8, width_str, " "), 10);
            if (parts.next()) |height_str| {
                const height = try std.fmt.parseInt(u16, std.mem.trim(u8, height_str, " "), 10);
                self.size.width = width;
                self.size.height = height;
            }
        }
    }

    fn parsePalette(self: *VobSubIdx, line: []const u8) !void {
        var parts = std.mem.split(u8, std.mem.trim(u8, line, " "), ",");
        var i: usize = 0;

        while (parts.next()) |color_str| : (i += 1) {
            if (i >= 16) break;
            const trimmed = std.mem.trim(u8, color_str, " ");
            const color = try std.fmt.parseInt(u32, trimmed, 16);
            self.palette[i] = color;
        }
    }

    fn parseTimestamp(self: *VobSubIdx, line: []const u8) !void {
        // Format: HH:MM:SS:mmm
        const trimmed = std.mem.trim(u8, line, " ");
        var parts = std.mem.split(u8, trimmed, ":");

        var hours: u64 = 0;
        var minutes: u64 = 0;
        var seconds: u64 = 0;
        var millis: u64 = 0;

        if (parts.next()) |h| hours = try std.fmt.parseInt(u64, std.mem.trim(u8, h, " "), 10);
        if (parts.next()) |m| minutes = try std.fmt.parseInt(u64, std.mem.trim(u8, m, " "), 10);
        if (parts.next()) |s| seconds = try std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10);
        if (parts.next()) |ms| millis = try std.fmt.parseInt(u64, std.mem.trim(u8, ms, " "), 10);

        const timestamp_us = (hours * 3600 + minutes * 60 + seconds) * 1_000_000 + millis * 1000;
        try self.timestamps.append(timestamp_us);
    }
};

/// VobSub SUB file parser (actual subtitle data)
pub const VobSubParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VobSubParser {
        return .{ .allocator = allocator };
    }

    pub fn parsePacket(data: []const u8) !VobSub.SubPacket {
        if (data.len < 4) return error.InsufficientData;

        // MPEG-2 PS packet header check
        if (data[0] != 0x00 or data[1] != 0x00 or data[2] != 0x01) {
            return error.InvalidPacketStart;
        }

        const stream_id = data[3];

        // Private stream 1 (0xBD) contains subtitles
        if (stream_id != 0xBD) return error.NotSubtitleStream;

        if (data.len < 9) return error.InsufficientData;

        const packet_length = (@as(u16, data[4]) << 8) | data[5];
        if (data.len < 6 + packet_length) return error.InsufficientData;

        // Skip PES header stuffing
        const header_data_length = data[8];
        var offset: usize = 9 + header_data_length;

        // Parse PTS if present
        var pts: u64 = 0;
        if (data[7] & 0x80 != 0) {
            if (offset + 5 > data.len) return error.InsufficientData;
            pts = parsePts(data[offset - header_data_length .. offset]);
        }

        // Subtitle stream ID (should be 0x20-0x3F for subtitles)
        if (offset >= data.len) return error.InsufficientData;
        const sub_stream_id = data[offset];
        offset += 1;

        // Packet size
        if (offset + 2 > data.len) return error.InsufficientData;
        const packet_size = (@as(u16, data[offset]) << 8) | data[offset + 1];
        offset += 2;

        // Control offset
        if (offset + 2 > data.len) return error.InsufficientData;
        const control_offset = (@as(u16, data[offset]) << 8) | data[offset + 1];
        offset += 2;

        const packet_data_end = offset + packet_size;
        if (packet_data_end > data.len) return error.InsufficientData;

        return VobSub.SubPacket{
            .stream_id = sub_stream_id,
            .pts = pts,
            .control_offset = control_offset,
            .data = data[offset..packet_data_end],
        };
    }

    fn parsePts(data: []const u8) u64 {
        if (data.len < 5) return 0;

        const pts: u64 = (@as(u64, data[0] & 0x0E) << 29) | (@as(u64, data[1]) << 22) | (@as(u64, (data[2] & 0xFE)) << 14) | (@as(u64, data[3]) << 7) | (@as(u64, data[4]) >> 1);

        return pts;
    }

    pub fn parseControlSequence(self: *VobSubParser, data: []const u8, offset: usize) !VobSub.ControlSequence {
        if (offset + 4 > data.len) return error.InsufficientData;

        var seq = VobSub.ControlSequence{
            .date = (@as(u16, data[offset]) << 8) | data[offset + 1],
            .next = (@as(u16, data[offset + 2]) << 8) | data[offset + 3],
            .commands = std.ArrayList(VobSub.Command).init(self.allocator),
        };

        var cmd_offset = offset + 4;

        while (cmd_offset < data.len) {
            const cmd_byte = data[cmd_offset];
            cmd_offset += 1;

            switch (cmd_byte) {
                0x00 => try seq.commands.append(.{ .force_display = {} }),
                0x01 => try seq.commands.append(.{ .start_display = {} }),
                0x02 => try seq.commands.append(.{ .stop_display = {} }),
                0x03 => {
                    // Set palette
                    if (cmd_offset + 2 > data.len) break;
                    const palette_data = (@as(u16, data[cmd_offset]) << 8) | data[cmd_offset + 1];
                    cmd_offset += 2;

                    try seq.commands.append(.{
                        .set_palette = [4]u8{
                            @truncate(palette_data >> 12),
                            @truncate((palette_data >> 8) & 0x0F),
                            @truncate((palette_data >> 4) & 0x0F),
                            @truncate(palette_data & 0x0F),
                        },
                    });
                },
                0x04 => {
                    // Set alpha
                    if (cmd_offset + 2 > data.len) break;
                    const alpha_data = (@as(u16, data[cmd_offset]) << 8) | data[cmd_offset + 1];
                    cmd_offset += 2;

                    try seq.commands.append(.{
                        .set_alpha = [4]u8{
                            @truncate(alpha_data >> 12),
                            @truncate((alpha_data >> 8) & 0x0F),
                            @truncate((alpha_data >> 4) & 0x0F),
                            @truncate(alpha_data & 0x0F),
                        },
                    });
                },
                0x05 => {
                    // Set display area
                    if (cmd_offset + 6 > data.len) break;

                    const x_start = (@as(u16, data[cmd_offset]) << 4) | (@as(u16, data[cmd_offset + 1]) >> 4);
                    const x_end = (@as(u16, data[cmd_offset + 1] & 0x0F) << 8) | data[cmd_offset + 2];
                    const y_start = (@as(u16, data[cmd_offset + 3]) << 4) | (@as(u16, data[cmd_offset + 4]) >> 4);
                    const y_end = (@as(u16, data[cmd_offset + 4] & 0x0F) << 8) | data[cmd_offset + 5];
                    cmd_offset += 6;

                    try seq.commands.append(.{
                        .set_display_area = .{
                            .x_start = x_start,
                            .x_end = x_end,
                            .y_start = y_start,
                            .y_end = y_end,
                        },
                    });
                },
                0x06 => {
                    // Set pixel data address
                    if (cmd_offset + 4 > data.len) break;
                    const top = (@as(u16, data[cmd_offset]) << 8) | data[cmd_offset + 1];
                    const bottom = (@as(u16, data[cmd_offset + 2]) << 8) | data[cmd_offset + 3];
                    cmd_offset += 4;

                    try seq.commands.append(.{
                        .set_pixel_data_address = .{
                            .top_field_offset = top,
                            .bottom_field_offset = bottom,
                        },
                    });
                },
                0xFF => {
                    try seq.commands.append(.{ .end_of_control = {} });
                    break;
                },
                else => {
                    // Unknown command, skip
                },
            }
        }

        return seq;
    }

    /// Decode RLE subtitle data to indexed pixels
    pub fn decodeRle(self: *VobSubParser, data: []const u8, width: u16, height: u16) ![]u8 {
        const pixel_count = @as(usize, width) * height;
        var pixels = try self.allocator.alloc(u8, pixel_count);
        @memset(pixels, 0);

        var pixel_idx: usize = 0;
        var offset: usize = 0;

        while (offset < data.len and pixel_idx < pixel_count) {
            const nibble_high = data[offset] >> 4;
            const nibble_low = data[offset] & 0x0F;
            offset += 1;

            if (nibble_high != 0) {
                // Short run
                const color = nibble_low;
                const count = nibble_high;

                for (0..count) |_| {
                    if (pixel_idx >= pixel_count) break;
                    pixels[pixel_idx] = @truncate(color);
                    pixel_idx += 1;
                }
            } else if (nibble_low != 0) {
                // Medium run
                if (offset >= data.len) break;
                const next_byte = data[offset];
                offset += 1;

                const count = @as(usize, nibble_low) << 4 | (next_byte >> 4);
                const color = next_byte & 0x0F;

                for (0..count) |_| {
                    if (pixel_idx >= pixel_count) break;
                    pixels[pixel_idx] = @truncate(color);
                    pixel_idx += 1;
                }
            } else {
                // Long run or end of line
                if (offset >= data.len) break;
                const next_byte = data[offset];
                offset += 1;

                if (next_byte == 0) {
                    // End of line - advance to next line
                    const line_width = width;
                    const current_line = pixel_idx / line_width;
                    pixel_idx = (current_line + 1) * line_width;
                } else {
                    const count = next_byte;
                    pixel_idx += count; // Transparent pixels
                }
            }
        }

        return pixels;
    }
};

/// VobSub subtitle decoder
pub const VobSubDecoder = struct {
    allocator: std.mem.Allocator,
    parser: VobSubParser,
    idx: VobSubIdx,

    pub fn init(allocator: std.mem.Allocator) VobSubDecoder {
        return .{
            .allocator = allocator,
            .parser = VobSubParser.init(allocator),
            .idx = VobSubIdx.init(allocator),
        };
    }

    pub fn deinit(self: *VobSubDecoder) void {
        self.idx.deinit();
    }

    pub fn loadIdx(self: *VobSubDecoder, data: []const u8) !void {
        try self.idx.parse(data);
    }

    pub fn decodeSubtitle(self: *VobSubDecoder, packet: VobSub.SubPacket) !VobSub.SubImage {
        // Parse control sequence to get display area, palette, alpha
        const control_seq = try self.parser.parseControlSequence(packet.data, packet.control_offset);
        defer control_seq.commands.deinit();

        var image = VobSub.SubImage{
            .pts = packet.pts,
            .duration_us = 0,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .palette = [4]u8{ 0, 1, 2, 3 },
            .alpha = [4]u8{ 0, 0, 0, 0 },
            .pixels = &[_]u8{},
        };

        // Extract information from control commands
        for (control_seq.commands.items) |cmd| {
            switch (cmd) {
                .set_palette => |pal| image.palette = pal,
                .set_alpha => |alpha| image.alpha = alpha,
                .set_display_area => |area| {
                    image.x = area.x_start;
                    image.y = area.y_start;
                    image.width = area.x_end - area.x_start + 1;
                    image.height = area.y_end - area.y_start + 1;
                },
                else => {},
            }
        }

        // Decode pixel data
        if (image.width > 0 and image.height > 0) {
            image.pixels = try self.parser.decodeRle(packet.data[0..packet.control_offset], image.width, image.height);
        }

        return image;
    }

    /// Render subtitle to RGBA
    pub fn renderToRgba(self: *VobSubDecoder, image: VobSub.SubImage) ![]u8 {
        const pixel_count = @as(usize, self.idx.size.width) * self.idx.size.height * 4; // RGBA
        var rgba = try self.allocator.alloc(u8, pixel_count);
        @memset(rgba, 0); // Transparent background

        // Render subtitle image
        for (0..image.height) |y| {
            for (0..image.width) |x| {
                const src_idx = y * image.width + x;
                if (src_idx >= image.pixels.len) continue;

                const palette_idx = image.pixels[src_idx];
                if (palette_idx >= 4) continue;

                const alpha = image.alpha[palette_idx];
                if (alpha == 0) continue; // Transparent

                const color_idx = image.palette[palette_idx];
                if (color_idx >= 16) continue;

                const color = self.idx.palette[color_idx];

                const dst_x = image.x + @as(u16, @intCast(x));
                const dst_y = image.y + @as(u16, @intCast(y));

                if (dst_x < self.idx.size.width and dst_y < self.idx.size.height) {
                    const dst_idx = (@as(usize, dst_y) * self.idx.size.width + dst_x) * 4;

                    rgba[dst_idx] = @truncate((color >> 16) & 0xFF); // R
                    rgba[dst_idx + 1] = @truncate((color >> 8) & 0xFF); // G
                    rgba[dst_idx + 2] = @truncate(color & 0xFF); // B
                    rgba[dst_idx + 3] = alpha * 17; // Scale 0-15 to 0-255
                }
            }
        }

        return rgba;
    }
};
