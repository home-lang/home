// Home Programming Language - USB HID (Human Interface Device) Driver
// Keyboard, mouse, and other HID device support

const Basics = @import("basics");

// ============================================================================
// HID Class Constants
// ============================================================================

/// HID Class Requests
pub const HidRequest = enum(u8) {
    GetReport = 0x01,
    GetIdle = 0x02,
    GetProtocol = 0x03,
    SetReport = 0x09,
    SetIdle = 0x0A,
    SetProtocol = 0x0B,
};

/// HID Report Types
pub const HidReportType = enum(u8) {
    Input = 0x01,
    Output = 0x02,
    Feature = 0x03,
};

/// HID Protocol
pub const HidProtocol = enum(u8) {
    Boot = 0,
    Report = 1,
};

/// HID Subclass
pub const HidSubclass = enum(u8) {
    None = 0,
    Boot = 1,
};

/// HID Boot Interface Protocol
pub const HidBootProtocol = enum(u8) {
    None = 0,
    Keyboard = 1,
    Mouse = 2,
};

// ============================================================================
// HID Descriptor Structures
// ============================================================================

/// HID Descriptor
pub const HidDescriptor = struct {
    /// HID class version
    bcd_hid: u16,
    /// Country code
    country_code: u8,
    /// Number of descriptors
    num_descriptors: u8,
    /// Descriptor type (Report)
    descriptor_type: u8,
    /// Descriptor length
    descriptor_length: u16,
};

/// HID Report Descriptor Item
pub const HidReportItem = struct {
    tag: u8,
    type: u2,
    size: u2,
    data: u32,

    pub const ItemType = enum(u2) {
        Main = 0,
        Global = 1,
        Local = 2,
        Reserved = 3,
    };
};

// ============================================================================
// HID Usage Tables
// ============================================================================

/// HID Usage Pages
pub const HidUsagePage = enum(u16) {
    GenericDesktop = 0x01,
    SimulationControls = 0x02,
    VRControls = 0x03,
    SportControls = 0x04,
    GameControls = 0x05,
    GenericDeviceControls = 0x06,
    Keyboard = 0x07,
    LED = 0x08,
    Button = 0x09,
    Ordinal = 0x0A,
    Telephony = 0x0B,
    Consumer = 0x0C,
    Digitizer = 0x0D,
    _,
};

/// Generic Desktop Usage IDs
pub const GenericDesktopUsage = enum(u16) {
    Pointer = 0x01,
    Mouse = 0x02,
    Joystick = 0x04,
    Gamepad = 0x05,
    Keyboard = 0x06,
    Keypad = 0x07,
    X = 0x30,
    Y = 0x31,
    Z = 0x32,
    Rx = 0x33,
    Ry = 0x34,
    Rz = 0x35,
    Wheel = 0x38,
    _,
};

// ============================================================================
// Keyboard Support
// ============================================================================

/// Keyboard modifier keys (bit flags)
pub const KeyboardModifiers = packed struct {
    left_ctrl: bool = false,
    left_shift: bool = false,
    left_alt: bool = false,
    left_gui: bool = false,
    right_ctrl: bool = false,
    right_shift: bool = false,
    right_alt: bool = false,
    right_gui: bool = false,

    pub fn toU8(self: KeyboardModifiers) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(value: u8) KeyboardModifiers {
        return @bitCast(value);
    }
};

/// Standard boot protocol keyboard report (8 bytes)
pub const KeyboardReport = packed struct {
    /// Modifier keys
    modifiers: KeyboardModifiers,
    /// Reserved byte
    reserved: u8,
    /// Up to 6 simultaneous key presses
    keycodes: [6]u8,

    pub fn init() KeyboardReport {
        return .{
            .modifiers = @bitCast(@as(u8, 0)),
            .reserved = 0,
            .keycodes = [_]u8{0} ** 6,
        };
    }
};

/// USB HID Keyboard Scan Codes
pub const KeyCode = enum(u8) {
    None = 0x00,
    ErrorRollOver = 0x01,
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
    Enter = 0x28,
    Escape = 0x29,
    Backspace = 0x2A,
    Tab = 0x2B,
    Space = 0x2C,
    Minus = 0x2D,
    Equal = 0x2E,
    LeftBracket = 0x2F,
    RightBracket = 0x30,
    Backslash = 0x31,
    Semicolon = 0x33,
    Apostrophe = 0x34,
    Grave = 0x35,
    Comma = 0x36,
    Period = 0x37,
    Slash = 0x38,
    CapsLock = 0x39,
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
    PrintScreen = 0x46,
    ScrollLock = 0x47,
    Pause = 0x48,
    Insert = 0x49,
    Home = 0x4A,
    PageUp = 0x4B,
    Delete = 0x4C,
    End = 0x4D,
    PageDown = 0x4E,
    RightArrow = 0x4F,
    LeftArrow = 0x50,
    DownArrow = 0x51,
    UpArrow = 0x52,
    _,
};

