const std = @import("std");

/// Modern testing framework inspired by Vitest, Jest, Pest, and Bun
/// Provides beautiful, developer-friendly testing experience
pub const ModernTest = struct {
    allocator: std.mem.Allocator,
    suites: std.ArrayList(Suite),
    config: Config,
    reporter: Reporter,
    snapshots: Snapshots,
    watch_mode: bool = false,

    pub const Config = struct {
        parallel: bool = true,
        watch: bool = false,
        bail: bool = false, // Stop on first failure
        timeout_ms: u64 = 5000,
        retry: u8 = 0,
        coverage: bool = false,
        reporter: ReporterType = .pretty,
        snapshot_update: bool = false,
        filter: ?[]const u8 = null, // Run tests matching pattern
        verbose: bool = false,

        pub const ReporterType = enum {
            pretty, // Default, colored output
            minimal, // Minimal output
            verbose, // Detailed output
            json, // JSON output for CI
            tap, // TAP protocol
        };
    };

    /// Test suite (describe block)
    pub const Suite = struct {
        name: []const u8,
        tests: std.ArrayList(Test),
        nested_suites: std.ArrayList(Suite),
        before_all: ?*const fn () anyerror!void = null,
        after_all: ?*const fn () anyerror!void = null,
        before_each: ?*const fn () anyerror!void = null,
        after_each: ?*const fn () anyerror!void = null,
        only: bool = false, // Run only this suite
        skip: bool = false, // Skip this suite
        concurrent: bool = false, // Run tests in parallel
    };

    /// Individual test (it/test block)
    pub const Test = struct {
        name: []const u8,
        func: *const fn (*Expect) anyerror!void,
        only: bool = false,
        skip: bool = false,
        todo: bool = false,
        timeout_ms: ?u64 = null,
        retry: ?u8 = null,
        tags: []const []const u8 = &.{},
    };

    /// Expect API (Jest/Vitest style)
    pub const Expect = struct {
        allocator: std.mem.Allocator,
        value: Value,
        not: bool = false,
        failures: *std.ArrayList(Failure),

        pub const Value = union(enum) {
            int: i64,
            uint: u64,
            float: f64,
            bool: bool,
            string: []const u8,
            pointer: *anyopaque,
            null_value: void,
            any: std.json.Value,
        };

        pub const Failure = struct {
            message: []const u8,
            expected: ?[]const u8,
            actual: ?[]const u8,
            stack: ?[]const u8,
        };

        // Matchers
        pub fn toBe(self: *Expect, expected: anytype) !void {
            const matches = try self.compareValues(expected);
            if (self.not) {
                if (matches) {
                    try self.fail("Expected values to be different", expected, expected);
                }
            } else {
                if (!matches) {
                    try self.fail("Expected values to be equal", expected, self.value);
                }
            }
        }

        pub fn toEqual(self: *Expect, expected: anytype) !void {
            // Deep equality check
            try self.toBe(expected);
        }

        pub fn toBeTruthy(self: *Expect) !void {
            const is_truthy = switch (self.value) {
                .bool => |b| b,
                .int => |i| i != 0,
                .uint => |u| u != 0,
                .string => |s| s.len > 0,
                .null_value => false,
                else => true,
            };

            if (self.not) {
                if (is_truthy) try self.fail("Expected value to be falsy", null, self.value);
            } else {
                if (!is_truthy) try self.fail("Expected value to be truthy", null, self.value);
            }
        }

        pub fn toBeFalsy(self: *Expect) !void {
            self.not = !self.not;
            try self.toBeTruthy();
            self.not = !self.not;
        }

        pub fn toBeNull(self: *Expect) !void {
            const is_null = switch (self.value) {
                .null_value => true,
                else => false,
            };

            if (self.not) {
                if (is_null) try self.fail("Expected value not to be null", null, null);
            } else {
                if (!is_null) try self.fail("Expected value to be null", null, self.value);
            }
        }

        pub fn toBeGreaterThan(self: *Expect, threshold: anytype) !void {
            const actual_num = self.getNumericValue();
            const threshold_num = @as(f64, @floatFromInt(threshold));

            if (self.not) {
                if (actual_num > threshold_num) {
                    try self.fail("Expected value not to be greater than", threshold, self.value);
                }
            } else {
                if (actual_num <= threshold_num) {
                    try self.fail("Expected value to be greater than", threshold, self.value);
                }
            }
        }

        pub fn toBeLessThan(self: *Expect, threshold: anytype) !void {
            const actual_num = self.getNumericValue();
            const threshold_num = @as(f64, @floatFromInt(threshold));

            if (self.not) {
                if (actual_num < threshold_num) {
                    try self.fail("Expected value not to be less than", threshold, self.value);
                }
            } else {
                if (actual_num >= threshold_num) {
                    try self.fail("Expected value to be less than", threshold, self.value);
                }
            }
        }

        pub fn toContain(self: *Expect, item: anytype) !void {
            // For strings, check substring
            const contains = switch (self.value) {
                .string => |s| blk: {
                    const needle = switch (@TypeOf(item)) {
                        []const u8 => item,
                        else => @compileError("toContain on string requires string parameter"),
                    };
                    break :blk std.mem.indexOf(u8, s, needle) != null;
                },
                else => return error.InvalidType,
            };

            if (self.not) {
                if (contains) {
                    try self.fail("Expected value not to contain item", item, self.value);
                }
            } else {
                if (!contains) {
                    try self.fail("Expected value to contain item", item, self.value);
                }
            }
        }

        pub fn toHaveLength(self: *Expect, expected_len: usize) !void {
            const actual_len = switch (self.value) {
                .string => |s| s.len,
                else => return error.InvalidType,
            };

            if (self.not) {
                if (actual_len == expected_len) {
                    try self.fail("Expected length to be different", expected_len, actual_len);
                }
            } else {
                if (actual_len != expected_len) {
                    try self.fail("Expected length to match", expected_len, actual_len);
                }
            }
        }

        pub fn toMatch(self: *Expect, pattern: []const u8) !void {
            // Simple glob-style pattern matching (not full regex)
            const text = switch (self.value) {
                .string => |s| s,
                else => return error.InvalidType,
            };

            const matches = matchPattern(text, pattern);

            if (self.not) {
                if (matches) {
                    try self.fail("Expected value not to match pattern", pattern, self.value);
                }
            } else {
                if (!matches) {
                    try self.fail("Expected value to match pattern", pattern, self.value);
                }
            }
        }

        fn matchPattern(text: []const u8, pattern: []const u8) bool {
            // Simple glob matching: * matches any sequence
            if (pattern.len == 0) return text.len == 0;
            if (text.len == 0) return pattern[0] == '*' and matchPattern(text, pattern[1..]);

            if (pattern[0] == '*') {
                // Match zero or more characters
                return matchPattern(text, pattern[1..]) or matchPattern(text[1..], pattern);
            } else if (pattern[0] == text[0]) {
                return matchPattern(text[1..], pattern[1..]);
            }
            return false;
        }

        pub fn toThrow(self: *Expect) !void {
            // Check if function throws
            _ = self;
            return error.NotImplemented;
        }

        pub fn toMatchSnapshot(self: *Expect, name: ?[]const u8, snapshots: *Snapshots) !void {
            // Snapshot testing
            const snapshot_name = name orelse "default";

            // Convert value to string representation
            const value_str = try std.fmt.allocPrint(
                self.allocator,
                "{any}",
                .{self.value},
            );
            defer self.allocator.free(value_str);

            const matches = try snapshots.matchSnapshot(snapshot_name, value_str);

            if (self.not) {
                if (matches) {
                    try self.fail("Expected value not to match snapshot", snapshot_name, value_str);
                }
            } else {
                if (!matches) {
                    try self.fail("Expected value to match snapshot", snapshot_name, value_str);
                }
            }
        }

        // Helpers
        fn compareValues(self: *Expect, expected: anytype) !bool {
            const T = @TypeOf(expected);
            const type_info = @typeInfo(T);

            return switch (type_info) {
                .Int, .ComptimeInt => blk: {
                    const exp_val: i64 = @intCast(expected);
                    break :blk switch (self.value) {
                        .int => |i| i == exp_val,
                        .uint => |u| @as(i64, @intCast(u)) == exp_val,
                        else => false,
                    };
                },
                .Float, .ComptimeFloat => blk: {
                    const exp_val: f64 = @floatCast(expected);
                    break :blk switch (self.value) {
                        .float => |f| f == exp_val,
                        else => false,
                    };
                },
                .Bool => blk: {
                    break :blk switch (self.value) {
                        .bool => |b| b == expected,
                        else => false,
                    };
                },
                .Pointer => |ptr| blk: {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        // String comparison
                        break :blk switch (self.value) {
                            .string => |s| std.mem.eql(u8, s, expected),
                            else => false,
                        };
                    }
                    break :blk false;
                },
                else => false,
            };
        }

        fn getNumericValue(self: *Expect) f64 {
            return switch (self.value) {
                .int => |i| @floatFromInt(i),
                .uint => |u| @floatFromInt(u),
                .float => |f| f,
                else => 0.0,
            };
        }

        fn fail(self: *Expect, message: []const u8, expected: anytype, actual: anytype) !void {
            const exp_str = if (@TypeOf(expected) == @TypeOf(null))
                null
            else
                try std.fmt.allocPrint(self.allocator, "{any}", .{expected});

            const act_str = try std.fmt.allocPrint(self.allocator, "{any}", .{actual});

            try self.failures.append(.{
                .message = message,
                .expected = exp_str,
                .actual = act_str,
                .stack = null,
            });
        }
    };

    /// Snapshot testing
    pub const Snapshots = struct {
        allocator: std.mem.Allocator,
        snapshots: std.StringHashMap([]const u8),
        snapshot_dir: []const u8,

        pub fn init(allocator: std.mem.Allocator, dir: []const u8) Snapshots {
            return .{
                .allocator = allocator,
                .snapshots = std.StringHashMap([]const u8).init(allocator),
                .snapshot_dir = dir,
            };
        }

        pub fn deinit(self: *Snapshots) void {
            self.snapshots.deinit();
        }

        pub fn matchSnapshot(self: *Snapshots, name: []const u8, value: []const u8) !bool {
            const snapshot = self.snapshots.get(name);
            if (snapshot) |snap| {
                return std.mem.eql(u8, snap, value);
            }

            // First time seeing this snapshot, save it
            try self.snapshots.put(name, try self.allocator.dupe(u8, value));
            return true;
        }

        pub fn updateSnapshot(self: *Snapshots, name: []const u8, value: []const u8) !void {
            try self.snapshots.put(name, try self.allocator.dupe(u8, value));
        }
    };

    /// Mock/Spy functionality
    pub const Mock = struct {
        allocator: std.mem.Allocator,
        calls: std.ArrayList(Call),
        return_values: std.ArrayList(?*anyopaque),
        impl: ?*const fn ([]const ?*anyopaque) anyerror!?*anyopaque,

        pub const Call = struct {
            args: []const ?*anyopaque,
            return_value: ?*anyopaque,
            timestamp: i64,
        };

        pub fn init(allocator: std.mem.Allocator) Mock {
            return .{
                .allocator = allocator,
                .calls = std.ArrayList(Call).init(allocator),
                .return_values = std.ArrayList(?*anyopaque).init(allocator),
                .impl = null,
            };
        }

        pub fn deinit(self: *Mock) void {
            self.calls.deinit();
            self.return_values.deinit();
        }

        pub fn mockReturnValue(self: *Mock, value: ?*anyopaque) !void {
            try self.return_values.append(value);
        }

        pub fn mockImplementation(
            self: *Mock,
            impl: *const fn ([]const ?*anyopaque) anyerror!?*anyopaque,
        ) void {
            self.impl = impl;
        }

        pub fn call(self: *Mock, args: []const ?*anyopaque) !?*anyopaque {
            const result = if (self.impl) |impl|
                try impl(args)
            else if (self.return_values.items.len > 0)
                self.return_values.items[self.calls.items.len % self.return_values.items.len]
            else
                null;

            try self.calls.append(.{
                .args = args,
                .return_value = result,
                .timestamp = std.time.milliTimestamp(),
            });

            return result;
        }

        // Assertions
        pub fn toHaveBeenCalled(self: *Mock) bool {
            return self.calls.items.len > 0;
        }

        pub fn toHaveBeenCalledTimes(self: *Mock, times: usize) bool {
            return self.calls.items.len == times;
        }

        pub fn toHaveBeenCalledWith(self: *Mock, args: []const ?*anyopaque) bool {
            for (self.calls.items) |call| {
                if (std.mem.eql(?*anyopaque, call.args, args)) {
                    return true;
                }
            }
            return false;
        }
    };

    /// Pretty reporter (default)
    pub const Reporter = struct {
        allocator: std.mem.Allocator,
        config: Config.ReporterType,
        writer: std.io.AnyWriter,
        use_color: bool = true,

        const Color = struct {
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";
            const dim = "\x1b[2m";
            const red = "\x1b[31m";
            const green = "\x1b[32m";
            const yellow = "\x1b[33m";
            const blue = "\x1b[34m";
            const cyan = "\x1b[36m";
            const gray = "\x1b[90m";
        };

        pub fn init(allocator: std.mem.Allocator, config: Config.ReporterType) Reporter {
            return .{
                .allocator = allocator,
                .config = config,
                .writer = std.io.getStdOut().writer().any(),
            };
        }

        pub fn suiteStart(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.print("\n{s}{s}{s}\n", .{ Color.bold, name, Color.reset });
                },
                .minimal => {},
                .verbose => {
                    try self.writer.print("Suite: {s}\n", .{name});
                },
                .json, .tap => {},
            }
        }

        pub fn testPass(self: *Reporter, name: []const u8, duration_ms: f64) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.print(
                        "  {s}✓{s} {s}{s}{s} {s}({d:.2}ms){s}\n",
                        .{ Color.green, Color.reset, Color.dim, name, Color.reset, Color.gray, duration_ms, Color.reset },
                    );
                },
                .minimal => {
                    try self.writer.print(".", .{});
                },
                .verbose => {
                    try self.writer.print("PASS {s} ({d:.2}ms)\n", .{ name, duration_ms });
                },
                .json, .tap => {},
            }
        }

        pub fn testFail(self: *Reporter, name: []const u8, failures: []const Expect.Failure) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.print("  {s}✗{s} {s}\n", .{ Color.red, Color.reset, name });

                    for (failures) |failure| {
                        try self.writer.print("    {s}{s}{s}\n", .{ Color.red, failure.message, Color.reset });
                        if (failure.expected) |exp| {
                            try self.writer.print("    {s}Expected:{s} {s}\n", .{ Color.green, Color.reset, exp });
                        }
                        if (failure.actual) |act| {
                            try self.writer.print("    {s}Actual:{s}   {s}\n", .{ Color.red, Color.reset, act });
                        }
                    }
                },
                .minimal => {
                    try self.writer.print("F", .{});
                },
                .verbose => {
                    try self.writer.print("FAIL {s}\n", .{name});
                    for (failures) |failure| {
                        try self.writer.print("  {s}\n", .{failure.message});
                    }
                },
                .json, .tap => {},
            }
        }

        pub fn testSkip(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.print("  {s}○{s} {s}{s}{s}\n", .{ Color.yellow, Color.reset, Color.dim, name, Color.reset });
                },
                .minimal => {
                    try self.writer.print("S", .{});
                },
                .verbose => {
                    try self.writer.print("SKIP {s}\n", .{name});
                },
                .json, .tap => {},
            }
        }

        pub fn testTodo(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.print("  {s}○{s} {s}{s} (TODO){s}\n", .{ Color.cyan, Color.reset, Color.dim, name, Color.reset });
                },
                .minimal => {
                    try self.writer.print("T", .{});
                },
                .verbose => {
                    try self.writer.print("TODO {s}\n", .{name});
                },
                .json, .tap => {},
            }
        }

        pub fn summary(
            self: *Reporter,
            total: usize,
            passed: usize,
            failed: usize,
            skipped: usize,
            todo: usize,
            duration_ms: f64,
        ) !void {
            switch (self.config) {
                .pretty => {
                    try self.writer.writeAll("\n");
                    try self.writer.print("{s}Tests:{s}  ", .{ Color.bold, Color.reset });

                    if (failed > 0) {
                        try self.writer.print("{s}{d} failed{s}, ", .{ Color.red, failed, Color.reset });
                    }
                    if (passed > 0) {
                        try self.writer.print("{s}{d} passed{s}, ", .{ Color.green, passed, Color.reset });
                    }
                    if (skipped > 0) {
                        try self.writer.print("{s}{d} skipped{s}, ", .{ Color.yellow, skipped, Color.reset });
                    }
                    if (todo > 0) {
                        try self.writer.print("{s}{d} todo{s}, ", .{ Color.cyan, todo, Color.reset });
                    }

                    try self.writer.print("{d} total\n", .{total});
                    try self.writer.print("{s}Time:{s}   {d:.2}s\n", .{ Color.bold, Color.reset, duration_ms / 1000.0 });

                    if (failed == 0) {
                        try self.writer.print("\n{s}{s}✓ All tests passed!{s}\n", .{ Color.bold, Color.green, Color.reset });
                    }
                },
                .minimal => {
                    try self.writer.print("\n{d}/{d} passed\n", .{ passed, total });
                },
                .verbose => {
                    try self.writer.print(
                        "\nTotal: {d}, Passed: {d}, Failed: {d}, Skipped: {d}, Todo: {d}\n",
                        .{ total, passed, failed, skipped, todo },
                    );
                    try self.writer.print("Duration: {d:.2}s\n", .{duration_ms / 1000.0});
                },
                .json => {
                    // JSON output
                    try self.writer.print(
                        "{{\"total\":{d},\"passed\":{d},\"failed\":{d},\"skipped\":{d},\"todo\":{d},\"duration\":{d:.2}}}\n",
                        .{ total, passed, failed, skipped, todo, duration_ms },
                    );
                },
                .tap => {
                    // TAP protocol
                    try self.writer.print("1..{d}\n", .{total});
                },
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) ModernTest {
        return .{
            .allocator = allocator,
            .suites = std.ArrayList(Suite).init(allocator),
            .config = config,
            .reporter = Reporter.init(allocator, config.reporter),
            .snapshots = Snapshots.init(allocator, "__snapshots__"),
        };
    }

    pub fn deinit(self: *ModernTest) void {
        self.suites.deinit();
        self.snapshots.deinit();
    }

    /// Run all collected tests
    pub fn run(self: *ModernTest) !struct {
        total: usize,
        passed: usize,
        failed: usize,
        skipped: usize,
        todo: usize,
    } {
        const start_time = std.time.milliTimestamp();

        var total: usize = 0;
        var passed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        var todo: usize = 0;

        for (self.suites.items) |*suite| {
            try self.runSuite(suite, &total, &passed, &failed, &skipped, &todo);
        }

        const end_time = std.time.milliTimestamp();
        const duration_ms: f64 = @floatFromInt(end_time - start_time);

        try self.reporter.summary(total, passed, failed, skipped, todo, duration_ms);

        return .{
            .total = total,
            .passed = passed,
            .failed = failed,
            .skipped = skipped,
            .todo = todo,
        };
    }

    fn runSuite(
        self: *ModernTest,
        suite: *Suite,
        total: *usize,
        passed: *usize,
        failed: *usize,
        skipped: *usize,
        todo: *usize,
    ) !void {
        if (suite.skip) return;

        try self.reporter.suiteStart(suite.name);

        // Run beforeAll
        if (suite.before_all) |before| {
            try before();
        }

        // Run tests
        for (suite.tests.items) |test_case| {
            total.* += 1;

            if (test_case.skip) {
                try self.reporter.testSkip(test_case.name);
                skipped.* += 1;
                continue;
            }

            if (test_case.todo) {
                try self.reporter.testTodo(test_case.name);
                todo.* += 1;
                continue;
            }

            // Run beforeEach
            if (suite.before_each) |before| {
                try before();
            }

            const test_start = std.time.milliTimestamp();

            var failures = std.ArrayList(Expect.Failure).init(self.allocator);
            defer failures.deinit();

            var test_expect = Expect{
                .allocator = self.allocator,
                .value = .{ .null_value = {} },
                .failures = &failures,
            };

            // Run test
            test_case.func(&test_expect) catch |err| {
                try failures.append(.{
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Test threw error: {s}",
                        .{@errorName(err)},
                    ),
                    .expected = null,
                    .actual = null,
                    .stack = null,
                });
            };

            const test_end = std.time.milliTimestamp();
            const test_duration: f64 = @floatFromInt(test_end - test_start);

            if (failures.items.len > 0) {
                try self.reporter.testFail(test_case.name, failures.items);
                failed.* += 1;
            } else {
                try self.reporter.testPass(test_case.name, test_duration);
                passed.* += 1;
            }

            // Run afterEach
            if (suite.after_each) |after| {
                try after();
            }
        }

        // Run nested suites
        for (suite.nested_suites.items) |*nested| {
            try self.runSuite(nested, total, passed, failed, skipped, todo);
        }

        // Run afterAll
        if (suite.after_all) |after| {
            try after();
        }
    }
};

