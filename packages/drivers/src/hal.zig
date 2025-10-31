// Hardware Abstraction Layer (HAL)
// Provides unified interface for common peripherals across different platforms

const std = @import("std");

/// GPIO (General Purpose Input/Output) HAL
pub const GPIO = struct {
    pub const Direction = enum {
        input,
        output,
    };

    pub const Pull = enum {
        none,
        up,
        down,
    };

    pub const Trigger = enum {
        none,
        rising,
        falling,
        both,
    };

    /// Platform-specific GPIO operations
    pub const Operations = struct {
        set_direction: *const fn (pin: u32, dir: Direction) anyerror!void,
        set_value: *const fn (pin: u32, value: bool) anyerror!void,
        get_value: *const fn (pin: u32) anyerror!bool,
        set_pull: *const fn (pin: u32, pull: Pull) anyerror!void,
        set_trigger: *const fn (pin: u32, trigger: Trigger) anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations) GPIO {
        return .{ .ops = ops };
    }

    pub fn setDirection(self: GPIO, pin: u32, dir: Direction) !void {
        return self.ops.set_direction(pin, dir);
    }

    pub fn setValue(self: GPIO, pin: u32, value: bool) !void {
        return self.ops.set_value(pin, value);
    }

    pub fn getValue(self: GPIO, pin: u32) !bool {
        return self.ops.get_value(pin);
    }

    pub fn setPull(self: GPIO, pin: u32, pull: Pull) !void {
        return self.ops.set_pull(pin, pull);
    }

    pub fn setTrigger(self: GPIO, pin: u32, trigger: Trigger) !void {
        return self.ops.set_trigger(pin, trigger);
    }
};

