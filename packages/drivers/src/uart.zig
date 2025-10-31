// UART Driver Implementation
// Universal Asynchronous Receiver/Transmitter for serial communication

const std = @import("std");

/// UART register offsets (16550 compatible)
pub const Registers = struct {
    pub const RBR: u16 = 0x0; // Receiver Buffer Register (read)
    pub const THR: u16 = 0x0; // Transmitter Holding Register (write)
    pub const IER: u16 = 0x1; // Interrupt Enable Register
    pub const IIR: u16 = 0x2; // Interrupt Identification Register (read)
    pub const FCR: u16 = 0x2; // FIFO Control Register (write)
    pub const LCR: u16 = 0x3; // Line Control Register
    pub const MCR: u16 = 0x4; // Modem Control Register
    pub const LSR: u16 = 0x5; // Line Status Register
    pub const MSR: u16 = 0x6; // Modem Status Register
    pub const SCR: u16 = 0x7; // Scratch Register
    pub const DLL: u16 = 0x0; // Divisor Latch Low (when DLAB=1)
    pub const DLH: u16 = 0x1; // Divisor Latch High (when DLAB=1)
};

/// Line Status Register bits
pub const LSR = struct {
    pub const DATA_READY: u8 = 1 << 0;
    pub const OVERRUN_ERROR: u8 = 1 << 1;
    pub const PARITY_ERROR: u8 = 1 << 2;
    pub const FRAMING_ERROR: u8 = 1 << 3;
    pub const BREAK_INTERRUPT: u8 = 1 << 4;
    pub const THR_EMPTY: u8 = 1 << 5;
    pub const TRANSMITTER_EMPTY: u8 = 1 << 6;
    pub const FIFO_ERROR: u8 = 1 << 7;
};

/// Line Control Register bits
pub const LCR = struct {
    pub const WORD_LENGTH_5: u8 = 0b00;
    pub const WORD_LENGTH_6: u8 = 0b01;
    pub const WORD_LENGTH_7: u8 = 0b10;
    pub const WORD_LENGTH_8: u8 = 0b11;
    pub const STOP_BITS_1: u8 = 0 << 2;
    pub const STOP_BITS_2: u8 = 1 << 2;
    pub const PARITY_NONE: u8 = 0 << 3;
    pub const PARITY_ODD: u8 = 1 << 3;
    pub const PARITY_EVEN: u8 = 3 << 3;
    pub const PARITY_MARK: u8 = 5 << 3;
    pub const PARITY_SPACE: u8 = 7 << 3;
    pub const DLAB: u8 = 1 << 7;
};

/// FIFO Control Register bits
pub const FCR = struct {
    pub const ENABLE_FIFO: u8 = 1 << 0;
    pub const CLEAR_RX_FIFO: u8 = 1 << 1;
    pub const CLEAR_TX_FIFO: u8 = 1 << 2;
    pub const DMA_MODE: u8 = 1 << 3;
    pub const TRIGGER_1: u8 = 0b00 << 6;
    pub const TRIGGER_4: u8 = 0b01 << 6;
    pub const TRIGGER_8: u8 = 0b10 << 6;
    pub const TRIGGER_14: u8 = 0b11 << 6;
};

/// UART configuration
pub const Config = struct {
    baud_rate: u32,
    data_bits: u8,
    stop_bits: u8,
    parity: Parity,
    clock_freq: u32,

    pub const Parity = enum {
        none,
        odd,
        even,
        mark,
        space,
    };

    pub fn default() Config {
        return .{
            .baud_rate = 115200,
            .data_bits = 8,
            .stop_bits = 1,
            .parity = .none,
            .clock_freq = 1843200, // Standard PC UART clock
        };
    }
};

