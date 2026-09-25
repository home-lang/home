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

test "checker visits match guards and arm bodies" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) {
        \\    match value {
        \\        true if 1 => missing_name,
        \\        false => 0,
        \\    }
        \\}
    ));
}

test "checker defines identifier pattern bindings in their arm" {
    try std.testing.expect(try checkSource(
        \\fn classify(value: i32) {
        \\    match value {
        \\        captured => captured,
        \\    }
        \\}
    ));
}

test "checker rejects mismatched trait implementation signatures" {
    try std.testing.expect(!try checkSource(
        \\trait Convert {
        \\    fn convert(value: i32): bool;
        \\}
        \\impl Convert for i32 {
        \\    fn convert(value: bool) -> bool { return value }
        \\}
    ));
}

test "checker rejects an unresolved declared type" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let value: Nonexistent = 1
        \\}
    ));
}

test "checker preserves tuple element types during destructuring" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let (number, text) = (1, "s")
        \\    number + text
        \\}
    ));
}

test "checker rejects tuple destructuring arity mismatches" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let (first, second) = (1, 2, 3)
        \\}
    ));
}

test "checker rejects incompatible match expression arm types" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) {
        \\    let result = match value {
        \\        true => 1,
        \\        false => "no",
        \\    }
        \\}
    ));
}

test "checker visits every match expression arm" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) {
        \\    let result = match value {
        \\        true => 1,
        \\        false => missing_name,
        \\    }
        \\}
    ));
}

test "checker scopes match expression bindings to their arm" {
    try std.testing.expect(try checkSource(
        \\fn classify(value: i32) -> i32 {
        \\    return match value {
        \\        captured if captured > 0 => captured,
        \\        _ => 0,
        \\    }
        \\}
    ));
}
