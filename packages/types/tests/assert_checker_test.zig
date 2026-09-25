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

test "checker rejects a non-boolean assert condition" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    assert 1
        \\}
    ));
}

test "checker accepts a boolean assert condition" {
    try std.testing.expect(try checkSource(
        \\fn run() {
        \\    assert true, "expected truth"
        \\}
    ));
}

test "checker visits an assert message expression" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    assert true, missing_message
        \\}
    ));
}