/// UART driver
pub const Driver = struct {
    base_address: usize,
    config: Config,

    pub fn init(base_address: usize, config: Config) !Driver {
        var driver = Driver{
            .base_address = base_address,
            .config = config,
        };

        try driver.configure();
        return driver;
    }

    /// Configure UART
    fn configure(self: *Driver) !void {
        // Disable interrupts
        self.writeReg(Registers.IER, 0x00);

        // Enable DLAB to set baud rate
        self.writeReg(Registers.LCR, LCR.DLAB);

        // Set baud rate divisor
        const divisor = self.config.clock_freq / (16 * self.config.baud_rate);
        self.writeReg(Registers.DLL, @intCast(divisor & 0xFF));
        self.writeReg(Registers.DLH, @intCast((divisor >> 8) & 0xFF));

        // Configure data format (8N1 by default)
        var lcr: u8 = switch (self.config.data_bits) {
            5 => LCR.WORD_LENGTH_5,
            6 => LCR.WORD_LENGTH_6,
            7 => LCR.WORD_LENGTH_7,
            8 => LCR.WORD_LENGTH_8,
            else => return error.InvalidDataBits,
        };

        lcr |= if (self.config.stop_bits == 2) LCR.STOP_BITS_2 else LCR.STOP_BITS_1;

        lcr |= switch (self.config.parity) {
            .none => LCR.PARITY_NONE,
            .odd => LCR.PARITY_ODD,
            .even => LCR.PARITY_EVEN,
            .mark => LCR.PARITY_MARK,
            .space => LCR.PARITY_SPACE,
        };

        self.writeReg(Registers.LCR, lcr);

        // Enable and clear FIFOs
        self.writeReg(Registers.FCR, FCR.ENABLE_FIFO | FCR.CLEAR_RX_FIFO | FCR.CLEAR_TX_FIFO | FCR.TRIGGER_14);

        // Enable interrupts (optional)
        // self.writeReg(Registers.IER, 0x01); // Enable received data interrupt
    }

    /// Write a single byte
    pub fn writeByte(self: *Driver, byte: u8) void {
        // Wait for transmitter to be ready
        while ((self.readReg(Registers.LSR) & LSR.THR_EMPTY) == 0) {}
        self.writeReg(Registers.THR, byte);
    }

    /// Write multiple bytes
    pub fn write(self: *Driver, data: []const u8) void {
        for (data) |byte| {
            self.writeByte(byte);
        }
    }

    /// Read a single byte (blocking)
    pub fn readByte(self: *Driver) u8 {
        // Wait for data to be available
        while ((self.readReg(Registers.LSR) & LSR.DATA_READY) == 0) {}
        return self.readReg(Registers.RBR);
    }

    /// Read a single byte (non-blocking)
    pub fn tryReadByte(self: *Driver) ?u8 {
        if ((self.readReg(Registers.LSR) & LSR.DATA_READY) != 0) {
            return self.readReg(Registers.RBR);
        }
        return null;
    }

    /// Read multiple bytes
    pub fn read(self: *Driver, buffer: []u8) usize {
        var count: usize = 0;
        for (buffer) |*byte| {
            if (self.tryReadByte()) |b| {
                byte.* = b;
                count += 1;
            } else {
                break;
            }
        }
        return count;
    }

    /// Check if data is available
    pub fn dataAvailable(self: *Driver) bool {
        return (self.readReg(Registers.LSR) & LSR.DATA_READY) != 0;
    }

    /// Check if transmitter is empty
    pub fn transmitterEmpty(self: *Driver) bool {
        return (self.readReg(Registers.LSR) & LSR.TRANSMITTER_EMPTY) != 0;
    }

    /// Get line status
    pub fn getLineStatus(self: *Driver) u8 {
        return self.readReg(Registers.LSR);
    }

    /// Write to register
    fn writeReg(self: *Driver, offset: u16, value: u8) void {
        const addr = self.base_address + offset;
        @as(*volatile u8, @ptrFromInt(addr)).* = value;
    }

    /// Read from register
    fn readReg(self: *Driver, offset: u16) u8 {
        const addr = self.base_address + offset;
        return @as(*volatile u8, @ptrFromInt(addr)).*;
    }

    /// Writer interface for std.fmt
    pub const Writer = std.io.Writer(*Driver, error{}, writeFn);

    pub fn writer(self: *Driver) Writer {
        return .{ .context = self };
    }

    fn writeFn(self: *Driver, bytes: []const u8) error{}!usize {
        self.write(bytes);
        return bytes.len;
    }
};

