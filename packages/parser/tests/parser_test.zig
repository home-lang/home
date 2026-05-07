const std = @import("std");
const testing = std.testing;
const home = @import("home");
const Lexer = home.lexer.Lexer;
const Parser = home.parser.Parser;
const ast = home.ast;

fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*ast.Program {
    var lexer = Lexer.init(allocator, source);
    var tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = try Parser.init(allocator, tokens.items);
    defer parser.deinit();

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
    try testing.expectEqual(@as(i128, 42), expr.IntegerLiteral.value);
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
    // Use an identifier so the parser can't fold the expression at parse time
    // (see foldIntegerBinary in parser.zig). The dedicated folding test below
    // covers the literal-on-literal path.
    const program = try parseSource(testing.allocator, "x + 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const binary = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, binary.op);
    try testing.expect(binary.left.* == .Identifier);
    try testing.expectEqualStrings("x", binary.left.Identifier.name);
    try testing.expect(binary.right.* == .IntegerLiteral);
    try testing.expectEqual(@as(i128, 2), binary.right.IntegerLiteral.value);
}

test "parser: binary expression - multiplication" {
    const program = try parseSource(testing.allocator, "x * 4");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const binary = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Mul, binary.op);
}

test "parser: operator precedence" {
    const program = try parseSource(testing.allocator, "x + y * 3");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);

    const add = expr.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, add.op);
    try testing.expect(add.left.* == .Identifier);
    try testing.expect(add.right.* == .BinaryExpr);

    const mul = add.right.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Mul, mul.op);
}

test "parser: integer binary expressions are constant-folded" {
    // The parser folds literal-on-literal arithmetic at parse time so the
    // type checker / codegen never see it. `1 + 2 * 3` should collapse all
    // the way to a single IntegerLiteral with value 7.
    const program = try parseSource(testing.allocator, "1 + 2 * 3");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .IntegerLiteral);
    try testing.expectEqual(@as(i128, 7), expr.IntegerLiteral.value);
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
    try testing.expectEqual(@as(i128, 42), unary.operand.IntegerLiteral.value);
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
    const program = try parseSource(testing.allocator, "if (x > 0) { return x }");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .IfStmt);

    const if_stmt = stmt.IfStmt;
    try testing.expect(if_stmt.condition.* == .BinaryExpr);
    try testing.expectEqual(@as(usize, 1), if_stmt.then_block.statements.len);
    try testing.expect(if_stmt.else_block == null);
}

test "parser: if-else statement" {
    const program = try parseSource(testing.allocator, "if (true) { return 1 } else { return 0 }");
    defer program.deinit(testing.allocator);

    const if_stmt = program.statements[0].IfStmt;
    try testing.expect(if_stmt.else_block != null);
    try testing.expectEqual(@as(usize, 1), if_stmt.else_block.?.statements.len);
}

test "parser: brace-less if statement (single return)" {
    // Issue #48: `if (cond) <stmt>` should parse the same as
    // `if (cond) { <stmt> }`. The single statement is wrapped in a
    // synthetic block so downstream consumers see a uniform shape.
    const program = try parseSource(testing.allocator, "if (cond) return 0;");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .IfStmt);
    const if_stmt = stmt.IfStmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.then_block.statements.len);
    try testing.expect(if_stmt.then_block.statements[0] == .ReturnStmt);
    try testing.expect(if_stmt.else_block == null);
}

test "parser: brace-less if-else (single statements both sides)" {
    const program = try parseSource(testing.allocator, "if (cond) x = 1; else x = 2;");
    defer program.deinit(testing.allocator);

    const if_stmt = program.statements[0].IfStmt;
    try testing.expectEqual(@as(usize, 1), if_stmt.then_block.statements.len);
    try testing.expect(if_stmt.else_block != null);
    try testing.expectEqual(@as(usize, 1), if_stmt.else_block.?.statements.len);
}

test "parser: brace-less if dangling-else binds to innermost" {
    // `if (a) if (b) c() else d()` — the `else` binds to the inner `if`,
    // matching C/Zig/Rust convention. The outer `if` has no else branch.
    const program = try parseSource(testing.allocator, "if (a) if (b) c(); else d();");
    defer program.deinit(testing.allocator);

    const outer = program.statements[0].IfStmt;
    try testing.expect(outer.else_block == null);
    try testing.expectEqual(@as(usize, 1), outer.then_block.statements.len);

    // The wrapped then-block contains exactly the inner `if` statement.
    const inner_stmt = outer.then_block.statements[0];
    try testing.expect(inner_stmt == .IfStmt);
    try testing.expect(inner_stmt.IfStmt.else_block != null);
}

test "parser: brace-less chained else-if" {
    const program = try parseSource(testing.allocator, "if (c) foo(); else if (d) bar(); else baz();");
    defer program.deinit(testing.allocator);

    const outer = program.statements[0].IfStmt;
    try testing.expect(outer.else_block != null);
    // The else-block wraps the `else if` as a single nested IfStmt.
    const else_block = outer.else_block.?;
    try testing.expectEqual(@as(usize, 1), else_block.statements.len);
    try testing.expect(else_block.statements[0] == .IfStmt);

    const middle = else_block.statements[0].IfStmt;
    try testing.expect(middle.else_block != null);
    // The trailing `else baz();` is a single-statement block with one stmt.
    try testing.expectEqual(@as(usize, 1), middle.else_block.?.statements.len);
}

