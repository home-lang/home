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

test "checker keeps void as the unit return type" {
    try std.testing.expect(try checkSource(
        \\fn noop() -> void {
        \\    return
        \\}
    ));
}

test "checker accepts compatible destructured tuple elements" {
    try std.testing.expect(try checkSource(
        \\fn add() -> int {
        \\    let (left, right) = (1, 2)
        \\    return left + right
        \\}
    ));
}

test "checker rejects non-boolean match expression guards" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: i32) {
        \\    let result = match value {
        \\        captured if captured => 1,
        \\        _ => 0,
        \\    }
        \\}
    ));
}

test "checker propagates expected types into all match arms" {
    try std.testing.expect(try checkSource(
        \\fn classify(value: bool) -> u32 {
        \\    return match value {
        \\        true => 1,
        \\        false => 2,
        \\    }
        \\}
    ));
}

test "checker resolves closure captures through the parent scope" {
    try std.testing.expect(try checkSource(
        \\fn run() -> i32 {
        \\    let base: i32 = 40
        \\    let add = |value: i32| base + value
        \\    return add(2)
        \\}
    ));
}

test "checker enforces closure return annotations" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let broken = |value: i32|: bool value + 1
        \\}
    ));
}

test "checker rejects void function arguments" {
    try std.testing.expect(!try checkSource(
        \\fn consume(value: i32) {}
        \\fn noop() -> void { return }
        \\fn run() {
        \\    consume(noop())
        \\}
    ));
}

test "checker suppresses cascades with unknown rather than void" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let value: Missing = 1
        \\    let result = value + 1
        \\}
    ));
}
