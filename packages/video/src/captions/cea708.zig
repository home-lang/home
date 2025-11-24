// Home Video Library - CEA-708 Digital Television Closed Captions
// DTVCC - Modern closed captions for digital television (ATSC)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// CEA-708 Constants
// ============================================================================

pub const MAX_SERVICES = 8;
pub const MAX_WINDOWS = 8;
pub const CAPTION_BUFFER_SIZE = 32;

// Command codes
pub const CMD_SET_CURRENT_WINDOW = 0x80;
pub const CMD_CLEAR_WINDOWS = 0x88;
pub const CMD_DISPLAY_WINDOWS = 0x89;
pub const CMD_HIDE_WINDOWS = 0x8A;
pub const CMD_TOGGLE_WINDOWS = 0x8B;
pub const CMD_DELETE_WINDOWS = 0x8C;
pub const CMD_DELAY = 0x8D;
pub const CMD_DELAY_CANCEL = 0x8E;
pub const CMD_RESET = 0x8F;
pub const CMD_SET_PEN_ATTRIBUTES = 0x90;
pub const CMD_SET_PEN_COLOR = 0x91;
pub const CMD_SET_PEN_LOCATION = 0x92;
pub const CMD_SET_WINDOW_ATTRIBUTES = 0x97;
pub const CMD_DEFINE_WINDOW = 0x98;

// ============================================================================
// CEA-708 Types
// ============================================================================

pub const ServiceNumber = u3; // 1-7 (0 reserved)

pub const PenSize = enum(u2) {
    small = 0,
    standard = 1,
    large = 2,
};

pub const FontStyle = enum(u3) {
    default = 0,
    mono_serif = 1,
    prop_serif = 2,
    mono_sans = 3,
    prop_sans = 4,
    casual = 5,
    cursive = 6,
    small_caps = 7,
};

pub const TextTag = enum(u4) {
    dialog = 0,
    source_ident = 1,
    electronic_voice = 2,
    foreign = 3,
    voiceover = 4,
    audible_translation = 5,
    subtitle_translation = 6,
    voice_description = 7,
    song_lyrics = 8,
    effect_description = 9,
    score_description = 10,
    expletive = 11,
    // 12-15 reserved
};

pub const Opacity = enum(u2) {
    solid = 0,
    flash = 1,
    translucent = 2,
    transparent = 3,
};

pub const Color = struct {
    r: u2,
    g: u2,
    b: u2,

    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0 };
    pub const WHITE = Color{ .r = 3, .g = 3, .b = 3 };
    pub const RED = Color{ .r = 3, .g = 0, .b = 0 };
    pub const GREEN = Color{ .r = 0, .g = 3, .b = 0 };
    pub const BLUE = Color{ .r = 0, .g = 0, .b = 3 };
    pub const YELLOW = Color{ .r = 3, .g = 3, .b = 0 };
    pub const MAGENTA = Color{ .r = 3, .g = 0, .b = 3 };
    pub const CYAN = Color{ .r = 0, .g = 3, .b = 3 };
};

pub const PenAttributes = struct {
    size: PenSize = .standard,
    font: FontStyle = .default,
    text_tag: TextTag = .dialog,
    offset: i2 = 0, // Subscript/superscript
    italic: bool = false,
    underline: bool = false,
    edge_type: u3 = 0, // 0=none, 1=raised, 2=depressed, 3=uniform, 4=drop shadow
};

pub const PenColor = struct {
    foreground: Color = Color.WHITE,
    foreground_opacity: Opacity = .solid,
    background: Color = Color.BLACK,
    background_opacity: Opacity = .solid,
    edge_color: Color = Color.BLACK,
};

pub const WindowAttributes = struct {
    justify: u2 = 0, // 0=left, 1=right, 2=center, 3=full
    print_direction: u2 = 0, // 0=left-to-right, 1=right-to-left, 2=top-to-bottom, 3=bottom-to-top
    scroll_direction: u2 = 0,
    word_wrap: bool = true,
    display_effect: u2 = 0, // 0=snap, 1=fade, 2=wipe
    effect_direction: u2 = 0,
    effect_speed: u4 = 0,
    fill_color: Color = Color.BLACK,
    fill_opacity: Opacity = .solid,
    border_type: u2 = 0, // 0=none, 1=raised, 2=depressed, 3=uniform, 4=drop shadow
    border_color: Color = Color.BLACK,
};