test "parser: regression — braced if with else if and else still works" {
    const program = try parseSource(testing.allocator,
        \\if (c) { foo() } else if (d) { bar() } else { baz() }
    );
    defer program.deinit(testing.allocator);

    const outer = program.statements[0].IfStmt;
    try testing.expectEqual(@as(usize, 1), outer.then_block.statements.len);
    try testing.expect(outer.else_block != null);
    const middle = outer.else_block.?.statements[0].IfStmt;
    try testing.expect(middle.else_block != null);
    try testing.expectEqual(@as(usize, 1), middle.else_block.?.statements.len);
}

test "parser: while statement" {
    const program = try parseSource(testing.allocator, "while (x < 10) { increment(x) }");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .WhileStmt);

    const while_stmt = stmt.WhileStmt;
    try testing.expect(while_stmt.condition.* == .BinaryExpr);
    try testing.expectEqual(@as(usize, 1), while_stmt.body.statements.len);
    // No continue-expression on the plain form.
    try testing.expect(while_stmt.continue_expr == null);
}

test "parser: while-with-continue-expression (Zig form)" {
    // Wrap in a function so `var i: u32 = 0` is allowed.
    const program = try parseSource(
        testing.allocator,
        "fn loop_body(): u32 { var i: u32 = 0; while (i < 10) : (i += 1) { foo(i) }; return 0 }",
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const fn_decl = program.statements[0].FnDecl;

    // The `var i` decl, the `while`, and the `return` are siblings.
    var found: ?*ast.WhileStmt = null;
    for (fn_decl.body.statements) |s| {
        if (s == .WhileStmt) found = s.WhileStmt;
    }
    try testing.expect(found != null);
    const while_stmt = found.?;

    try testing.expect(while_stmt.condition.* == .BinaryExpr);
    try testing.expect(while_stmt.continue_expr != null);
    // The continue-expression is `i += 1` — a compound assignment, which
    // the parser models as an AssignmentExpr.
    try testing.expect(while_stmt.continue_expr.?.* == .AssignmentExpr);
    try testing.expectEqual(@as(usize, 1), while_stmt.body.statements.len);
}

test "parser: while-with-continue-expression nested" {
    const program = try parseSource(
        testing.allocator,
        \\fn nested(): u32 {
        \\    var i: u32 = 0
        \\    var j: u32 = 0
        \\    while (i < 4) : (i += 1) {
        \\        while (j < 4) : (j += 1) {
        \\            foo(i, j)
        \\        }
        \\    }
        \\    return 0
        \\}
        ,
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const fn_decl = program.statements[0].FnDecl;

    var outer: ?*ast.WhileStmt = null;
    for (fn_decl.body.statements) |s| {
        if (s == .WhileStmt) outer = s.WhileStmt;
    }
    try testing.expect(outer != null);
    try testing.expect(outer.?.continue_expr != null);

    // Inner while sits inside the outer body.
    var inner: ?*ast.WhileStmt = null;
    for (outer.?.body.statements) |s| {
        if (s == .WhileStmt) inner = s.WhileStmt;
    }
    try testing.expect(inner != null);
    try testing.expect(inner.?.continue_expr != null);
}

test "parser: while without continue-expression keeps continue_expr null" {
    // Regression: the `:` peek must not fire on the plain form.
    const program = try parseSource(testing.allocator, "while (x < 10) { increment(x) }");
    defer program.deinit(testing.allocator);

    const while_stmt = program.statements[0].WhileStmt;
    try testing.expect(while_stmt.continue_expr == null);
}

test "parser: for statement" {
    const program = try parseSource(testing.allocator, "for (i in items) { process(i) }");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ForStmt);

    const for_stmt = stmt.ForStmt;
    try testing.expectEqualStrings("i", for_stmt.iterator);
    try testing.expect(for_stmt.iterable.* == .Identifier);
    try testing.expectEqualStrings("items", for_stmt.iterable.Identifier.name);
    try testing.expectEqual(@as(usize, 1), for_stmt.body.statements.len);
}

test "parser: for statement Zig-style single iterator" {
    const program = try parseSource(testing.allocator, "for (items) |item| { process(item) }");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ForStmt);

    const for_stmt = stmt.ForStmt;
    try testing.expectEqualStrings("item", for_stmt.iterator);
    try testing.expect(for_stmt.iterable.* == .Identifier);
    try testing.expectEqualStrings("items", for_stmt.iterable.Identifier.name);
    try testing.expect(for_stmt.index == null);
    try testing.expectEqual(@as(usize, 1), for_stmt.body.statements.len);
}

test "parser: for statement Zig-style with index" {
    const program = try parseSource(testing.allocator, "for (items, 0..) |item, idx| { process(item, idx) }");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ForStmt);

    const for_stmt = stmt.ForStmt;
    try testing.expectEqualStrings("item", for_stmt.iterator);
    try testing.expect(for_stmt.index != null);
    try testing.expectEqualStrings("idx", for_stmt.index.?);
    try testing.expect(for_stmt.iterable.* == .Identifier);
    try testing.expectEqualStrings("items", for_stmt.iterable.Identifier.name);
}

