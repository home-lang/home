const std = @import("std");
const home = @import("home");

fn checkSource(source: []const u8) !bool {
    const allocator = std.testing.allocator;
    var lexer = home.lexer.Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = try home.parser.Parser.init(allocator, tokens.items);
    defer parser.deinit();
    parser.module_resolver.io = std.testing.io;
    try parser.module_resolver.setSourceRoot("packages/types/tests/fixtures/import_alias_main.home");
    const module_key = try allocator.dupe(u8, "import_alias_support");
    errdefer allocator.free(module_key);
    const module_file = try allocator.dupe(u8, "packages/types/tests/fixtures/import_alias_support.home");
    errdefer allocator.free(module_file);
    try parser.module_resolver.module_cache.put(module_key, .{
        .path = &.{"import_alias_support"},
        .file_path = module_file,
        .name = "import_alias_support",
        .is_zig = false,
    });
    const program = try parser.parse();
    defer program.deinit(allocator);

    var checker = home.types.TypeChecker.init(allocator, program);
    defer checker.deinit();
    return checker.check();
}

fn checkSourceWithImports(source: []const u8) !bool {
    const allocator = std.testing.allocator;
    var lexer = home.lexer.Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = try home.parser.Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var checker = home.types.TypeChecker.initWithSourcePath(
        allocator,
        program,
        "packages/types/tests/fixtures/import_alias_main.home",
    );
    checker.io = std.testing.io;
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

test "checker gives typed closures callable function types" {
    try std.testing.expect(try checkSource(
        \\fn run() -> i32 {
        \\    let add_one = |value: i32| value + 1
        \\    return add_one(2)
        \\}
    ));
}

test "checker rejects closure calls with the wrong argument type" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let add_one = |value: i32| value + 1
        \\    add_one("wrong")
        \\}
    ));
}

test "checker visits closure bodies before they are called" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let broken = |value: i32| value + "wrong"
        \\}
    ));
}

test "checker resolves exported import alias members" {
    try std.testing.expect(try checkSourceWithImports(
        \\import import_alias_support as support
        \\fn run() -> i32 {
        \\    return support.exported(1)
        \\}
    ));
}

test "checker rejects missing import alias members" {
    try std.testing.expect(!try checkSourceWithImports(
        \\import import_alias_support as support
        \\fn run() {
        \\    support.anything
        \\}
    ));
}

test "checker hides non-public import alias members" {
    try std.testing.expect(!try checkSourceWithImports(
        \\import import_alias_support as support
        \\fn run() {
        \\    support.hidden
        \\}
    ));
}

test "checker rejects arithmetic with a void value" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let value = noop() + 1
        \\}
    ));
}

test "checker rejects void as a condition" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    if noop() {}
        \\}
    ));
}