/// Global test registration helpers (for nice syntax)
pub var global_test_framework: ?*ModernTest = null;
pub var current_suite: ?*ModernTest.Suite = null;

/// describe() - Create a test suite
pub fn describe(name: []const u8, func: *const fn () anyerror!void) !void {
    if (global_test_framework) |framework| {
        var suite = ModernTest.Suite{
            .name = name,
            .tests = std.ArrayList(ModernTest.Test).init(framework.allocator),
            .nested_suites = std.ArrayList(ModernTest.Suite).init(framework.allocator),
        };

        const prev_suite = current_suite;
        current_suite = &suite;

        // Execute the describe block to collect tests
        try func();

        current_suite = prev_suite;

        // Add to parent or root
        if (prev_suite) |parent| {
            try parent.nested_suites.append(suite);
        } else {
            try framework.suites.append(suite);
        }
    }
}

/// it() / test() - Create a test case
pub fn it(name: []const u8, func: *const fn (*ModernTest.Expect) anyerror!void) !void {
    if (current_suite) |suite| {
        const test_case = ModernTest.Test{
            .name = name,
            .func = func,
        };
        try suite.tests.append(test_case);
    }
}


/// beforeAll() - Run before all tests in suite
pub fn beforeAll(func: *const fn () anyerror!void) void {
    if (current_suite) |suite| {
        suite.before_all = func;
    }
}

