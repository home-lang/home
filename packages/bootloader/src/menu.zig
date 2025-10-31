// Boot Menu Implementation
// Interactive text-based boot menu for UEFI

const std = @import("std");
const uefi = @import("uefi.zig");
const bootloader = @import("bootloader.zig");

/// Menu colors
pub const MenuColor = enum(usize) {
    black = 0x00,
    blue = 0x01,
    green = 0x02,
    cyan = 0x03,
    red = 0x04,
    magenta = 0x05,
    brown = 0x06,
    light_gray = 0x07,
    dark_gray = 0x08,
    light_blue = 0x09,
    light_green = 0x0A,
    light_cyan = 0x0B,
    light_red = 0x0C,
    light_magenta = 0x0D,
    yellow = 0x0E,
    white = 0x0F,

    pub fn makeAttribute(fg: MenuColor, bg: MenuColor) usize {
        return @intFromEnum(fg) | (@intFromEnum(bg) << 4);
    }
};

/// Key codes
pub const Key = enum(u16) {
    up = 0x01,
    down = 0x02,
    enter = 0x0D,
    escape = 0x1B,
    space = 0x20,
    e = 0x65, // Edit command line
};

/// Menu input event
pub const InputEvent = struct {
    key: u16,
    scan_code: u16,

    pub fn isUp(self: InputEvent) bool {
        return self.scan_code == @intFromEnum(Key.up);
    }

    pub fn isDown(self: InputEvent) bool {
        return self.scan_code == @intFromEnum(Key.down);
    }

    pub fn isEnter(self: InputEvent) bool {
        return self.key == @intFromEnum(Key.enter);
    }

    pub fn isEscape(self: InputEvent) bool {
        return self.key == @intFromEnum(Key.escape);
    }

    pub fn isEdit(self: InputEvent) bool {
        return self.key == @intFromEnum(Key.e) or self.key == ('E' - 'A' + 1);
    }
};

