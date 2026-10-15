const std = @import("std");
const ast = @import("ast");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;
const TestRunner = @import("test_runner").TestRunner;

const source =
    \\@test
    \\fn passing() {}
    \\@test
    \\fn failing() { break }
;

const ParsedFixture = struct {
    tokens: std.ArrayList(@import("lexer").Token),
    parser: Parser,
    program: *ast.Program,

    fn init(allocator: std.mem.Allocator) !ParsedFixture {
        var lexer = Lexer.init(allocator, source);
        var tokens = try lexer.tokenize();
        errdefer tokens.deinit(allocator);
        var parser = try Parser.init(allocator, tokens.items);
        errdefer parser.deinit();
        const program = try parser.parse();
        return .{ .tokens = tokens, .parser = parser, .program = program };
    }

    fn deinit(self: *ParsedFixture, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
        self.parser.deinit();
        self.tokens.deinit(allocator);
        self.* = undefined;
    }
};

fn findFunction(program: *const ast.Program, name: []const u8) *ast.FnDecl {
    for (program.statements) |statement| switch (statement) {
        .FnDecl => |function| if (std.mem.eql(u8, function.name, name)) return function,
        else => {},
    };
    unreachable;
}

fn case(name: []const u8, function: *ast.FnDecl) TestRunner.TestCase {
    return .{
        .name = name,
        .fn_decl = function,
        .file_path = "fixture.test.home",
        .line = function.node.loc.line,
    };
}

const AllocationContext = struct {
    program: *ast.Program,
    passing: *ast.FnDecl,
};

fn runParallelWithAllocator(allocator: std.mem.Allocator, context: AllocationContext) !void {
    var runner = TestRunner.init(allocator, std.testing.io, context.program, .{
        .parallel = true,
        .max_threads = 2,
    });
    defer runner.deinit();
    for (0..4) |_| try runner.addTest(case("passing", context.passing));
    try runner.runAll();
    try std.testing.expectEqual(@as(usize, 4), runner.results.items.len);
}

test "sequential execution reports pass and interpreter failure" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var runner = TestRunner.init(std.testing.allocator, std.testing.io, fixture.program, .{});
    defer runner.deinit();
    try runner.addTest(case("passing", findFunction(fixture.program, "passing")));
    try runner.addTest(case("failing", findFunction(fixture.program, "failing")));

    try runner.runAll();
    try std.testing.expectEqual(@as(usize, 2), runner.results.items.len);
    try std.testing.expectEqual(TestRunner.TestResult.Status.Passed, runner.results.items[0].status);
    try std.testing.expectEqual(TestRunner.TestResult.Status.Failed, runner.results.items[1].status);
    try std.testing.expect(std.mem.indexOf(u8, runner.results.items[1].message.?, "Break") != null);
    try std.testing.expectEqual(@as(u8, 1), runner.getExitCode());
}

test "filtering and fail-fast preserve test selection and order" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var filtered = TestRunner.init(std.testing.allocator, std.testing.io, fixture.program, .{ .filter = "pass" });
    defer filtered.deinit();
    try filtered.addTest(case("passing", findFunction(fixture.program, "passing")));
    try filtered.addTest(case("failing", findFunction(fixture.program, "failing")));
    try filtered.runAll();
    try std.testing.expectEqual(@as(usize, 1), filtered.results.items.len);
    try std.testing.expectEqual(@as(u8, 0), filtered.getExitCode());

    var fail_fast = TestRunner.init(std.testing.allocator, std.testing.io, fixture.program, .{ .fail_fast = true });
    defer fail_fast.deinit();
    try fail_fast.addTest(case("failing", findFunction(fixture.program, "failing")));
    try fail_fast.addTest(case("passing", findFunction(fixture.program, "passing")));
    try fail_fast.runAll();
    try std.testing.expectEqual(@as(usize, 1), fail_fast.results.items.len);
}

test "parallel execution completes every selected test" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    const passing = findFunction(fixture.program, "passing");

    var runner = TestRunner.init(std.testing.allocator, std.testing.io, fixture.program, .{
        .parallel = true,
        .max_threads = 3,
    });
    defer runner.deinit();
    for (0..12) |_| {
        try runner.addTest(case("passing", passing));
    }

    try runner.runAll();
    try std.testing.expectEqual(@as(usize, 12), runner.results.items.len);
    for (runner.results.items) |result| {
        try std.testing.expectEqual(TestRunner.TestResult.Status.Passed, result.status);
    }
}

test "parallel execution releases every partial allocation" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runParallelWithAllocator,
        .{AllocationContext{
            .program = fixture.program,
            .passing = findFunction(fixture.program, "passing"),
        }},
    );
}

test "parallel execution rejects a zero worker limit" {
    var fixture = try ParsedFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var runner = TestRunner.init(std.testing.allocator, std.testing.io, fixture.program, .{
        .parallel = true,
        .max_threads = 0,
    });
    defer runner.deinit();
    try runner.addTest(case("passing", findFunction(fixture.program, "passing")));
    try std.testing.expectError(error.InvalidThreadCount, runner.runAll());
}
