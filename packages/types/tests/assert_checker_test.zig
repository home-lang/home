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

test "checker rejects a pattern with the wrong matched type" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) {
        \\    match value {
        \\        1 => 1,
        \\        _ => 0,
        \\    }
        \\}
    ));
}

test "checker rejects a non-exhaustive boolean match" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) {
        \\    match value {
        \\        true => 1,
        \\    }
        \\}
    ));
}

test "checker visits extension method bodies" {
    try std.testing.expect(!try checkSource(
        \\extend i32 {
        \\    fn broken(value: i32) { missing_name }
        \\}
    ));
}
