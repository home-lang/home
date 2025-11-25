// Home Programming Language - USB HID (Human Interface Device) Driver
// Keyboard, Mouse, and other HID devices

const Basics = @import("basics");
const usb = @import("usb.zig");
const sync = @import("sync");

// ============================================================================
// HID Class Codes
// ============================================================================

pub const HidSubclass = enum(u8) {
    None = 0,
    Boot = 1,
    _,
};

pub const HidProtocol = enum(u8) {
    None = 0,
    Keyboard = 1,
    Mouse = 2,
    _,
};

// ============================================================================
// HID Descriptor
// ============================================================================

pub const HidDescriptor = extern struct {
    b_length: u8,
    b_descriptor_type: u8,
    bcd_hid: u16,
    b_country_code: u8,
    b_num_descriptors: u8,
    b_descriptor_type_report: u8,
    w_descriptor_length: u16,
};

// ============================================================================
// HID Requests
// ============================================================================

pub const HidRequest = enum(u8) {
    GetReport = 0x01,
    GetIdle = 0x02,
    GetProtocol = 0x03,
    SetReport = 0x09,
    SetIdle = 0x0A,
    SetProtocol = 0x0B,
    _,
};

pub const HidReportType = enum(u8) {
    Input = 1,
    Output = 2,
    Feature = 3,
    _,
};

// ============================================================================
// Keyboard HID
// ============================================================================

pub const KeyboardModifiers = packed struct(u8) {
    left_ctrl: bool = false,
    left_shift: bool = false,
    left_alt: bool = false,
    left_gui: bool = false,
    right_ctrl: bool = false,
    right_shift: bool = false,
    right_alt: bool = false,
    right_gui: bool = false,
};

pub const KeyboardReport = extern struct {
    modifiers: u8,
    reserved: u8,
    keycodes: [6]u8,

    pub fn getModifiers(self: *const KeyboardReport) KeyboardModifiers {
        return @bitCast(self.modifiers);
    }

    pub fn hasKey(self: *const KeyboardReport, keycode: u8) bool {
        for (self.keycodes) |key| {
            if (key == keycode) return true;
        }
        return false;
    }
};

pub const HidKeyboard = struct {
    device: *usb.UsbDevice,
    endpoint: u8,
    interval: u8,
    current_report: KeyboardReport,
    previous_report: KeyboardReport,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    pub fn init(allocator: Basics.Allocator, device: *usb.UsbDevice, endpoint: u8, interval: u8) !*HidKeyboard {
        const keyboard = try allocator.create(HidKeyboard);
        keyboard.* = .{
            .device = device,
            .endpoint = endpoint,
            .interval = interval,
            .current_report = Basics.mem.zeroes(KeyboardReport),
            .previous_report = Basics.mem.zeroes(KeyboardReport),
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
        return keyboard;
    }

    pub fn deinit(self: *HidKeyboard) void {
        self.allocator.destroy(self);
    }

    pub fn setProtocol(self: *HidKeyboard, protocol: HidProtocol) !void {
        const setup = usb.UsbSetupPacket.init(
            .{ .recipient = 1, .request_type = 1, .direction = 0 }, // Class, Interface, Out
            @enumFromInt(@intFromEnum(HidRequest.SetProtocol)),
            @intFromEnum(protocol),
            0,
            0,
        );

        _ = try self.device.controlTransfer(setup, &[_]u8{});
    }

    pub fn setIdle(self: *HidKeyboard, duration: u8) !void {
        const setup = usb.UsbSetupPacket.init(
            .{ .recipient = 1, .request_type = 1, .direction = 0 },
            @enumFromInt(@intFromEnum(HidRequest.SetIdle)),
            @as(u16, duration) << 8,
            0,
            0,
        );

        _ = try self.device.controlTransfer(setup, &[_]u8{});
    }

    pub fn poll(self: *HidKeyboard) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.previous_report = self.current_report;

        var buffer: [@sizeOf(KeyboardReport)]u8 = undefined;
        var urb = usb.Urb.init(self.device, self.endpoint, .Interrupt, .In, &buffer);

        try self.device.controller.submitUrb(&urb);

        // Wait for completion with yield
        while (urb.status == .Pending) {
            asm volatile ("pause"); // Yield CPU while waiting
        }

        if (urb.status == .Completed and urb.actual_length >= @sizeOf(KeyboardReport)) {
            self.current_report = @as(*const KeyboardReport, @ptrCast(@alignCast(&buffer))).*;
        }
    }

    pub fn getKeyPressed(self: *HidKeyboard) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find new key press
        for (self.current_report.keycodes) |key| {
            if (key == 0) continue;
            if (!self.previous_report.hasKey(key)) {
                return key;
            }
        }
        return null;
    }

    pub fn getKeyReleased(self: *HidKeyboard) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find key release
        for (self.previous_report.keycodes) |key| {
            if (key == 0) continue;
            if (!self.current_report.hasKey(key)) {
                return key;
            }
        }
        return null;
    }
};

