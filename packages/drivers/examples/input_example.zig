// Example: Input Device Drivers

const std = @import("std");
const drivers = @import("drivers");

pub fn main() !void {
    std.debug.print("=== Input Device Example ===\n\n", .{});

    // Keyboard information
    std.debug.print("PS/2 Keyboard:\n", .{});
    std.debug.print("  Data Port: 0x60\n", .{});
    std.debug.print("  Status Port: 0x64\n", .{});
    std.debug.print("  Command Port: 0x64\n\n", .{});

    // Key code examples
    std.debug.print("Key Codes:\n", .{});
    const keys = [_]struct { name: []const u8, code: drivers.input.KeyCode }{
        .{ .name = "A", .code = .a },
        .{ .name = "Enter", .code = .enter },
        .{ .name = "Space", .code = .space },
        .{ .name = "Escape", .code = .escape },
        .{ .name = "F1", .code = .f1 },
        .{ .name = "Arrow Up", .code = .up },
    };

    for (keys) |key| {
        std.debug.print("  {s}: 0x{X:0>2}\n", .{ key.name, @intFromEnum(key.code) });
    }

    // Keyboard simulation
    std.debug.print("\nKeyboard Simulation:\n", .{});
    var keyboard = drivers.input.PS2Keyboard.init();

    // Simulate key events
    std.debug.print("  Simulated key press: 'A'\n", .{});
    var mods = drivers.input.KeyModifiers{};
    const event_a = drivers.input.KeyEvent{
        .code = .a,
        .scancode = 0x1E,
        .modifiers = mods,
        .character = 'a',
    };
    std.debug.print("    Code: {s}, Scancode: 0x{X:0>2}, Char: '{c}'\n", .{
        @tagName(event_a.code),
        event_a.scancode,
        event_a.character.?,
    });

    std.debug.print("  Simulated key press: 'A' with Shift\n", .{});
    mods.shift = true;
    const event_A = drivers.input.KeyEvent{
        .code = .a,
        .scancode = 0x1E,
        .modifiers = mods,
        .character = 'A',
    };
    std.debug.print("    Code: {s}, Scancode: 0x{X:0>2}, Char: '{c}', Shift: {}\n", .{
        @tagName(event_A.code),
        event_A.scancode,
        event_A.character.?,
        event_A.modifiers.shift,
    });

    // Mouse information
    std.debug.print("\nPS/2 Mouse:\n", .{});
    std.debug.print("  Data Port: 0x60\n", .{});
    std.debug.print("  Status Port: 0x64\n", .{});
    std.debug.print("  3-byte packet protocol\n\n", .{});

    // Mouse simulation
    std.debug.print("Mouse Simulation:\n", .{});
    var mouse = drivers.input.PS2Mouse.init();

    // Simulate mouse movement
    std.debug.print("  Simulated mouse move: dx=10, dy=-5\n", .{});
    const move_event = drivers.input.InputEvent{
        .mouse_move = drivers.input.MouseMoveEvent{
            .x = 100,
            .y = 200,
            .dx = 10,
            .dy = -5,
        },
    };
    std.debug.print("    Position: ({d}, {d})\n", .{
        move_event.mouse_move.x,
        move_event.mouse_move.y,
    });

    // Simulate button press
    std.debug.print("  Simulated mouse button press: Left\n", .{});
    const button_event = drivers.input.InputEvent{
        .mouse_button_press = drivers.input.MouseButtonEvent{
            .button = .left,
            .x = 100,
            .y = 200,
        },
    };
    std.debug.print("    Button: {s}, Position: ({d}, {d})\n", .{
        @tagName(button_event.mouse_button_press.button),
        button_event.mouse_button_press.x,
        button_event.mouse_button_press.y,
    });

    // Event queue
    std.debug.print("\nInput Event Queue:\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var event_queue = drivers.input.InputEventQueue.init(allocator);
    defer event_queue.deinit();

    try event_queue.push(move_event);
    try event_queue.push(button_event);

    std.debug.print("  Queued 2 events\n", .{});

    var count: usize = 0;
    while (event_queue.pop()) |event| {
        count += 1;
        std.debug.print("  Event {d}: {s}\n", .{ count, @tagName(event) });
    }

    std.debug.print("\nInput driver API demonstration complete!\n", .{});
    std.debug.print("Note: Actual hardware interaction requires kernel mode\n", .{});
}
