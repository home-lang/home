const std = @import("std");
const home = @import("home");

fn checkSource(source: []const u8) !bool {
    const allocator = std.testing.allocator;
    var lexer = home.lexer.Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = try home.parser.Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var checker = home.types.TypeChecker.init(allocator, program);
    defer checker.deinit();
    return checker.check();
}

test "checker rejects a value with the wrong function return type" {
    try std.testing.expect(!try checkSource(
        \\fn answer() -> bool {
        \\    return 42
        \\}
    ));
}

test "checker accepts a correctly typed function return" {
    try std.testing.expect(try checkSource(
        \\fn answer() -> i32 {
        \\    return 42
        \\}
    ));
}

test "checker visits statements nested in unsafe blocks" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    unsafe {
        \\        missing_name
        \\    }
        \\}
    ));
}
