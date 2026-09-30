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

fn checkSourceWithImportsAtPath(source: []const u8, source_path: []const u8) !bool {
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
        source_path,
    );
    checker.io = std.testing.io;
    defer checker.deinit();
    return checker.check();
}

fn checkSourceWithImports(source: []const u8) !bool {
    return checkSourceWithImportsAtPath(
        source,
        "packages/types/tests/fixtures/import_alias_main.home",
    );
}

fn checkSourceWithImportsErrorMessages(
    source: []const u8,
    required: []const []const u8,
    forbidden: []const []const u8,
) !bool {
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
    _ = try checker.check();

    for (required) |needle| {
        for (checker.errors.items) |type_error| {
            if (std.mem.indexOf(u8, type_error.message, needle) != null) break;
        } else return false;
    }
    for (forbidden) |needle| {
        for (checker.errors.items) |type_error| {
            if (std.mem.indexOf(u8, type_error.message, needle) != null) return false;
        }
    }
    return true;
}

fn checkSourceErrorContains(source: []const u8, needle: []const u8) !bool {
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
    _ = try checker.check();
    for (checker.errors.items) |type_error| {
        if (std.mem.indexOf(u8, type_error.message, needle) != null) return true;
    }
    return false;
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

test "checker recognizes never as the bottom type" {
    try std.testing.expect(try checkSource(
        \\fn halt(): never {
        \\    loop {}
        \\}
        \\fn answer(): i32 {
        \\    return halt()
        \\}
    ));
}

test "checker types panic as a string-taking bottom expression" {
    try std.testing.expect(try checkSource(
        \\fn fail(): string {
        \\    return panic("not ready")
        \\}
    ));

    try std.testing.expect(!try checkSource(
        \\fn invalid_message() {
        \\    panic(42)
        \\}
    ));

    try std.testing.expect(!try checkSource(
        \\fn missing_message() {
        \\    panic()
        \\}
    ));
}

test "checker preserves future payloads through await" {
    try std.testing.expect(try checkSource(
        \\async fn fetch(): i32 {
        \\    return 7
        \\}
        \\fn resolved(): i32 {
        \\    return await fetch()
        \\}
    ));

    try std.testing.expect(!try checkSource(
        \\async fn fetch(): i32 { return 7 }
        \\fn unresolved(): i32 { return fetch() }
    ));

    try std.testing.expect(!try checkSource(
        \\fn invalid(): i32 { return await 1 }
    ));
}

test "checker rejects widening an existing mutable array" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let narrow: [i32] = [1]
        \\    let widened: [i64] = narrow
        \\}
    ));
}

test "checker permits covariance through an immutable array view" {
    try std.testing.expect(try checkSource(
        \\fn first(values: &[i64]) -> i64 {
        \\    return values[0]
        \\}
        \\fn run() {
        \\    let narrow: [i32] = [1]
        \\    first(&narrow)
        \\}
    ));
}

test "checker rejects unsafe member access through a nullable binding" {
    try std.testing.expect(!try checkSource(
        \\struct Box { value: i32 }
        \\fn run() {
        \\    let maybe: ?Box = null
        \\    let value = maybe.value
        \\}
    ));
}

test "checker accepts safe navigation through a nullable binding" {
    try std.testing.expect(try checkSource(
        \\struct Box { value: i32 }
        \\fn run() {
        \\    let maybe: ?Box = null
        \\    let value = maybe?.value
        \\}
    ));
}

test "checker rejects a constant out-of-bounds array index" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let items = [1, 2, 3]
        \\    let missing = items[3]
        \\}
    ));
}

test "checker accepts a constant in-bounds array index" {
    try std.testing.expect(try checkSource(
        \\fn run() {
        \\    let items = [1, 2, 3]
        \\    let present = items[2]
        \\}
    ));
}

test "checker accepts every array slice form used by the example" {
    try std.testing.expect(try checkSource(
        \\let numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        \\let slice1 = numbers[2..5]
        \\println(slice1)
        \\let slice2 = numbers[2..=5]
        \\println(slice2)
        \\let slice3 = numbers[..3]
        \\println(slice3)
        \\let slice4 = numbers[7..]
        \\println(slice4)
        \\let slice5 = numbers[5..5]
        \\println(slice5)
        \\let slice6 = numbers[..]
        \\println(slice6)
    ));
}

test "checker rejects constant arithmetic that overflows its destination" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    let value: u8 = 200 + 100
        \\}
    ));
}

test "checker accepts constant arithmetic within its destination range" {
    try std.testing.expect(try checkSource(
        \\fn run() {
        \\    let value: u8 = 100 + 20
        \\}
    ));
}

