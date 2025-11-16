const std = @import("std");
const testing = std.testing;
const Lexer = @import("lexer");
const Parser = @import("parser");

test "TypeScript-style colon syntax for function return types" {
    const source = "fn add(a: int, b: int): int { return a + b }";

    var lexer = Lexer.Lexer.init(testing.allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = try Parser.Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);

    const stmt = program.statements[0];
    try testing.expect(stmt == .FnDecl);

    const fn_decl = stmt.FnDecl;
    try testing.expectEqualStrings("add", fn_decl.name);
    try testing.expect(fn_decl.return_type != null);
    try testing.expectEqualStrings("int", fn_decl.return_type.?);
}

test "TypeScript-style colon syntax for closures" {
    const source = "let multiply = |a: i32, b: i32|: i32 { a * b };";

    var lexer = Lexer.Lexer.init(testing.allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    var parser = try Parser.Parser.init(testing.allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
}
