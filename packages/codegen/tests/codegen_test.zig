const std = @import("std");
const testing = std.testing;
const codegen = @import("codegen");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;

test "codegen: x64 assembler creation" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try testing.expect(true);
}

test "codegen: emit push instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.pushReg(.rbp);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit pop instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.popReg(.rbp);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit mov register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.movRegReg(.rax, .rbx);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit mov immediate to register" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.movRegImm64(.rax, 42);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit syscall" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.syscall();

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit xor register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.xorRegReg(.rax, .rax);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit add register to register" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.addRegReg(.rax, .rbx);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit sub register from register" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.subRegReg(.rax, .rbx);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: emit return instruction" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    try assembler.ret();

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: function prologue pattern" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    // Standard x64 function prologue
    try assembler.pushReg(.rbp);
    try assembler.movRegReg(.rbp, .rsp);

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: function epilogue pattern" {
    const allocator = testing.allocator;

    var assembler = codegen.x64.Assembler.init(allocator);
    defer assembler.deinit();

    // Standard x64 function epilogue
    try assembler.movRegReg(.rsp, .rbp);
    try assembler.popReg(.rbp);
    try assembler.ret();

    const code = try assembler.getCode();
    defer allocator.free(code);

    try testing.expect(code.len > 0);
}

test "codegen: match expression fallthrough emits a non-returning panic" {
    const allocator = testing.allocator;
    const source =
        \\fn classify(value: bool) -> i32 {
        \\    return match value { true => 1 }
        \\}
    ;
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null, null);
    defer native_codegen.deinit();
    const machine_code = try native_codegen.generate();
    defer allocator.free(machine_code);

    var found = false;
    for (native_codegen.string_literals.items) |literal| {
        if (std.mem.startsWith(u8, literal, codegen.match_expression_fallthrough_panic)) found = true;
    }
    try testing.expect(found);
}

test "codegen: unmatched match expression executable exits instead of returning zero" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> i32 {
        \\    return match true { false => 7 }
        \\}
    ;
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_path);
    const executable_path = try std.fs.path.join(allocator, &.{ dir_path, "match-fallthrough" });
    defer allocator.free(executable_path);

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null, null);
    defer native_codegen.deinit();
    native_codegen.io = testing.io;
    try native_codegen.writeExecutable(executable_path);

    const result = try std.process.run(allocator, testing.io, .{
        .argv = &.{executable_path},
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 101) {
        std.debug.print("match fallthrough term={} stderr={s}\n", .{ result.term, result.stderr });
    }
    try testing.expectEqual(std.process.Child.Term{ .exited = 101 }, result.term);
    try testing.expect(std.mem.indexOf(u8, result.stderr, codegen.match_expression_fallthrough_panic) != null);
}
