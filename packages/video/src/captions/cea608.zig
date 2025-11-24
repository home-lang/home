// Home Video Library - CEA-608 Closed Captions
// Line 21 VBI captions for analog NTSC (also used in digital)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// CEA-608 Constants
// ============================================================================

pub const CHANNEL_1 = 0;
pub const CHANNEL_2 = 1;

// Control codes
pub const CC_RESUME_CAPTION_LOADING = 0x20;
pub const CC_BACKSPACE = 0x21;
pub const CC_DELETE_TO_END_OF_ROW = 0x24;
pub const CC_ROLL_UP_2 = 0x25;
pub const CC_ROLL_UP_3 = 0x26;
pub const CC_ROLL_UP_4 = 0x27;
pub const CC_FLASH_ON = 0x28;
pub const CC_RESUME_DIRECT_CAPTIONING = 0x29;
pub const CC_TEXT_RESTART = 0x2A;
pub const CC_RESUME_TEXT_DISPLAY = 0x2B;
pub const CC_ERASE_DISPLAYED_MEMORY = 0x2C;
pub const CC_CARRIAGE_RETURN = 0x2D;
pub const CC_ERASE_NON_DISPLAYED = 0x2E;
pub const CC_END_OF_CAPTION = 0x2F;

// ============================================================================
// CEA-608 Types
// ============================================================================

pub const CaptionMode = enum {
    pop_on, // Pop-up captions (buffered)
    paint_on, // Paint-on captions (direct)
    roll_up_2, // Roll-up 2 rows
    roll_up_3, // Roll-up 3 rows
    roll_up_4, // Roll-up 4 rows
    text, // Text mode (non-caption)
};

pub const CaptionStyle = struct {
    italic: bool = false,
    underline: bool = false,
    flash: bool = false,
    color: Color = .white,
    background: Color = .transparent,
};

pub const Color = enum(u8) {
    white = 0,
    green = 1,
    blue = 2,
    cyan = 3,
    red = 4,
    yellow = 5,
    magenta = 6,
    black = 7,
    transparent = 8,
};

pub const Position = struct {
    row: u8, // 1-15 (row 15 is bottom)
    column: u8, // 0-31
};

// ============================================================================
// CEA-608 Character Set
// ============================================================================

const BASIC_CHARS: [96]u8 = .{
    ' ', '!', '"', '#', '$', '%', '&', '\'', '(', ')', 'á', '+', ',', '-', '.', '/',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
    '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '[', 'é', ']', 'í', 'ó',
    'ú', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'ç', '÷', 'Ñ', 'ñ', '█',
};

const SPECIAL_CHARS: [32][]const u8 = .{
    "®", "°", "½", "¿", "™", "¢", "£", "♪", "à", " ", "è", "â", "ê", "î", "ô", "û",
    "Á", "É", "Ó", "Ú", "Ü", "ü", "'", "¡", "*", "'", "—", "©", "℠", "·", """, """,
};

// ============================================================================
// CEA-608 Screen Buffer
// ============================================================================

pub const ScreenCell = struct {
    char: u8 = ' ',
    style: CaptionStyle = .{},
};

pub const ScreenBuffer = struct {
    rows: [15][32]ScreenCell,

    pub fn init() ScreenBuffer {
        var buf = ScreenBuffer{
            .rows = undefined,
        };
        for (&buf.rows) |*row| {
            for (row) |*cell| {
                cell.* = .{};
            }
        }
        return buf;
    }

    pub fn clear(self: *ScreenBuffer) void {
        for (&self.rows) |*row| {
            for (row) |*cell| {
                cell.* = .{};
            }
        }
    }

    pub fn writeChar(self: *ScreenBuffer, row: u8, col: u8, char: u8, style: CaptionStyle) void {
        if (row >= 15 or col >= 32) return;
        self.rows[row][col] = .{ .char = char, .style = style };
    }

    pub fn getText(self: *const ScreenBuffer, allocator: Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);

        for (self.rows, 0..) |row, r| {
            var has_content = false;
            for (row) |cell| {
                if (cell.char != ' ') {
                    has_content = true;
                    break;
                }
            }

            if (has_content) {
                // Trim trailing spaces
                var end: usize = 32;
                while (end > 0 and row[end - 1].char == ' ') {
                    end -= 1;
                }

                for (row[0..end]) |cell| {
                    try output.append(cell.char);
                }

                if (r < 14) {
                    try output.append('\n');
                }
            }
        }

        return output.toOwnedSlice();
    }
};