// ============================================================================
// CEA-708 Window
// ============================================================================

pub const Window = struct {
    id: u3,
    visible: bool = false,
    defined: bool = false,

    // Window position and size
    anchor_vertical: u7 = 0, // 0-74 (percentage of screen height)
    anchor_horizontal: u8 = 0, // 0-209 (percentage of screen width)
    anchor_point: u4 = 0, // Which corner to anchor
    row_count: u4 = 0, // Minus 1
    column_count: u6 = 0, // Minus 1

    // Relative positioning
    relative_positioning: bool = false,

    // Row lock and column lock
    row_lock: bool = false,
    column_lock: bool = false,

    // Current pen position
    pen_row: u4 = 0,
    pen_column: u6 = 0,

    // Attributes
    pen_attributes: PenAttributes = .{},
    pen_color: PenColor = .{},
    window_attributes: WindowAttributes = .{},

    // Text buffer
    buffer: [CAPTION_BUFFER_SIZE][CAPTION_BUFFER_SIZE]Cell = undefined,

    const Cell = struct {
        char: u16 = ' ',
        attributes: PenAttributes = .{},
        color: PenColor = .{},
    };

    pub fn init(id: u3) Window {
        var window = Window{
            .id = id,
            .buffer = undefined,
        };
        window.clear();
        return window;
    }

    pub fn clear(self: *Window) void {
        for (&self.buffer) |*row| {
            for (row) |*cell| {
                cell.* = .{};
            }
        }
        self.pen_row = 0;
        self.pen_column = 0;
    }

    pub fn writeChar(self: *Window, char: u16) void {
        if (self.pen_row >= CAPTION_BUFFER_SIZE or self.pen_column >= CAPTION_BUFFER_SIZE) {
            return;
        }

        self.buffer[self.pen_row][self.pen_column] = .{
            .char = char,
            .attributes = self.pen_attributes,
            .color = self.pen_color,
        };

        // Advance pen
        self.pen_column += 1;
        if (self.pen_column >= self.column_count + 1) {
            if (self.window_attributes.word_wrap) {
                self.pen_column = 0;
                self.pen_row += 1;
                if (self.pen_row >= self.row_count + 1) {
                    self.pen_row = self.row_count;
                    // Scroll
                    self.scrollUp();
                }
            } else {
                self.pen_column = self.column_count;
            }
        }
    }

    pub fn backspace(self: *Window) void {
        if (self.pen_column > 0) {
            self.pen_column -= 1;
            self.buffer[self.pen_row][self.pen_column] = .{};
        }
    }

    pub fn carriageReturn(self: *Window) void {
        self.pen_column = 0;
        self.pen_row += 1;
        if (self.pen_row >= self.row_count + 1) {
            self.pen_row = self.row_count;
            self.scrollUp();
        }
    }

    fn scrollUp(self: *Window) void {
        var r: usize = 0;
        while (r < self.row_count) : (r += 1) {
            @memcpy(&self.buffer[r], &self.buffer[r + 1]);
        }
        // Clear last row
        for (&self.buffer[self.row_count]) |*cell| {
            cell.* = .{};
        }
    }

    pub fn getText(self: *const Window, allocator: Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);

        for (0..self.row_count + 1) |r| {
            var has_content = false;
            for (0..self.column_count + 1) |c| {
                if (self.buffer[r][c].char != ' ') {
                    has_content = true;
                    break;
                }
            }

            if (has_content) {
                for (0..self.column_count + 1) |c| {
                    const char = self.buffer[r][c].char;
                    if (char < 128) {
                        try output.append(@intCast(char));
                    } else {
                        // Simplified: convert to '?'
                        try output.append('?');
                    }
                }
                if (r < self.row_count) {
                    try output.append('\n');
                }
            }
        }

        return output.toOwnedSlice();
    }
};

// ============================================================================
// CEA-708 Service
// ============================================================================