test "parser: block statement" {
    const program = try parseSource(testing.allocator, "{ let x = 1; let y = 2 }");
    defer program.deinit(testing.allocator);

    const stmt = program.statements[0];
    try testing.expect(stmt == .BlockStmt);

    const block = stmt.BlockStmt;
    try testing.expectEqual(@as(usize, 2), block.statements.len);
}

test "parser: function declaration" {
    const program = try parseSource(testing.allocator, "fn add(a: int, b: int): int { return a + b }");
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

test "parser: struct declaration" {
    const program = try parseSource(testing.allocator, "struct Point { x: int y: int }");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .StructDecl);

    const struct_decl = stmt.StructDecl;
    try testing.expectEqualStrings("Point", struct_decl.name);
    try testing.expectEqual(@as(usize, 2), struct_decl.fields.len);
    try testing.expectEqualStrings("x", struct_decl.fields[0].name);
    try testing.expectEqualStrings("int", struct_decl.fields[0].type_name);
    try testing.expectEqualStrings("y", struct_decl.fields[1].name);
    try testing.expectEqualStrings("int", struct_decl.fields[1].type_name);
}

test "parser: struct declaration with commas" {
    const program = try parseSource(testing.allocator, "struct Person { name: string, age: int, }");
    defer program.deinit(testing.allocator);

    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("Person", struct_decl.name);
    try testing.expectEqual(@as(usize, 2), struct_decl.fields.len);
    try testing.expectEqualStrings("name", struct_decl.fields[0].name);
    try testing.expectEqualStrings("string", struct_decl.fields[0].type_name);
    try testing.expectEqualStrings("age", struct_decl.fields[1].name);
    try testing.expectEqualStrings("int", struct_decl.fields[1].type_name);
}

// Issue #55: doc-comments (///) inside struct/enum bodies should be
// accepted between items. They are silently consumed for now (future
// work: attach them to the next AST item).
test "parser: struct body accepts /// doc-comments between items" {
    const src =
        \\pub const Foo = struct {
        \\    /// leading doc on first field
        \\    field_a: u32,
        \\
        \\    /// doc between fields
        \\    field_b: u64,
        \\
        \\    /// doc before a method
        \\    pub fn bar(self: *Foo) u32 {
        \\        return self.field_a;
        \\    }
        \\
        \\    /// doc before associated const
        \\    pub const KIND: u8 = 1;
        \\
        \\    /// multi-line doc
        \\    /// continued on next line
        \\    pub fn baz(self: *Foo) u64 {
        \\        return self.field_b;
        \\    }
        \\}
    ;
    const program = try parseSource(testing.allocator, src);
    defer program.deinit(testing.allocator);

    // Should parse cleanly into a single struct decl with two fields
    // and two methods. The associated const is currently skip-parsed
    // (mirrors enum-body / pre-existing struct-body behavior) so it
    // does not appear in the AST yet.
    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .StructDecl);
    const struct_decl = stmt.StructDecl;
    try testing.expectEqualStrings("Foo", struct_decl.name);
    try testing.expectEqual(@as(usize, 2), struct_decl.fields.len);
    try testing.expectEqualStrings("field_a", struct_decl.fields[0].name);
    try testing.expectEqualStrings("field_b", struct_decl.fields[1].name);
    try testing.expectEqual(@as(usize, 2), struct_decl.methods.len);
    try testing.expectEqualStrings("bar", struct_decl.methods[0].name);
    try testing.expectEqualStrings("baz", struct_decl.methods[1].name);
}

test "parser: enum body accepts /// doc-comments between items" {
    // NOTE: associated `const` inside an enum body has a separate
    // parser limitation that's out of scope for #55 — we exercise
    // doc-comments before/between variants and before a method only.
    const src =
        \\pub const Color = enum(u8) {
        \\    /// red channel
        \\    RED,
        \\    /// green channel
        \\    GREEN,
        \\
        \\    /// doc before a method
        \\    pub fn is_warm(self: Color) bool {
        \\        return self == .RED;
        \\    }
        \\}
    ;
    const program = try parseSource(testing.allocator, src);
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .EnumDecl);
    const enum_decl = stmt.EnumDecl;
    try testing.expectEqualStrings("Color", enum_decl.name);
    try testing.expectEqual(@as(usize, 2), enum_decl.variants.len);
    try testing.expectEqualStrings("RED", enum_decl.variants[0].name);
    try testing.expectEqualStrings("GREEN", enum_decl.variants[1].name);
    try testing.expectEqual(@as(usize, 1), enum_decl.methods.len);
    try testing.expectEqualStrings("is_warm", enum_decl.methods[0].name);
}

test "parser: struct without doc-comments still parses identically (regression)" {
    const src =
        \\pub const Bar = struct {
        \\    a: u32,
        \\    b: u32,
        \\
        \\    pub fn sum(self: *Bar) u32 {
        \\        return self.a + self.b;
        \\    }
        \\}
    ;
    const program = try parseSource(testing.allocator, src);
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("Bar", struct_decl.name);
    try testing.expectEqual(@as(usize, 2), struct_decl.fields.len);
    try testing.expectEqual(@as(usize, 1), struct_decl.methods.len);
    try testing.expectEqualStrings("sum", struct_decl.methods[0].name);
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

test "parser: array literal" {
    const program = try parseSource(testing.allocator, "[1, 2, 3]");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);

    const array = expr.ArrayLiteral;
    try testing.expectEqual(@as(usize, 3), array.elements.len);
    try testing.expect(array.elements[0].* == .IntegerLiteral);
    try testing.expect(array.elements[1].* == .IntegerLiteral);
    try testing.expect(array.elements[2].* == .IntegerLiteral);
}

