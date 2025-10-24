// Home Programming Language - Serial Port Driver
// COM port driver for kernel debugging and early console

const Basics = @import("basics");
const asm = @import("asm.zig");

// ============================================================================
// Serial Port Constants
// ============================================================================

pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;
pub const COM3: u16 = 0x3E8;
pub const COM4: u16 = 0x2E8;

// Register offsets
const DATA = 0;           // Data register (DLAB=0)
const INT_ENABLE = 1;     // Interrupt enable (DLAB=0)
const DIVISOR_LOW = 0;    // Divisor latch low (DLAB=1)
const DIVISOR_HIGH = 1;   // Divisor latch high (DLAB=1)
const INT_ID_FIFO = 2;    // Interrupt ID / FIFO control
const LINE_CONTROL = 3;   // Line control
const MODEM_CONTROL = 4;  // Modem control
const LINE_STATUS = 5;    // Line status
const MODEM_STATUS = 6;   // Modem status
const SCRATCH = 7;        // Scratch register

// Line control bits
const DLAB = 0x80;        // Divisor latch access bit

// Line status bits
const DATA_READY = 0x01;
const OVERRUN_ERROR = 0x02;
const PARITY_ERROR = 0x04;
const FRAMING_ERROR = 0x08;
const BREAK_INDICATOR = 0x10;
const TRANSMIT_EMPTY = 0x20;
const TRANSMITTER_EMPTY = 0x40;
const IMPENDING_ERROR = 0x80;

// ============================================================================
// Serial Port Configuration
// ============================================================================

pub const Parity = enum(u8) {
    None = 0x00,
    Odd = 0x08,
    Even = 0x18,
    Mark = 0x28,
    Space = 0x38,
};

pub const StopBits = enum(u8) {
    One = 0x00,
    Two = 0x04,
};

pub const DataBits = enum(u8) {
    Five = 0x00,
    Six = 0x01,
    Seven = 0x02,
    Eight = 0x03,
};

pub const BaudRate = enum(u16) {
    Baud115200 = 1,
    Baud57600 = 2,
    Baud38400 = 3,
    Baud19200 = 6,
    Baud9600 = 12,
    Baud4800 = 24,
    Baud2400 = 48,
};

// ============================================================================
// Serial Port Driver
// ============================================================================

