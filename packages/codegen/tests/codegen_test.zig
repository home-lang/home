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

    const panic_prefix = "panic: non-exhaustive match expression: no arm matched value ";
    var found = false;
    for (native_codegen.string_literals.items) |literal| {
        if (std.mem.eql(u8, literal, panic_prefix)) found = true;
    }
    try testing.expect(found);
}
