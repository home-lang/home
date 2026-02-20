// Home Programming Language - VGA Text Mode Driver
// 80x25 color text mode display

const Basics = @import("basics");
const assembly = @import("asm.zig");

// ============================================================================
// VGA Constants
// ============================================================================

pub const VGA_WIDTH: usize = 80;
pub const VGA_HEIGHT: usize = 25;
pub const VGA_BUFFER: usize = 0xB8000;

// ============================================================================
// VGA Colors
// ============================================================================

pub const Color = enum(u4) {
    Black = 0,
    Blue = 1,
    Green = 2,
    Cyan = 3,
    Red = 4,
    Magenta = 5,
    Brown = 6,
    LightGray = 7,
    DarkGray = 8,
    LightBlue = 9,
    LightGreen = 10,
    LightCyan = 11,
    LightRed = 12,
    Pink = 13,
    Yellow = 14,
    White = 15,
};

pub const ColorCode = packed struct(u8) {
    foreground: Color,
    background: Color,

    pub fn new(fg: Color, bg: Color) ColorCode {
        return .{ .foreground = fg, .background = bg };
    }

    pub fn toByte(self: ColorCode) u8 {
        return @bitCast(self);
    }
};

// ============================================================================
// VGA Character
// ============================================================================

pub const VgaChar = packed struct(u16) {
    char: u8,
    color: ColorCode,

    pub fn new(char: u8, color: ColorCode) VgaChar {
        return .{ .char = char, .color = color };
    }

    pub fn toU16(self: VgaChar) u16 {
        return @bitCast(self);
    }
};

// ============================================================================
// VGA Buffer
// ============================================================================

pub const VgaBuffer = struct {
    buffer: [*]volatile VgaChar,
    width: usize,
    height: usize,
    cursor_x: usize,
    cursor_y: usize,
    color: ColorCode,

    pub fn init() VgaBuffer {
        return .{
            .buffer = @ptrFromInt(VGA_BUFFER),
            .width = VGA_WIDTH,
            .height = VGA_HEIGHT,
            .cursor_x = 0,
            .cursor_y = 0,
            .color = ColorCode.new(.White, .Black),
        };
    }

    /// Set text color
    pub fn setColor(self: *VgaBuffer, color: ColorCode) void {
        self.color = color;
    }

    /// Clear the screen
    pub fn clear(self: *VgaBuffer) void {
        const blank = VgaChar.new(' ', self.color);
        for (0..self.width * self.height) |i| {
            self.buffer[i] = blank;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.updateCursor();
    }

    /// Write a character at specific position
    pub fn putCharAt(self: *VgaBuffer, char: u8, x: usize, y: usize, color: ColorCode) void {
        if (x >= self.width or y >= self.height) return;
        const index = y * self.width + x;
        self.buffer[index] = VgaChar.new(char, color);
    }

    /// Write a character at cursor
    pub fn putChar(self: *VgaBuffer, char: u8) void {
        switch (char) {
            '\n' => self.newline(),
            '\r' => self.cursor_x = 0,
            '\t' => {
                const spaces = 4 - (self.cursor_x % 4);
                for (0..spaces) |_| {
                    self.putChar(' ');
                }
            },
            '\x08' => { // Backspace
                if (self.cursor_x > 0) {
                    self.cursor_x -= 1;
                    self.putCharAt(' ', self.cursor_x, self.cursor_y, self.color);
                }
            },
            else => {
                self.putCharAt(char, self.cursor_x, self.cursor_y, self.color);
                self.cursor_x += 1;

                if (self.cursor_x >= self.width) {
                    self.newline();
                }
            },
        }
        self.updateCursor();
    }

    /// Move to new line
    fn newline(self: *VgaBuffer) void {
        self.cursor_x = 0;
        self.cursor_y += 1;

        if (self.cursor_y >= self.height) {
            self.scroll();
            self.cursor_y = self.height - 1;
        }
    }

    /// Scroll screen up by one line
    fn scroll(self: *VgaBuffer) void {
        // Move all lines up
        for (0..self.height - 1) |y| {
            for (0..self.width) |x| {
                const src_index = (y + 1) * self.width + x;
                const dst_index = y * self.width + x;
                self.buffer[dst_index] = self.buffer[src_index];
            }
        }

        // Clear last line
        const blank = VgaChar.new(' ', self.color);
        const last_line_start = (self.height - 1) * self.width;
        for (0..self.width) |x| {
            self.buffer[last_line_start + x] = blank;
        }
    }

    /// Write a string
    pub fn writeString(self: *VgaBuffer, str: []const u8) void {
        for (str) |char| {
            self.putChar(char);
        }
    }

    /// Print formatted text
    pub fn print(self: *VgaBuffer, comptime fmt: []const u8, args: anytype) void {
        const writer = self.writer();
        Basics.fmt.format(writer, fmt, args) catch {};
    }

    /// Print with newline
    pub fn println(self: *VgaBuffer, comptime fmt: []const u8, args: anytype) void {
        self.print(fmt ++ "\n", args);
    }

    /// Get writer interface
    pub fn writer(self: *VgaBuffer) Writer {
        return .{ .context = self };
    }

    pub const Writer = struct {
        context: *VgaBuffer,

        pub const Error = error{};

        pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
            self.context.writeString(bytes);
        }

        pub fn writeByte(self: Writer, byte: u8) Error!void {
            self.context.putChar(byte);
        }
    };

    /// Update hardware cursor position
    fn updateCursor(self: *VgaBuffer) void {
        const pos = self.cursor_y * self.width + self.cursor_x;

        // Cursor low byte
        assembly.outb(0x3D4, 0x0F);
        assembly.outb(0x3D5, @truncate(pos));

        // Cursor high byte
        assembly.outb(0x3D4, 0x0E);
        assembly.outb(0x3D5, @truncate(pos >> 8));
    }

    /// Show cursor
    pub fn showCursor(self: *VgaBuffer) void {
        _ = self;
        assembly.outb(0x3D4, 0x0A);
        assembly.outb(0x3D5, 0x00);
    }

    /// Hide cursor
    pub fn hideCursor(self: *VgaBuffer) void {
        _ = self;
        assembly.outb(0x3D4, 0x0A);
        assembly.outb(0x3D5, 0x20);
    }

    /// Set cursor position
    pub fn setCursor(self: *VgaBuffer, x: usize, y: usize) void {
        if (x >= self.width or y >= self.height) return;
        self.cursor_x = x;
        self.cursor_y = y;
        self.updateCursor();
    }

    /// Draw a box
    pub fn drawBox(self: *VgaBuffer, x: usize, y: usize, w: usize, h: usize, color: ColorCode) void {
        const chars = BoxChars.single();

        // Top border
        self.putCharAt(chars.top_left, x, y, color);
        for (1..w - 1) |i| {
            self.putCharAt(chars.horizontal, x + i, y, color);
        }
        self.putCharAt(chars.top_right, x + w - 1, y, color);

        // Sides
        for (1..h - 1) |i| {
            self.putCharAt(chars.vertical, x, y + i, color);
            self.putCharAt(chars.vertical, x + w - 1, y + i, color);
        }

        // Bottom border
        self.putCharAt(chars.bottom_left, x, y + h - 1, color);
        for (1..w - 1) |i| {
            self.putCharAt(chars.horizontal, x + i, y + h - 1, color);
        }
        self.putCharAt(chars.bottom_right, x + w - 1, y + h - 1, color);
    }

    /// Fill rectangle
    pub fn fillRect(self: *VgaBuffer, x: usize, y: usize, w: usize, h: usize, char: u8, color: ColorCode) void {
        for (0..h) |dy| {
            for (0..w) |dx| {
                self.putCharAt(char, x + dx, y + dy, color);
            }
        }
    }
};

