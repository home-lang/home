// Home OS - Input Device Support
// Keyboard and mouse drivers with event handling

const std = @import("std");
const drivers = @import("drivers.zig");

// ============================================================================
// Input Event Types
// ============================================================================

pub const InputEventType = enum {
    key_press,
    key_release,
    mouse_move,
    mouse_button_press,
    mouse_button_release,
    mouse_scroll,
};

pub const InputEvent = union(InputEventType) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    mouse_move: MouseMoveEvent,
    mouse_button_press: MouseButtonEvent,
    mouse_button_release: MouseButtonEvent,
    mouse_scroll: MouseScrollEvent,
};

// ============================================================================
// Keyboard Support
// ============================================================================

pub const KeyCode = enum(u8) {
    // Letters
    a = 0x1E,
    b = 0x30,
    c = 0x2E,
    d = 0x20,
    e = 0x12,
    f = 0x21,
    g = 0x22,
    h = 0x23,
    i = 0x17,
    j = 0x24,
    k = 0x25,
    l = 0x26,
    m = 0x32,
    n = 0x31,
    o = 0x18,
    p = 0x19,
    q = 0x10,
    r = 0x13,
    s = 0x1F,
    t = 0x14,
    u = 0x16,
    v = 0x2F,
    w = 0x11,
    x = 0x2D,
    y = 0x15,
    z = 0x2C,

    // Numbers
    num_0 = 0x0B,
    num_1 = 0x02,
    num_2 = 0x03,
    num_3 = 0x04,
    num_4 = 0x05,
    num_5 = 0x06,
    num_6 = 0x07,
    num_7 = 0x08,
    num_8 = 0x09,
    num_9 = 0x0A,

    // Function keys
    f1 = 0x3B,
    f2 = 0x3C,
    f3 = 0x3D,
    f4 = 0x3E,
    f5 = 0x3F,
    f6 = 0x40,
    f7 = 0x41,
    f8 = 0x42,
    f9 = 0x43,
    f10 = 0x44,
    f11 = 0x57,
    f12 = 0x58,

    // Special keys
    escape = 0x01,
    backspace = 0x0E,
    tab = 0x0F,
    enter = 0x1C,
    space = 0x39,
    left_ctrl = 0x1D,
    left_shift = 0x2A,
    right_shift = 0x36,
    left_alt = 0x38,
    caps_lock = 0x3A,

    // Navigation
    up = 0x48,
    down = 0x50,
    left = 0x4B,
    right = 0x4D,
    page_up = 0x49,
    page_down = 0x51,
    home = 0x47,
    end = 0x4F,
    insert = 0x52,
    delete = 0x53,

    _,
};

pub const KeyModifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    scroll_lock: bool = false,
    reserved: u1 = 0,
};

pub const KeyEvent = struct {
    code: KeyCode,
    scancode: u8,
    modifiers: KeyModifiers,
    character: ?u8,
};

// ============================================================================
// PS/2 Keyboard Driver
// ============================================================================

