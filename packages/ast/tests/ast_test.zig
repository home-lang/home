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

test "ast: tuple struct literal" {
    const loc = ast.SourceLocation{ .line = 5, .column = 10 };
    const lit = ast.TupleStructLiteral.init("Point", &.{}, loc);

    try testing.expectEqual(ast.NodeType.TupleStructLiteral, lit.node.type);
    try testing.expectEqualStrings("Point", lit.type_name);
    try testing.expectEqual(@as(usize, 5), lit.node.loc.line);
    try testing.expectEqual(@as(usize, 10), lit.node.loc.column);
}

test "ast: anonymous struct" {
    const loc = ast.SourceLocation{ .line = 3, .column = 7 };
    const anon = ast.AnonymousStruct.init(&.{}, loc);

    try testing.expectEqual(ast.NodeType.AnonymousStruct, anon.node.type);
    try testing.expectEqual(@as(usize, 3), anon.node.loc.line);
    try testing.expectEqual(@as(usize, 7), anon.node.loc.column);
}

test "ast: splat expression" {
    const allocator = testing.allocator;
    const loc = ast.SourceLocation{ .line = 2, .column = 4 };

    // Create a simple identifier as the inner expression
    var inner_expr = ast.Expr{ .Identifier = ast.Identifier.init("args", loc) };

    const splat = ast.SplatExpr.init(&inner_expr, .FunctionCall, loc);

    try testing.expectEqual(ast.NodeType.SplatExpr, splat.node.type);
    try testing.expectEqual(ast.SplatExpr.SplatContext.FunctionCall, splat.context);
    try testing.expectEqual(@as(usize, 2), splat.node.loc.line);
    _ = allocator;
}

test "ast: array destructuring" {
    const loc = ast.SourceLocation{ .line = 8, .column = 1 };
    const destruct = ast.ArrayDestructuring.init(&.{}, null, loc);

    try testing.expectEqual(ast.NodeType.ArrayDestructuring, destruct.node.type);
    try testing.expectEqual(@as(usize, 8), destruct.node.loc.line);
    try testing.expectEqual(@as(usize, 1), destruct.node.loc.column);
}

test "ast: object destructuring" {
    const loc = ast.SourceLocation{ .line = 12, .column = 5 };
    const destruct = ast.ObjectDestructuring.init(&.{}, null, loc);

    try testing.expectEqual(ast.NodeType.ObjectDestructuring, destruct.node.type);
    try testing.expectEqual(@as(usize, 12), destruct.node.loc.line);
    try testing.expectEqual(@as(usize, 5), destruct.node.loc.column);
}

test "ast: dispatch call" {
    const loc = ast.SourceLocation{ .line = 15, .column = 3 };
    const call = ast.DispatchCall.init("draw", &.{}, loc);

    try testing.expectEqual(ast.NodeType.DispatchCall, call.node.type);
    try testing.expectEqualStrings("draw", call.function_name);
    try testing.expectEqual(@as(?usize, null), call.resolved_variant);
    try testing.expectEqual(@as(usize, 15), call.node.loc.line);
}

test "ast: expr getLocation for new expression types" {
    const allocator = testing.allocator;

    // Test TupleStructLiteral in Expr
    {
        const loc = ast.SourceLocation{ .line = 10, .column = 20 };
        const lit = try allocator.create(ast.TupleStructLiteral);
        lit.* = ast.TupleStructLiteral.init("Color", &.{}, loc);
        const expr = ast.Expr{ .TupleStructLiteral = lit };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 10), result_loc.line);
        try testing.expectEqual(@as(usize, 20), result_loc.column);
        allocator.destroy(lit);
    }

    // Test AnonymousStruct in Expr
    {
        const loc = ast.SourceLocation{ .line = 11, .column = 21 };
        const anon = try allocator.create(ast.AnonymousStruct);
        anon.* = ast.AnonymousStruct.init(&.{}, loc);
        const expr = ast.Expr{ .AnonymousStruct = anon };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 11), result_loc.line);
        try testing.expectEqual(@as(usize, 21), result_loc.column);
        allocator.destroy(anon);
    }

    // Test SplatExpr in Expr
    {
        const loc = ast.SourceLocation{ .line = 12, .column = 22 };
        var inner_expr = ast.Expr{ .Identifier = ast.Identifier.init("items", loc) };
        const splat = try allocator.create(ast.SplatExpr);
        splat.* = ast.SplatExpr.init(&inner_expr, .ArrayLiteral, loc);
        const expr = ast.Expr{ .SplatExpr = splat };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 12), result_loc.line);
        try testing.expectEqual(@as(usize, 22), result_loc.column);
        allocator.destroy(splat);
    }

    // Test ArrayDestructuring in Expr
    {
        const loc = ast.SourceLocation{ .line = 13, .column = 23 };
        const destruct = try allocator.create(ast.ArrayDestructuring);
        destruct.* = ast.ArrayDestructuring.init(&.{}, null, loc);
        const expr = ast.Expr{ .ArrayDestructuring = destruct };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 13), result_loc.line);
        try testing.expectEqual(@as(usize, 23), result_loc.column);
        allocator.destroy(destruct);
    }

    // Test ObjectDestructuring in Expr
    {
        const loc = ast.SourceLocation{ .line = 14, .column = 24 };
        const destruct = try allocator.create(ast.ObjectDestructuring);
        destruct.* = ast.ObjectDestructuring.init(&.{}, null, loc);
        const expr = ast.Expr{ .ObjectDestructuring = destruct };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 14), result_loc.line);
        try testing.expectEqual(@as(usize, 24), result_loc.column);
        allocator.destroy(destruct);
    }

    // Test DispatchCall in Expr
    {
        const loc = ast.SourceLocation{ .line = 15, .column = 25 };
        const call = try allocator.create(ast.DispatchCall);
        call.* = ast.DispatchCall.init("render", &.{}, loc);
        const expr = ast.Expr{ .DispatchCall = call };
        const result_loc = expr.getLocation();
        try testing.expectEqual(@as(usize, 15), result_loc.line);
        try testing.expectEqual(@as(usize, 25), result_loc.column);
        allocator.destroy(call);
    }
}