/// UART (Universal Asynchronous Receiver-Transmitter) HAL
pub const UART = struct {
    pub const Config = struct {
        baud_rate: u32,
        data_bits: u8,
        stop_bits: u8,
        parity: Parity,
    };

    pub const Parity = enum {
        none,
        odd,
        even,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        write_byte: *const fn (byte: u8) anyerror!void,
        read_byte: *const fn () anyerror!u8,
        write_bytes: *const fn (bytes: []const u8) anyerror!usize,
        read_bytes: *const fn (buffer: []u8) anyerror!usize,
        is_readable: *const fn () bool,
        is_writable: *const fn () bool,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !UART {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn writeByte(self: UART, byte: u8) !void {
        return self.ops.write_byte(byte);
    }

    pub fn readByte(self: UART) !u8 {
        return self.ops.read_byte();
    }

    pub fn write(self: UART, bytes: []const u8) !usize {
        return self.ops.write_bytes(bytes);
    }

    pub fn read(self: UART, buffer: []u8) !usize {
        return self.ops.read_bytes(buffer);
    }

    pub fn isReadable(self: UART) bool {
        return self.ops.is_readable();
    }

    pub fn isWritable(self: UART) bool {
        return self.ops.is_writable();
    }
};

/// SPI (Serial Peripheral Interface) HAL
pub const SPI = struct {
    pub const Config = struct {
        clock_speed: u32,
        mode: Mode,
        bit_order: BitOrder,
    };

    pub const Mode = enum(u2) {
        mode0 = 0, // CPOL=0, CPHA=0
        mode1 = 1, // CPOL=0, CPHA=1
        mode2 = 2, // CPOL=1, CPHA=0
        mode3 = 3, // CPOL=1, CPHA=1
    };

    pub const BitOrder = enum {
        msb_first,
        lsb_first,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        transfer: *const fn (tx_data: []const u8, rx_data: []u8) anyerror!void,
        select_device: *const fn (cs: u32) anyerror!void,
        deselect_device: *const fn () anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !SPI {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn transfer(self: SPI, tx_data: []const u8, rx_data: []u8) !void {
        return self.ops.transfer(tx_data, rx_data);
    }

    pub fn selectDevice(self: SPI, cs: u32) !void {
        return self.ops.select_device(cs);
    }

    pub fn deselectDevice(self: SPI) !void {
        return self.ops.deselect_device();
    }
};

/// I2C (Inter-Integrated Circuit) HAL
pub const I2C = struct {
    pub const Config = struct {
        clock_speed: u32,
        addressing_mode: AddressingMode,
    };

    pub const AddressingMode = enum {
        address_7bit,
        address_10bit,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        write: *const fn (addr: u16, data: []const u8) anyerror!void,
        read: *const fn (addr: u16, buffer: []u8) anyerror!void,
        write_read: *const fn (addr: u16, tx_data: []const u8, rx_data: []u8) anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !I2C {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn write(self: I2C, addr: u16, data: []const u8) !void {
        return self.ops.write(addr, data);
    }

    pub fn read(self: I2C, addr: u16, buffer: []u8) !void {
        return self.ops.read(addr, buffer);
    }

    pub fn writeRead(self: I2C, addr: u16, tx_data: []const u8, rx_data: []u8) !void {
        return self.ops.write_read(addr, tx_data, rx_data);
    }
};

/// Timer HAL
pub const Timer = struct {
    pub const Config = struct {
        frequency: u32,
        mode: Mode,
    };

    pub const Mode = enum {
        oneshot,
        periodic,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        start: *const fn () anyerror!void,
        stop: *const fn () anyerror!void,
        get_count: *const fn () u64,
        set_callback: *const fn (callback: *const fn () void) anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !Timer {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn start(self: Timer) !void {
        return self.ops.start();
    }

    pub fn stop(self: Timer) !void {
        return self.ops.stop();
    }

    pub fn getCount(self: Timer) u64 {
        return self.ops.get_count();
    }

    pub fn setCallback(self: Timer, callback: *const fn () void) !void {
        return self.ops.set_callback(callback);
    }
};

/// PWM (Pulse Width Modulation) HAL
pub const PWM = struct {
    pub const Config = struct {
        frequency: u32,
        duty_cycle: u8, // 0-100%
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        set_duty_cycle: *const fn (duty: u8) anyerror!void,
        set_frequency: *const fn (freq: u32) anyerror!void,
        start: *const fn () anyerror!void,
        stop: *const fn () anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !PWM {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn setDutyCycle(self: PWM, duty: u8) !void {
        return self.ops.set_duty_cycle(duty);
    }

    pub fn setFrequency(self: PWM, freq: u32) !void {
        return self.ops.set_frequency(freq);
    }

    pub fn start(self: PWM) !void {
        return self.ops.start();
    }

    pub fn stop(self: PWM) !void {
        return self.ops.stop();
    }
};

/// ADC (Analog-to-Digital Converter) HAL
pub const ADC = struct {
    pub const Config = struct {
        resolution: u8, // bits
        sample_rate: u32,
        reference_voltage: u32, // millivolts
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        read_channel: *const fn (channel: u8) anyerror!u16,
        read_voltage: *const fn (channel: u8) anyerror!u32, // millivolts
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !ADC {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn readChannel(self: ADC, channel: u8) !u16 {
        return self.ops.read_channel(channel);
    }

    pub fn readVoltage(self: ADC, channel: u8) !u32 {
        return self.ops.read_voltage(channel);
    }
};

/// Watchdog Timer HAL
pub const Watchdog = struct {
    pub const Config = struct {
        timeout_ms: u32,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        start: *const fn () anyerror!void,
        feed: *const fn () anyerror!void,
        stop: *const fn () anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !Watchdog {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn start(self: Watchdog) !void {
        return self.ops.start();
    }

    pub fn feed(self: Watchdog) !void {
        return self.ops.feed();
    }

    pub fn stop(self: Watchdog) !void {
        return self.ops.stop();
    }
};

/// RTC (Real-Time Clock) HAL
pub const RTC = struct {
    pub const DateTime = struct {
        year: u16,
        month: u8, // 1-12
        day: u8, // 1-31
        hour: u8, // 0-23
        minute: u8, // 0-59
        second: u8, // 0-59
    };

    pub const Operations = struct {
        init: *const fn () anyerror!void,
        get_time: *const fn () anyerror!DateTime,
        set_time: *const fn (dt: DateTime) anyerror!void,
        get_timestamp: *const fn () u64, // Unix timestamp
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations) !RTC {
        try ops.init();
        return .{ .ops = ops };
    }

    pub fn getTime(self: RTC) !DateTime {
        return self.ops.get_time();
    }

    pub fn setTime(self: RTC, dt: DateTime) !void {
        return self.ops.set_time(dt);
    }

    pub fn getTimestamp(self: RTC) u64 {
        return self.ops.get_timestamp();
    }
};

/// DMA (Direct Memory Access) HAL
pub const DMA = struct {
    pub const Config = struct {
        channel: u8,
        priority: Priority,
        direction: Direction,
    };

    pub const Priority = enum {
        low,
        medium,
        high,
        very_high,
    };

    pub const Direction = enum {
        memory_to_memory,
        memory_to_peripheral,
        peripheral_to_memory,
    };

    pub const Operations = struct {
        init: *const fn (config: Config) anyerror!void,
        start_transfer: *const fn (src: usize, dst: usize, len: usize) anyerror!void,
        stop_transfer: *const fn () anyerror!void,
        is_complete: *const fn () bool,
        set_callback: *const fn (callback: *const fn () void) anyerror!void,
    };

    ops: *const Operations,

    pub fn init(ops: *const Operations, config: Config) !DMA {
        try ops.init(config);
        return .{ .ops = ops };
    }

    pub fn startTransfer(self: DMA, src: usize, dst: usize, len: usize) !void {
        return self.ops.start_transfer(src, dst, len);
    }

    pub fn stopTransfer(self: DMA) !void {
        return self.ops.stop_transfer();
    }

    pub fn isComplete(self: DMA) bool {
        return self.ops.is_complete();
    }

    pub fn setCallback(self: DMA, callback: *const fn () void) !void {
        return self.ops.set_callback(callback);
    }
};

// Tests
test "HAL structures" {
    const testing = std.testing;

    // Test that all HAL structures compile
    _ = GPIO;
    _ = UART;
    _ = SPI;
    _ = I2C;
    _ = Timer;
    _ = PWM;
    _ = ADC;
    _ = Watchdog;
    _ = RTC;
    _ = DMA;

    // Test config structures
    const uart_config = UART.Config{
        .baud_rate = 115200,
        .data_bits = 8,
        .stop_bits = 1,
        .parity = .none,
    };
    try testing.expectEqual(@as(u32, 115200), uart_config.baud_rate);

    const spi_config = SPI.Config{
        .clock_speed = 1000000,
        .mode = .mode0,
        .bit_order = .msb_first,
    };
    try testing.expectEqual(@as(u32, 1000000), spi_config.clock_speed);
}