// ============================================================================
// CEA-608 Decoder
// ============================================================================

pub const Cea608Decoder = struct {
    // Screen buffers
    displayed: ScreenBuffer,
    non_displayed: ScreenBuffer,

    // Current state
    mode: CaptionMode,
    channel: u8,
    current_row: u8,
    current_col: u8,
    current_style: CaptionStyle,
    roll_base: u8, // Base row for roll-up mode

    // Previous command (for repeat detection)
    last_cmd: u16,

    allocator: Allocator,

    pub fn init(allocator: Allocator) Cea608Decoder {
        return .{
            .displayed = ScreenBuffer.init(),
            .non_displayed = ScreenBuffer.init(),
            .mode = .pop_on,
            .channel = 0,
            .current_row = 14, // Bottom row
            .current_col = 0,
            .current_style = .{},
            .roll_base = 14,
            .last_cmd = 0,
            .allocator = allocator,
        };
    }

    /// Decode a CEA-608 byte pair
    pub fn decode(self: *Cea608Decoder, byte1: u8, byte2: u8) !?CaptionEvent {
        // Remove parity bits
        const b1 = byte1 & 0x7F;
        const b2 = byte2 & 0x7F;

        // Null padding
        if (b1 == 0x80 or b1 == 0x00) return null;

        // Check for control code
        if (b1 >= 0x10 and b1 <= 0x1F) {
            // Prevent duplicate commands
            const cmd = (@as(u16, b1) << 8) | b2;
            if (cmd == self.last_cmd) {
                self.last_cmd = 0;
                return null;
            }
            self.last_cmd = cmd;

            return try self.handleControlCode(b1, b2);
        }

        self.last_cmd = 0;

        // Special characters
        if (b1 >= 0x11 and b1 <= 0x13) {
            return try self.handleSpecialChar(b1, b2);
        }

        // Basic characters
        if (b1 >= 0x20) {
            try self.writeCharacter(b1);
            if (b2 >= 0x20) {
                try self.writeCharacter(b2);
            }
            return null;
        }

        return null;
    }

    fn handleControlCode(self: *Cea608Decoder, b1: u8, b2: u8) !?CaptionEvent {
        // Determine channel
        const channel = if (b1 & 0x08 != 0) @as(u8, 1) else @as(u8, 0);
        if (channel != self.channel) return null;

        const cmd = b2 & 0x0F;
        const cmd_high = (b2 >> 4) & 0x07;

        // Preamble Address Codes (PAC) - set position and style
        if (b1 >= 0x10 and b1 <= 0x17 and cmd_high <= 0x02) {
            return try self.handlePAC(b1, b2);
        }

        // Mid-row codes - change style
        if (b1 == 0x11 or b1 == 0x19) {
            return try self.handleMidRowCode(b2);
        }

        // Caption control codes
        switch (b2) {
            CC_RESUME_CAPTION_LOADING => {
                self.mode = .pop_on;
            },
            CC_BACKSPACE => {
                if (self.current_col > 0) {
                    self.current_col -= 1;
                    self.writeToBuffer(self.current_row, self.current_col, ' ', self.current_style);
                }
            },
            CC_DELETE_TO_END_OF_ROW => {
                for (self.current_col..32) |col| {
                    self.writeToBuffer(self.current_row, @intCast(col), ' ', self.current_style);
                }
            },
            CC_ROLL_UP_2 => {
                self.mode = .roll_up_2;
                self.roll_base = 14;
            },
            CC_ROLL_UP_3 => {
                self.mode = .roll_up_3;
                self.roll_base = 14;
            },
            CC_ROLL_UP_4 => {
                self.mode = .roll_up_4;
                self.roll_base = 14;
            },
            CC_RESUME_DIRECT_CAPTIONING => {
                self.mode = .paint_on;
            },
            CC_TEXT_RESTART, CC_RESUME_TEXT_DISPLAY => {
                self.mode = .text;
            },
            CC_ERASE_DISPLAYED_MEMORY => {
                self.displayed.clear();
                return CaptionEvent{ .screen_cleared = {} };
            },
            CC_CARRIAGE_RETURN => {
                if (self.mode == .roll_up_2 or self.mode == .roll_up_3 or self.mode == .roll_up_4) {
                    try self.rollUp();
                    self.current_col = 0;
                }
            },
            CC_ERASE_NON_DISPLAYED => {
                self.non_displayed.clear();
            },
            CC_END_OF_CAPTION => {
                // Swap buffers
                const temp = self.displayed;
                self.displayed = self.non_displayed;
                self.non_displayed = temp;
                self.non_displayed.clear();
                return CaptionEvent{ .caption_ready = try self.displayed.getText(self.allocator) };
            },
            else => {},
        }

        return null;
    }

    fn handlePAC(self: *Cea608Decoder, b1: u8, b2: u8) !?CaptionEvent {
        // Calculate row
        const row_map = [_]u8{ 10, 0, 1, 2, 10, 11, 12, 13, 14, 3, 4, 5, 6, 7, 8, 9 };
        const row_idx = ((b1 & 0x07) << 1) | ((b2 >> 5) & 0x01);
        self.current_row = row_map[row_idx];

        // Calculate indent (column)
        const indent = (b2 >> 1) & 0x0F;
        self.current_col = indent * 4;

        // Set style
        if (b2 & 0x01 != 0) {
            self.current_style.underline = true;
        } else {
            self.current_style.underline = false;
        }

        // Color from bits
        const color_bits = (b2 >> 1) & 0x07;
        self.current_style.color = switch (color_bits) {
            0 => .white,
            1 => .green,
            2 => .blue,
            3 => .cyan,
            4 => .red,
            5 => .yellow,
            6 => .magenta,
            7 => .white, // Italic white
            else => .white,
        };

        if (color_bits == 7) {
            self.current_style.italic = true;
        }

        return null;
    }

    fn handleMidRowCode(self: *Cea608Decoder, b2: u8) !?CaptionEvent {
        // Mid-row codes change style without moving cursor
        const code = b2 & 0x0E;
        switch (code) {
            0x00 => {}, // White
            0x02 => {}, // Green
            0x04 => {}, // Blue
            0x06 => {}, // Cyan
            0x08 => {}, // Red
            0x0A => {}, // Yellow
            0x0C => {}, // Magenta
            0x0E => self.current_style.italic = true,
            else => {},
        }

        if (b2 & 0x01 != 0) {
            self.current_style.underline = true;
        }

        return null;
    }

    fn handleSpecialChar(self: *Cea608Decoder, b1: u8, b2: u8) !?CaptionEvent {
        _ = b1;
        const char_idx = b2 & 0x0F;
        if (char_idx < SPECIAL_CHARS.len) {
            const special = SPECIAL_CHARS[char_idx];
            // For simplicity, use first byte of UTF-8
            if (special.len > 0) {
                try self.writeCharacter(special[0]);
            }
        }
        return null;
    }

    fn writeCharacter(self: *Cea608Decoder, char: u8) !void {
        if (self.current_col >= 32) return;

        self.writeToBuffer(self.current_row, self.current_col, char, self.current_style);
        self.current_col += 1;

        // Auto-wrap
        if (self.current_col >= 32) {
            if (self.mode == .roll_up_2 or self.mode == .roll_up_3 or self.mode == .roll_up_4) {
                try self.rollUp();
                self.current_col = 0;
            }
        }
    }

    fn writeToBuffer(self: *Cea608Decoder, row: u8, col: u8, char: u8, style: CaptionStyle) void {
        const buffer = if (self.mode == .pop_on) &self.non_displayed else &self.displayed;
        buffer.writeChar(row, col, char, style);
    }

    fn rollUp(self: *Cea608Decoder) !void {
        const rows = switch (self.mode) {
            .roll_up_2 => @as(u8, 2),
            .roll_up_3 => @as(u8, 3),
            .roll_up_4 => @as(u8, 4),
            else => return,
        };

        const start_row = self.roll_base - rows + 1;

        // Shift rows up
        var r: u8 = start_row;
        while (r < self.roll_base) : (r += 1) {
            @memcpy(&self.displayed.rows[r], &self.displayed.rows[r + 1]);
        }

        // Clear bottom row
        for (&self.displayed.rows[self.roll_base]) |*cell| {
            cell.* = .{};
        }
    }

    pub fn getDisplayedText(self: *const Cea608Decoder) ![]const u8 {
        return self.displayed.getText(self.allocator);
    }

    pub fn reset(self: *Cea608Decoder) void {
        self.displayed.clear();
        self.non_displayed.clear();
        self.mode = .pop_on;
        self.current_row = 14;
        self.current_col = 0;
        self.current_style = .{};
        self.last_cmd = 0;
    }
};

