// Home Language - Input Module
// Keyboard and mouse input handling

const std = @import("std");

pub const Key = enum {
    A, B, C, D, E, F, G, H, I, J, K, L, M,
    N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7, Num8, Num9,
    Space, Enter, Escape, Tab, Backspace,
    Up, Down, Left, Right,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Shift, Control, Alt,
};

pub const MouseButton = enum {
    Left,
    Right,
    Middle,
};

pub const InputState = struct {
    keys: [256]bool = [_]bool{false} ** 256,
    mouse_buttons: [3]bool = [_]bool{false} ** 3,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_delta_x: i32 = 0,
    mouse_delta_y: i32 = 0,

    pub fn init() InputState {
        return InputState{};
    }

    pub fn isKeyPressed(self: *const InputState, key: Key) bool {
        const index = @intFromEnum(key);
        if (index >= self.keys.len) return false;
        return self.keys[index];
    }

    pub fn isMouseButtonPressed(self: *const InputState, button: MouseButton) bool {
        const index = @intFromEnum(button);
        return self.mouse_buttons[index];
    }

    pub fn getMousePosition(self: *const InputState) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    pub fn getMouseDelta(self: *const InputState) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_delta_x, .y = self.mouse_delta_y };
    }
};
