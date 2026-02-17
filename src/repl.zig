const std = @import("std");
const lexer_mod = @import("lexer");
const Lexer = lexer_mod.Lexer;
const Parser = @import("parser").Parser;
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;

const Color = enum {
    Reset,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .Reset => "\x1b[0m",
            .Red => "\x1b[31m",
            .Green => "\x1b[32m",
            .Yellow => "\x1b[33m",
            .Blue => "\x1b[34m",
            .Magenta => "\x1b[35m",
            .Cyan => "\x1b[36m",
        };
    }
};

pub const Repl = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{
            .allocator = allocator,
        };
    }

    pub fn run(self: *Repl) !void {
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const stdin_file = std.Io.File.stdin();
        var stdin_buf: [8192]u8 = undefined;
        var stdin_file_reader = stdin_file.reader(io, &stdin_buf);
        var stdin_reader = &stdin_file_reader.interface;

        // Print welcome banner
        self.printBanner();

        // Use a fixed buffer for multi-line input (simpler, no ArrayList issues)
        var multi_line_buf: [16384]u8 = undefined;
        var multi_line_len: usize = 0;

        var is_multiline = false;
        var brace_count: i32 = 0;

        while (true) {
            // Print prompt
            if (is_multiline) {
                std.debug.print("{s}...> {s}", .{ Color.Yellow.code(), Color.Reset.code() });
            } else {
                std.debug.print("{s}>>> {s}", .{ Color.Green.code(), Color.Reset.code() });
            }

            // Read line - try to take up to newline delimiter
            const line = stdin_reader.takeDelimiter('\n') catch |err| {
                if (err == error.EndOfStream or err == error.ReadFailed) {
                    std.debug.print("\n", .{});
                    break;
                }
                std.debug.print("\n", .{});
                return err;
            } orelse {
                std.debug.print("\n", .{});
                break;
            };

            // Trim whitespace
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Handle special commands
            if (!is_multiline) {
                if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
                    std.debug.print("{s}Goodbye!{s}\n", .{ Color.Cyan.code(), Color.Reset.code() });
                    break;
                }

                if (std.mem.eql(u8, trimmed, "help")) {
                    self.printHelp();
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "clear")) {
                    std.debug.print("\x1b[2J\x1b[H", .{});
                    continue;
                }

                if (trimmed.len == 0) {
                    continue;
                }
            }

            // Append line to multi-line buffer
            if (multi_line_len + line.len + 1 > multi_line_buf.len) {
                std.debug.print("{s}Error:{s} Input too long\n\n", .{ Color.Red.code(), Color.Reset.code() });
                multi_line_len = 0;
                is_multiline = false;
                brace_count = 0;
                continue;
            }
            @memcpy(multi_line_buf[multi_line_len .. multi_line_len + line.len], line);
            multi_line_len += line.len;
            multi_line_buf[multi_line_len] = '\n';
            multi_line_len += 1;

            // Count braces to detect multi-line input
            for (trimmed) |c| {
                if (c == '{' or c == '[' or c == '(') {
                    brace_count += 1;
                } else if (c == '}' or c == ']' or c == ')') {
                    brace_count -= 1;
                }
            }

            // If braces are balanced, execute the code
            if (brace_count <= 0) {
                const input = multi_line_buf[0..multi_line_len];
                try self.executeInput(input);

                // Reset for next input
                multi_line_len = 0;
                is_multiline = false;
                brace_count = 0;
            } else {
                is_multiline = true;
            }
        }
    }

    fn printBanner(self: *Repl) void {
        _ = self;
        std.debug.print(
            \\{s}
            \\  _    _
            \\ | |  | |
            \\ | |__| | ___  _ __ ___   ___
            \\ |  __  |/ _ \| '_ ` _ \ / _ \
            \\ | |  | | (_) | | | | | |  __/
            \\ |_|  |_|\___/|_| |_| |_|\___|
            \\{s}
            \\
            \\{s}Home REPL v0.1.0{s}
            \\The speed of Zig. The safety of Rust. The joy of TypeScript.
            \\
            \\Type {s}help{s} for available commands, {s}exit{s} to quit.
            \\
            \\
        , .{
            Color.Blue.code(),
            Color.Reset.code(),
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
        });
    }

    fn printHelp(self: *Repl) void {
        _ = self;
        std.debug.print(
            \\{s}Available Commands:{s}
            \\  {s}help{s}       Show this help message
            \\  {s}exit{s}       Exit the REPL (or use Ctrl+D)
            \\  {s}quit{s}       Exit the REPL
            \\  {s}clear{s}      Clear the screen
            \\
            \\{s}Tips:{s}
            \\  - Multi-line input is supported. Just keep typing and the REPL will
            \\    detect when you've closed all braces/brackets/parentheses
            \\  - You can write full programs with functions, variables, and more
            \\  - Use print() to display values
            \\
            \\{s}Examples:{s}
            \\  >>> let x = 42
            \\  >>> print(x)
            \\  >>> fn greet(name: str) {{
            \\  ...>   print("Hello, " + name)
            \\  ...> }}
            \\  >>> greet("World")
            \\
            \\
        , .{
            Color.Green.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
            Color.Yellow.code(),
            Color.Reset.code(),
            Color.Cyan.code(),
            Color.Reset.code(),
            Color.Cyan.code(),
            Color.Reset.code(),
        });
    }

    fn executeInput(self: *Repl, input: []const u8) !void {
        // Tokenize
        var lexer = Lexer.init(self.allocator, input);
        var tokens = lexer.tokenize() catch |err| {
            std.debug.print("{s}Lexer error:{s} {}\n\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return;
        };
        defer tokens.deinit(self.allocator);

        // Parse
        var parser = Parser.init(self.allocator, tokens.items) catch |err| {
            std.debug.print("{s}Parser initialization error:{s} {}\n\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return;
        };
        const program = parser.parse() catch |err| {
            std.debug.print("{s}Parser error:{s} {}\n\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return;
        };

        // Interpret
        const interpreter = Interpreter.init(self.allocator, program) catch |err| {
            std.debug.print("{s}Interpreter init error:{s} {}\n\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return;
        };
        defer interpreter.deinit();

        interpreter.interpret() catch |err| {
            if (err == error.Return) {
                // Normal return from main, not an error
                return;
            }
            std.debug.print("{s}Runtime error:{s} {}\n\n", .{ Color.Red.code(), Color.Reset.code(), err });
            return;
        };
    }
};

pub fn start(allocator: std.mem.Allocator) !void {
    var repl = Repl.init(allocator);
    try repl.run();
}