pub const PS2Keyboard = struct {
    data_port: u16 = 0x60,
    status_port: u16 = 0x64,
    command_port: u16 = 0x64,
    modifiers: KeyModifiers = .{},
    event_handler: ?*const fn (event: KeyEvent) void = null,

    pub const ScanCodeSet = enum {
        set1,
        set2,
        set3,
    };

    pub fn init() PS2Keyboard {
        return .{};
    }

    pub fn readScancode(self: *PS2Keyboard) ?u8 {
        // Check if data is available
        const status = self.inb(self.status_port);
        if ((status & 0x01) == 0) return null;

        return self.inb(self.data_port);
    }

    pub fn handleIRQ(self: *PS2Keyboard) void {
        const scancode = self.readScancode() orelse return;

        // Check if this is a release event (bit 7 set)
        const released = (scancode & 0x80) != 0;
        const code: KeyCode = @enumFromInt(scancode & 0x7F);

        // Update modifiers
        self.updateModifiers(code, !released);

        const event = KeyEvent{
            .code = code,
            .scancode = scancode & 0x7F,
            .modifiers = self.modifiers,
            .character = self.scancodeToChar(code),
        };

        if (self.event_handler) |handler| {
            handler(event);
        }
    }

    fn updateModifiers(self: *PS2Keyboard, code: KeyCode, pressed: bool) void {
        switch (code) {
            .left_shift, .right_shift => self.modifiers.shift = pressed,
            .left_ctrl => self.modifiers.ctrl = pressed,
            .left_alt => self.modifiers.alt = pressed,
            .caps_lock => {
                if (pressed) {
                    self.modifiers.caps_lock = !self.modifiers.caps_lock;
                }
            },
            else => {},
        }
    }

    fn scancodeToChar(self: *PS2Keyboard, code: KeyCode) ?u8 {
        const shift = self.modifiers.shift;
        const caps = self.modifiers.caps_lock;

        return switch (code) {
            // Letters
            .a => if (shift != caps) 'A' else 'a',
            .b => if (shift != caps) 'B' else 'b',
            .c => if (shift != caps) 'C' else 'c',
            .d => if (shift != caps) 'D' else 'd',
            .e => if (shift != caps) 'E' else 'e',
            .f => if (shift != caps) 'F' else 'f',
            .g => if (shift != caps) 'G' else 'g',
            .h => if (shift != caps) 'H' else 'h',
            .i => if (shift != caps) 'I' else 'i',
            .j => if (shift != caps) 'J' else 'j',
            .k => if (shift != caps) 'K' else 'k',
            .l => if (shift != caps) 'L' else 'l',
            .m => if (shift != caps) 'M' else 'm',
            .n => if (shift != caps) 'N' else 'n',
            .o => if (shift != caps) 'O' else 'o',
            .p => if (shift != caps) 'P' else 'p',
            .q => if (shift != caps) 'Q' else 'q',
            .r => if (shift != caps) 'R' else 'r',
            .s => if (shift != caps) 'S' else 's',
            .t => if (shift != caps) 'T' else 't',
            .u => if (shift != caps) 'U' else 'u',
            .v => if (shift != caps) 'V' else 'v',
            .w => if (shift != caps) 'W' else 'w',
            .x => if (shift != caps) 'X' else 'x',
            .y => if (shift != caps) 'Y' else 'y',
            .z => if (shift != caps) 'Z' else 'z',

            // Numbers
            .num_0 => if (shift) ')' else '0',
            .num_1 => if (shift) '!' else '1',
            .num_2 => if (shift) '@' else '2',
            .num_3 => if (shift) '#' else '3',
            .num_4 => if (shift) '$' else '4',
            .num_5 => if (shift) '%' else '5',
            .num_6 => if (shift) '^' else '6',
            .num_7 => if (shift) '&' else '7',
            .num_8 => if (shift) '*' else '8',
            .num_9 => if (shift) '(' else '9',

            // Special
            .space => ' ',
            .enter => '\n',
            .tab => '\t',
            .backspace => 0x08,

            else => null,
        };
    }

    inline fn inb(self: *PS2Keyboard, port: u16) u8 {
        _ = self;
        return asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "N{dx}" (port),
        );
    }

    inline fn outb(self: *PS2Keyboard, port: u16, value: u8) void {
        _ = self;
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        );
    }
};

// ============================================================================
// Mouse Support
// ============================================================================

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    button4 = 3,
    button5 = 4,
};

pub const MouseMoveEvent = struct {
    x: i32,
    y: i32,
    dx: i16,
    dy: i16,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    x: i32,
    y: i32,
};

pub const MouseScrollEvent = struct {
    dx: i8,
    dy: i8,
};

// ============================================================================
// PS/2 Mouse Driver
// ============================================================================

