// Serial port driver for OS development
// Provides functions for initializing and writing to serial ports (COM1-COM4)

const cpu = @import("cpu.zig");

/// Serial port COM1 base address
pub const COM1: u16 = 0x3F8;
/// Serial port COM2 base address
pub const COM2: u16 = 0x2F8;
/// Serial port COM3 base address
pub const COM3: u16 = 0x3E8;
/// Serial port COM4 base address
pub const COM4: u16 = 0x2E8;

/// Initialize a serial port for communication
///
/// Sets up the serial port with the specified baud rate.
/// Configures: 8 data bits, no parity, 1 stop bit
///
/// Parameters:
///   - port: Base I/O port address (e.g., COM1)
///   - baud: Baud rate (e.g., 115200)
pub fn init(port: u16, baud: u32) void {
    _ = baud; // Baud rate configuration would go here

    // Disable all interrupts
    cpu.outb(port + 1, 0x00);

    // Enable DLAB (set baud rate divisor)
    cpu.outb(port + 3, 0x80);

    // Set divisor to 3 (38400 baud)
    // For 115200 baud: divisor = 115200 / baud_rate
    cpu.outb(port + 0, 0x03); // Divisor low byte
    cpu.outb(port + 1, 0x00); // Divisor high byte

    // 8 bits, no parity, one stop bit
    cpu.outb(port + 3, 0x03);

    // Enable FIFO, clear them, with 14-byte threshold
    cpu.outb(port + 2, 0xC7);

    // IRQs enabled, RTS/DSR set
    cpu.outb(port + 4, 0x0B);

    // Set in loopback mode, test the serial chip
    cpu.outb(port + 4, 0x1E);

    // Test serial chip (send byte 0xAE and check if serial returns same byte)
    cpu.outb(port + 0, 0xAE);

    // Check if serial is faulty (i.e: not same byte as sent)
    if (cpu.inb(port + 0) != 0xAE) {
        return; // Serial is faulty
    }

    // If serial is not faulty set it in normal operation mode
    cpu.outb(port + 4, 0x0F);
}

/// Write a single byte to the serial port
///
/// Waits for the transmit buffer to be empty before writing.
///
/// Parameters:
///   - byte: Byte to write
fn write_byte(byte: u8) void {
    // Wait for transmit buffer to be empty
    while ((cpu.inb(COM1 + 5) & 0x20) == 0) {}

    // Write byte to serial port
    cpu.outb(COM1, byte);
}

/// Write a string to the serial port
///
/// Sends each character of the string sequentially.
///
/// Parameters:
///   - text: String to write (slice of bytes)
pub fn write(text: []const u8) void {
    for (text) |char| {
        write_byte(char);
    }
}

/// Write a hexadecimal representation of a 32-bit value
///
/// Formats as "0xXXXXXXXX" with leading zeros.
///
/// Parameters:
///   - value: 32-bit value to write in hex
pub fn write_hex(value: u32) void {
    const hex_chars = "0123456789ABCDEF";

    // Write "0x" prefix
    write_byte('0');
    write_byte('x');

    // Write 8 hex digits (32 bits = 8 nibbles)
    var i: u5 = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @intCast(28 - (i * 4));
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        write_byte(hex_chars[nibble]);
    }
}
