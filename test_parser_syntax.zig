const std = @import("std");
const Lexer = @import("packages/lexer/src/lexer.zig").Lexer;
const Parser = @import("packages/parser/src/parser.zig").Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read test file
    const file = try std.fs.cwd().openFile("test_syntax_changes.home", .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);

    std.debug.print("Source code:\n{s}\n\n", .{source});

    // Lex the source
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    std.debug.print("Tokens ({d}):\n", .{tokens.items.len});
    for (tokens.items) |token| {
        std.debug.print("  {}\n", .{token});
    }

    // Parse the source
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();

    const program = parser.parse() catch |err| {
        std.debug.print("\nParsing failed: {}\n", .{err});
        return err;
    };
    defer program.deinit(allocator);

    std.debug.print("\nParsing successful!\n", .{});
    std.debug.print("Program has {d} statements\n", .{program.statements.len});
}
