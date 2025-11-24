const std = @import("std");
const testing = std.testing;
const codegen = @import("codegen");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;

// Helper to parse Home source code into an AST
fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*ast.Program {
    var lexer = Lexer.init(source);
    var parser = Parser.init(allocator, &lexer);
    return try parser.parseProgram();
}

test "type inference: simple let binding" {
    const allocator = testing.allocator;

    const source =
        \\fn test_func(): i32 {
        \\    let x = 42;
        \\    return x;
        \\}
    ;

    var program = try parseSource(allocator, source);
    defer {
        for (program.statements) |stmt| {
            ast.freeStmt(allocator, stmt);
        }
        allocator.free(program.statements);
        allocator.destroy(program);
    }

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null);
    defer native_codegen.deinit();

    // Run type inference
    const inference_ok = try native_codegen.runTypeInference();
    try testing.expect(inference_ok);

    // Check that type was inferred for variable x
    const inferred_type = try native_codegen.getInferredType("x");
    if (inferred_type) |ty| {
        defer allocator.free(ty);
        // Should infer i32 for literal 42
        try testing.expectEqualStrings("i32", ty);
    } else {
        try testing.expect(false); // Should have inferred a type
    }
}

test "type inference: array literal" {
    const allocator = testing.allocator;

    const source =
        \\fn test_func(): i32 {
        \\    let arr = [1, 2, 3];
        \\    return 0;
        \\}
    ;

    var program = try parseSource(allocator, source);
    defer {
        for (program.statements) |stmt| {
            ast.freeStmt(allocator, stmt);
        }
        allocator.free(program.statements);
        allocator.destroy(program);
    }

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null);
    defer native_codegen.deinit();

    // Run type inference
    const inference_ok = try native_codegen.runTypeInference();
    try testing.expect(inference_ok);

    // Check that array type was inferred
    const inferred_type = try native_codegen.getInferredType("arr");
    if (inferred_type) |ty| {
        defer allocator.free(ty);
        // Should infer [i32] for array of integers
        try testing.expectEqualStrings("[i32]", ty);
    } else {
        try testing.expect(false); // Should have inferred a type
    }
}

test "type inference: boolean literal" {
    const allocator = testing.allocator;

    const source =
        \\fn test_func(): i32 {
        \\    let flag = true;
        \\    return 0;
        \\}
    ;

    var program = try parseSource(allocator, source);
    defer {
        for (program.statements) |stmt| {
            ast.freeStmt(allocator, stmt);
        }
        allocator.free(program.statements);
        allocator.destroy(program);
    }

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null);
    defer native_codegen.deinit();

    // Run type inference
    const inference_ok = try native_codegen.runTypeInference();
    try testing.expect(inference_ok);

    // Check that bool type was inferred
    const inferred_type = try native_codegen.getInferredType("flag");
    if (inferred_type) |ty| {
        defer allocator.free(ty);
        // Should infer bool for boolean literal
        try testing.expectEqualStrings("bool", ty);
    } else {
        try testing.expect(false); // Should have inferred a type
    }
}

test "type inference: binary expression" {
    const allocator = testing.allocator;

    const source =
        \\fn test_func(): i32 {
        \\    let result = 10 + 20;
        \\    return result;
        \\}
    ;

    var program = try parseSource(allocator, source);
    defer {
        for (program.statements) |stmt| {
            ast.freeStmt(allocator, stmt);
        }
        allocator.free(program.statements);
        allocator.destroy(program);
    }

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null);
    defer native_codegen.deinit();

    // Run type inference
    const inference_ok = try native_codegen.runTypeInference();
    try testing.expect(inference_ok);

    // Check that type was inferred for result
    const inferred_type = try native_codegen.getInferredType("result");
    if (inferred_type) |ty| {
        defer allocator.free(ty);
        // Should infer i32 for addition of integers
        try testing.expectEqualStrings("i32", ty);
    } else {
        try testing.expect(false); // Should have inferred a type
    }
}

test "type inference: function parameter propagation" {
    const allocator = testing.allocator;

    const source =
        \\fn add(a: i32, b: i32): i32 {
        \\    let sum = a + b;
        \\    return sum;
        \\}
    ;

    var program = try parseSource(allocator, source);
    defer {
        for (program.statements) |stmt| {
            ast.freeStmt(allocator, stmt);
        }
        allocator.free(program.statements);
        allocator.destroy(program);
    }

    var native_codegen = codegen.NativeCodegen.init(allocator, program, null);
    defer native_codegen.deinit();

    // Run type inference
    const inference_ok = try native_codegen.runTypeInference();
    try testing.expect(inference_ok);

    // Check that type was inferred for sum
    const inferred_type = try native_codegen.getInferredType("sum");
    if (inferred_type) |ty| {
        defer allocator.free(ty);
        // Should infer i32 from parameters
        try testing.expectEqualStrings("i32", ty);
    } else {
        try testing.expect(false); // Should have inferred a type
    }
}
