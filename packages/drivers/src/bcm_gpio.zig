// Home Programming Language - BCM2835/BCM2711 GPIO Driver
// For Raspberry Pi 3/4

const std = @import("std");

// ============================================================================
// BCM GPIO Register Layout
// ============================================================================

pub const GpioRegs = extern struct {
    gpfsel: [6]u32, // Function select
    reserved1: u32,
    gpset: [2]u32, // Pin output set
    reserved2: u32,
    gpclr: [2]u32, // Pin output clear
    reserved3: u32,
    gplev: [2]u32, // Pin level
    reserved4: u32,
    gpeds: [2]u32, // Event detect status
    reserved5: u32,
    gpren: [2]u32, // Rising edge detect enable
    reserved6: u32,
    gpfen: [2]u32, // Falling edge detect enable
    reserved7: u32,
    gphen: [2]u32, // High detect enable
    reserved8: u32,
    gplen: [2]u32, // Low detect enable
    reserved9: u32,
    gparen: [2]u32, // Async rising edge detect
    reserved10: u32,
    gpafen: [2]u32, // Async falling edge detect
    reserved11: u32,
    gppud: u32, // Pull-up/down enable (BCM2835)
    gppudclk: [2]u32, // Pull-up/down clock (BCM2835)
    reserved12: [4]u32,
    // BCM2711 (RPi 4) has different pull-up/down registers at offset 0xE4
    gpio_pup_pdn_cntrl: [4]u32, // Pull-up/down control (BCM2711)
};

// GPIO base addresses
pub const BCM2835_GPIO_BASE = 0x3F200000; // Raspberry Pi 3
pub const BCM2711_GPIO_BASE = 0xFE200000; // Raspberry Pi 4

// ============================================================================
// GPIO Functions
// ============================================================================

pub const GpioFunction = enum(u3) {
    Input = 0b000,
    Output = 0b001,
    Alt0 = 0b100,
    Alt1 = 0b101,
    Alt2 = 0b110,
    Alt3 = 0b111,
    Alt4 = 0b011,
    Alt5 = 0b010,
};

pub const GpioPull = enum(u2) {
    None = 0b00,
    PullDown = 0b01,
    PullUp = 0b10,
};

// ============================================================================
// GPIO Driver
// ============================================================================

pub const GpioDriver = struct {
    regs: *volatile GpioRegs,
    is_bcm2711: bool, // true for RPi 4, false for RPi 3

    pub fn init(base_addr: u64, is_bcm2711: bool) GpioDriver {
        return .{
            .regs = @ptrFromInt(base_addr),
            .is_bcm2711 = is_bcm2711,
        };
    }

    /// Set GPIO pin function
    pub fn setFunction(self: *GpioDriver, pin: u8, function: GpioFunction) void {
        if (pin >= 54) return; // BCM has 54 GPIO pins

        const reg_index = pin / 10;
        const bit_offset: u5 = @intCast((pin % 10) * 3);

        // Read current value
        var val = self.regs.gpfsel[reg_index];

        // Clear the 3 bits for this pin
        val &= ~(@as(u32, 0b111) << bit_offset);

        // Set new function
        val |= @as(u32, @intFromEnum(function)) << bit_offset;

        self.regs.gpfsel[reg_index] = val;
    }

    /// Set GPIO pin high
    pub fn setPin(self: *GpioDriver, pin: u8) void {
        if (pin >= 54) return;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        self.regs.gpset[reg_index] = @as(u32, 1) << bit_offset;
    }

    /// Set GPIO pin low
    pub fn clearPin(self: *GpioDriver, pin: u8) void {
        if (pin >= 54) return;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        self.regs.gpclr[reg_index] = @as(u32, 1) << bit_offset;
    }

    /// Read GPIO pin level
    pub fn readPin(self: *GpioDriver, pin: u8) bool {
        if (pin >= 54) return false;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        return (self.regs.gplev[reg_index] & (@as(u32, 1) << bit_offset)) != 0;
    }

    /// Toggle GPIO pin
    pub fn togglePin(self: *GpioDriver, pin: u8) void {
        if (self.readPin(pin)) {
            self.clearPin(pin);
        } else {
            self.setPin(pin);
        }
    }

    /// Set pull-up/down for a pin
    pub fn setPull(self: *GpioDriver, pin: u8, pull: GpioPull) void {
        if (pin >= 54) return;

        if (self.is_bcm2711) {
            // BCM2711 (Raspberry Pi 4) method
            const reg_index = pin / 16;
            const bit_offset: u5 = @intCast((pin % 16) * 2);

            var val = self.regs.gpio_pup_pdn_cntrl[reg_index];
            val &= ~(@as(u32, 0b11) << bit_offset);
            val |= @as(u32, @intFromEnum(pull)) << bit_offset;
            self.regs.gpio_pup_pdn_cntrl[reg_index] = val;
        } else {
            // BCM2835 (Raspberry Pi 3) method
            self.regs.gppud = @intFromEnum(pull);

            // Wait 150 cycles
            var i: u32 = 0;
            while (i < 150) : (i += 1) {
                asm volatile ("nop");
            }

            const reg_index = pin / 32;
            const bit_offset: u5 = @intCast(pin % 32);
            self.regs.gppudclk[reg_index] = @as(u32, 1) << bit_offset;

            // Wait 150 cycles
            i = 0;
            while (i < 150) : (i += 1) {
                asm volatile ("nop");
            }

            self.regs.gppud = 0;
            self.regs.gppudclk[reg_index] = 0;
        }
    }

    /// Enable rising edge detection
    pub fn enableRisingEdge(self: *GpioDriver, pin: u8) void {
        if (pin >= 54) return;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        self.regs.gpren[reg_index] |= @as(u32, 1) << bit_offset;
    }

    /// Enable falling edge detection
    pub fn enableFallingEdge(self: *GpioDriver, pin: u8) void {
        if (pin >= 54) return;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        self.regs.gpfen[reg_index] |= @as(u32, 1) << bit_offset;
    }

    /// Check if event was detected
    pub fn eventDetected(self: *GpioDriver, pin: u8) bool {
        if (pin >= 54) return false;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        return (self.regs.gpeds[reg_index] & (@as(u32, 1) << bit_offset)) != 0;
    }

    /// Clear event detection status
    pub fn clearEvent(self: *GpioDriver, pin: u8) void {
        if (pin >= 54) return;

        const reg_index = pin / 32;
        const bit_offset: u5 = @intCast(pin % 32);

        // Write 1 to clear
        self.regs.gpeds[reg_index] = @as(u32, 1) << bit_offset;
    }
};