/// Boot menu state
pub const BootMenu = struct {
    config: *bootloader.BootConfig,
    selected_index: usize,
    timeout_remaining: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: *bootloader.BootConfig) BootMenu {
        return .{
            .config = config,
            .selected_index = config.default_entry,
            .timeout_remaining = config.timeout_seconds,
            .allocator = allocator,
        };
    }

    /// Display the boot menu
    pub fn display(self: *BootMenu, con_out: *uefi.SimpleTextOutput) !void {
        // Clear screen
        _ = con_out.clear_screen(con_out);

        // Set colors
        _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));

        // Display header
        try self.printHeader(con_out);

        // Display entries
        try self.printEntries(con_out);

        // Display footer
        try self.printFooter(con_out);
    }

    fn printHeader(self: *BootMenu, con_out: *uefi.SimpleTextOutput) !void {
        const header =
            \\
            \\  ╔═══════════════════════════════════════════════════════════╗
            \\  ║                    Home OS Bootloader                     ║
            \\  ║                       Version 1.0.0                       ║
            \\  ╚═══════════════════════════════════════════════════════════╝
            \\
            \\
        ;

        try uefi.UEFIHelper.print(con_out, header, self.allocator);
    }

    fn printEntries(self: *BootMenu, con_out: *uefi.SimpleTextOutput) !void {
        const entries = self.config.entries.items;

        for (entries, 0..) |*entry, i| {
            // Set colors based on selection
            if (i == self.selected_index) {
                _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.black, .light_gray));
                try uefi.UEFIHelper.print(con_out, "  > ", self.allocator);
            } else {
                _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));
                try uefi.UEFIHelper.print(con_out, "    ", self.allocator);
            }

            // Print entry name
            const name = entry.getName();
            try uefi.UEFIHelper.print(con_out, name, self.allocator);

            // Reset colors
            _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));

            // Show if it's the default
            if (entry.default) {
                try uefi.UEFIHelper.print(con_out, " (default)", self.allocator);
            }

            try uefi.UEFIHelper.print(con_out, "\n", self.allocator);

            // Show kernel path for selected entry
            if (i == self.selected_index) {
                _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.dark_gray, .black));
                try uefi.UEFIHelper.print(con_out, "      Kernel: ", self.allocator);
                try uefi.UEFIHelper.print(con_out, entry.getKernelPath(), self.allocator);
                try uefi.UEFIHelper.print(con_out, "\n", self.allocator);

                if (entry.getInitrdPath().len > 0) {
                    try uefi.UEFIHelper.print(con_out, "      Initrd: ", self.allocator);
                    try uefi.UEFIHelper.print(con_out, entry.getInitrdPath(), self.allocator);
                    try uefi.UEFIHelper.print(con_out, "\n", self.allocator);
                }

                _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));
            }
        }
    }

    fn printFooter(self: *BootMenu, con_out: *uefi.SimpleTextOutput) !void {
        try uefi.UEFIHelper.print(con_out, "\n", self.allocator);

        // Print timeout if active
        if (self.timeout_remaining > 0) {
            _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.yellow, .black));

            const timeout_msg = try std.fmt.allocPrint(
                self.allocator,
                "  Booting in {d} seconds... (press any key to stop)\n",
                .{self.timeout_remaining},
            );
            defer self.allocator.free(timeout_msg);

            try uefi.UEFIHelper.print(con_out, timeout_msg, self.allocator);
            _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));
        }

        try uefi.UEFIHelper.print(con_out, "\n", self.allocator);
        try uefi.UEFIHelper.print(con_out, "  ↑/↓: Select  |  Enter: Boot  |  E: Edit  |  Esc: Firmware Setup\n", self.allocator);
    }

    /// Handle user input
    pub fn handleInput(self: *BootMenu, event: InputEvent) void {
        // Stop timeout on any input
        self.timeout_remaining = 0;

        if (event.isUp()) {
            if (self.selected_index > 0) {
                self.selected_index -= 1;
            } else {
                self.selected_index = self.config.getEntryCount() - 1;
            }
        } else if (event.isDown()) {
            self.selected_index = (self.selected_index + 1) % self.config.getEntryCount();
        }
    }

    /// Run the boot menu loop
    pub fn run(self: *BootMenu, con_out: *uefi.SimpleTextOutput) !MenuResult {
        while (true) {
            // Display menu
            try self.display(con_out);

            // Check timeout
            if (self.timeout_remaining > 0) {
                // Wait 1 second
                // In production, would use UEFI timer events
                self.timeout_remaining -= 1;

                if (self.timeout_remaining == 0) {
                    return MenuResult{
                        .action = .boot,
                        .entry_index = self.selected_index,
                    };
                }
            }

            // In production, would poll for keyboard input
            // For now, just return boot action
            return MenuResult{
                .action = .boot,
                .entry_index = self.selected_index,
            };
        }
    }

    /// Move selection up
    pub fn selectPrevious(self: *BootMenu) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        } else {
            self.selected_index = self.config.getEntryCount() - 1;
        }
    }

    /// Move selection down
    pub fn selectNext(self: *BootMenu) void {
        self.selected_index = (self.selected_index + 1) % self.config.getEntryCount();
    }

    /// Get currently selected entry
    pub fn getSelectedEntry(self: *BootMenu) ?*bootloader.BootEntry {
        return self.config.getEntry(self.selected_index);
    }

    /// Decrease timeout
    pub fn tick(self: *BootMenu) bool {
        if (self.timeout_remaining > 0) {
            self.timeout_remaining -= 1;
            return self.timeout_remaining == 0;
        }
        return false;
    }

    /// Cancel timeout
    pub fn cancelTimeout(self: *BootMenu) void {
        self.timeout_remaining = 0;
    }
};

/// Menu action result
pub const MenuAction = enum {
    boot,
    edit,
    firmware_setup,
    reboot,
    shutdown,
};

/// Menu result
pub const MenuResult = struct {
    action: MenuAction,
    entry_index: usize,
};

/// Command line editor
pub const CommandLineEditor = struct {
    buffer: [512]u8,
    length: usize,
    cursor: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) CommandLineEditor {
        var editor: CommandLineEditor = undefined;
        editor.allocator = allocator;
        editor.cursor = 0;
        editor.length = 0;

        @memset(&editor.buffer, 0);

        if (initial.len > 0) {
            const len = @min(initial.len, editor.buffer.len);
            @memcpy(editor.buffer[0..len], initial[0..len]);
            editor.length = len;
            editor.cursor = len;
        }

        return editor;
    }

    pub fn display(self: *CommandLineEditor, con_out: *uefi.SimpleTextOutput) !void {
        _ = con_out.clear_screen(con_out);

        try uefi.UEFIHelper.print(con_out, "\n  Edit Kernel Command Line:\n\n  ", self.allocator);

        _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.yellow, .black));
        const text = self.buffer[0..self.length];
        try uefi.UEFIHelper.print(con_out, text, self.allocator);
        _ = con_out.set_attribute(con_out, MenuColor.makeAttribute(.white, .black));

        try uefi.UEFIHelper.print(con_out, "\n\n  Press Enter to save, Escape to cancel\n", self.allocator);
    }

    pub fn insertChar(self: *CommandLineEditor, char: u8) void {
        if (self.length < self.buffer.len) {
            // Shift characters right
            var i = self.length;
            while (i > self.cursor) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }

            self.buffer[self.cursor] = char;
            self.cursor += 1;
            self.length += 1;
        }
    }

    pub fn deleteChar(self: *CommandLineEditor) void {
        if (self.cursor > 0) {
            // Shift characters left
            var i = self.cursor - 1;
            while (i < self.length - 1) : (i += 1) {
                self.buffer[i] = self.buffer[i + 1];
            }

            self.cursor -= 1;
            self.length -= 1;
            self.buffer[self.length] = 0;
        }
    }

    pub fn moveCursorLeft(self: *CommandLineEditor) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
        }
    }

    pub fn moveCursorRight(self: *CommandLineEditor) void {
        if (self.cursor < self.length) {
            self.cursor += 1;
        }
    }

    pub fn getText(self: *const CommandLineEditor) []const u8 {
        return self.buffer[0..self.length];
    }
};