pub const SerialPort = struct {
    port: u16,
    initialized: bool,

    pub fn init(port: u16) SerialPort {
        return .{
            .port = port,
            .initialized = false,
        };
    }

    /// Initialize serial port with default settings
    pub fn setup(self: *SerialPort) !void {
        try self.configure(.{
            .baud_rate = .Baud115200,
            .data_bits = .Eight,
            .stop_bits = .One,
            .parity = .None,
        });
    }

    /// Configure serial port
    pub fn configure(self: *SerialPort, config: struct {
        baud_rate: BaudRate,
        data_bits: DataBits,
        stop_bits: StopBits,
        parity: Parity,
    }) !void {
        // Disable interrupts
        asm.outb(self.port + INT_ENABLE, 0x00);

        // Enable DLAB (set baud rate divisor)
        asm.outb(self.port + LINE_CONTROL, DLAB);

        // Set baud rate
        const divisor = @intFromEnum(config.baud_rate);
        asm.outb(self.port + DIVISOR_LOW, @truncate(divisor));
        asm.outb(self.port + DIVISOR_HIGH, @truncate(divisor >> 8));

        // Configure line: data bits, stop bits, parity
        const line_config = @intFromEnum(config.data_bits) |
            @intFromEnum(config.stop_bits) |
            @intFromEnum(config.parity);
        asm.outb(self.port + LINE_CONTROL, line_config);

        // Enable FIFO, clear TX/RX queues, 14-byte threshold
        asm.outb(self.port + INT_ID_FIFO, 0xC7);

        // Enable IRQs, RTS/DSR set
        asm.outb(self.port + MODEM_CONTROL, 0x0B);

        // Test serial chip (loopback test)
        asm.outb(self.port + MODEM_CONTROL, 0x1E);
        asm.outb(self.port + DATA, 0xAE);

        if (asm.inb(self.port + DATA) != 0xAE) {
            return error.SerialPortFailed;
        }

        // Set normal operation mode
        asm.outb(self.port + MODEM_CONTROL, 0x0F);

        self.initialized = true;
    }

    /// Check if transmit buffer is empty
    fn isTransmitEmpty(self: SerialPort) bool {
        return (asm.inb(self.port + LINE_STATUS) & TRANSMIT_EMPTY) != 0;
    }

    /// Check if data is available
    fn isDataAvailable(self: SerialPort) bool {
        return (asm.inb(self.port + LINE_STATUS) & DATA_READY) != 0;
    }

    /// Write a single byte
    pub fn writeByte(self: SerialPort, byte: u8) void {
        // Wait for transmit buffer to be empty
        while (!self.isTransmitEmpty()) {
            asm.pause();
        }
        asm.outb(self.port + DATA, byte);
    }

    /// Read a single byte
    pub fn readByte(self: SerialPort) u8 {
        // Wait for data to be available
        while (!self.isDataAvailable()) {
            asm.pause();
        }
        return asm.inb(self.port + DATA);
    }

    /// Write a string
    pub fn writeString(self: SerialPort, str: []const u8) void {
        for (str) |byte| {
            if (byte == '\n') {
                self.writeByte('\r');
            }
            self.writeByte(byte);
        }
    }

    /// Write formatted text
    pub fn print(self: SerialPort, comptime fmt: []const u8, args: anytype) void {
        const writer = self.writer();
        Basics.fmt.format(writer, fmt, args) catch {};
    }

    /// Print with newline
    pub fn println(self: SerialPort, comptime fmt: []const u8, args: anytype) void {
        self.print(fmt ++ "\n", args);
    }

    /// Get writer interface
    pub fn writer(self: SerialPort) Writer {
        return .{ .context = self };
    }

    pub const Writer = struct {
        context: SerialPort,

        pub const Error = error{};

        pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
            self.context.writeString(bytes);
        }

        pub fn writeByte_(self: Writer, byte: u8) Error!void {
            self.context.writeByte(byte);
        }
    };

    /// Try to read without blocking
    pub fn tryReadByte(self: SerialPort) ?u8 {
        if (self.isDataAvailable()) {
            return asm.inb(self.port + DATA);
        }
        return null;
    }

    /// Get line status
    pub fn getLineStatus(self: SerialPort) LineStatus {
        const status = asm.inb(self.port + LINE_STATUS);
        return .{
            .data_ready = (status & DATA_READY) != 0,
            .overrun_error = (status & OVERRUN_ERROR) != 0,
            .parity_error = (status & PARITY_ERROR) != 0,
            .framing_error = (status & FRAMING_ERROR) != 0,
            .break_indicator = (status & BREAK_INDICATOR) != 0,
            .transmit_empty = (status & TRANSMIT_EMPTY) != 0,
            .transmitter_empty = (status & TRANSMITTER_EMPTY) != 0,
        };
    }

    /// Flush transmit buffer
    pub fn flush(self: SerialPort) void {
        while (!self.isTransmitEmpty()) {
            asm.pause();
        }
    }
};

pub const LineStatus = struct {
    data_ready: bool,
    overrun_error: bool,
    parity_error: bool,
    framing_error: bool,
    break_indicator: bool,
    transmit_empty: bool,
    transmitter_empty: bool,
};

// ============================================================================
// Global Serial Console
// ============================================================================

var global_console: ?SerialPort = null;

/// Initialize global serial console
pub fn initConsole() !void {
    var serial = SerialPort.init(COM1);
    try serial.setup();
    global_console = serial;
}

/// Get global console (must be initialized first)
pub fn console() SerialPort {
    return global_console orelse @panic("Serial console not initialized");
}

/// Print to serial console
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (global_console) |serial| {
        serial.print(fmt, args);
    }
}

/// Print line to serial console
pub fn println(comptime fmt: []const u8, args: anytype) void {
    if (global_console) |serial| {
        serial.println(fmt, args);
    }
}

// ============================================================================
// Panic Handler Integration
// ============================================================================

/// Panic handler that writes to serial port
pub fn panicHandler(msg: []const u8, stack_trace: ?*Basics.builtin.StackTrace) noreturn {
    _ = stack_trace;

    if (global_console) |serial| {
        serial.println("\n!!! KERNEL PANIC !!!", .{});
        serial.println("{s}", .{msg});
        serial.println("System halted.", .{});
    }

    // Halt
    while (true) {
        asm.cli();
        asm.hlt();
    }
}

// Tests
test "serial port init" {
    var serial = SerialPort.init(COM1);
    try Basics.testing.expectEqual(@as(u16, COM1), serial.port);
    try Basics.testing.expect(!serial.initialized);
}

test "baud rate values" {
    try Basics.testing.expectEqual(@as(u16, 1), @intFromEnum(BaudRate.Baud115200));
    try Basics.testing.expectEqual(@as(u16, 12), @intFromEnum(BaudRate.Baud9600));
}