test "parser: empty array literal" {
    const program = try parseSource(testing.allocator, "[]");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expectEqual(@as(usize, 0), expr.ArrayLiteral.elements.len);
}

test "parser: index expression" {
    const program = try parseSource(testing.allocator, "arr[0]");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .IndexExpr);

    const index = expr.IndexExpr;
    try testing.expect(index.array.* == .Identifier);
    try testing.expectEqualStrings("arr", index.array.Identifier.name);
    try testing.expect(index.index.* == .IntegerLiteral);
    try testing.expectEqual(@as(i128, 0), index.index.IntegerLiteral.value);
}

test "parser: member access expression" {
    const program = try parseSource(testing.allocator, "point.x");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .MemberExpr);

    const member = expr.MemberExpr;
    try testing.expect(member.object.* == .Identifier);
    try testing.expectEqualStrings("point", member.object.Identifier.name);
    try testing.expectEqualStrings("x", member.member);
}

test "parser: chained member access" {
    const program = try parseSource(testing.allocator, "obj.field.nested");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .MemberExpr);

    const outer_member = expr.MemberExpr;
    try testing.expectEqualStrings("nested", outer_member.member);
    try testing.expect(outer_member.object.* == .MemberExpr);

    const inner_member = outer_member.object.MemberExpr;
    try testing.expectEqualStrings("field", inner_member.member);
    try testing.expect(inner_member.object.* == .Identifier);
    try testing.expectEqualStrings("obj", inner_member.object.Identifier.name);
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

test "parser: compound assignment += operator" {
    const program = try parseSource(testing.allocator, "x += 5");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .ExprStmt);

    const expr = stmt.ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);

    // Compound assignment is desugared to: x = x + 5
    const assign = expr.AssignmentExpr;
    try testing.expect(assign.target.* == .Identifier);
    try testing.expect(assign.value.* == .BinaryExpr);

    const bin_expr = assign.value.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, bin_expr.op);
}

test "parser: compound assignment -= operator" {
    const program = try parseSource(testing.allocator, "count -= 1");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);

    const assign = expr.AssignmentExpr;
    try testing.expect(assign.value.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.Sub, assign.value.BinaryExpr.op);
}

test "parser: compound assignment *= operator" {
    const program = try parseSource(testing.allocator, "total *= 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);
    try testing.expectEqual(ast.BinaryOp.Mul, expr.AssignmentExpr.value.BinaryExpr.op);
}

test "parser: compound assignment /= operator" {
    const program = try parseSource(testing.allocator, "value /= 10");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);
    try testing.expectEqual(ast.BinaryOp.Div, expr.AssignmentExpr.value.BinaryExpr.op);
}

test "parser: compound assignment %= operator" {
    const program = try parseSource(testing.allocator, "remainder %= 3");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);
    try testing.expectEqual(ast.BinaryOp.Mod, expr.AssignmentExpr.value.BinaryExpr.op);
}

test "parser: compound assignment with complex expression" {
    const program = try parseSource(testing.allocator, "x += y * 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .AssignmentExpr);

    const assign = expr.AssignmentExpr;
    try testing.expect(assign.value.* == .BinaryExpr);

    const add_expr = assign.value.BinaryExpr;
    try testing.expectEqual(ast.BinaryOp.Add, add_expr.op);

    // Right side should be y * 2
    try testing.expect(add_expr.right.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.Mul, add_expr.right.BinaryExpr.op);
}

// ============================================================================
// NEW FEATURE TESTS - and/or keywords, null literal, import syntax, etc.
// ============================================================================

test "parser: null literal" {
    const program = try parseSource(testing.allocator, "null");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .NullLiteral);
}

test "parser: and keyword" {
    const program = try parseSource(testing.allocator, "true and false");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.And, expr.BinaryExpr.op);
}

test "parser: or keyword" {
    const program = try parseSource(testing.allocator, "true or false");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.Or, expr.BinaryExpr.op);
}

test "parser: && operator" {
    const program = try parseSource(testing.allocator, "a && b");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.And, expr.BinaryExpr.op);
}

test "parser: || operator" {
    const program = try parseSource(testing.allocator, "a || b");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.Or, expr.BinaryExpr.op);
}

test "parser: complex boolean with and/or" {
    const program = try parseSource(testing.allocator, "a and b or c");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    // Due to precedence, this should be (a and b) or c
    try testing.expectEqual(ast.BinaryOp.Or, expr.BinaryExpr.op);
}

test "parser: array literal with trailing comma" {
    const program = try parseSource(testing.allocator, "[1, 2, 3,]");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expectEqual(@as(usize, 3), expr.ArrayLiteral.elements.len);
}

// Issue #50 — typed array literals: `[_]T{...}` / `[N]T{...}` where the
// element type can be a simple identifier, a namespaced path, or a
// slice/array/pointer/optional prefix.

test "parser: typed array literal with primitive element type" {
    const program = try parseSource(testing.allocator, "[_]u8{1, 2, 3}");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expectEqual(@as(usize, 3), expr.ArrayLiteral.elements.len);
    try testing.expect(expr.ArrayLiteral.explicit_type != null);
    try testing.expectEqualStrings("[_]u8", expr.ArrayLiteral.explicit_type.?);
}