test "boot menu initialization" {
    const testing = std.testing;

    var config = bootloader.BootConfig.init(testing.allocator);
    defer config.deinit();

    const entry = bootloader.BootEntry.init("Test Entry");
    try config.addEntry(entry);

    const menu = BootMenu.init(testing.allocator, &config);

    try testing.expectEqual(@as(usize, 0), menu.selected_index);
    try testing.expectEqual(@as(u32, 5), menu.timeout_remaining);
}

test "menu navigation" {
    const testing = std.testing;

    var config = bootloader.BootConfig.init(testing.allocator);
    defer config.deinit();

    const entry1 = bootloader.BootEntry.init("Entry 1");
    const entry2 = bootloader.BootEntry.init("Entry 2");
    const entry3 = bootloader.BootEntry.init("Entry 3");

    try config.addEntry(entry1);
    try config.addEntry(entry2);
    try config.addEntry(entry3);

    var menu = BootMenu.init(testing.allocator, &config);

    // Initial selection
    try testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Move down
    menu.selectNext();
    try testing.expectEqual(@as(usize, 1), menu.selected_index);

    menu.selectNext();
    try testing.expectEqual(@as(usize, 2), menu.selected_index);

    // Wrap around
    menu.selectNext();
    try testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Move up
    menu.selectPrevious();
    try testing.expectEqual(@as(usize, 2), menu.selected_index);
}

test "timeout handling" {
    const testing = std.testing;

    var config = bootloader.BootConfig.init(testing.allocator);
    defer config.deinit();

    const entry = bootloader.BootEntry.init("Test Entry");
    try config.addEntry(entry);

    var menu = BootMenu.init(testing.allocator, &config);

    try testing.expectEqual(@as(u32, 5), menu.timeout_remaining);

    // Tick once
    const expired = menu.tick();
    try testing.expect(!expired);
    try testing.expectEqual(@as(u32, 4), menu.timeout_remaining);

    // Cancel timeout
    menu.cancelTimeout();
    try testing.expectEqual(@as(u32, 0), menu.timeout_remaining);
}

test "command line editor" {
    const testing = std.testing;

    var editor = CommandLineEditor.init(testing.allocator, "root=/dev/sda1");

    try testing.expectEqualStrings("root=/dev/sda1", editor.getText());
    try testing.expectEqual(@as(usize, 14), editor.cursor);

    // Insert character
    editor.insertChar(' ');
    editor.insertChar('q');
    editor.insertChar('u');
    editor.insertChar('i');
    editor.insertChar('e');
    editor.insertChar('t');

    try testing.expectEqualStrings("root=/dev/sda1 quiet", editor.getText());

    // Delete character
    editor.deleteChar();
    try testing.expectEqualStrings("root=/dev/sda1 quie", editor.getText());

    // Move cursor
    editor.moveCursorLeft();
    editor.moveCursorLeft();
    try testing.expectEqual(@as(usize, 17), editor.cursor);
}

test "input event detection" {
    const testing = std.testing;

    const up_event = InputEvent{ .key = 0, .scan_code = @intFromEnum(Key.up) };
    try testing.expect(up_event.isUp());
    try testing.expect(!up_event.isDown());

    const enter_event = InputEvent{ .key = @intFromEnum(Key.enter), .scan_code = 0 };
    try testing.expect(enter_event.isEnter());

    const edit_event = InputEvent{ .key = @intFromEnum(Key.e), .scan_code = 0 };
    try testing.expect(edit_event.isEdit());
}