test "checker routes use-after-move through drop safety" {
    const source =
        \\fn run() {
        \\    let original = "owned"
        \\    let moved = original
        \\    let invalid = original
        \\}
    ;
    try std.testing.expect(!try checkSource(source));
    try std.testing.expect(try checkSourceErrorContains(source, "Drop safety violation"));
}

test "checker isolates ownership state between test declarations" {
    try std.testing.expect(try checkSource(
        \\fn owns_string() {
        \\    let result = "owned"
        \\    print(result)
        \\}
        \\it('reuses the local name') {
        \\    let result = 5
        \\    assert(result == 5)
        \\}
    ));
}

test "checker keeps a string alive when it is cloned" {
    try std.testing.expect(try checkSource(
        \\fn preserve() {
        \\    let original = "owned"
        \\    let cloned = original.clone()
        \\    print(original)
        \\    print(cloned)
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

test "checker rejects raw pointer dereference outside unsafe" {
    const source =
        \\fn read(ptr: *u8) -> u8 {
        \\    return *ptr
        \\}
    ;
    try std.testing.expect(!try checkSource(source));
    try std.testing.expect(try checkSourceErrorContains(source, "raw pointer dereference requires an unsafe block"));
}

test "checker accepts raw pointer dereference inside unsafe" {
    try std.testing.expect(try checkSource(
        \\fn read(ptr: *u8) -> u8 {
        \\    return unsafe { *ptr }
        \\}
    ));
}

test "checker keeps safe reference dereference outside unsafe" {
    try std.testing.expect(try checkSource(
        \\fn read(value: &i32) -> i32 {
        \\    return *value
        \\}
    ));
}

test "checker rejects raw pointer arithmetic outside unsafe" {
    try std.testing.expect(!try checkSource(
        \\fn advance(ptr: *u8) -> *u8 {
        \\    return ptr + 1
        \\}
    ));
}

test "checker accepts raw pointer arithmetic inside unsafe" {
    try std.testing.expect(try checkSource(
        \\fn advance(ptr: *u8) -> *u8 {
        \\    return unsafe { ptr + 1 }
        \\}
    ));
}

test "checker rejects external calls outside unsafe" {
    try std.testing.expect(!try checkSource(
        \\extern fn foreign_value() -> i32
        \\fn read() -> i32 { return foreign_value() }
    ));
}

test "checker accepts external calls inside unsafe" {
    try std.testing.expect(try checkSource(
        \\extern fn foreign_value() -> i32
        \\fn read() -> i32 { return unsafe { foreign_value() } }
    ));
}

test "checker accepts variadic output builtins" {
    try std.testing.expect(try checkSource(
        \\fn run() {
        \\    print("value", 1, true)
        \\    println("value", 1, true)
        \\}
    ));
}

test "checker visits print arguments" {
    try std.testing.expect(!try checkSource(
        \\fn run() {
        \\    print("value", missing_value)
        \\}
    ));
}

test "checker enforces unsafe function calls" {
    const outside =
        \\unsafe fn raw_value() -> i32 { return 1 }
        \\fn read() -> i32 { return raw_value() }
    ;
    try std.testing.expect(!try checkSource(outside));
    try std.testing.expect(try checkSourceErrorContains(outside, "call to unsafe or external function requires an unsafe block"));

    try std.testing.expect(try checkSource(
        \\unsafe fn raw_value() -> i32 { return 1 }
        \\fn read() -> i32 { return unsafe { raw_value() } }
    ));
}

test "checker preserves reflection builtin result types" {
    try std.testing.expect(try checkSource(
        \\fn cast_values(width: u32, address: u64): u64 {
        \\    let widened: u64 = @as(u64, width)
        \\    let pointer_value: u64 = @intFromPtr(&widened)
        \\    let narrowed: u32 = @intCast(widened)
        \\    let loaded: u8 = unsafe { @as(*u8, @ptrFromInt(address)).* }
        \\    return widened + pointer_value + @as(u64, narrowed) + @as(u64, loaded)
        \\}
    ));
}

test "checker distinguishes typed undefined storage from null" {
    try std.testing.expect(try checkSource(
        \\fn initialize(): u32 {
        \\    var value: u32 = undefined
        \\    value = 42
        \\    return value
        \\}
    ));
    try std.testing.expect(!try checkSource(
        \\fn read_too_soon(): u32 {
        \\    var value: u32 = undefined
        \\    return value
        \\}
    ));
    try std.testing.expect(!try checkSource(
        \\fn invalid_null() {
        \\    let value: u32 = null
        \\}
    ));
    try std.testing.expect(!try checkSource(
        \\fn missing_context() {
        \\    let value = undefined
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

test "checker rejects a non-exhaustive boolean match expression" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: bool) -> i32 {
        \\    return match value { true => 1 }
        \\}
    ));
}

test "checker accepts an exhaustive boolean match expression" {
    try std.testing.expect(try checkSource(
        \\fn classify(value: bool) -> i32 {
        \\    return match value {
        \\        true => 1,
        \\        false => 0,
        \\    }
        \\}
    ));
}

test "checker rejects a non-exhaustive enum match expression" {
    try std.testing.expect(!try checkSource(
        \\enum State { ready, waiting }
        \\fn classify(value: State) -> i32 {
        \\    return match value { ready => 1 }
        \\}
    ));
}

test "checker rejects a non-exhaustive Result match expression" {
    try std.testing.expect(!try checkSource(
        \\fn classify(value: Result<i32, string>) -> i32 {
        \\    return match value { Ok(_) => 1 }
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

test "checker resolves exported constants through import aliases" {
    try std.testing.expect(try checkSourceWithImports(
        \\import import_alias_support as support
        \\fn run() -> i32 {
        \\    return support.EXPORTED_VALUE
        \\}
    ));
}

test "checker resolves quoted Home imports relative to the importer" {
    try std.testing.expect(try checkSourceWithImportsAtPath(
        \\import "core/kernel_init.home" as kernel_init
        \\fn run() -> i32 {
        \\    return kernel_init.boot_stage()
        \\}
    , "packages/types/tests/fixtures/kernel/main.home"));
}

test "checker rejects missing import alias members" {
    try std.testing.expect(!try checkSourceWithImports(
        \\import import_alias_support as support
        \\fn run() {
        \\    support.anything
        \\}
    ));
}

test "checker rejects an unresolved import" {
    try std.testing.expect(!try checkSourceWithImports(
        \\import definitely_missing_module as missing
    ));
}

test "checker hides non-public import alias members" {
    try std.testing.expect(try checkSourceWithImportsErrorMessages(
        \\import import_alias_support as support
        \\fn run() {
        \\    support.hidden
        \\}
    , &.{"Module 'support' has no exported member 'hidden'"}, &.{"Struct 'support' has no field 'hidden'"}));
}

test "checker diagnoses missing imported namespace calls without a void cascade" {
    try std.testing.expect(try checkSourceWithImportsErrorMessages(
        \\import import_alias_support as support
        \\fn run() -> i32 {
        \\    return support.hidden_with_argument(missing_value)
        \\}
    , &.{
        "Module 'support' has no exported member 'hidden_with_argument'",
        "Undefined variable",
    }, &.{"Type mismatch"}));
}

test "checker does not retain module identity after an import alias is shadowed" {
    try std.testing.expect(try checkSourceWithImports(
        \\import import_alias_support as support
        \\struct LocalCounter { value: i32 }
        \\fn run() {
        \\    let support = LocalCounter { value: 1 }
        \\    let count = support.len()
        \\}
    ));
}

test "checker preserves imported struct method signatures" {
    try std.testing.expect(try checkSourceWithImports(
        \\import import_alias_support { Counter }
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    let result: i32 = counter.add(2)
        \\}
    ));
}

test "checker validates imported struct method arguments" {
    try std.testing.expect(!try checkSourceWithImports(
        \\import import_alias_support { Counter }
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    counter.add("wrong")
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

test "checker validates inherent impl method arguments" {
    try std.testing.expect(!try checkSource(
        \\struct Counter { value: i32 }
        \\impl Counter {
        \\    fn add(self, amount: i32) -> i32 { return self.value + amount }
        \\}
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    counter.add("wrong")
        \\}
    ));
}

test "checker validates trait impl method arguments" {
    try std.testing.expect(!try checkSource(
        \\trait Adjust { fn add(self, amount: i32): i32; }
        \\struct Counter { value: i32 }
        \\impl Adjust for Counter {
        \\    fn add(self, amount: i32) -> i32 { return self.value + amount }
        \\}
        \\fn run() {
        \\    let counter = Counter { value: 1 }
        \\    counter.add(false)
        \\}
    ));
}

test "checker preserves static method return types" {
    try std.testing.expect(try checkSource(
        \\struct Factory {
        \\    fn make(value: i32) -> i32 { return value }
        \\}
        \\fn run() {
        \\    let result: i32 = Factory::make(1)
        \\}
    ));
}

test "checker validates static method arguments" {
    try std.testing.expect(!try checkSource(
        \\struct Factory {
        \\    fn make(value: i32) -> i32 { return value }
        \\}
        \\fn run() {
        \\    Factory::make("wrong")
        \\}
    ));
}

test "checker rejects missing static methods" {
    try std.testing.expect(!try checkSource(
        \\struct Factory {}
        \\fn run() {
        \\    Factory::missing()
        \\}
    ));
}