/// afterAll() - Run after all tests in suite
pub fn afterAll(func: *const fn () anyerror!void) void {
    if (current_suite) |suite| {
        suite.after_all = func;
    }
}

/// beforeEach() - Run before each test
pub fn beforeEach(func: *const fn () anyerror!void) void {
    if (current_suite) |suite| {
        suite.before_each = func;
    }
}

/// afterEach() - Run after each test
pub fn afterEach(func: *const fn () anyerror!void) void {
    if (current_suite) |suite| {
        suite.after_each = func;
    }
}

/// expect() - Create an expectation
pub fn expect(allocator: std.mem.Allocator, value: anytype, failures: *std.ArrayList(ModernTest.Expect.Failure)) ModernTest.Expect {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    const expect_value = switch (type_info) {
        .Int, .ComptimeInt => ModernTest.Expect.Value{ .int = @intCast(value) },
        .Float, .ComptimeFloat => ModernTest.Expect.Value{ .float = @floatCast(value) },
        .Bool => ModernTest.Expect.Value{ .bool = value },
        .Pointer => |ptr| blk: {
            if (ptr.size == .Slice and ptr.child == u8) {
                break :blk ModernTest.Expect.Value{ .string = value };
            }
            break :blk ModernTest.Expect.Value{ .pointer = @constCast(@ptrCast(value)) };
        },
        .Null => ModernTest.Expect.Value{ .null_value = {} },
        else => ModernTest.Expect.Value{ .pointer = @constCast(@ptrCast(&value)) },
    };

    return ModernTest.Expect{
        .allocator = allocator,
        .value = expect_value,
        .failures = failures,
    };
}

/// test - Convenient namespace for all testing functions
pub const test = struct {
    pub usingnamespace struct {
        pub const describe = @import("modern_test.zig").describe;
        pub const it = @import("modern_test.zig").it;
        pub const beforeAll = @import("modern_test.zig").beforeAll;
        pub const afterAll = @import("modern_test.zig").afterAll;
        pub const beforeEach = @import("modern_test.zig").beforeEach;
        pub const afterEach = @import("modern_test.zig").afterEach;
        pub const expect = @import("modern_test.zig").expect;
    };
};
