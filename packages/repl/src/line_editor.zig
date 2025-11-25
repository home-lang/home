const std = @import("std");

/// Advanced line editor with history, completion, and editing
///
/// Features:
/// - Line editing (cursor movement, insertion, deletion)
/// - Command history (up/down arrows)
/// - Tab completion
/// - Emacs-style key bindings
/// - Multi-line support
pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize,
    history: *History,
    completer: ?*Completer,
    prompt: []const u8,

    /// Key codes
    pub const Key = enum {
        Char,
        Enter,
        Tab,
        Backspace,
        Delete,
        Left,
        Right,
        Up,
        Down,
        Home,
        End,
        CtrlA, // Home
        CtrlE, // End
        CtrlU, // Clear line
        CtrlK, // Kill to end
        CtrlL, // Clear screen
        CtrlC, // Interrupt
        CtrlD, // EOF
        Unknown,
    };

    pub const History = @import("repl.zig").History;
    pub const Completer = @import("repl.zig").Completer;

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) LineEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .cursor = 0,
            .history = undefined,
            .completer = null,
            .prompt = prompt,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit();
    }

    pub fn setHistory(self: *LineEditor, history: *History) void {
        self.history = history;
    }

    pub fn setCompleter(self: *LineEditor, completer: *Completer) void {
        self.completer = completer;
    }

    /// Read a line from stdin with editing support
    pub fn readLine(self: *LineEditor) !?[]const u8 {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut().writer();

        // Enable raw mode for terminal
        const original_termios = try enableRawMode(stdin);
        defer disableRawMode(stdin, original_termios) catch {};

        self.buffer.clearRetainingCapacity();
        self.cursor = 0;

        // Print prompt
        try stdout.print("{s}", .{self.prompt});

        var temp_history_index: ?usize = null;

        while (true) {
            const key = try self.readKey(stdin);

            switch (key) {
                .Enter => {
                    try stdout.print("\r\n", .{});
                    if (self.buffer.items.len > 0) {
                        return try self.allocator.dupe(u8, self.buffer.items);
                    } else {
                        return try self.allocator.dupe(u8, "");
                    }
                },
                .Char => |c| {
                    try self.insertChar(c);
                    try self.refresh(stdout);
                },
                .Backspace => {
                    if (self.cursor > 0) {
                        _ = self.buffer.orderedRemove(self.cursor - 1);
                        self.cursor -= 1;
                        try self.refresh(stdout);
                    }
                },
                .Delete => {
                    if (self.cursor < self.buffer.items.len) {
                        _ = self.buffer.orderedRemove(self.cursor);
                        try self.refresh(stdout);
                    }
                },
                .Left => {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        try self.moveCursor(stdout);
                    }
                },
                .Right => {
                    if (self.cursor < self.buffer.items.len) {
                        self.cursor += 1;
                        try self.moveCursor(stdout);
                    }
                },
                .Home, .CtrlA => {
                    self.cursor = 0;
                    try self.moveCursor(stdout);
                },
                .End, .CtrlE => {
                    self.cursor = self.buffer.items.len;
                    try self.moveCursor(stdout);
                },
                .Up => {
                    if (self.history.previous()) |entry| {
                        temp_history_index = self.history.current_index;
                        self.buffer.clearRetainingCapacity();
                        try self.buffer.appendSlice(entry);
                        self.cursor = self.buffer.items.len;
                        try self.refresh(stdout);
                    }
                },
                .Down => {
                    if (temp_history_index) |_| {
                        if (self.history.next()) |entry| {
                            self.buffer.clearRetainingCapacity();
                            try self.buffer.appendSlice(entry);
                            self.cursor = self.buffer.items.len;
                            try self.refresh(stdout);
                        } else {
                            temp_history_index = null;
                            self.buffer.clearRetainingCapacity();
                            self.cursor = 0;
                            try self.refresh(stdout);
                        }
                    }
                },
                .Tab => {
                    if (self.completer) |comp| {
                        try self.handleCompletion(comp, stdout);
                    }
                },
                .CtrlU => {
                    // Clear from cursor to beginning
                    if (self.cursor > 0) {
                        const new_buffer = try self.allocator.dupe(u8, self.buffer.items[self.cursor..]);
                        self.buffer.clearRetainingCapacity();
                        try self.buffer.appendSlice(new_buffer);
                        self.allocator.free(new_buffer);
                        self.cursor = 0;
                        try self.refresh(stdout);
                    }
                },
                .CtrlK => {
                    // Clear from cursor to end
                    self.buffer.shrinkRetainingCapacity(self.cursor);
                    try self.refresh(stdout);
                },
                .CtrlL => {
                    // Clear screen
                    try stdout.print("\x1B[2J\x1B[H", .{});
                    try self.refresh(stdout);
                },
                .CtrlC => {
                    try stdout.print("^C\r\n", .{});
                    return null;
                },
                .CtrlD => {
                    if (self.buffer.items.len == 0) {
                        return null;
                    }
                },
                .Unknown => {},
            }
        }
    }

    fn insertChar(self: *LineEditor, c: u8) !void {
        try self.buffer.insert(self.cursor, c);
        self.cursor += 1;
    }

    fn refresh(self: *LineEditor, writer: anytype) !void {
        // Move cursor to start of line
        try writer.print("\r", .{});
        // Clear line
        try writer.print("\x1B[K", .{});
        // Print prompt and buffer
        try writer.print("{s}{s}", .{ self.prompt, self.buffer.items });
        // Move cursor to correct position
        const col = self.prompt.len + self.cursor;
        try writer.print("\r\x1B[{d}C", .{col});
    }

    fn moveCursor(self: *LineEditor, writer: anytype) !void {
        const col = self.prompt.len + self.cursor;
        try writer.print("\r\x1B[{d}C", .{col});
    }

    fn handleCompletion(self: *LineEditor, completer: *Completer, writer: anytype) !void {
        // Get word at cursor
        const word_start = self.findWordStart();
        const prefix = self.buffer.items[word_start..self.cursor];

        var completions = try completer.complete(prefix);
        defer completions.deinit();

        if (completions.items.len == 0) {
            // No completions
            return;
        } else if (completions.items.len == 1) {
            // Single completion - insert it
            const completion = completions.items[0];
            const suffix = completion[prefix.len..];

            for (suffix) |c| {
                try self.insertChar(c);
            }
            try self.refresh(writer);
        } else {
            // Multiple completions - show them
            try writer.print("\r\n", .{});
            for (completions.items) |completion| {
                try writer.print("  {s}\r\n", .{completion});
            }
            try self.refresh(writer);
        }
    }

    fn findWordStart(self: *LineEditor) usize {
        var i = self.cursor;
        while (i > 0) : (i -= 1) {
            const c = self.buffer.items[i - 1];
            if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == '{' or c == '}') {
                break;
            }
        }
        return i;
    }

    const KeyWithChar = union(Key) {
        Char: u8,
        Enter: void,
        Tab: void,
        Backspace: void,
        Delete: void,
        Left: void,
        Right: void,
        Up: void,
        Down: void,
        Home: void,
        End: void,
        CtrlA: void,
        CtrlE: void,
        CtrlU: void,
        CtrlK: void,
        CtrlL: void,
        CtrlC: void,
        CtrlD: void,
        Unknown: void,
    };

    fn readKey(self: *LineEditor, stdin: std.fs.File) !KeyWithChar {
        _ = self;
        var buf: [3]u8 = undefined;
        const n = try stdin.read(&buf);

        if (n == 0) return .{ .CtrlD = {} };

        const c = buf[0];

        // Control characters
        if (c == 3) return .{ .CtrlC = {} }; // Ctrl-C
        if (c == 4) return .{ .CtrlD = {} }; // Ctrl-D
        if (c == 1) return .{ .CtrlA = {} }; // Ctrl-A
        if (c == 5) return .{ .CtrlE = {} }; // Ctrl-E
        if (c == 11) return .{ .CtrlK = {} }; // Ctrl-K
        if (c == 12) return .{ .CtrlL = {} }; // Ctrl-L
        if (c == 21) return .{ .CtrlU = {} }; // Ctrl-U
        if (c == '\r' or c == '\n') return .{ .Enter = {} };
        if (c == '\t') return .{ .Tab = {} };
        if (c == 127 or c == 8) return .{ .Backspace = {} };

        // Escape sequences
        if (c == 27) {
            if (n >= 3 and buf[1] == '[') {
                return switch (buf[2]) {
                    'A' => .{ .Up = {} },
                    'B' => .{ .Down = {} },
                    'C' => .{ .Right = {} },
                    'D' => .{ .Left = {} },
                    'H' => .{ .Home = {} },
                    'F' => .{ .End = {} },
                    '3' => .{ .Delete = {} }, // Delete key sends ESC[3~
                    else => .{ .Unknown = {} },
                };
            }
            return .{ .Unknown = {} };
        }

        // Regular character
        return .{ .Char = c };
    }
};

/// Enable raw mode for terminal
fn enableRawMode(file: std.fs.File) !std.os.termios {
    const original = try std.os.tcgetattr(file.handle);
    var raw = original;

    // Disable canonical mode and echo
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    // Disable input processing
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;

    // Disable output processing
    raw.oflag.OPOST = false;

    // Set read timeout
    raw.cc[@intFromEnum(std.os.linux.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.os.linux.V.TIME)] = 1;

    try std.os.tcsetattr(file.handle, .FLUSH, raw);
    return original;
}

/// Disable raw mode for terminal
fn disableRawMode(file: std.fs.File, original: std.os.termios) !void {
    try std.os.tcsetattr(file.handle, .FLUSH, original);
}