// ============================================================================
// Caption Event
// ============================================================================

pub const CaptionEvent = union(enum) {
    caption_ready: []const u8,
    screen_cleared: void,
    mode_changed: CaptionMode,
};

// ============================================================================
// Line 21 VBI Extractor
// ============================================================================

pub const Line21Extractor = struct {
    /// Extract CEA-608 data from Line 21 VBI samples
    /// Expects 8-bit grayscale samples from line 21
    pub fn extractFromLine21(samples: []const u8) ?struct { byte1: u8, byte2: u8 } {
        if (samples.len < 100) return null;

        // CEA-608 is encoded in the middle of line 21
        // Clock run-in starts around sample 10
        // Start bit at sample 12
        // 7 data bits + parity for each of 2 bytes

        var byte1: u8 = 0;
        var byte2: u8 = 0;

        // Simplified extraction (real implementation needs clock recovery)
        const start_offset = 12;
        const bit_width = 4;

        // Extract first byte
        for (0..7) |i| {
            const sample_pos = start_offset + @as(usize, @intCast(i)) * bit_width;
            if (sample_pos >= samples.len) return null;

            const level = samples[sample_pos];
            if (level > 128) {
                byte1 |= @as(u8, 1) << @intCast(i);
            }
        }

        // Extract second byte
        const byte2_start = start_offset + 8 * bit_width;
        for (0..7) |i| {
            const sample_pos = byte2_start + i * bit_width;
            if (sample_pos >= samples.len) return null;

            const level = samples[sample_pos];
            if (level > 128) {
                byte2 |= @as(u8, 1) << @intCast(i);
            }
        }

        // Add parity bit (odd parity)
        byte1 |= calculateParity(byte1) << 7;
        byte2 |= calculateParity(byte2) << 7;

        return .{ .byte1 = byte1, .byte2 = byte2 };
    }
};