/// Keyboard HID handler
pub const KeyboardHandler = struct {
    /// Previous report for change detection
    prev_report: KeyboardReport,

    pub fn init() KeyboardHandler {
        return .{
            .prev_report = KeyboardReport.init(),
        };
    }

    /// Handle keyboard input report
    pub fn handleReport(self: *KeyboardHandler, data: []const u8) !void {
        if (data.len < @sizeOf(KeyboardReport)) {
            return error.InvalidReportSize;
        }

        const report: *const KeyboardReport = @ptrCast(@alignCast(data.ptr));

        // Check for modifier changes
        const prev_mods = self.prev_report.modifiers;
        const curr_mods = report.modifiers;

        if (prev_mods.left_ctrl != curr_mods.left_ctrl) {
            self.handleKeyEvent(.LeftCtrl, curr_mods.left_ctrl);
        }
        if (prev_mods.left_shift != curr_mods.left_shift) {
            self.handleKeyEvent(.LeftShift, curr_mods.left_shift);
        }
        if (prev_mods.left_alt != curr_mods.left_alt) {
            self.handleKeyEvent(.LeftAlt, curr_mods.left_alt);
        }
        if (prev_mods.left_gui != curr_mods.left_gui) {
            self.handleKeyEvent(.LeftGui, curr_mods.left_gui);
        }

        // Check for key presses/releases
        for (report.keycodes) |keycode| {
            if (keycode == 0) continue;

            // Check if this is a new key press
            var found = false;
            for (self.prev_report.keycodes) |prev_key| {
                if (prev_key == keycode) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                self.handleKeyEvent(.KeyPress, true);
                Basics.debug.print("HID Keyboard: Key pressed: 0x{x}\n", .{keycode});
            }
        }

        // Check for key releases
        for (self.prev_report.keycodes) |prev_key| {
            if (prev_key == 0) continue;

            var found = false;
            for (report.keycodes) |keycode| {
                if (keycode == prev_key) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                self.handleKeyEvent(.KeyRelease, false);
                Basics.debug.print("HID Keyboard: Key released: 0x{x}\n", .{prev_key});
            }
        }

        self.prev_report = report.*;
    }

    const KeyEvent = enum {
        LeftCtrl,
        LeftShift,
        LeftAlt,
        LeftGui,
        KeyPress,
        KeyRelease,
    };

    fn handleKeyEvent(self: *KeyboardHandler, event: KeyEvent, pressed: bool) void {
        _ = self;
        _ = event;
        _ = pressed;
        // TODO: Send input event to input subsystem
    }
};

// ============================================================================
// Mouse Support
// ============================================================================

/// Mouse button flags
pub const MouseButtons = packed struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    button4: bool = false,
    button5: bool = false,
    _reserved: u3 = 0,

    pub fn toU8(self: MouseButtons) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(value: u8) MouseButtons {
        return @bitCast(value);
    }
};

/// Standard boot protocol mouse report
pub const MouseReport = packed struct {
    /// Button state
    buttons: MouseButtons,
    /// X movement (relative)
    x: i8,
    /// Y movement (relative)
    y: i8,
    /// Wheel movement (optional)
    wheel: i8,

    pub fn init() MouseReport {
        return .{
            .buttons = @bitCast(@as(u8, 0)),
            .x = 0,
            .y = 0,
            .wheel = 0,
        };
    }
};