test "parser: typed array literal with namespaced element type" {
    const program = try parseSource(testing.allocator, "[_]usb.USBDeviceID{}");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expect(expr.ArrayLiteral.explicit_type != null);
    try testing.expectEqualStrings("[_]usb.USBDeviceID", expr.ArrayLiteral.explicit_type.?);
}

test "parser: typed array literal with deeply namespaced element type" {
    const program = try parseSource(testing.allocator, "[_]a.b.c.Foo{}");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expect(expr.ArrayLiteral.explicit_type != null);
    try testing.expectEqualStrings("[_]a.b.c.Foo", expr.ArrayLiteral.explicit_type.?);
}

test "parser: typed array literal with slice element type" {
    const program = try parseSource(testing.allocator, "[_][]const u8{ \"a\", \"b\" }");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expectEqual(@as(usize, 2), expr.ArrayLiteral.elements.len);
    try testing.expect(expr.ArrayLiteral.explicit_type != null);
}

test "parser: typed array literal with array-repeat operator" {
    const program = try parseSource(testing.allocator, "[_]Foo{ Foo{} } ** 16");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.Power, expr.BinaryExpr.op);
    try testing.expect(expr.BinaryExpr.left.* == .ArrayLiteral);
}

test "parser: typed array literal with explicit length" {
    const program = try parseSource(testing.allocator, "[16]u8{1, 2, 3}");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expect(expr.ArrayLiteral.explicit_type != null);
    try testing.expectEqualStrings("[16]u8", expr.ArrayLiteral.explicit_type.?);
}

test "parser: empty array" {
    const program = try parseSource(testing.allocator, "[]");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ArrayLiteral);
    try testing.expectEqual(@as(usize, 0), expr.ArrayLiteral.elements.len);
}

test "parser: range expression" {
    const program = try parseSource(testing.allocator, "0..10");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .RangeExpr);
    try testing.expectEqual(false, expr.RangeExpr.inclusive);
}

test "parser: inclusive range expression" {
    const program = try parseSource(testing.allocator, "0..=10");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .RangeExpr);
    try testing.expectEqual(true, expr.RangeExpr.inclusive);
}

test "parser: not equal comparison" {
    const program = try parseSource(testing.allocator, "x != null");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.NotEqual, expr.BinaryExpr.op);
}

test "parser: bitwise and" {
    const program = try parseSource(testing.allocator, "a & b");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.BitAnd, expr.BinaryExpr.op);
}

test "parser: bitwise or" {
    const program = try parseSource(testing.allocator, "a | b");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.BitOr, expr.BinaryExpr.op);
}

test "parser: bitwise xor" {
    const program = try parseSource(testing.allocator, "a ^ b");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.BitXor, expr.BinaryExpr.op);
}

test "parser: left shift" {
    const program = try parseSource(testing.allocator, "a << 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.LeftShift, expr.BinaryExpr.op);
}

test "parser: right shift" {
    const program = try parseSource(testing.allocator, "a >> 2");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .BinaryExpr);
    try testing.expectEqual(ast.BinaryOp.RightShift, expr.BinaryExpr.op);
}

test "parser: negation" {
    const program = try parseSource(testing.allocator, "-42");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .UnaryExpr);
    try testing.expectEqual(ast.UnaryOp.Neg, expr.UnaryExpr.op);
}

test "parser: logical not" {
    const program = try parseSource(testing.allocator, "!true");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .UnaryExpr);
    try testing.expectEqual(ast.UnaryOp.Not, expr.UnaryExpr.op);
}

test "parser: bitwise not" {
    const program = try parseSource(testing.allocator, "~x");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .UnaryExpr);
    try testing.expectEqual(ast.UnaryOp.BitNot, expr.UnaryExpr.op);
}

test "parser: member access" {
    const program = try parseSource(testing.allocator, "obj.field");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .MemberExpr);
    try testing.expectEqualStrings("field", expr.MemberExpr.member);
}

test "parser: triple chained member access" {
    const program = try parseSource(testing.allocator, "a.b.c");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .MemberExpr);
    try testing.expectEqualStrings("c", expr.MemberExpr.member);
    try testing.expect(expr.MemberExpr.object.* == .MemberExpr);
}

test "parser: array index" {
    const program = try parseSource(testing.allocator, "arr[0]");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .IndexExpr);
}

test "parser: chained index" {
    const program = try parseSource(testing.allocator, "matrix[i][j]");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .IndexExpr);
    try testing.expect(expr.IndexExpr.array.* == .IndexExpr);
}

test "parser: method call" {
    const program = try parseSource(testing.allocator, "obj.method()");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .CallExpr);
}

