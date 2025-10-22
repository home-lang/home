const std = @import("std");
const testing = std.testing;
const codegen = @import("codegen");

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