/// Mouse HID handler
pub const MouseHandler = struct {
    /// Previous report for change detection
    prev_report: MouseReport,
    /// Accumulated X position
    pos_x: i32,
    /// Accumulated Y position
    pos_y: i32,

    pub fn init() MouseHandler {
        return .{
            .prev_report = MouseReport.init(),
            .pos_x = 0,
            .pos_y = 0,
        };
    }

    /// Handle mouse input report
    pub fn handleReport(self: *MouseHandler, data: []const u8) !void {
        if (data.len < 3) {
            return error.InvalidReportSize;
        }

        const report: *const MouseReport = @ptrCast(@alignCast(data.ptr));

        // Handle button changes
        const prev_btns = self.prev_report.buttons;
        const curr_btns = report.buttons;

        if (prev_btns.left != curr_btns.left) {
            Basics.debug.print("HID Mouse: Left button {s}\n", .{if (curr_btns.left) "pressed" else "released"});
            self.handleMouseButton(.Left, curr_btns.left);
        }
        if (prev_btns.right != curr_btns.right) {
            Basics.debug.print("HID Mouse: Right button {s}\n", .{if (curr_btns.right) "pressed" else "released"});
            self.handleMouseButton(.Right, curr_btns.right);
        }
        if (prev_btns.middle != curr_btns.middle) {
            Basics.debug.print("HID Mouse: Middle button {s}\n", .{if (curr_btns.middle) "pressed" else "released"});
            self.handleMouseButton(.Middle, curr_btns.middle);
        }

        // Handle movement
        if (report.x != 0 or report.y != 0) {
            self.pos_x += report.x;
            self.pos_y += report.y;
            Basics.debug.print("HID Mouse: Movement dx={}, dy={} (pos: {}, {})\n", .{ report.x, report.y, self.pos_x, self.pos_y });
            self.handleMouseMove(report.x, report.y);
        }

        // Handle wheel
        if (data.len >= 4 and report.wheel != 0) {
            Basics.debug.print("HID Mouse: Wheel {}\n", .{report.wheel});
            self.handleMouseWheel(report.wheel);
        }

        self.prev_report = report.*;
    }

    const MouseButton = enum {
        Left,
        Right,
        Middle,
    };

    fn handleMouseButton(self: *MouseHandler, button: MouseButton, pressed: bool) void {
        _ = self;
        _ = button;
        _ = pressed;
        // TODO: Send input event to input subsystem
    }

    fn handleMouseMove(self: *MouseHandler, dx: i8, dy: i8) void {
        _ = self;
        _ = dx;
        _ = dy;
        // TODO: Send mouse move event to input subsystem
    }

    fn handleMouseWheel(self: *MouseHandler, delta: i8) void {
        _ = self;
        _ = delta;
        // TODO: Send mouse wheel event to input subsystem
    }
};

// ============================================================================
// Gamepad Support
// ============================================================================

/// Gamepad button flags
pub const GamepadButtons = packed struct(u16) {
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    left_bumper: bool = false,
    right_bumper: bool = false,
    back: bool = false,
    start: bool = false,
    left_stick: bool = false,
    right_stick: bool = false,
    dpad_up: bool = false,
    dpad_down: bool = false,
    dpad_left: bool = false,
    dpad_right: bool = false,
    _reserved: u2 = 0,
};

/// Gamepad report (typical Xbox-style controller)
pub const GamepadReport = struct {
    /// Button state
    buttons: GamepadButtons,
    /// Left stick X (-32768 to 32767)
    left_x: i16,
    /// Left stick Y (-32768 to 32767)
    left_y: i16,
    /// Right stick X (-32768 to 32767)
    right_x: i16,
    /// Right stick Y (-32768 to 32767)
    right_y: i16,
    /// Left trigger (0-255)
    left_trigger: u8,
    /// Right trigger (0-255)
    right_trigger: u8,

    pub fn init() GamepadReport {
        return Basics.mem.zeroes(GamepadReport);
    }
};

/// Gamepad HID handler
pub const GamepadHandler = struct {
    /// Previous report for change detection
    prev_report: GamepadReport,

    pub fn init() GamepadHandler {
        return .{
            .prev_report = GamepadReport.init(),
        };
    }

    /// Handle gamepad input report
    pub fn handleReport(self: *GamepadHandler, data: []const u8) !void {
        if (data.len < @sizeOf(GamepadReport)) {
            return error.InvalidReportSize;
        }

        const report: *const GamepadReport = @ptrCast(@alignCast(data.ptr));

        // Handle button changes
        const prev_btns = @as(u16, @bitCast(self.prev_report.buttons));
        const curr_btns = @as(u16, @bitCast(report.buttons));

        if (prev_btns != curr_btns) {
            Basics.debug.print("HID Gamepad: Buttons changed: 0x{x}\n", .{curr_btns});
        }

        // Handle analog stick movements
        if (report.left_x != self.prev_report.left_x or report.left_y != self.prev_report.left_y) {
            Basics.debug.print("HID Gamepad: Left stick ({}, {})\n", .{ report.left_x, report.left_y });
        }

        if (report.right_x != self.prev_report.right_x or report.right_y != self.prev_report.right_y) {
            Basics.debug.print("HID Gamepad: Right stick ({}, {})\n", .{ report.right_x, report.right_y });
        }

        // Handle triggers
        if (report.left_trigger != self.prev_report.left_trigger) {
            Basics.debug.print("HID Gamepad: Left trigger {}\n", .{report.left_trigger});
        }

        if (report.right_trigger != self.prev_report.right_trigger) {
            Basics.debug.print("HID Gamepad: Right trigger {}\n", .{report.right_trigger});
        }

        self.prev_report = report.*;
    }
};

