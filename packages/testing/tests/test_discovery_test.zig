const std = @import("std");
const ast = @import("ast");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;
const discovery = @import("test_discovery");

const source =
    \\@test
    \\fn legacy_style() {}
    \\it("inline style") {}
    \\test "block style" {}
    \\fn helper() {}
    \\@deprecated
    \\union Payload { Number(i32), Text: string }
;

const AllocationContext = struct {
    program: *ast.Program,
};

fn discoverWithAllocator(allocator: std.mem.Allocator, context: AllocationContext) !void {
    var result = try discovery.discoverTests(allocator, context.program, "fixture.test.home");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.tests.items.len);
}

test "discovers annotated inline and block tests from the real parser AST" {
    var lex = Lexer.init(std.testing.allocator, source);
    var tokens = try lex.tokenize();
    defer tokens.deinit(std.testing.allocator);

    var parser = try Parser.init(std.testing.allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    var result = try discovery.discoverTests(std.testing.allocator, program, "fixture.test.home");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.tests.items.len);
    try std.testing.expectEqualStrings("legacy_style", result.tests.items[0].name);
    try std.testing.expectEqualStrings("inline style", result.tests.items[1].name);
    try std.testing.expectEqualStrings("block style", result.tests.items[2].name);
    for (result.tests.items) |test_item| {
        try std.testing.expectEqualStrings("fixture.test.home", test_item.file_path);
        try std.testing.expect(test_item.line > 0);
    }

    try std.testing.expect(result.tests.items[0].decl == .fn_decl);
    try std.testing.expect(result.tests.items[1].decl == .it_decl);
    try std.testing.expect(result.tests.items[2].decl == .it_decl);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        discoverWithAllocator,
        .{AllocationContext{ .program = program }},
    );
}

test "test function validation preserves semantic checks" {
    var lex = Lexer.init(std.testing.allocator, source);
    var tokens = try lex.tokenize();
    defer tokens.deinit(std.testing.allocator);

    var parser = try Parser.init(std.testing.allocator, tokens.items);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try discovery.validateTestFunction(program.statements[0].FnDecl);
}

test "attribute lists destroy owned argument nodes but not borrowed lexemes" {
    const argument = try std.testing.allocator.create(ast.Expr);
    argument.* = .{
        .StringLiteral = ast.StringLiteral.init(
            "borrowed value",
            .{ .line = 1, .column = 1 },
        ),
    };

    const arguments = try std.testing.allocator.alloc(*ast.Expr, 1);
    arguments[0] = argument;
    const attributes = try std.testing.allocator.alloc(ast.Attribute, 1);
    attributes[0] = ast.Attribute.init("borrowed name", arguments);

    var list = ast.AttributeList.init(attributes);
    list.deinit(std.testing.allocator);
}