fn calculateParity(byte: u8) u8 {
    var count: u8 = 0;
    var b = byte;
    while (b != 0) {
        count +%= b & 1;
        b >>= 1;
    }
    return count & 1;
}

// ============================================================================
// CEA-608 in MPEG User Data
// ============================================================================

pub const Cea608UserData = struct {
    /// Extract CEA-608 from ATSC A/53 user data
    pub fn extractFromUserData(data: []const u8) ?struct { byte1: u8, byte2: u8 } {
        if (data.len < 9) return null;

        // Check for ATSC identifier "GA94"
        if (data[0] != 0x47 or data[1] != 0x41 or data[2] != 0x39 or data[3] != 0x34) {
            return null;
        }

        // User data type code (0x03 for CC)
        if (data[4] != 0x03) return null;

        // Check cc_count
        const cc_count = data[5] & 0x1F;
        if (cc_count == 0 or data.len < 7 + cc_count * 3) return null;

        // First CC data pair
        const cc_valid = (data[7] & 0x04) != 0;
        const cc_type = data[7] & 0x03;

        // Type 0 or 1 = CEA-608
        if (cc_valid and (cc_type == 0 or cc_type == 1)) {
            return .{
                .byte1 = data[8],
                .byte2 = data[9],
            };
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CEA-608 basic character" {
    const testing = std.testing;

    var decoder = Cea608Decoder.init(testing.allocator);

    // Write "ABC"
    _ = try decoder.decode(0x41, 0x42); // AB
    _ = try decoder.decode(0x43, 0x00); // C

    const text = try decoder.getDisplayedText();
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ABC") != null);
}

test "CEA-608 pop-on caption" {
    const testing = std.testing;

    var decoder = Cea608Decoder.init(testing.allocator);

    // Resume caption loading (pop-on mode)
    _ = try decoder.decode(0x14, 0x20);

    // Write text to non-displayed buffer
    _ = try decoder.decode(0x54, 0x45); // TE
    _ = try decoder.decode(0x53, 0x54); // ST

    // End of caption (flip buffers)
    const event = try decoder.decode(0x14, 0x2F);

    try testing.expect(event != null);
    try testing.expect(event.? == .caption_ready);

    testing.allocator.free(event.?.caption_ready);
}

test "CEA-608 parity calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 1), calculateParity(0b0000001));
    try testing.expectEqual(@as(u8, 0), calculateParity(0b0000011));
    try testing.expectEqual(@as(u8, 1), calculateParity(0b0000111));
}