// ============================================================================
// Generic HID Device
// ============================================================================

/// HID Device
pub const HidDevice = struct {
    /// Device type (keyboard, mouse, etc.)
    device_type: DeviceType,
    /// Input report size
    input_report_size: usize,
    /// Output report size
    output_report_size: usize,
    /// Protocol (boot or report)
    protocol: HidProtocol,
    /// Allocator
    allocator: Basics.Allocator,

    /// Type-specific handlers
    keyboard: ?KeyboardHandler,
    mouse: ?MouseHandler,
    gamepad: ?GamepadHandler,

    pub const DeviceType = enum {
        Keyboard,
        Mouse,
        Joystick,
        Gamepad,
        Generic,
    };

    /// Initialize HID device
    pub fn init(allocator: Basics.Allocator, descriptor: *const HidDescriptor, device_type: DeviceType) !*HidDevice {
        const device = try allocator.create(HidDevice);
        errdefer allocator.destroy(device);

        device.* = .{
            .device_type = device_type,
            .input_report_size = descriptor.descriptor_length,
            .output_report_size = 0,
            .protocol = .Report,
            .allocator = allocator,
            .keyboard = null,
            .mouse = null,
            .gamepad = null,
        };

        // Initialize type-specific handler
        switch (device_type) {
            .Keyboard => device.keyboard = KeyboardHandler.init(),
            .Mouse => device.mouse = MouseHandler.init(),
            .Gamepad => device.gamepad = GamepadHandler.init(),
            else => {},
        }

        return device;
    }

    pub fn deinit(self: *HidDevice) void {
        self.allocator.destroy(self);
    }

    /// Process HID input report
    pub fn processReport(self: *HidDevice, data: []const u8) !void {
        switch (self.device_type) {
            .Keyboard => {
                if (self.keyboard) |*kb| {
                    try kb.handleReport(data);
                }
            },
            .Mouse => {
                if (self.mouse) |*mouse| {
                    try mouse.handleReport(data);
                }
            },
            .Gamepad => {
                if (self.gamepad) |*gamepad| {
                    try gamepad.handleReport(data);
                }
            },
            else => {
                Basics.debug.print("HID: Unsupported device type\n", .{});
            },
        }
    }

    /// Set HID protocol (boot or report)
    pub fn setProtocol(self: *HidDevice, protocol: HidProtocol) void {
        self.protocol = protocol;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hid - keyboard report" {
    const testing = Basics.testing;

    var kb = KeyboardHandler.init();

    // Simulate a key press (A key with left shift)
    var report = KeyboardReport.init();
    report.modifiers.left_shift = true;
    report.keycodes[0] = @intFromEnum(KeyCode.A);

    const data = Basics.mem.asBytes(&report);
    try kb.handleReport(data);

    // Verify we captured the report
    try testing.expect(kb.prev_report.modifiers.left_shift);
    try testing.expectEqual(@as(u8, @intFromEnum(KeyCode.A)), kb.prev_report.keycodes[0]);
}

test "hid - mouse report" {
    const testing = Basics.testing;

    var mouse = MouseHandler.init();

    // Simulate mouse movement with left button
    var report = MouseReport.init();
    report.buttons.left = true;
    report.x = 10;
    report.y = -5;
    report.wheel = 1;

    const data = Basics.mem.asBytes(&report);
    try mouse.handleReport(data);

    // Verify position updated
    try testing.expectEqual(@as(i32, 10), mouse.pos_x);
    try testing.expectEqual(@as(i32, -5), mouse.pos_y);
    try testing.expect(mouse.prev_report.buttons.left);
}

test "hid - gamepad report" {
    const testing = Basics.testing;

    var gamepad = GamepadHandler.init();

    // Simulate gamepad input
    var report = GamepadReport.init();
    report.buttons.a = true;
    report.left_x = 16384; // Half right
    report.left_y = -16384; // Half up

    const data = Basics.mem.asBytes(&report);
    try gamepad.handleReport(data);

    // Verify we captured the report
    try testing.expect(gamepad.prev_report.buttons.a);
    try testing.expectEqual(@as(i16, 16384), gamepad.prev_report.left_x);
}

test "hid - device init" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    var desc = HidDescriptor{
        .bcd_hid = 0x0111,
        .country_code = 0,
        .num_descriptors = 1,
        .descriptor_type = 0x22,
        .descriptor_length = 63,
    };

    var device = try HidDevice.init(allocator, &desc, .Keyboard);
    defer device.deinit();

    try testing.expectEqual(HidDevice.DeviceType.Keyboard, device.device_type);
    try testing.expect(device.keyboard != null);
}
