const std = @import("std");
const testing = std.testing;
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;
const ast = @import("ast");

fn parseExpression(allocator: std.mem.Allocator, source: []const u8) !*ast.Expr {
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items);
    defer parser.deinit();

    return try parser.parseExpression();
}

test "parse simple interpolated string" {
    const allocator = testing.allocator;
    const expr = try parseExpression(allocator, "\"Hello {name}!\"");
    defer allocator.destroy(expr);

    try testing.expectEqual(ast.NodeType.InterpolatedString, @as(ast.NodeType, expr.*));

    const interp = expr.InterpolatedString;
    try testing.expectEqual(@as(usize, 2), interp.parts.len);
    try testing.expectEqualStrings("Hello ", interp.parts[0]);
    try testing.expectEqualStrings("!", interp.parts[1]);

    try testing.expectEqual(@as(usize, 1), interp.expressions.len);
    try testing.expectEqual(ast.NodeType.Identifier, @as(ast.NodeType, interp.expressions[0]));
}

test "parse multiple interpolations" {
    const allocator = testing.allocator;
    const expr = try parseExpression(allocator, "\"Hello {first} {last}!\"");
    defer allocator.destroy(expr);

    const interp = expr.InterpolatedString;
    try testing.expectEqual(@as(usize, 3), interp.parts.len);
    try testing.expectEqualStrings("Hello ", interp.parts[0]);
    try testing.expectEqualStrings(" ", interp.parts[1]);
    try testing.expectEqualStrings("!", interp.parts[2]);

    try testing.expectEqual(@as(usize, 2), interp.expressions.len);
}

test "parse interpolation with expression" {
    const allocator = testing.allocator;
    const expr = try parseExpression(allocator, "\"Result: {x + 1}\"");
    defer allocator.destroy(expr);

    const interp = expr.InterpolatedString;
    try testing.expectEqual(@as(usize, 2), interp.parts.len);
    try testing.expectEqual(@as(usize, 1), interp.expressions.len);

    // The expression should be a binary expression
    try testing.expectEqual(ast.NodeType.BinaryExpr, @as(ast.NodeType, interp.expressions[0]));
}

test "parse interpolation with function call" {
    const allocator = testing.allocator;
    const expr = try parseExpression(allocator, "\"Value: {foo(x)}\"");
    defer allocator.destroy(expr);

    const interp = expr.InterpolatedString;
    try testing.expectEqual(@as(usize, 2), interp.parts.len);
    try testing.expectEqual(@as(usize, 1), interp.expressions.len);

    // The expression should be a call expression
    try testing.expectEqual(ast.NodeType.CallExpr, @as(ast.NodeType, interp.expressions[0]));
}

test "parse empty interpolation parts" {
    const allocator = testing.allocator;
    const expr = try parseExpression(allocator, "\"{x}\"");
    defer allocator.destroy(expr);

    const interp = expr.InterpolatedString;
    try testing.expectEqual(@as(usize, 2), interp.parts.len);
    try testing.expectEqualStrings("", interp.parts[0]);
    try testing.expectEqualStrings("", interp.parts[1]);
    try testing.expectEqual(@as(usize, 1), interp.expressions.len);
}
