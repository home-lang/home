const std = @import("std");
const testing = std.testing;
const ion = @import("ion");
const Lexer = ion.lexer.Lexer;
const Parser = ion.parser.Parser;
const ast = ion.ast;

fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*ast.Program {
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items);
    return try parser.parse();
}

test "parser: integer literal" {
    const program = try parseSource(testing.allocator, "42");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ExprStmt);

    const expr = stmt.ExprStmt;
    try testing.expect(expr.* == .IntegerLiteral);
    try testing.expectEqual(@as(i64, 42), expr.IntegerLiteral.value);
}

test "parser: float literal" {
    const program = try parseSource(testing.allocator, "3.14");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .FloatLiteral);
    try testing.expectEqual(@as(f64, 3.14), expr.FloatLiteral.value);
}

test "parser: string literal" {
    const program = try parseSource(testing.allocator, "\"hello\"");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .StringLiteral);
    try testing.expectEqualStrings("hello", expr.StringLiteral.value);
}

test "parser: boolean literals" {
    const program_true = try parseSource(testing.allocator, "true");
    defer program_true.deinit(testing.allocator);

    const expr_true = program_true.statements[0].ExprStmt;
    try testing.expect(expr_true.* == .BooleanLiteral);
    try testing.expectEqual(true, expr_true.BooleanLiteral.value);

    const program_false = try parseSource(testing.allocator, "false");
    defer program_false.deinit(testing.allocator);

    const expr_false = program_false.statements[0].ExprStmt;
    try testing.expect(expr_false.* == .BooleanLiteral);
    try testing.expectEqual(false, expr_false.BooleanLiteral.value);
}

test "parser: identifier" {
    const program = try parseSource(testing.allocator, "foo");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .Identifier);
    try testing.expectEqualStrings("foo", expr.Identifier.name);
}

test "parser: binary expression - addition" {
    const program = try parseSource(testing.allocator, "1 + 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const binary = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, binary.op);
    try testing.expect(binary.left.* == .IntegerLiteral);
    try testing.expectEqual(@as(i64, 1), binary.left.IntegerLiteral.value);
    try testing.expect(binary.right.* == .IntegerLiteral);
    try testing.expectEqual(@as(i64, 2), binary.right.IntegerLiteral.value);
}

test "parser: binary expression - multiplication" {
    const program = try parseSource(testing.allocator, "3 * 4");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const binary = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Mul, binary.op);
}

test "parser: operator precedence" {
    const program = try parseSource(testing.allocator, "1 + 2 * 3");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const add = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, add.op);
    try testing.expect(add.left.* == .IntegerLiteral);
    try testing.expect(add.right.* == .BinaryExpr);

    const mul = add.right.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Mul, mul.op);
}

test "parser: comparison operators" {
    const program = try parseSource(testing.allocator, "x > 5");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const binary = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Greater, binary.op);
}

test "parser: unary expression" {
    const program = try parseSource(testing.allocator, "-42");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .UnaryExpr);

    const unary = expr.UnaryExpr;
    try testing.expectEqual(ast.UnaryOp.Neg, unary.op);
    try testing.expect(unary.operand.* == .IntegerLiteral);
    try testing.expectEqual(@as(i64, 42), unary.operand.IntegerLiteral.value);
}

test "parser: call expression" {
    const program = try parseSource(testing.allocator, "foo()");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .CallExpr);

    const call = expr.CallExpr;
    try testing.expect(call.callee.* == .Identifier);
    try testing.expectEqualStrings("foo", call.callee.Identifier.name);
    try testing.expectEqual(@as(usize, 0), call.args.len);
}

test "parser: call expression with arguments" {
    const program = try parseSource(testing.allocator, "add(1, 2)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .CallExpr);

    const call = expr.CallExpr;
    try testing.expectEqual(@as(usize, 2), call.args.len);
    try testing.expect(call.args[0].* == .IntegerLiteral);
    try testing.expect(call.args[1].* == .IntegerLiteral);
}

test "parser: let declaration" {
    const program = try parseSource(testing.allocator, "let x = 42");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .LetDecl);

    const decl = stmt.LetDecl;
    try testing.expectEqualStrings("x", decl.name);
    try testing.expect(decl.value != null);
    try testing.expect(decl.value.?.* == .IntegerLiteral);
}