pub const Service = struct {
    number: ServiceNumber,
    windows: [MAX_WINDOWS]Window,
    current_window: u3 = 0,

    pub fn init(number: ServiceNumber) Service {
        var service = Service{
            .number = number,
            .windows = undefined,
        };
        for (0..MAX_WINDOWS) |i| {
            service.windows[i] = Window.init(@intCast(i));
        }
        return service;
    }

    pub fn getCurrentWindow(self: *Service) *Window {
        return &self.windows[self.current_window];
    }

    pub fn reset(self: *Service) void {
        for (&self.windows) |*window| {
            window.clear();
            window.visible = false;
            window.defined = false;
        }
        self.current_window = 0;
    }
};

// ============================================================================
// CEA-708 Decoder
// ============================================================================

pub const Cea708Decoder = struct {
    services: [MAX_SERVICES]Service,
    current_service: ServiceNumber = 1,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Cea708Decoder {
        var decoder = Cea708Decoder{
            .services = undefined,
            .allocator = allocator,
        };
        for (0..MAX_SERVICES) |i| {
            decoder.services[i] = Service.init(@intCast(i));
        }
        return decoder;
    }

    /// Decode a CEA-708 caption channel packet
    pub fn decodePacket(self: *Cea708Decoder, data: []const u8) ![]CaptionEvent {
        if (data.len < 3) return &[_]CaptionEvent{};

        var events = std.ArrayList(CaptionEvent).init(self.allocator);

        // Parse service block header
        const service_number = @as(ServiceNumber, @truncate(data[0] & 0x07));
        const block_size = @as(u8, @truncate(data[1] & 0x1F));

        if (block_size == 0 or data.len < 2 + block_size) {
            return events.toOwnedSlice();
        }

        self.current_service = service_number;
        var service = &self.services[service_number];

        // Parse commands and characters
        var offset: usize = 2;
        const end_offset = 2 + block_size;

        while (offset < end_offset) {
            const byte = data[offset];
            offset += 1;

            // Control codes (0x00-0x1F)
            if (byte <= 0x1F) {
                if (byte == 0x00 or byte == 0x08 or byte == 0x0D) {
                    // NUL, BS, CR
                    try self.handleC0Code(service, byte, &events);
                }
                continue;
            }

            // G0 characters (0x20-0x7F)
            if (byte >= 0x20 and byte <= 0x7F) {
                service.getCurrentWindow().writeChar(byte);
                continue;
            }

            // Commands (0x80-0x9F)
            if (byte >= 0x80 and byte <= 0x9F) {
                offset = try self.handleCommand(service, data, offset - 1, &events);
                continue;
            }

            // G2/G3 characters (0xA0-0xFF) - extended characters
            if (byte >= 0xA0) {
                service.getCurrentWindow().writeChar(byte);
                continue;
            }
        }

        return events.toOwnedSlice();
    }

    fn handleC0Code(self: *Cea708Decoder, service: *Service, code: u8, events: *std.ArrayList(CaptionEvent)) !void {
        _ = self;
        const window = service.getCurrentWindow();

        switch (code) {
            0x00 => {}, // NUL - ignore
            0x08 => window.backspace(), // BS
            0x0D => window.carriageReturn(), // CR
            else => {},
        }

        // Generate event if window is visible
        if (window.visible) {
            const text = try window.getText(self.allocator);
            try events.append(.{ .window_updated = .{ .window_id = window.id, .text = text } });
        }
    }

    fn handleCommand(
        self: *Cea708Decoder,
        service: *Service,
        data: []const u8,
        offset: usize,
        events: *std.ArrayList(CaptionEvent),
    ) !usize {
        var pos = offset;
        const cmd = data[pos];
        pos += 1;

        switch (cmd) {
            CMD_SET_CURRENT_WINDOW => {
                if (pos >= data.len) return pos;
                service.current_window = @truncate(data[pos] & 0x07);
                pos += 1;
            },
            CMD_CLEAR_WINDOWS => {
                if (pos >= data.len) return pos;
                const bitmap = data[pos];
                pos += 1;
                for (0..8) |i| {
                    if (bitmap & (@as(u8, 1) << @intCast(i)) != 0) {
                        service.windows[i].clear();
                    }
                }
            },
            CMD_DISPLAY_WINDOWS => {
                if (pos >= data.len) return pos;
                const bitmap = data[pos];
                pos += 1;
                for (0..8) |i| {
                    if (bitmap & (@as(u8, 1) << @intCast(i)) != 0) {
                        service.windows[i].visible = true;
                        const text = try service.windows[i].getText(self.allocator);
                        try events.append(.{ .window_shown = .{
                            .window_id = @intCast(i),
                            .text = text,
                        } });
                    }
                }
            },
            CMD_HIDE_WINDOWS => {
                if (pos >= data.len) return pos;
                const bitmap = data[pos];
                pos += 1;
                for (0..8) |i| {
                    if (bitmap & (@as(u8, 1) << @intCast(i)) != 0) {
                        service.windows[i].visible = false;
                        try events.append(.{ .window_hidden = .{ .window_id = @intCast(i) } });
                    }
                }
            },
            CMD_TOGGLE_WINDOWS => {
                if (pos >= data.len) return pos;
                const bitmap = data[pos];
                pos += 1;
                for (0..8) |i| {
                    if (bitmap & (@as(u8, 1) << @intCast(i)) != 0) {
                        service.windows[i].visible = !service.windows[i].visible;
                    }
                }
            },
            CMD_DELETE_WINDOWS => {
                if (pos >= data.len) return pos;
                const bitmap = data[pos];
                pos += 1;
                for (0..8) |i| {
                    if (bitmap & (@as(u8, 1) << @intCast(i)) != 0) {
                        service.windows[i].clear();
                        service.windows[i].defined = false;
                        service.windows[i].visible = false;
                    }
                }
            },
            CMD_RESET => {
                service.reset();
                try events.append(.service_reset);
            },
            CMD_SET_PEN_ATTRIBUTES => {
                if (pos + 1 >= data.len) return pos;
                try self.setPenAttributes(service, data[pos .. pos + 2]);
                pos += 2;
            },
            CMD_SET_PEN_COLOR => {
                if (pos + 2 >= data.len) return pos;
                try self.setPenColor(service, data[pos .. pos + 3]);
                pos += 3;
            },
            CMD_SET_PEN_LOCATION => {
                if (pos + 1 >= data.len) return pos;
                const window = service.getCurrentWindow();
                window.pen_row = @truncate(data[pos] & 0x0F);
                window.pen_column = @truncate(data[pos + 1] & 0x3F);
                pos += 2;
            },
            CMD_SET_WINDOW_ATTRIBUTES => {
                if (pos + 3 >= data.len) return pos;
                try self.setWindowAttributes(service, data[pos .. pos + 4]);
                pos += 4;
            },
            CMD_DEFINE_WINDOW => {
                if (pos + 5 >= data.len) return pos;
                try self.defineWindow(service, data[pos .. pos + 6]);
                pos += 6;
            },
            else => {
                // Unknown command, try to skip it
                // Most commands are 0-6 bytes
            },
        }

        return pos;
    }

    fn setPenAttributes(self: *Cea708Decoder, service: *Service, data: []const u8) !void {
        _ = self;
        if (data.len < 2) return;

        const window = service.getCurrentWindow();
        window.pen_attributes.size = @enumFromInt(@as(u2, @truncate(data[0] & 0x03)));
        window.pen_attributes.offset = @intCast((data[0] >> 2) & 0x03);
        window.pen_attributes.text_tag = @enumFromInt(@as(u4, @truncate((data[0] >> 4) & 0x0F)));

        window.pen_attributes.font = @enumFromInt(@as(u3, @truncate(data[1] & 0x07)));
        window.pen_attributes.edge_type = @truncate((data[1] >> 3) & 0x07);
        window.pen_attributes.underline = (data[1] & 0x40) != 0;
        window.pen_attributes.italic = (data[1] & 0x80) != 0;
    }

    fn setPenColor(self: *Cea708Decoder, service: *Service, data: []const u8) !void {
        _ = self;
        if (data.len < 3) return;

        const window = service.getCurrentWindow();

        // Foreground
        window.pen_color.foreground_opacity = @enumFromInt(@as(u2, @truncate(data[0] & 0x03)));
        window.pen_color.foreground = .{
            .r = @truncate((data[0] >> 2) & 0x03),
            .g = @truncate((data[0] >> 4) & 0x03),
            .b = @truncate((data[0] >> 6) & 0x03),
        };

        // Background
        window.pen_color.background_opacity = @enumFromInt(@as(u2, @truncate(data[1] & 0x03)));
        window.pen_color.background = .{
            .r = @truncate((data[1] >> 2) & 0x03),
            .g = @truncate((data[1] >> 4) & 0x03),
            .b = @truncate((data[1] >> 6) & 0x03),
        };

        // Edge color
        window.pen_color.edge_color = .{
            .r = @truncate(data[2] & 0x03),
            .g = @truncate((data[2] >> 2) & 0x03),
            .b = @truncate((data[2] >> 4) & 0x03),
        };
    }

    fn setWindowAttributes(self: *Cea708Decoder, service: *Service, data: []const u8) !void {
        _ = self;
        if (data.len < 4) return;

        const window = service.getCurrentWindow();

        window.window_attributes.fill_opacity = @enumFromInt(@as(u2, @truncate(data[0] & 0x03)));
        window.window_attributes.fill_color = .{
            .r = @truncate((data[0] >> 2) & 0x03),
            .g = @truncate((data[0] >> 4) & 0x03),
            .b = @truncate((data[0] >> 6) & 0x03),
        };

        window.window_attributes.border_type = @truncate(data[1] & 0x03);
        window.window_attributes.border_color = .{
            .r = @truncate((data[1] >> 2) & 0x03),
            .g = @truncate((data[1] >> 4) & 0x03),
            .b = @truncate((data[1] >> 6) & 0x03),
        };

        window.window_attributes.word_wrap = (data[2] & 0x40) != 0;
        window.window_attributes.print_direction = @truncate(data[2] & 0x03);
        window.window_attributes.scroll_direction = @truncate((data[2] >> 2) & 0x03);
        window.window_attributes.justify = @truncate((data[2] >> 4) & 0x03);

        window.window_attributes.effect_speed = @truncate(data[3] & 0x0F);
        window.window_attributes.effect_direction = @truncate((data[3] >> 4) & 0x03);
        window.window_attributes.display_effect = @truncate((data[3] >> 6) & 0x03);
    }

    fn defineWindow(self: *Cea708Decoder, service: *Service, data: []const u8) !void {
        _ = self;
        if (data.len < 6) return;

        const window_id = @as(u3, @truncate(data[0] & 0x07));
        var window = &service.windows[window_id];

        window.defined = true;
        window.visible = (data[0] & 0x20) != 0;

        window.anchor_point = @truncate((data[0] >> 4) & 0x0F);
        window.relative_positioning = (data[1] & 0x80) != 0;
        window.anchor_vertical = @truncate(data[1] & 0x7F);
        window.anchor_horizontal = data[2];

        window.row_count = @truncate(data[3] & 0x0F);
        window.column_count = @truncate(data[4] & 0x3F);

        window.row_lock = (data[5] & 0x08) != 0;
        window.column_lock = (data[5] & 0x10) != 0;
    }

    pub fn reset(self: *Cea708Decoder) void {
        for (&self.services) |*service| {
            service.reset();
        }
        self.current_service = 1;
    }
};

// ============================================================================
// Caption Events
// ============================================================================

pub const CaptionEvent = union(enum) {
    window_shown: struct { window_id: u3, text: []const u8 },
    window_hidden: struct { window_id: u3 },
    window_updated: struct { window_id: u3, text: []const u8 },
    service_reset: void,
};

// ============================================================================
// Tests
// ============================================================================

test "CEA-708 window init" {
    const testing = std.testing;

    var window = Window.init(0);
    window.clear();

    try testing.expectEqual(@as(u4, 0), window.pen_row);
    try testing.expectEqual(@as(u6, 0), window.pen_column);
}

test "CEA-708 service init" {
    const testing = std.testing;

    var service = Service.init(1);
    try testing.expectEqual(@as(ServiceNumber, 1), service.number);
    try testing.expectEqual(@as(u3, 0), service.current_window);
}

test "CEA-708 decoder init" {
    const testing = std.testing;

    var decoder = Cea708Decoder.init(testing.allocator);
    try testing.expectEqual(@as(ServiceNumber, 1), decoder.current_service);

    decoder.reset();
    try testing.expectEqual(@as(ServiceNumber, 1), decoder.current_service);
}
