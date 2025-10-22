const std = @import("std");
const testing = std.testing;
const ast = @import("ast");

test "ast: source location" {
    const loc = ast.SourceLocation{ .line = 10, .column = 25 };

    try testing.expectEqual(@as(usize, 10), loc.line);
    try testing.expectEqual(@as(usize, 25), loc.column);
}

test "ast: node types enum" {
    // Verify node type enums exist and are different
    try testing.expect(ast.NodeType.IntegerLiteral != ast.NodeType.FloatLiteral);
    try testing.expect(ast.NodeType.StringLiteral != ast.NodeType.BooleanLiteral);
    try testing.expect(ast.NodeType.Identifier != ast.NodeType.BinaryExpr);
    try testing.expect(ast.NodeType.LetDecl != ast.NodeType.FnDecl);
}

test "ast: integer literal" {
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const lit = ast.IntegerLiteral.init(42, loc);

    try testing.expectEqual(ast.NodeType.IntegerLiteral, lit.node.type);
    try testing.expectEqual(@as(i64, 42), lit.value);
    try testing.expectEqual(@as(usize, 1), lit.node.loc.line);
}

test "ast: float literal" {
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const lit = ast.FloatLiteral.init(3.14, loc);

    try testing.expectEqual(ast.NodeType.FloatLiteral, lit.node.type);
    try testing.expectEqual(@as(f64, 3.14), lit.value);
}

test "ast: boolean literal" {
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const lit = ast.BooleanLiteral.init(true, loc);

    try testing.expectEqual(ast.NodeType.BooleanLiteral, lit.node.type);
    try testing.expectEqual(true, lit.value);
}

test "ast: string literal" {
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const lit = ast.StringLiteral.init("hello", loc);

    try testing.expectEqual(ast.NodeType.StringLiteral, lit.node.type);
    try testing.expectEqualStrings("hello", lit.value);
}

test "ast: identifier" {
    const loc = ast.SourceLocation{ .line = 1, .column = 1 };
    const ident = ast.Identifier.init("variable_name", loc);

    try testing.expectEqual(ast.NodeType.Identifier, ident.node.type);
    try testing.expectEqualStrings("variable_name", ident.name);
}