test "parser: method call with arguments" {
    const program = try parseSource(testing.allocator, "obj.method(1, 2)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .CallExpr);
    try testing.expectEqual(@as(usize, 2), expr.CallExpr.args.len);
}

test "parser: inline asm simple string form" {
    const program = try parseSource(testing.allocator, "asm(\"nop\")");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
    try testing.expectEqualStrings("nop", expr.InlineAsm.instruction);
}

test "parser: inline asm Rust-style asm! macro form" {
    // Rust-style `asm!(...)` with operand grammar (in/out specifiers).
    // The body is captured as an opaque token range — we just need the
    // parser to stop reporting `Expected '(' after 'asm'`.
    const program = try parseSource(
        testing.allocator,
        "asm!(\"mrs {}, CurrentEL\", out(reg) el)",
    );
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
}

test "parser: inline asm Rust-style asm! with multiple operands" {
    const program = try parseSource(
        testing.allocator,
        "asm!(\"rdmsr\", in(\"ecx\") msr, out(\"eax\") lo, out(\"edx\") hi)",
    );
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
}

test "parser: inline asm Zig-style volatile brace form" {
    const program = try parseSource(
        testing.allocator,
        "asm volatile { \"mov %rbp, %0\" : \"=r\" (fp) }",
    );
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
}

test "parser: inline asm Zig-style volatile single-instruction brace form" {
    const program = try parseSource(testing.allocator, "asm volatile { \"hlt\" }");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
}

test "parser: inline asm volatile paren form (existing)" {
    const program = try parseSource(
        testing.allocator,
        "asm volatile (\"mov x0, x1\" : : : \"memory\")",
    );
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .InlineAsm);
}

// Function type aliases (Issue #51) ----------------------------------------
//
// `pub const Name = fn(...) Ret` is routed through the same type-expression
// entry point as struct-field types and variable annotations. The parser
// produces a TypeAliasDecl carrying the function-type as a string in the
// existing string-encoded type slot.

test "parser: const fn-type alias with named params" {
    const program = try parseSource(
        testing.allocator,
        "pub const BlockReadFn = fn(lba: u64, count: u32, buffer: [*]u8) bool",
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .TypeAliasDecl);
    try testing.expectEqualStrings("BlockReadFn", stmt.TypeAliasDecl.name);
    try testing.expect(stmt.TypeAliasDecl.is_public);
    // Named parameters are accepted; only types appear in the encoding.
    try testing.expect(std.mem.indexOf(u8, stmt.TypeAliasDecl.target_type, "u64") != null);
    try testing.expect(std.mem.indexOf(u8, stmt.TypeAliasDecl.target_type, "lba") == null);
    try testing.expect(std.mem.indexOf(u8, stmt.TypeAliasDecl.target_type, "bool") != null);
}

test "parser: const fn-type alias with unnamed params" {
    const program = try parseSource(
        testing.allocator,
        "pub const SyscallHandler = fn(u64, u64, u64, u64, u64, u64) u64",
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .TypeAliasDecl);
    try testing.expectEqualStrings("SyscallHandler", stmt.TypeAliasDecl.name);
    try testing.expect(stmt.TypeAliasDecl.is_public);
}

test "parser: const fn-type alias with void return (no return type)" {
    const program = try parseSource(
        testing.allocator,
        "pub const NoReturn = fn(u64);",
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .TypeAliasDecl);
    try testing.expectEqualStrings("NoReturn", stmt.TypeAliasDecl.name);
}

test "parser: const fn-type alias optional (?fn)" {
    const program = try parseSource(
        testing.allocator,
        "pub const OptArg = ?fn() void;",
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .TypeAliasDecl);
    try testing.expectEqualStrings("OptArg", stmt.TypeAliasDecl.name);
    // Encoding starts with `?` so downstream sees a nullable function type.
    try testing.expect(stmt.TypeAliasDecl.target_type.len > 0);
    try testing.expectEqual(@as(u8, '?'), stmt.TypeAliasDecl.target_type[0]);
}

test "parser: const primitive alias still parses as LetDecl" {
    // Regression: only `fn(...)`-shaped RHS is rerouted; ordinary primitive
    // aliases keep producing a LetDecl with an Identifier RHS.
    const program = try parseSource(testing.allocator, "pub const Foo = u32;");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const stmt = program.statements[0];
    try testing.expect(stmt == .LetDecl);
    try testing.expectEqualStrings("Foo", stmt.LetDecl.name);
    try testing.expect(stmt.LetDecl.is_public);
    try testing.expect(stmt.LetDecl.value != null);
    try testing.expect(stmt.LetDecl.value.?.* == .Identifier);
    try testing.expectEqualStrings("u32", stmt.LetDecl.value.?.Identifier.name);
}

// Issue #57 — `?T` accepts any compound type expression for `T`. Each test
// asserts the encoded `type_name` round-trips so downstream passes see the
// expected string. Parsed via struct-field type position; the same grammar
// handles let-annotations, return types, and parameter types.

test "parser: optional named type — ?Foo" {
    const program = try parseSource(testing.allocator, "struct S { f: ?Foo }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqual(@as(usize, 1), struct_decl.fields.len);
    try testing.expectEqualStrings("?Foo", struct_decl.fields[0].type_name);
}

test "parser: optional primitive — ?u32" {
    const program = try parseSource(testing.allocator, "struct S { f: ?u32 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?u32", struct_decl.fields[0].type_name);
}

test "parser: optional slice — ?[]T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?[]u8 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?[]u8", struct_decl.fields[0].type_name);
}

test "parser: optional const slice — ?[]const T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?[]const u8 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?[]u8", struct_decl.fields[0].type_name);
}

test "parser: optional pointer — ?*T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?*Foo }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?*Foo", struct_decl.fields[0].type_name);
}

test "parser: optional const pointer — ?*const T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?*const Foo }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?*const Foo", struct_decl.fields[0].type_name);
}

test "parser: chained optional pointer — ?*?*T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?*?*Foo }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?*?*Foo", struct_decl.fields[0].type_name);
}