// ============================================================================
// Common GPIO Pin Definitions for Raspberry Pi
// ============================================================================

pub const RaspberryPiPins = struct {
    // UART0
    pub const UART0_TX = 14;
    pub const UART0_RX = 15;

    // I2C1
    pub const I2C1_SDA = 2;
    pub const I2C1_SCL = 3;

    // SPI0
    pub const SPI0_MOSI = 10;
    pub const SPI0_MISO = 9;
    pub const SPI0_SCLK = 11;
    pub const SPI0_CE0 = 8;
    pub const SPI0_CE1 = 7;

    // PWM
    pub const PWM0 = 12;
    pub const PWM1 = 13;

    // Status LED (varies by model)
    pub const STATUS_LED_PI3 = 47; // ACT LED on Pi 3
    pub const STATUS_LED_PI4 = 42; // ACT LED on Pi 4
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Initialize GPIO for Raspberry Pi 3
pub fn initRaspberryPi3() GpioDriver {
    return GpioDriver.init(BCM2835_GPIO_BASE, false);
}

/// Initialize GPIO for Raspberry Pi 4
pub fn initRaspberryPi4() GpioDriver {
    return GpioDriver.init(BCM2711_GPIO_BASE, true);
}

/// Blink LED on status pin
pub fn blinkStatusLED(gpio: *GpioDriver, pin: u8, times: u32) void {
    gpio.setFunction(pin, .Output);

    var i: u32 = 0;
    while (i < times) : (i += 1) {
        gpio.setPin(pin);
        busyWait(500000);
        gpio.clearPin(pin);
        busyWait(500000);
    }
}

/// Simple busy wait (not accurate, just for delays)
fn busyWait(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "GPIO register size" {
    try std.testing.expectEqual(@as(usize, 0xF4), @sizeOf(GpioRegs));
}

test "GPIO function encoding" {
    try std.testing.expectEqual(@as(u3, 0b000), @intFromEnum(GpioFunction.Input));
    try std.testing.expectEqual(@as(u3, 0b001), @intFromEnum(GpioFunction.Output));
    try std.testing.expectEqual(@as(u3, 0b100), @intFromEnum(GpioFunction.Alt0));
}

test "GPIO pin constants" {
    try std.testing.expectEqual(@as(u8, 14), RaspberryPiPins.UART0_TX);
    try std.testing.expectEqual(@as(u8, 15), RaspberryPiPins.UART0_RX);
}
