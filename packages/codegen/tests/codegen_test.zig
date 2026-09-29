const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const codegen = @import("codegen");
const Lexer = @import("lexer").Lexer;
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const SymbolTable = parser_mod.SymbolTable;
const ModuleResolver = parser_mod.ModuleResolver;
const TypeChecker = @import("types").TypeChecker;
const ComptimeValueStore = @import("comptime").integration.ComptimeValueStore;

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

test "codegen: undefined reserves storage without writing a zero initializer" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> i32 {
        \\    var value: i32 = undefined
        \\    var bytes: [4]u8 = undefined
        \\    return 0
        \\}
    ;
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var checker = TypeChecker.init(allocator, program);
    defer checker.deinit();
    try testing.expect(try checker.check());

    var x64_codegen = codegen.NativeCodegen.init(allocator, program, null, null);
    defer x64_codegen.deinit();
    const x64_code = try x64_codegen.generate();
    defer allocator.free(x64_code);
    try testing.expectEqual(@as(usize, 32), x64_codegen.locals.get("bytes").?.size);
    const zero_then_push = [_]u8{ 0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0x50 };
    try testing.expect(std.mem.indexOf(u8, x64_code, &zero_then_push) == null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_path);
    const arm64_path = try std.fs.path.join(allocator, &.{ dir_path, "undefined-arm64" });
    defer allocator.free(arm64_path);
    var arm64_codegen = codegen.Aarch64NativeCodegen.init(allocator, program);
    defer arm64_codegen.deinit();
    arm64_codegen.io = testing.io;
    try arm64_codegen.writeExecutable(arm64_path);
    try testing.expectEqual(@as(u32, 4), arm64_codegen.local_array_lens.get("bytes").?);
    var pos: usize = 0;
    while (pos + 4 <= arm64_codegen.assembler.code.items.len) : (pos += 4) {
        const instruction = std.mem.readInt(u32, arm64_codegen.assembler.code.items[pos..][0..4], .little);
        try testing.expect(instruction & 0xffc00000 != 0xf9000000);
    }

    var symbol_table = SymbolTable.init(allocator);
    defer symbol_table.deinit();
    var module_resolver = try ModuleResolver.init(allocator, null);
    defer module_resolver.deinit();
    var kernel_codegen = codegen.HomeKernelCodegen.init(allocator, &symbol_table, &module_resolver);
    defer kernel_codegen.deinit();
    const assembly = try kernel_codegen.generate(program);
    try testing.expect(std.mem.indexOf(u8, assembly, "movq %rax, -") == null);
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