// ============================================================================
// Mouse HID
// ============================================================================

pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    button4: bool = false,
    button5: bool = false,
    _padding: u3 = 0,
};

pub const MouseReport = extern struct {
    buttons: u8,
    x: i8,
    y: i8,
    wheel: i8,

    pub fn getButtons(self: *const MouseReport) MouseButtons {
        return @bitCast(self.buttons);
    }
};

pub const HidMouse = struct {
    device: *usb.UsbDevice,
    endpoint: u8,
    interval: u8,
    current_report: MouseReport,
    previous_report: MouseReport,
    cursor_x: i32,
    cursor_y: i32,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    pub fn init(allocator: Basics.Allocator, device: *usb.UsbDevice, endpoint: u8, interval: u8) !*HidMouse {
        const mouse = try allocator.create(HidMouse);
        mouse.* = .{
            .device = device,
            .endpoint = endpoint,
            .interval = interval,
            .current_report = Basics.mem.zeroes(MouseReport),
            .previous_report = Basics.mem.zeroes(MouseReport),
            .cursor_x = 0,
            .cursor_y = 0,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
        };
        return mouse;
    }

    pub fn deinit(self: *HidMouse) void {
        self.allocator.destroy(self);
    }

    pub fn setProtocol(self: *HidMouse, protocol: HidProtocol) !void {
        const setup = usb.UsbSetupPacket.init(
            .{ .recipient = 1, .request_type = 1, .direction = 0 },
            @enumFromInt(@intFromEnum(HidRequest.SetProtocol)),
            @intFromEnum(protocol),
            0,
            0,
        );

        _ = try self.device.controlTransfer(setup, &[_]u8{});
    }

    pub fn poll(self: *HidMouse) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.previous_report = self.current_report;

        var buffer: [@sizeOf(MouseReport)]u8 = undefined;
        var urb = usb.Urb.init(self.device, self.endpoint, .Interrupt, .In, &buffer);

        try self.device.controller.submitUrb(&urb);

        // Wait for completion with yield
        while (urb.status == .Pending) {
            asm volatile ("pause"); // Yield CPU while waiting
        }

        if (urb.status == .Completed and urb.actual_length >= @sizeOf(MouseReport)) {
            self.current_report = @as(*const MouseReport, @ptrCast(@alignCast(&buffer))).*;

            // Update cursor position
            self.cursor_x += self.current_report.x;
            self.cursor_y += self.current_report.y;
        }
    }

    pub fn getPosition(self: *HidMouse) struct { x: i32, y: i32 } {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{ .x = self.cursor_x, .y = self.cursor_y };
    }

    pub fn getDelta(self: *HidMouse) struct { dx: i8, dy: i8 } {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{ .dx = self.current_report.x, .dy = self.current_report.y };
    }

    pub fn getButtonPressed(self: *HidMouse, button: enum { left, right, middle }) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const buttons = self.current_report.getButtons();
        return switch (button) {
            .left => buttons.left,
            .right => buttons.right,
            .middle => buttons.middle,
        };
    }

    pub fn getWheelDelta(self: *HidMouse) i8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.current_report.wheel;
    }
};

// ============================================================================
// HID Device Initialization
// ============================================================================

pub fn initHidDevice(allocator: Basics.Allocator, device: *usb.UsbDevice, interface: *usb.UsbInterfaceDescriptor, endpoint: *usb.UsbEndpointDescriptor) !void {
    const protocol: HidProtocol = @enumFromInt(interface.b_interface_protocol);

    switch (protocol) {
        .Keyboard => {
            const keyboard = try HidKeyboard.init(allocator, device, endpoint.getNumber(), endpoint.b_interval);
            errdefer keyboard.deinit();

            // Set boot protocol
            try keyboard.setProtocol(.Keyboard);

            // Set idle rate (0 = infinite, only report on change)
            try keyboard.setIdle(0);

            // Keyboard initialized and ready for input events
            Basics.debug.print("USB HID: Keyboard initialized\n", .{});
            _ = keyboard;
        },
        .Mouse => {
            const mouse = try HidMouse.init(allocator, device, endpoint.getNumber(), endpoint.b_interval);
            errdefer mouse.deinit();

            // Set boot protocol
            try mouse.setProtocol(.Mouse);

            // Mouse initialized and ready for input events
            Basics.debug.print("USB HID: Mouse initialized\n", .{});
            _ = mouse;
        },
        else => {
            // Unknown HID device
            return error.UnsupportedHidDevice;
        },
    }
}

// ============================================================================
// USB HID Keycodes (Subset)
// ============================================================================