// ============================================================================
// Box Drawing Characters
// ============================================================================

pub const BoxChars = struct {
    top_left: u8,
    top_right: u8,
    bottom_left: u8,
    bottom_right: u8,
    horizontal: u8,
    vertical: u8,

    pub fn single() BoxChars {
        return .{
            .top_left = 0xDA,      // ┌
            .top_right = 0xBF,     // ┐
            .bottom_left = 0xC0,   // └
            .bottom_right = 0xD9,  // ┘
            .horizontal = 0xC4,    // ─
            .vertical = 0xB3,      // │
        };
    }

    pub fn double() BoxChars {
        return .{
            .top_left = 0xC9,      // ╔
            .top_right = 0xBB,     // ╗
            .bottom_left = 0xC8,   // ╚
            .bottom_right = 0xBC,  // ╝
            .horizontal = 0xCD,    // ═
            .vertical = 0xBA,      // ║
        };
    }
};

// ============================================================================
// Global VGA Console
// ============================================================================

var global_vga: ?VgaBuffer = null;

/// Initialize global VGA console
pub fn initConsole() void {
    global_vga = VgaBuffer.init();
    global_vga.?.clear();
}

/// Get global VGA console
pub fn console() *VgaBuffer {
    if (global_vga) |*vga| {
        return vga;
    }
    @panic("VGA console not initialized");
}

/// Print to VGA console
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (global_vga) |*vga| {
        vga.print(fmt, args);
    }
}

/// Print line to VGA console
pub fn println(comptime fmt: []const u8, args: anytype) void {
    if (global_vga) |*vga| {
        vga.println(fmt, args);
    }
}

// Tests
test "color code" {
    const color = ColorCode.new(.White, .Black);
    try Basics.testing.expectEqual(@as(u4, @intFromEnum(Color.White)), @intFromEnum(color.foreground));
    try Basics.testing.expectEqual(@as(u4, @intFromEnum(Color.Black)), @intFromEnum(color.background));
}

test "vga char" {
    const color = ColorCode.new(.White, .Black);
    const char = VgaChar.new('A', color);
    try Basics.testing.expectEqual(@as(u8, 'A'), char.char);
}

test "vga buffer init" {
    var vga = VgaBuffer.init();
    try Basics.testing.expectEqual(@as(usize, 0), vga.cursor_x);
    try Basics.testing.expectEqual(@as(usize, 0), vga.cursor_y);
    try Basics.testing.expectEqual(VGA_WIDTH, vga.width);
    try Basics.testing.expectEqual(VGA_HEIGHT, vga.height);
}
