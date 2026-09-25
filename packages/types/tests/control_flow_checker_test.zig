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

test "checker rejects indexing and slicing void" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let indexed = noop()[0]
        \\    let sliced = noop()[0..1]
        \\}
    ));
}

test "checker rejects void member and safe navigation access" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let direct = noop().value
        \\    let safe = noop()?.value
        \\}
    ));
}

test "checker rejects void in if expression joins" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let value = if true then noop() else 1
        \\}
    ));
}

test "checker rejects void in typed array literals" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let values: [i32] = [noop(), 1]
        \\}
    ));
}

test "checker does not coerce arrays of void" {
    try std.testing.expect(!try checkSource(
        \\fn noop() -> void { return }
        \\fn run() {
        \\    let units = [noop()]
        \\    let values: [i32] = units
        \\}
    ));
}

test "checker rejects unresolved result member types" {
    try std.testing.expect(!try checkSource(
        \\fn inspect(value: Result<i32, Missing>) {}
    ));
}

test "checker rejects unresolved map member types" {
    try std.testing.expect(!try checkSource(
        \\fn inspect(value: HashMap<string, Missing>) {}
    ));
}

test "checker rejects calls through unresolved capitalized values" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    Missing.create()
        \\}
    ));
}

test "checker rejects missing enum variant constructors" {
    try std.testing.expect(!try checkSource(
        \\enum Choice { One, Two }
        \\fn run() {
        \\    Choice.Three()
        \\}
    ));
}

test "checker rejects unknown string methods" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    "value".missing()
        \\}
    ));
}

test "checker rejects unknown array methods" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let values = [1, 2]
        \\    values.missing()
        \\}
    ));
}

test "checker validates inline struct method arguments" {
    try std.testing.expect(!try checkSource(
        \\struct Counter {
        \\    value: i32
        \\    fn add(self, amount: i32) -> i32 { return amount }
        \\}
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    counter.add("wrong")
        \\}
    ));
}

test "checker excludes self from inline method arity" {
    try std.testing.expect(!try checkSource(
        \\struct Counter {
        \\    value: i32
        \\    fn read(self) -> i32 { return 1 }
        \\}
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    counter.read(1)
        \\}
    ));
}