test "parser: optional fixed array — ?[N]T" {
    const program = try parseSource(testing.allocator, "struct S { f: ?[16]u8 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("?[16]u8", struct_decl.fields[0].type_name);
}

test "parser: optional fn-pointer — ?fn() Ret" {
    const program = try parseSource(testing.allocator, "struct S { f: ?fn() void }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    // Encoding starts with `?` so downstream sees a nullable function type.
    try testing.expect(struct_decl.fields[0].type_name.len > 0);
    try testing.expectEqual(@as(u8, '?'), struct_decl.fields[0].type_name[0]);
}

test "parser: double optional — ??T" {
    const program = try parseSource(testing.allocator, "struct S { f: ??u32 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("??u32", struct_decl.fields[0].type_name);
}

// Issue #61: Zig-style error-union types in type position.
// Both `ErrorSet!T` (postfix, explicit error set) and `!T` (prefix,
// anonymous error set) parse and encode as `Result<Payload, ErrorSet>`
// (with `AnyError` as the implicit error set for the anonymous form).

test "parser: error-union return — explicit error set" {
    const program = try parseSource(testing.allocator, "fn foo(): MyError!u32 { return 0 }");
    defer program.deinit(testing.allocator);
    const fn_decl = program.statements[0].FnDecl;
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("Result<u32, MyError>", fn_decl.return_type.?);
}

test "parser: error-union return — explicit error set, void payload" {
    const program = try parseSource(
        testing.allocator,
        "pub fn check_kernel_buffer(ptr: usize, size: usize, write: bool) UsercopyError!void { return }",
    );
    defer program.deinit(testing.allocator);
    const fn_decl = program.statements[0].FnDecl;
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("Result<void, UsercopyError>", fn_decl.return_type.?);
}

test "parser: error-union return — anonymous error set" {
    const program = try parseSource(testing.allocator, "fn foo(): !u32 { return 0 }");
    defer program.deinit(testing.allocator);
    const fn_decl = program.statements[0].FnDecl;
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("Result<u32, AnyError>", fn_decl.return_type.?);
}

test "parser: error-union let-annotation" {
    const program = try parseSource(testing.allocator, "let x: MyError!u32 = bar()");
    defer program.deinit(testing.allocator);
    const decl = program.statements[0].LetDecl;
    try testing.expect(decl.type_name != null);
    try testing.expectEqualStrings("Result<u32, MyError>", decl.type_name.?);
}

test "parser: error-union struct field" {
    const program = try parseSource(testing.allocator, "struct S { f: MyError!u32 }");
    defer program.deinit(testing.allocator);
    const struct_decl = program.statements[0].StructDecl;
    try testing.expectEqualStrings("Result<u32, MyError>", struct_decl.fields[0].type_name);
}

test "parser: error-union fn parameter" {
    const program = try parseSource(testing.allocator, "fn process(r: MyError!u32) void { return }");
    defer program.deinit(testing.allocator);
    const fn_decl = program.statements[0].FnDecl;
    try testing.expectEqual(@as(usize, 1), fn_decl.params.len);
    try testing.expectEqualStrings("Result<u32, MyError>", fn_decl.params[0].type_name);
}

test "parser: error-union with pointer payload" {
    const program = try parseSource(testing.allocator, "fn foo(): MyError!*Foo { return null }");
    defer program.deinit(testing.allocator);
    const fn_decl = program.statements[0].FnDecl;
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("Result<*Foo, MyError>", fn_decl.return_type.?);
}

test "parser: regression — boolean-not still works in expression position" {
    // After adding postfix `!` in type position, `!x` in expression
    // position must still parse as a unary boolean-not.
    const program = try parseSource(testing.allocator, "let y = !x");
    defer program.deinit(testing.allocator);
    const decl = program.statements[0].LetDecl;
    try testing.expectEqualStrings("y", decl.name);
    // The RHS is a unary `!` expression — encoded as UnaryExpr with .Not op.
    try testing.expect(decl.value != null);
    try testing.expect(decl.value.?.* == .UnaryExpr);
    try testing.expectEqual(ast.UnaryOp.Not, decl.value.?.UnaryExpr.op);
}

// Issue #58: @memset / @memcpy accept both 2-arg (Zig 0.11+ slice) and
// 3-arg (legacy ptr+len) forms. The parser only validates arity loosely;
// the typechecker enforces real signatures against actual operand types.

test "parser: @memset 2-arg slice form" {
    const program = try parseSource(testing.allocator, "@memset(buf, 0)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ReflectExpr);
    const reflect = expr.ReflectExpr;
    try testing.expectEqual(ast.ReflectExpr.ReflectKind.MemSet, reflect.kind);
    try testing.expect(reflect.second_arg != null);
    try testing.expect(reflect.third_arg == null);
}

test "parser: @memcpy 2-arg slice form" {
    const program = try parseSource(testing.allocator, "@memcpy(dst, src)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ReflectExpr);
    const reflect = expr.ReflectExpr;
    try testing.expectEqual(ast.ReflectExpr.ReflectKind.MemCpy, reflect.kind);
    try testing.expect(reflect.second_arg != null);
    try testing.expect(reflect.third_arg == null);
}

test "parser: @memset 3-arg legacy form" {
    const program = try parseSource(testing.allocator, "@memset(p, 0, 8)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ReflectExpr);
    const reflect = expr.ReflectExpr;
    try testing.expectEqual(ast.ReflectExpr.ReflectKind.MemSet, reflect.kind);
    try testing.expect(reflect.second_arg != null);
    try testing.expect(reflect.third_arg != null);
}

test "parser: @memcpy 3-arg legacy form" {
    const program = try parseSource(testing.allocator, "@memcpy(d, s, 8)");
    defer program.deinit(testing.allocator);

    const expr = program.statements[0].ExprStmt;
    try testing.expect(expr.* == .ReflectExpr);
    const reflect = expr.ReflectExpr;
    try testing.expectEqual(ast.ReflectExpr.ReflectKind.MemCpy, reflect.kind);
    try testing.expect(reflect.second_arg != null);
    try testing.expect(reflect.third_arg != null);
}

// Issue #60: Zig-style `try expr` error-propagation statement form.
// `try EXPR` (when not followed by `{`) is shorthand for
// `EXPR catch |err| return err` and parses as an ExprStmt wrapping a
// TryExpr with no else branch. The lowering itself is a typecheck-time
// concern; the parser just emits the AST node.
test "parser: try expr statement form (issue #60)" {
    const program = try parseSource(testing.allocator,
        \\fn foo(): u32 {
        \\    try self.bar()
        \\    return 0
        \\}
    );
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
    const fn_stmt = program.statements[0].FnDecl;
    try testing.expect(fn_stmt.body.statements.len >= 1);

    // First statement of body should be ExprStmt -> TryExpr (no else_branch).
    const first = fn_stmt.body.statements[0];
    try testing.expect(first == .ExprStmt);
    try testing.expect(first.ExprStmt.* == .TryExpr);
    try testing.expect(first.ExprStmt.TryExpr.else_branch == null);
    // Operand is a call expression `self.bar()`.
    try testing.expect(first.ExprStmt.TryExpr.operand.* == .CallExpr);
}

test "parser: try expr expression form in let binding (issue #60)" {
    const program = try parseSource(testing.allocator,
        \\fn foo(): u32 {
        \\    let x = try foo()
        \\    return 0
        \\}
    );
    defer program.deinit(testing.allocator);

    const fn_stmt = program.statements[0].FnDecl;
    try testing.expect(fn_stmt.body.statements.len >= 1);

    // First statement of body should be a LetDecl whose initializer is a TryExpr.
    const first = fn_stmt.body.statements[0];
    try testing.expect(first == .LetDecl);
    const init_expr = first.LetDecl.value orelse return error.MissingInitializer;
    try testing.expect(init_expr.* == .TryExpr);
    try testing.expect(init_expr.TryExpr.else_branch == null);
    try testing.expect(init_expr.TryExpr.operand.* == .CallExpr);
}

test "parser: try expr nested as call argument (issue #60)" {
    // `try` as an expression should be usable wherever an expression
    // is — including inside a call's argument list.
    const program = try parseSource(testing.allocator,
        \\fn foo(): u32 {
        \\    let x = try self.method(try other(), 42)
        \\    return 0
        \\}
    );
    defer program.deinit(testing.allocator);

    const fn_stmt = program.statements[0].FnDecl;
    const first = fn_stmt.body.statements[0];
    try testing.expect(first == .LetDecl);
    const init_expr = first.LetDecl.value orelse return error.MissingInitializer;
    try testing.expect(init_expr.* == .TryExpr);
    // Outer try wraps a CallExpr.
    try testing.expect(init_expr.TryExpr.operand.* == .CallExpr);
}

test "parser: try { ... } catch { ... } JS-style still works (regression)" {
    // Issue #60 should not break the existing JS-style try-catch
    // statement form; `try` followed by `{` still selects the
    // try/catch/finally parser.
    const program = try parseSource(testing.allocator,
        \\fn foo(): u32 {
        \\    try {
        \\        risky()
        \\    } catch (e) {
        \\        log(e)
        \\    }
        \\    return 0
        \\}
    );
    defer program.deinit(testing.allocator);

    const fn_stmt = program.statements[0].FnDecl;
    const first = fn_stmt.body.statements[0];
    try testing.expect(first == .TryStmt);
}

test "parser: try expr else fallback expression form still works (regression)" {
    // The pre-existing `try expr else default` form (used as an expression)
    // must keep working — covered by `tryElseExpr` in primary() with the
    // infix `else` operator in `parsePrecedence`. The fallback gets
    // attached to the inner TryExpr because the operand parser already
    // consumes the `else` infix as part of parsing `parse() else 0`.
    const program = try parseSource(testing.allocator,
        \\fn foo(): u32 {
        \\    let x = try parse() else 0
        \\    return x
        \\}
    );
    defer program.deinit(testing.allocator);

    const fn_stmt = program.statements[0].FnDecl;
    const first = fn_stmt.body.statements[0];
    try testing.expect(first == .LetDecl);
    const init_expr = first.LetDecl.value orelse return error.MissingInitializer;
    try testing.expect(init_expr.* == .TryExpr);
    // Either the outer TryExpr or its inner TryExpr-wrapped operand must
    // carry the else_branch — both shapes lower to the same semantics.
    const has_else = init_expr.TryExpr.else_branch != null or
        (init_expr.TryExpr.operand.* == .TryExpr and
            init_expr.TryExpr.operand.TryExpr.else_branch != null);
    try testing.expect(has_else);
}