pub const PS2Mouse = struct {
    data_port: u16 = 0x60,
    status_port: u16 = 0x64,
    command_port: u16 = 0x64,
    x: i32 = 0,
    y: i32 = 0,
    buttons: u8 = 0,
    packet: [4]u8 = undefined,
    packet_index: u8 = 0,
    event_handler: ?*const fn (event: InputEvent) void = null,

    pub fn init() PS2Mouse {
        return .{};
    }

    pub fn enable(self: *PS2Mouse) void {
        // Enable auxiliary device
        self.waitWrite();
        self.outb(self.command_port, 0xA8);

        // Enable interrupts
        self.waitWrite();
        self.outb(self.command_port, 0x20);
        self.waitRead();
        var status = self.inb(self.data_port);
        status |= 0x02; // Enable IRQ12
        self.waitWrite();
        self.outb(self.command_port, 0x60);
        self.waitWrite();
        self.outb(self.data_port, status);

        // Set defaults
        self.sendCommand(0xF6);

        // Enable data reporting
        self.sendCommand(0xF4);
    }

    pub fn handleIRQ(self: *PS2Mouse) void {
        const byte = self.inb(self.data_port);
        self.packet[self.packet_index] = byte;
        self.packet_index += 1;

        if (self.packet_index >= 3) {
            self.processPacket();
            self.packet_index = 0;
        }
    }

    fn processPacket(self: *PS2Mouse) void {
        const flags = self.packet[0];
        const dx: i16 = @bitCast(@as(u16, self.packet[1]));
        const dy: i16 = @bitCast(@as(u16, self.packet[2]));

        // Update position
        self.x += dx;
        self.y -= dy; // Y is inverted

        // Update buttons
        const old_buttons = self.buttons;
        self.buttons = flags & 0x07;

        // Generate move event
        if (dx != 0 or dy != 0) {
            const move_event = InputEvent{
                .mouse_move = MouseMoveEvent{
                    .x = self.x,
                    .y = self.y,
                    .dx = dx,
                    .dy = -dy,
                },
            };

            if (self.event_handler) |handler| {
                handler(move_event);
            }
        }

        // Generate button events
        for (0..3) |i| {
            const button_bit: u8 = @intCast(1 << i);
            const button: MouseButton = @enumFromInt(i);

            // Button press
            if ((self.buttons & button_bit) != 0 and (old_buttons & button_bit) == 0) {
                const press_event = InputEvent{
                    .mouse_button_press = MouseButtonEvent{
                        .button = button,
                        .x = self.x,
                        .y = self.y,
                    },
                };

                if (self.event_handler) |handler| {
                    handler(press_event);
                }
            }

            // Button release
            if ((self.buttons & button_bit) == 0 and (old_buttons & button_bit) != 0) {
                const release_event = InputEvent{
                    .mouse_button_release = MouseButtonEvent{
                        .button = button,
                        .x = self.x,
                        .y = self.y,
                    },
                };

                if (self.event_handler) |handler| {
                    handler(release_event);
                }
            }
        }
    }

    fn sendCommand(self: *PS2Mouse, command: u8) void {
        self.waitWrite();
        self.outb(self.command_port, 0xD4);
        self.waitWrite();
        self.outb(self.data_port, command);
        self.waitRead();
        _ = self.inb(self.data_port); // ACK
    }

    fn waitWrite(self: *PS2Mouse) void {
        while ((self.inb(self.status_port) & 0x02) != 0) {
            asm volatile ("pause");
        }
    }

    fn waitRead(self: *PS2Mouse) void {
        while ((self.inb(self.status_port) & 0x01) == 0) {
            asm volatile ("pause");
        }
    }

    inline fn inb(self: *PS2Mouse, port: u16) u8 {
        _ = self;
        return asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "N{dx}" (port),
        );
    }

    inline fn outb(self: *PS2Mouse, port: u16, value: u8) void {
        _ = self;
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        );
    }
};

// ============================================================================
// Input Event Queue
// ============================================================================

pub const InputEventQueue = struct {
    queue: std.ArrayList(InputEvent),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) InputEventQueue {
        return .{
            .queue = std.ArrayList(InputEvent).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *InputEventQueue) void {
        self.queue.deinit();
    }

    pub fn push(self: *InputEventQueue, event: InputEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(event);
    }

    pub fn pop(self: *InputEventQueue) ?InputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    pub fn peek(self: *InputEventQueue) ?InputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return null;
        return self.queue.items[0];
    }

    pub fn clear(self: *InputEventQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.queue.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "key modifiers" {
    const testing = std.testing;

    var mods = KeyModifiers{};
    try testing.expect(!mods.shift);
    try testing.expect(!mods.ctrl);

    mods.shift = true;
    try testing.expect(mods.shift);
}

test "keycode values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0x1E), @intFromEnum(KeyCode.a));
    try testing.expectEqual(@as(u8, 0x39), @intFromEnum(KeyCode.space));
}