test "parser: let declaration with type" {
    const program = try parseSource(testing.allocator, "let x: int = 42");
    defer program.deinit(testing.allocator);

    const decl = program.statements[0].LetDecl;
    try testing.expectEqualStrings("x", decl.name);
    try testing.expect(decl.type_name != null);
    try testing.expectEqualStrings("int", decl.type_name.?);
}

test "parser: mutable let declaration" {
    const program = try parseSource(testing.allocator, "let mut x = 10");
    defer program.deinit(testing.allocator);

    const decl = program.statements[0].LetDecl;
    try testing.expect(decl.is_mutable);
}

test "parser: return statement" {
    const program = try parseSource(testing.allocator, "return 42");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ReturnStmt);

    const ret = stmt.ReturnStmt;
    try testing.expect(ret.value != null);
    try testing.expect(ret.value.?.* == .IntegerLiteral);
}

test "parser: return statement without value" {
    const program = try parseSource(testing.allocator, "return");
    defer program.deinit(testing.allocator);

    const ret = program.statements[0].ReturnStmt;
    try testing.expect(ret.value == null);
}

test "parser: if statement" {
    const program = try parseSource(testing.allocator, "if x > 0 { return x }");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .IfStmt);

    const if_stmt = stmt.IfStmt;
    try testing.expect(if_stmt.condition.* == .BinaryExpr);
    try testing.expectEqual(@as(usize, 1), if_stmt.then_block.statements.len);
    try testing.expect(if_stmt.else_block == null);
}

test "parser: if-else statement" {
    const program = try parseSource(testing.allocator, "if true { return 1 } else { return 0 }");
    defer program.deinit(testing.allocator);

    const if_stmt = program.statements[0].IfStmt;
    try testing.expect(if_stmt.else_block != null);
    try testing.expectEqual(@as(usize, 1), if_stmt.else_block.?.statements.len);
}

test "parser: block statement" {
    const program = try parseSource(testing.allocator, "{ let x = 1 let y = 2 }");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .BlockStmt);

    const block = stmt.BlockStmt;
    try testing.expectEqual(@as(usize, 2), block.statements.len);
}

test "parser: function declaration" {
    const program = try parseSource(testing.allocator, "fn add(a: int, b: int) -> int { return a + b }");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .FnDecl);

    const fn_decl = stmt.FnDecl;
    try testing.expectEqualStrings("add", fn_decl.name);
    try testing.expectEqual(@as(usize, 2), fn_decl.params.len);
    try testing.expectEqualStrings("a", fn_decl.params[0].name);
    try testing.expectEqualStrings("int", fn_decl.params[0].type_name);
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("int", fn_decl.return_type.?);
}

test "parser: function without parameters" {
    const program = try parseSource(testing.allocator, "fn main() { }");
    defer program.deinit(testing.allocator);

    const fn_decl = program.statements[0].FnDecl;
    try testing.expectEqualStrings("main", fn_decl.name);
    try testing.expectEqual(@as(usize, 0), fn_decl.params.len);
    try testing.expect(fn_decl.return_type == null);
}

test "parser: complex expression" {
    const program = try parseSource(testing.allocator, "(x + y) * z >= 100");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    // Should parse as: ((x + y) * z) >= 100
    const comparison = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.GreaterEq, comparison.op);
    try testing.expect(comparison.left.* == .BinaryExpr);
}

test "parser: multiple statements" {
    const program = try parseSource(testing.allocator,
        \\let x = 10
        \\let y = 20
        \\return x + y
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), program.statements.len);
    try testing.expect(program.statements[0] == .LetDecl);
    try testing.expect(program.statements[1] == .LetDecl);
    try testing.expect(program.statements[2] == .ReturnStmt);
}
