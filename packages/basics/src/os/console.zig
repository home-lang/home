// Console output for OS development
// Provides VGA text mode console functionality

const cpu = @import("cpu.zig");

/// VGA text mode buffer address
const VGA_BUFFER: usize = 0xB8000;

/// VGA text mode dimensions
pub const VGA_WIDTH: usize = 80;
pub const VGA_HEIGHT: usize = 25;

/// VGA color codes
pub const Color = enum(u8) {
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
    LightMagenta = 13,
    Yellow = 14,
    White = 15,
};

/// VGA character cell (16-bit: 8-bit char + 8-bit attribute)
const VgaCell = packed struct {
    char: u8,
    color: u8,
};

/// Current cursor position
var cursor_x: usize = 0;
var cursor_y: usize = 0;

/// Current text color
var current_color: u8 = make_color(Color.White, Color.Black);

/// Create a VGA color attribute byte
///
/// Combines foreground and background colors into a single byte.
///
/// Parameters:
///   - fg: Foreground color
///   - bg: Background color
///
/// Returns: Color attribute byte
pub fn make_color(fg: Color, bg: Color) u8 {
    return @intFromEnum(fg) | (@intFromEnum(bg) << 4);
}

/// Set the current text color
///
/// Parameters:
///   - fg: Foreground color
///   - bg: Background color
pub fn set_color(fg: Color, bg: Color) void {
    current_color = make_color(fg, bg);
}

/// Get VGA buffer as a pointer
///
/// Returns: Pointer to VGA text buffer
fn get_buffer() [*]volatile VgaCell {
    return @ptrFromInt(VGA_BUFFER);
}

/// Clear the screen
///
/// Fills the entire VGA buffer with spaces.
pub fn clear() void {
    const buffer = get_buffer();
    const blank = VgaCell{
        .char = ' ',
        .color = current_color,
    };

    var i: usize = 0;
    while (i < VGA_WIDTH * VGA_HEIGHT) : (i += 1) {
        buffer[i] = blank;
    }

    cursor_x = 0;
    cursor_y = 0;
}

/// Scroll the screen up by one line
///
/// Moves all lines up and clears the bottom line.
fn scroll() void {
    const buffer = get_buffer();
    const blank = VgaCell{
        .char = ' ',
        .color = current_color,
    };

    // Move all lines up
    var y: usize = 0;
    while (y < VGA_HEIGHT - 1) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            const src_index = (y + 1) * VGA_WIDTH + x;
            const dst_index = y * VGA_WIDTH + x;
            buffer[dst_index] = buffer[src_index];
        }
    }

    // Clear bottom line
    var x: usize = 0;
    while (x < VGA_WIDTH) : (x += 1) {
        const index = (VGA_HEIGHT - 1) * VGA_WIDTH + x;
        buffer[index] = blank;
    }

    cursor_y = VGA_HEIGHT - 1;
}

/// Write a single character to the screen
///
/// Handles newlines and automatic scrolling.
///
/// Parameters:
///   - char: Character to write
pub fn putchar(char: u8) void {
    if (char == '\n') {
        cursor_x = 0;
        cursor_y += 1;
    } else {
        const buffer = get_buffer();
        const index = cursor_y * VGA_WIDTH + cursor_x;

        buffer[index] = VgaCell{
            .char = char,
            .color = current_color,
        };

        cursor_x += 1;

        if (cursor_x >= VGA_WIDTH) {
            cursor_x = 0;
            cursor_y += 1;
        }
    }

    if (cursor_y >= VGA_HEIGHT) {
        scroll();
    }
}

/// Write a string to the screen
///
/// Parameters:
///   - text: String to write
pub fn write(text: []const u8) void {
    for (text) |char| {
        putchar(char);
    }
}

/// Write a hexadecimal number
///
/// Formats as "0xXXXXXXXX".
///
/// Parameters:
///   - value: 32-bit value to write
pub fn write_hex(value: u32) void {
    const hex_chars = "0123456789ABCDEF";

    putchar('0');
    putchar('x');

    var i: u5 = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @intCast(28 - (i * 4));
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        putchar(hex_chars[nibble]);
    }
}

/// Initialize the console
///
/// Clears the screen and resets cursor position.
pub fn init() void {
    current_color = make_color(Color.White, Color.Black);
    clear();
}