pub const KeyCode = enum(u8) {
    None = 0x00,

    // Letters
    A = 0x04,
    B = 0x05,
    C = 0x06,
    D = 0x07,
    E = 0x08,
    F = 0x09,
    G = 0x0A,
    H = 0x0B,
    I = 0x0C,
    J = 0x0D,
    K = 0x0E,
    L = 0x0F,
    M = 0x10,
    N = 0x11,
    O = 0x12,
    P = 0x13,
    Q = 0x14,
    R = 0x15,
    S = 0x16,
    T = 0x17,
    U = 0x18,
    V = 0x19,
    W = 0x1A,
    X = 0x1B,
    Y = 0x1C,
    Z = 0x1D,

    // Numbers
    Num1 = 0x1E,
    Num2 = 0x1F,
    Num3 = 0x20,
    Num4 = 0x21,
    Num5 = 0x22,
    Num6 = 0x23,
    Num7 = 0x24,
    Num8 = 0x25,
    Num9 = 0x26,
    Num0 = 0x27,

    // Special keys
    Enter = 0x28,
    Escape = 0x29,
    Backspace = 0x2A,
    Tab = 0x2B,
    Space = 0x2C,

    // Function keys
    F1 = 0x3A,
    F2 = 0x3B,
    F3 = 0x3C,
    F4 = 0x3D,
    F5 = 0x3E,
    F6 = 0x3F,
    F7 = 0x40,
    F8 = 0x41,
    F9 = 0x42,
    F10 = 0x43,
    F11 = 0x44,
    F12 = 0x45,

    // Arrow keys
    Right = 0x4F,
    Left = 0x50,
    Down = 0x51,
    Up = 0x52,

    _,

    pub fn toChar(self: KeyCode, shift: bool) ?u8 {
        return switch (self) {
            .A => if (shift) 'A' else 'a',
            .B => if (shift) 'B' else 'b',
            .C => if (shift) 'C' else 'c',
            .D => if (shift) 'D' else 'd',
            .E => if (shift) 'E' else 'e',
            .F => if (shift) 'F' else 'f',
            .G => if (shift) 'G' else 'g',
            .H => if (shift) 'H' else 'h',
            .I => if (shift) 'I' else 'i',
            .J => if (shift) 'J' else 'j',
            .K => if (shift) 'K' else 'k',
            .L => if (shift) 'L' else 'l',
            .M => if (shift) 'M' else 'm',
            .N => if (shift) 'N' else 'n',
            .O => if (shift) 'O' else 'o',
            .P => if (shift) 'P' else 'p',
            .Q => if (shift) 'Q' else 'q',
            .R => if (shift) 'R' else 'r',
            .S => if (shift) 'S' else 's',
            .T => if (shift) 'T' else 't',
            .U => if (shift) 'U' else 'u',
            .V => if (shift) 'V' else 'v',
            .W => if (shift) 'W' else 'w',
            .X => if (shift) 'X' else 'x',
            .Y => if (shift) 'Y' else 'y',
            .Z => if (shift) 'Z' else 'z',
            .Num1 => if (shift) '!' else '1',
            .Num2 => if (shift) '@' else '2',
            .Num3 => if (shift) '#' else '3',
            .Num4 => if (shift) '$' else '4',
            .Num5 => if (shift) '%' else '5',
            .Num6 => if (shift) '^' else '6',
            .Num7 => if (shift) '&' else '7',
            .Num8 => if (shift) '*' else '8',
            .Num9 => if (shift) '(' else '9',
            .Num0 => if (shift) ')' else '0',
            .Space => ' ',
            .Enter => '\n',
            .Tab => '\t',
            else => null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "keyboard report" {
    var report = KeyboardReport{
        .modifiers = 0x02, // Left shift
        .reserved = 0,
        .keycodes = [_]u8{ 0x04, 0, 0, 0, 0, 0 }, // 'A'
    };

    const mods = report.getModifiers();
    try Basics.testing.expect(mods.left_shift);
    try Basics.testing.expect(!mods.left_ctrl);
    try Basics.testing.expect(report.hasKey(0x04));
    try Basics.testing.expect(!report.hasKey(0x05));
}

test "mouse report" {
    const report = MouseReport{
        .buttons = 0x01, // Left button
        .x = 10,
        .y = -5,
        .wheel = 1,
    };

    const buttons = report.getButtons();
    try Basics.testing.expect(buttons.left);
    try Basics.testing.expect(!buttons.right);
    try Basics.testing.expectEqual(@as(i8, 10), report.x);
    try Basics.testing.expectEqual(@as(i8, -5), report.y);
}

test "keycode to char" {
    try Basics.testing.expectEqual(@as(u8, 'a'), KeyCode.A.toChar(false).?);
    try Basics.testing.expectEqual(@as(u8, 'A'), KeyCode.A.toChar(true).?);
    try Basics.testing.expectEqual(@as(u8, '1'), KeyCode.Num1.toChar(false).?);
    try Basics.testing.expectEqual(@as(u8, '!'), KeyCode.Num1.toChar(true).?);
}
