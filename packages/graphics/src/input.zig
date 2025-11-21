// Home Programming Language - Input System
// Cross-platform keyboard and mouse input handling
//
// This module provides a unified input interface across platforms

const std = @import("std");
const cocoa = @import("cocoa");

// ============================================================================
// Input Types
// ============================================================================

pub const KeyCode = enum(u16) {
    // Letters
    A = 0,
    B = 11,
    C = 8,
    D = 2,
    E = 14,
    F = 3,
    G = 5,
    H = 4,
    I = 34,
    J = 38,
    K = 40,
    L = 37,
    M = 46,
    N = 45,
    O = 31,
    P = 35,
    Q = 12,
    R = 15,
    S = 1,
    T = 17,
    U = 32,
    V = 9,
    W = 13,
    X = 7,
    Y = 16,
    Z = 6,

    // Numbers
    Num0 = 29,
    Num1 = 18,
    Num2 = 19,
    Num3 = 20,
    Num4 = 21,
    Num5 = 23,
    Num6 = 22,
    Num7 = 26,
    Num8 = 28,
    Num9 = 25,

    // Function keys
    F1 = 122,
    F2 = 120,
    F3 = 99,
    F4 = 118,
    F5 = 96,
    F6 = 97,
    F7 = 98,
    F8 = 100,
    F9 = 101,
    F10 = 109,
    F11 = 103,
    F12 = 111,

    // Special keys
    Escape = 53,
    Return = 36,
    Tab = 48,
    Space = 49,
    Delete = 51, // macOS delete key (backspace) - value 51
    // Note: Backspace is same as Delete on macOS

    // Arrow keys
    LeftArrow = 123,
    RightArrow = 124,
    DownArrow = 125,
    UpArrow = 126,

    // Modifiers
    LeftShift = 56,
    RightShift = 60,
    LeftControl = 59,
    RightControl = 62,
    LeftAlt = 58,
    RightAlt = 61,
    LeftCommand = 55,
    RightCommand = 54,

    // Other
    CapsLock = 57,
    Equal = 24,
    Minus = 27,
    LeftBracket = 33,
    RightBracket = 30,
    Backslash = 42,
    Semicolon = 41,
    Quote = 39,
    Comma = 43,
    Period = 47,
    Slash = 44,
    Grave = 50,

    Unknown = 0xFFFF,

    pub fn fromMacOS(vk_code: u16) KeyCode {
        return @enumFromInt(vk_code);
    }
};

pub const MouseButton = enum(u8) {
    Left = 0,
    Right = 1,
    Middle = 2,
    Button4 = 3,
    Button5 = 4,
};

pub const ModifierKeys = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
    caps_lock: bool = false,
    _padding: u3 = 0,
};

pub const InputEvent = union(enum) {
    KeyDown: struct {
        key: KeyCode,
        modifiers: ModifierKeys,
        repeat: bool,
    },
    KeyUp: struct {
        key: KeyCode,
        modifiers: ModifierKeys,
    },
    MouseDown: struct {
        button: MouseButton,
        x: f32,
        y: f32,
        modifiers: ModifierKeys,
    },
    MouseUp: struct {
        button: MouseButton,
        x: f32,
        y: f32,
        modifiers: ModifierKeys,
    },
    MouseMove: struct {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
    },
    MouseScroll: struct {
        dx: f32,
        dy: f32,
    },
};

// ============================================================================
// Input State
// ============================================================================

