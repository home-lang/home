const std = @import("std");
const ast = @import("ast");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;
const discovery = @import("test_discovery");
const executor = @import("test_executor");

const source =
    \\@test
    \\fn passing() {}
    \\@test
    \\fn failing() { break }
    \\it("inline pass") {}
    \\it("inline fail") { break }
;

const ParsedFixture = struct {
    tokens: std.ArrayList(@import("lexer").Token),
    parser: Parser,
    program: *ast.Program,
    discovered: discovery.TestDiscoveryResult,

    fn init(allocator: std.mem.Allocator) !ParsedFixture {
        var lexer = Lexer.init(allocator, source);
        var tokens = try lexer.tokenize();
        errdefer tokens.deinit(allocator);
        var parser = try Parser.init(allocator, tokens.items);
        errdefer parser.deinit();
        const program = try parser.parse();
        errdefer program.deinit(allocator);
        const discovered = try discovery.discoverTests(allocator, program, "fixture.test.home");
        return .{
            .tokens = tokens,
            .parser = parser,
            .program = program,
            .discovered = discovered,
        };
    }

    fn deinit(self: *ParsedFixture, allocator: std.mem.Allocator) void {
        self.discovered.deinit();
        self.program.deinit(allocator);
        self.parser.deinit();
        self.tokens.deinit(allocator);
        self.* = undefined;
    }
};

const AllocationContext = struct {
    program: *ast.Program,
    discovered: *discovery.TestDiscoveryResult,
};

fn executeWithAllocator(allocator: std.mem.Allocator, context: AllocationContext) !void {
    var result = try executor.executeTestsWithIo(
        allocator,
        std.testing.io,
        context.program,
        context.discovered,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.total);
}

test "executor runs function and inline tests in isolation" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var result = try executor.executeTestsWithIo(
        std.testing.allocator,
        std.testing.io,
        fixture.program,
        &fixture.discovered,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.total);
    try std.testing.expectEqual(@as(usize, 2), result.passed);
    try std.testing.expectEqual(@as(usize, 2), result.failed);
    try std.testing.expect(result.results.items[0].success);
    try std.testing.expect(!result.results.items[1].success);
    try std.testing.expect(result.results.items[2].success);
    try std.testing.expect(!result.results.items[3].success);
    try std.testing.expect(std.mem.indexOf(u8, result.results.items[1].error_message.?, "Break") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.results.items[3].error_message.?, "Break") != null);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try executor.printResults(&result, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "2 passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "fixture.test.home") != null);
}

test "executor releases every partial allocation" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        executeWithAllocator,
        .{AllocationContext{
            .program = fixture.program,
            .discovered = &fixture.discovered,
        }},
    );
}

test "compatibility executor uses the same semantics" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var result = try executor.executeTests(
        std.testing.allocator,
        fixture.program,
        &fixture.discovered,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.passed);
    try std.testing.expectEqual(@as(usize, 2), result.failed);
}
