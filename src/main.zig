const std = @import("std");
const Lexer = @import("lexer/lexer.zig").Lexer;

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

fn printUsage() void {
    std.debug.print(
        \\{s}Ion Compiler{s} - The speed of Zig. The safety of Rust. The joy of TypeScript.
        \\
        \\{s}Usage:{s}
        \\  ion <command> [arguments]
        \\
        \\{s}Commands:{s}
        \\  parse <file>    Parse an Ion file and display tokens
        \\  help            Display this help message
        \\
        \\{s}Examples:{s}
        \\  ion parse hello.ion
        \\  ion help
        \\
    , .{ Color.Blue.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code(), Color.Green.code(), Color.Reset.code() });
}

fn parseCommand(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("{s}Error:{s} Failed to open file '{s}': {}\n", .{ Color.Red.code(), Color.Reset.code(), file_path, err });
        return err;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10 MB max
    defer allocator.free(source);

    // Tokenize
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    // Print header
    std.debug.print("{s}Parsing:{s} {s}\n", .{ Color.Blue.code(), Color.Reset.code(), file_path });
    std.debug.print("{s}Tokens:{s} {d}\n\n", .{ Color.Blue.code(), Color.Reset.code(), tokens.items.len });

    // Print tokens with color
    for (tokens.items) |token| {
        const color = switch (token.type) {
            .Fn, .Let, .Const, .If, .Else, .Return, .Struct, .Enum, .Match, .For, .While, .Loop, .Import, .Async, .Await, .Comptime => Color.Magenta,
            .String => Color.Green,
            .Integer, .Float => Color.Yellow,
            .Identifier => Color.Cyan,
            .Eof => Color.Blue,
            else => Color.Reset,
        };

        std.debug.print("{s}{}{s}\n", .{ color.code(), token, Color.Reset.code() });
    }

    std.debug.print("\n{s}Success:{s} Parsed {d} tokens\n", .{ Color.Green.code(), Color.Reset.code(), tokens.items.len });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "parse")) {
        if (args.len < 3) {
            std.debug.print("{s}Error:{s} 'parse' command requires a file path\n\n", .{ Color.Red.code(), Color.Reset.code() });
            printUsage();
            std.process.exit(1);
        }

        try parseCommand(allocator, args[2]);
        return;
    }

    std.debug.print("{s}Error:{s} Unknown command '{s}'\n\n", .{ Color.Red.code(), Color.Reset.code(), command });
    printUsage();
    std.process.exit(1);
}