pub const InputState = struct {
    keys_down: [256]bool,
    keys_pressed: [256]bool, // Just pressed this frame
    keys_released: [256]bool, // Just released this frame

    mouse_buttons_down: [5]bool,
    mouse_buttons_pressed: [5]bool,
    mouse_buttons_released: [5]bool,

    mouse_x: f32,
    mouse_y: f32,
    mouse_dx: f32,
    mouse_dy: f32,
    mouse_scroll_x: f32,
    mouse_scroll_y: f32,

    modifiers: ModifierKeys,

    allocator: std.mem.Allocator,
    events: std.ArrayList(InputEvent),

    pub fn init(allocator: std.mem.Allocator) InputState {
        return InputState{
            .keys_down = [_]bool{false} ** 256,
            .keys_pressed = [_]bool{false} ** 256,
            .keys_released = [_]bool{false} ** 256,
            .mouse_buttons_down = [_]bool{false} ** 5,
            .mouse_buttons_pressed = [_]bool{false} ** 5,
            .mouse_buttons_released = [_]bool{false} ** 5,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_dx = 0,
            .mouse_dy = 0,
            .mouse_scroll_x = 0,
            .mouse_scroll_y = 0,
            .modifiers = ModifierKeys{},
            .allocator = allocator,
            .events = .{},
        };
    }

    pub fn deinit(self: *InputState) void {
        self.events.deinit(self.allocator);
    }

    /// Call this at the start of each frame
    pub fn beginFrame(self: *InputState) void {
        // Clear per-frame state
        @memset(&self.keys_pressed, false);
        @memset(&self.keys_released, false);
        @memset(&self.mouse_buttons_pressed, false);
        @memset(&self.mouse_buttons_released, false);
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.mouse_scroll_x = 0;
        self.mouse_scroll_y = 0;
        self.events.clearRetainingCapacity();
    }

    /// Process an input event
    pub fn processEvent(self: *InputState, event: InputEvent) !void {
        try self.events.append(self.allocator, event);

        switch (event) {
            .KeyDown => |key_event| {
                const key_index = @intFromEnum(key_event.key);
                if (key_index < 256) {
                    if (!self.keys_down[key_index]) {
                        self.keys_pressed[key_index] = true;
                    }
                    self.keys_down[key_index] = true;
                }
                self.modifiers = key_event.modifiers;
            },
            .KeyUp => |key_event| {
                const key_index = @intFromEnum(key_event.key);
                if (key_index < 256) {
                    self.keys_released[key_index] = true;
                    self.keys_down[key_index] = false;
                }
                self.modifiers = key_event.modifiers;
            },
            .MouseDown => |mouse_event| {
                const button_index = @intFromEnum(mouse_event.button);
                if (button_index < 5) {
                    self.mouse_buttons_pressed[button_index] = true;
                    self.mouse_buttons_down[button_index] = true;
                }
                self.mouse_x = mouse_event.x;
                self.mouse_y = mouse_event.y;
                self.modifiers = mouse_event.modifiers;
            },
            .MouseUp => |mouse_event| {
                const button_index = @intFromEnum(mouse_event.button);
                if (button_index < 5) {
                    self.mouse_buttons_released[button_index] = true;
                    self.mouse_buttons_down[button_index] = false;
                }
                self.mouse_x = mouse_event.x;
                self.mouse_y = mouse_event.y;
                self.modifiers = mouse_event.modifiers;
            },
            .MouseMove => |mouse_event| {
                self.mouse_dx += mouse_event.dx;
                self.mouse_dy += mouse_event.dy;
                self.mouse_x = mouse_event.x;
                self.mouse_y = mouse_event.y;
            },
            .MouseScroll => |scroll_event| {
                self.mouse_scroll_x += scroll_event.dx;
                self.mouse_scroll_y += scroll_event.dy;
            },
        }
    }

    // Query functions
    pub fn isKeyDown(self: *const InputState, key: KeyCode) bool {
        const key_index = @intFromEnum(key);
        return if (key_index < 256) self.keys_down[key_index] else false;
    }

    pub fn isKeyPressed(self: *const InputState, key: KeyCode) bool {
        const key_index = @intFromEnum(key);
        return if (key_index < 256) self.keys_pressed[key_index] else false;
    }

    pub fn isKeyReleased(self: *const InputState, key: KeyCode) bool {
        const key_index = @intFromEnum(key);
        return if (key_index < 256) self.keys_released[key_index] else false;
    }

    pub fn isMouseButtonDown(self: *const InputState, button: MouseButton) bool {
        const button_index = @intFromEnum(button);
        return if (button_index < 5) self.mouse_buttons_down[button_index] else false;
    }

    pub fn isMouseButtonPressed(self: *const InputState, button: MouseButton) bool {
        const button_index = @intFromEnum(button);
        return if (button_index < 5) self.mouse_buttons_pressed[button_index] else false;
    }

    pub fn isMouseButtonReleased(self: *const InputState, button: MouseButton) bool {
        const button_index = @intFromEnum(button);
        return if (button_index < 5) self.mouse_buttons_released[button_index] else false;
    }

    pub fn getMousePosition(self: *const InputState) struct { x: f32, y: f32 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    pub fn getMouseDelta(self: *const InputState) struct { dx: f32, dy: f32 } {
        return .{ .dx = self.mouse_dx, .dy = self.mouse_dy };
    }

    pub fn getMouseScroll(self: *const InputState) struct { dx: f32, dy: f32 } {
        return .{ .dx = self.mouse_scroll_x, .dy = self.mouse_scroll_y };
    }

    pub fn getModifiers(self: *const InputState) ModifierKeys {
        return self.modifiers;
    }
};

// ============================================================================
// Platform-specific event conversion
// ============================================================================

pub fn convertMacOSEvent(ns_event: cocoa.id, window_height: f32) ?InputEvent {
    const event_type = cocoa.eventType(ns_event);

    switch (event_type) {
        .KeyDown => {
            const key_code = cocoa.keyCode(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .KeyDown = .{
                    .key = KeyCode.fromMacOS(key_code),
                    .modifiers = convertModifiers(modifiers),
                    .repeat = false, // TODO: detect key repeat
                },
            };
        },
        .KeyUp => {
            const key_code = cocoa.keyCode(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .KeyUp = .{
                    .key = KeyCode.fromMacOS(key_code),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .LeftMouseDown => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseDown = .{
                    .button = .Left,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y), // Flip Y coordinate
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .LeftMouseUp => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseUp = .{
                    .button = .Left,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .RightMouseDown => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseDown = .{
                    .button = .Right,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .RightMouseUp => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseUp = .{
                    .button = .Right,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .OtherMouseDown => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseDown = .{
                    .button = .Middle,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .OtherMouseUp => {
            const location = cocoa.mouseLocation(ns_event);
            const modifiers = cocoa.modifierFlags(ns_event);

            return InputEvent{
                .MouseUp = .{
                    .button = .Middle,
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .modifiers = convertModifiers(modifiers),
                },
            };
        },
        .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged => {
            const location = cocoa.mouseLocation(ns_event);

            // TODO: Track previous position to calculate delta
            return InputEvent{
                .MouseMove = .{
                    .x = @floatCast(location.x),
                    .y = @floatCast(window_height - location.y),
                    .dx = 0, // TODO: Calculate delta
                    .dy = 0,
                },
            };
        },
        .ScrollWheel => {
            // TODO: Get scroll delta from event
            return InputEvent{
                .MouseScroll = .{
                    .dx = 0,
                    .dy = 0,
                },
            };
        },
        else => {
            return null;
        },
    }
}

fn convertModifiers(ns_modifiers: cocoa.NSEventModifierFlags) ModifierKeys {
    return ModifierKeys{
        .shift = ns_modifiers.shift,
        .control = ns_modifiers.control,
        .alt = ns_modifiers.option,
        .command = ns_modifiers.command,
        .caps_lock = ns_modifiers.caps_lock,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "InputState initialization" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = InputState.init(allocator);
    defer input.deinit();

    // Check initial state
    try testing.expect(!input.isKeyDown(.W));
    try testing.expect(!input.isMouseButtonDown(.Left));
}

test "KeyCode conversion" {
    const testing = std.testing;

    // Test letter key conversion
    const key = KeyCode.fromMacOS(13); // W key on macOS
    try testing.expectEqual(KeyCode.W, key);
}

test "Input event processing" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input = InputState.init(allocator);
    defer input.deinit();

    input.beginFrame();

    // Simulate key press
    const key_down_event = InputEvent{
        .KeyDown = .{
            .key = .W,
            .modifiers = ModifierKeys{},
            .repeat = false,
        },
    };

    try input.processEvent(key_down_event);

    // Check state
    try testing.expect(input.isKeyDown(.W));
    try testing.expect(input.isKeyPressed(.W));
    try testing.expect(!input.isKeyReleased(.W));

    // Next frame
    input.beginFrame();
    try testing.expect(input.isKeyDown(.W));
    try testing.expect(!input.isKeyPressed(.W)); // Only true for first frame
}