test "codegen: comptime values are evaluated before native emission" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> i32 {
        \\    return comptime 6 * 7
        \\}
    ;
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(allocator);

    var comptime_store = ComptimeValueStore.init(allocator);
    defer comptime_store.deinit();
    var checker = TypeChecker.initWithComptime(allocator, program, &comptime_store);
    defer checker.deinit();
    const type_check_passed = try checker.check();
    if (!type_check_passed) {
        for (checker.errors.items) |type_error| {
            std.debug.print("comptime type error: {s} at {d}:{d}\n", .{
                type_error.message,
                type_error.loc.line,
                type_error.loc.column,
            });
        }
    }
    try testing.expect(type_check_passed);
    try testing.expectEqual(@as(usize, 1), comptime_store.values.count());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_path);
    const executable_path = try std.fs.path.join(allocator, &.{ dir_path, "comptime-result" });
    defer allocator.free(executable_path);

    var native_codegen = codegen.NativeCodegen.init(allocator, program, &comptime_store, null);
    defer native_codegen.deinit();
    native_codegen.io = testing.io;
    try native_codegen.writeExecutable(executable_path);

    const result = try std.process.run(allocator, testing.io, .{
        .argv = &.{executable_path},
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
}

test "codegen: dynamic arrays use mapped native storage" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = testing.allocator;
    const source =
        \\fn main() -> i32 {
        \\    let mut values = Array.new()
        \\    values.push(7)
        \\    return values.pop()
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
    const executable_path = try std.fs.path.join(allocator, &.{ dir_path, "mapped-array" });
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
    try testing.expectEqual(std.process.Child.Term{ .exited = 7 }, result.term);
}

test "codegen: native module symbols keep same-named helpers distinct" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "left.home", .data = "fn helper() -> i32 { return 19 }\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "right.home", .data = "fn helper() -> i32 { return 23 }\n" });

    const source =
        \\import left as left
        \\import right as right
        \\fn main() -> i32 { return left.helper() + right.helper() }
    ;
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);
    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();
    parser.module_resolver.io = testing.io;
    try parser.module_resolver.setSourceRootDirect(root);
    const program = try parser.parse();
    defer program.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main.home" });
    defer allocator.free(main_path);

    const arm64_path = try std.fs.path.join(allocator, &.{ root, "module-symbols-arm64" });
    defer allocator.free(arm64_path);
    var arm64_codegen = codegen.Aarch64NativeCodegen.init(allocator, program);
    defer arm64_codegen.deinit();
    arm64_codegen.io = testing.io;
    try arm64_codegen.setSourceRoot(main_path);
    switch (builtin.os.tag) {
        .macos, .linux => try arm64_codegen.writeExecutable(arm64_path),
        else => arm64_codegen.writeExecutable(arm64_path) catch |err| {
            try testing.expectEqual(error.UnsupportedPlatform, err);
        },
    }
    const arm64_left = arm64_codegen.functions.get("left::helper") orelse return error.TestUnexpectedResult;
    const arm64_right = arm64_codegen.functions.get("right::helper") orelse return error.TestUnexpectedResult;
    try testing.expect(arm64_left != arm64_right);
    const arm64_main = arm64_codegen.functions.get("main") orelse return error.TestUnexpectedResult;
    var arm64_calls_left = false;
    var arm64_calls_right = false;
    var arm64_call_pos = arm64_main;
    while (arm64_call_pos + 4 <= arm64_codegen.assembler.code.items.len) : (arm64_call_pos += 4) {
        const instruction = std.mem.readInt(u32, arm64_codegen.assembler.code.items[arm64_call_pos..][0..4], .little);
        if (instruction & 0xfc000000 != 0x94000000) continue;
        const immediate = instruction & 0x03ffffff;
        var word_offset: i64 = immediate;
        if (immediate & 0x02000000 != 0) word_offset -= 1 << 26;
        const target = @as(i64, @intCast(arm64_call_pos)) + word_offset * 4;
        if (target == @as(i64, @intCast(arm64_left))) arm64_calls_left = true;
        if (target == @as(i64, @intCast(arm64_right))) arm64_calls_right = true;
    }
    try testing.expect(arm64_calls_left);
    try testing.expect(arm64_calls_right);

    var x64_codegen = codegen.NativeCodegen.init(allocator, program, null, null);
    defer x64_codegen.deinit();
    x64_codegen.io = testing.io;
    try x64_codegen.setSourceRoot(main_path);
    const x64_code = try x64_codegen.generate();
    defer allocator.free(x64_code);
    const x64_left = x64_codegen.functions.get("left::helper") orelse return error.TestUnexpectedResult;
    const x64_right = x64_codegen.functions.get("right::helper") orelse return error.TestUnexpectedResult;
    try testing.expect(x64_left != x64_right);
    const x64_main = x64_codegen.functions.get("main") orelse return error.TestUnexpectedResult;
    var x64_calls_left = false;
    var x64_calls_right = false;
    var x64_call_pos = x64_main;
    while (x64_call_pos + 5 <= x64_code.len) : (x64_call_pos += 1) {
        if (x64_code[x64_call_pos] != 0xe8) continue;
        const relative = std.mem.readInt(i32, x64_code[x64_call_pos + 1 ..][0..4], .little);
        const target = @as(i64, @intCast(x64_call_pos + 5)) + @as(i64, relative);
        if (target == @as(i64, @intCast(x64_left))) x64_calls_left = true;
        if (target == @as(i64, @intCast(x64_right))) x64_calls_right = true;
    }
    try testing.expect(x64_calls_left);
    try testing.expect(x64_calls_right);
}