/// ARM PL011 UART (common on ARM platforms)
pub const PL011 = struct {
    pub const PL011Registers = struct {
        pub const DR: u16 = 0x000; // Data Register
        pub const RSR: u16 = 0x004; // Receive Status Register
        pub const FR: u16 = 0x018; // Flag Register
        pub const IBRD: u16 = 0x024; // Integer Baud Rate Divisor
        pub const FBRD: u16 = 0x028; // Fractional Baud Rate Divisor
        pub const LCRH: u16 = 0x02C; // Line Control Register
        pub const CR: u16 = 0x030; // Control Register
        pub const IMSC: u16 = 0x038; // Interrupt Mask Set/Clear
        pub const ICR: u16 = 0x044; // Interrupt Clear Register
    };

    pub const FR = struct {
        pub const TXFF: u8 = 1 << 5; // Transmit FIFO full
        pub const RXFE: u8 = 1 << 4; // Receive FIFO empty
        pub const BUSY: u8 = 1 << 3; // UART busy
    };

    pub const CR = struct {
        pub const UARTEN: u16 = 1 << 0; // UART enable
        pub const TXE: u16 = 1 << 8; // Transmit enable
        pub const RXE: u16 = 1 << 9; // Receive enable
    };

    pub const Driver = struct {
        base_address: usize,

        pub fn init(base_address: usize, baud_rate: u32, clock_freq: u32) !PL011.Driver {
            var driver = PL011.Driver{ .base_address = base_address };

            // Disable UART
            driver.writeReg(PL011Registers.CR, 0);

            // Calculate divisor
            const divisor = (clock_freq * 4) / baud_rate;
            const ibrd = divisor / 64;
            const fbrd = divisor % 64;

            driver.writeReg(PL011Registers.IBRD, @intCast(ibrd));
            driver.writeReg(PL011Registers.FBRD, @intCast(fbrd));

            // Configure: 8N1, FIFO enabled
            driver.writeReg(PL011Registers.LCRH, 0x70);

            // Enable UART, TX, and RX
            driver.writeReg(PL011Registers.CR, CR.UARTEN | CR.TXE | CR.RXE);

            return driver;
        }

        pub fn writeByte(self: *PL011.Driver, byte: u8) void {
            while ((self.readReg(PL011Registers.FR) & FR.TXFF) != 0) {}
            self.writeReg(PL011Registers.DR, byte);
        }

        pub fn write(self: *PL011.Driver, data: []const u8) void {
            for (data) |byte| {
                self.writeByte(byte);
            }
        }

        pub fn readByte(self: *PL011.Driver) u8 {
            while ((self.readReg(PL011Registers.FR) & FR.RXFE) != 0) {}
            return @intCast(self.readReg(PL011Registers.DR) & 0xFF);
        }

        pub fn tryReadByte(self: *PL011.Driver) ?u8 {
            if ((self.readReg(PL011Registers.FR) & FR.RXFE) == 0) {
                return @intCast(self.readReg(PL011Registers.DR) & 0xFF);
            }
            return null;
        }

        fn writeReg(self: *PL011.Driver, offset: u16, value: u16) void {
            const addr = self.base_address + offset;
            @as(*volatile u32, @ptrFromInt(addr)).* = value;
        }

        fn readReg(self: *PL011.Driver, offset: u16) u16 {
            const addr = self.base_address + offset;
            return @intCast(@as(*volatile u32, @ptrFromInt(addr)).*);
        }

        pub const Writer = std.io.Writer(*PL011.Driver, error{}, writeFn);

        pub fn writer(self: *PL011.Driver) Writer {
            return .{ .context = self };
        }

        fn writeFn(self: *PL011.Driver, bytes: []const u8) error{}!usize {
            self.write(bytes);
            return bytes.len;
        }
    };
};

test "UART config" {
    const testing = std.testing;

    const config = Config.default();
    try testing.expectEqual(@as(u32, 115200), config.baud_rate);
    try testing.expectEqual(@as(u8, 8), config.data_bits);
    try testing.expectEqual(Config.Parity.none, config.parity);
}
