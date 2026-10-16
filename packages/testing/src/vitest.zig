const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Native Vitest-style framework. Compatibility entrypoints use process IO;
/// embedders can inject IO and a writer explicitly.
pub const ModernTest = struct {
    allocator: Allocator,
    io: Io,
    suites: std.ArrayListUnmanaged(Suite) = .empty,
    config: Config,
    reporter: Reporter,
    snapshots: Snapshots,
    watch_mode: bool = false,

    pub const Config = struct {
        parallel: bool = true,
        watch: bool = false,
        bail: bool = false,
        timeout_ms: u64 = 5000,
        retry: u8 = 0,
        coverage: bool = false,
        reporter: ReporterType = .pretty,
        snapshot_update: bool = false,
        filter: ?[]const u8 = null,
        verbose: bool = false,

        pub const ReporterType = enum { pretty, minimal, verbose, json, tap };
    };

    pub const Results = struct {
        total: usize = 0,
        passed: usize = 0,
        failed: usize = 0,
        skipped: usize = 0,
        todo: usize = 0,
    };

    pub const Test = struct {
        name: []const u8,
        func: *const fn (*Expect) anyerror!void,
        only: bool = false,
        skip: bool = false,
        todo: bool = false,
        timeout_ms: ?u64 = null,
        retry: ?u8 = null,
        tags: []const []const u8 = &.{},
        owns_name: bool = false,

        fn deinit(self: *Test, allocator: Allocator) void {
            if (self.owns_name) allocator.free(self.name);
            self.* = undefined;
        }
    };

    pub const Suite = struct {
        name: []const u8,
        tests: std.ArrayListUnmanaged(Test) = .empty,
        nested_suites: std.ArrayListUnmanaged(Suite) = .empty,
        before_all: ?*const fn () anyerror!void = null,
        after_all: ?*const fn () anyerror!void = null,
        before_each: ?*const fn () anyerror!void = null,
        after_each: ?*const fn () anyerror!void = null,
        only: bool = false,
        skip: bool = false,
        concurrent: bool = false,
        owns_name: bool = false,

        fn initOwned(allocator: Allocator, name: []const u8) !Suite {
            return .{ .name = try allocator.dupe(u8, name), .owns_name = true };
        }

        fn deinit(self: *Suite, allocator: Allocator) void {
            for (self.tests.items) |*test_case| test_case.deinit(allocator);
            for (self.nested_suites.items) |*nested| nested.deinit(allocator);
            self.tests.deinit(allocator);
            self.nested_suites.deinit(allocator);
            if (self.owns_name) allocator.free(self.name);
            self.* = undefined;
        }

        fn hasOnly(self: *const Suite) bool {
            if (self.only) return true;
            for (self.tests.items) |test_case| if (test_case.only) return true;
            for (self.nested_suites.items) |nested| if (nested.hasOnly()) return true;
            return false;
        }
    };

    pub const Expect = struct {
        allocator: Allocator,
        value: Value,
        not: bool = false,
        failures: *std.ArrayListUnmanaged(Failure),

        pub const ThrowingFn = *const fn () anyerror!void;

        pub const Value = union(enum) {
            int: i64,
            uint: u64,
            float: f64,
            bool: bool,
            string: []const u8,
            pointer: ?*const anyopaque,
            null_value: void,
            any: std.json.Value,
            mock: *Mock,
            throwing: ThrowingFn,
        };

        pub const Failure = struct {
            message: []const u8,
            expected: ?[]const u8 = null,
            actual: ?[]const u8 = null,
            stack: ?[]const u8 = null,

            pub fn deinit(self: *Failure, allocator: Allocator) void {
                allocator.free(self.message);
                if (self.expected) |item| allocator.free(item);
                if (self.actual) |item| allocator.free(item);
                if (self.stack) |item| allocator.free(item);
                self.* = undefined;
            }
        };

        pub fn negate(self: *Expect) *Expect {
            self.not = !self.not;
            return self;
        }

        pub fn toBe(self: *Expect, expected: anytype) !void {
            const matches = valuesEqual(self.value, valueFrom(expected));
            if (matches == self.not) try self.fail("Expected values to be equal", expected, self.value);
        }

        pub fn toEqual(self: *Expect, expected: anytype) !void {
            try self.toBe(expected);
        }

        pub fn toBeTruthy(self: *Expect) !void {
            const matches = switch (self.value) {
                .bool => |item| item,
                .int => |item| item != 0,
                .uint => |item| item != 0,
                .float => |item| item != 0 and !std.math.isNan(item),
                .string => |item| item.len != 0,
                .pointer => |item| item != null,
                .null_value => false,
                else => true,
            };
            if (matches == self.not) try self.fail("Expected value to be truthy", null, self.value);
        }

        pub fn toBeFalsy(self: *Expect) !void {
            self.not = !self.not;
            defer self.not = !self.not;
            try self.toBeTruthy();
        }

        pub fn toBeNull(self: *Expect) !void {
            const matches = self.value == .null_value;
            if (matches == self.not) try self.fail("Expected value to be null", null, self.value);
        }

        pub fn toBeDefined(self: *Expect) !void {
            const matches = self.value != .null_value;
            if (matches == self.not) try self.fail("Expected value to be defined", null, self.value);
        }

        pub fn toBeUndefined(self: *Expect) !void {
            self.not = !self.not;
            defer self.not = !self.not;
            try self.toBeDefined();
        }

        pub fn toBeGreaterThan(self: *Expect, threshold: anytype) !void {
            try self.numericMatch(try numericValue(threshold), .greater);
        }

        pub fn toBeLessThan(self: *Expect, threshold: anytype) !void {
            try self.numericMatch(try numericValue(threshold), .less);
        }

        pub fn toBeGreaterThanOrEqual(self: *Expect, threshold: anytype) !void {
            try self.numericMatch(try numericValue(threshold), .greater_equal);
        }

        pub fn toBeLessThanOrEqual(self: *Expect, threshold: anytype) !void {
            try self.numericMatch(try numericValue(threshold), .less_equal);
        }

        const NumericComparison = enum { greater, less, greater_equal, less_equal };

        fn numericMatch(self: *Expect, threshold: f64, comparison: NumericComparison) !void {
            const actual = try self.getNumericValue();
            const matches = switch (comparison) {
                .greater => actual > threshold,
                .less => actual < threshold,
                .greater_equal => actual >= threshold,
                .less_equal => actual <= threshold,
            };
            if (matches == self.not) try self.fail("Numeric comparison failed", threshold, actual);
        }

        pub fn toBeCloseTo(self: *Expect, expected: f64, precision: ?usize) !void {
            const actual = try self.getNumericValue();
            const factor = std.math.pow(f64, 10, @floatFromInt(precision orelse 2));
            const matches = @round(actual * factor) == @round(expected * factor);
            if (matches == self.not) try self.fail("Expected value to be close to", expected, actual);
        }

        pub fn toContain(self: *Expect, item: []const u8) !void {
            const text = switch (self.value) {
                .string => |value| value,
                else => return error.InvalidType,
            };
            const matches = std.mem.indexOf(u8, text, item) != null;
            if (matches == self.not) try self.fail("Expected value to contain item", item, text);
        }

        pub fn toHaveLength(self: *Expect, expected_len: usize) !void {
            const actual_len = switch (self.value) {
                .string => |value| value.len,
                else => return error.InvalidType,
            };
            if ((actual_len == expected_len) == self.not) try self.fail("Expected length to match", expected_len, actual_len);
        }

        pub fn toMatch(self: *Expect, pattern: []const u8) !void {
            const text = switch (self.value) {
                .string => |value| value,
                else => return error.InvalidType,
            };
            if (matchPattern(text, pattern) == self.not) try self.fail("Expected value to match pattern", pattern, text);
        }

        /// Non-recursive wildcard matching. `*` matches any sequence and `?`
        /// matches one byte, without recursive backtracking.
        fn matchPattern(text: []const u8, pattern: []const u8) bool {
            var text_index: usize = 0;
            var pattern_index: usize = 0;
            var star_index: ?usize = null;
            var star_text_index: usize = 0;
            while (text_index < text.len) {
                if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index])) {
                    text_index += 1;
                    pattern_index += 1;
                } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                    star_index = pattern_index;
                    pattern_index += 1;
                    star_text_index = text_index;
                } else if (star_index) |star| {
                    star_text_index += 1;
                    text_index = star_text_index;
                    pattern_index = star + 1;
                } else return false;
            }
            while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
            return pattern_index == pattern.len;
        }

        pub fn toBeNaN(self: *Expect) !void {
            const matches = switch (self.value) {
                .float => |value| std.math.isNan(value),
                else => false,
            };
            if (matches == self.not) try self.fail("Expected value to be NaN", null, self.value);
        }

        pub fn toBeInfinite(self: *Expect) !void {
            const matches = switch (self.value) {
                .float => |value| std.math.isInf(value),
                else => false,
            };
            if (matches == self.not) try self.fail("Expected value to be infinite", null, self.value);
        }

        pub fn toBePositive(self: *Expect) !void {
            const actual = try self.getNumericValue();
            if ((actual > 0) == self.not) try self.fail("Expected value to be positive", null, actual);
        }

        pub fn toBeNegative(self: *Expect) !void {
            const actual = try self.getNumericValue();
            if ((actual < 0) == self.not) try self.fail("Expected value to be negative", null, actual);
        }

        pub fn toBeZero(self: *Expect) !void {
            const actual = try self.getNumericValue();
            if ((actual == 0) == self.not) try self.fail("Expected value to be zero", null, actual);
        }

        pub fn toBeEven(self: *Expect) !void {
            const matches = switch (self.value) {
                .int => |value| @mod(value, 2) == 0,
                .uint => |value| @mod(value, 2) == 0,
                else => return error.InvalidType,
            };
            if (matches == self.not) try self.fail("Expected value to be even", null, self.value);
        }

        pub fn toBeOdd(self: *Expect) !void {
            self.not = !self.not;
            defer self.not = !self.not;
            try self.toBeEven();
        }

        pub fn toStartWith(self: *Expect, prefix: []const u8) !void {
            const text = switch (self.value) {
                .string => |value| value,
                else => return error.InvalidType,
            };
            if (std.mem.startsWith(u8, text, prefix) == self.not) try self.fail("Expected value to start with", prefix, text);
        }

        pub fn toEndWith(self: *Expect, suffix: []const u8) !void {
            const text = switch (self.value) {
                .string => |value| value,
                else => return error.InvalidType,
            };
            if (std.mem.endsWith(u8, text, suffix) == self.not) try self.fail("Expected value to end with", suffix, text);
        }

        pub fn toBeEmpty(self: *Expect) !void {
            const matches = switch (self.value) {
                .string => |value| value.len == 0,
                .null_value => true,
                else => false,
            };
            if (matches == self.not) try self.fail("Expected value to be empty", null, self.value);
        }

        pub fn toBeBetween(self: *Expect, min: anytype, max: anytype) !void {
            const actual = try self.getNumericValue();
            const matches = actual >= try numericValue(min) and actual <= try numericValue(max);
            if (matches == self.not) try self.fail("Expected value to be between range", .{ min, max }, actual);
        }

        pub fn toHaveBeenCalled(self: *Expect) !void {
            const mock = switch (self.value) {
                .mock => |value| value,
                else => return error.InvalidType,
            };
            if (mock.toHaveBeenCalled() == self.not) try self.fail("Expected mock to have been called", null, mock.calls.items.len);
        }

        pub fn toHaveBeenCalledTimes(self: *Expect, times: usize) !void {
            const mock = switch (self.value) {
                .mock => |value| value,
                else => return error.InvalidType,
            };
            if (mock.toHaveBeenCalledTimes(times) == self.not) try self.fail("Expected mock call count to match", times, mock.calls.items.len);
        }

        pub fn toHaveBeenCalledWith(self: *Expect, args: []const ?*anyopaque) !void {
            const mock = switch (self.value) {
                .mock => |value| value,
                else => return error.InvalidType,
            };
            if (mock.toHaveBeenCalledWith(args) == self.not) try self.fail("Expected mock call arguments to match", args, mock.calls.items.len);
        }

        pub fn toThrow(self: *Expect) !void {
            const throwing = switch (self.value) {
                .throwing => |value| value,
                else => return error.InvalidType,
            };
            var thrown: ?anyerror = null;
            throwing() catch |err| {
                thrown = err;
            };
            if ((thrown != null) == self.not) try self.fail("Expected function to throw", null, thrown);
        }

        pub fn toThrowError(self: *Expect, expected: anyerror) !void {
            const throwing = switch (self.value) {
                .throwing => |value| value,
                else => return error.InvalidType,
            };
            var thrown: ?anyerror = null;
            throwing() catch |err| {
                thrown = err;
            };
            const matches = if (thrown) |err| err == expected else false;
            if (matches == self.not) try self.fail("Expected function to throw matching error", expected, thrown);
        }

        pub fn toMatchSnapshot(self: *Expect, name: ?[]const u8, snapshots: *Snapshots) !void {
            const rendered = try std.fmt.allocPrint(self.allocator, "{any}", .{self.value});
            defer self.allocator.free(rendered);
            const matches = try snapshots.matchSnapshot(name orelse "default", rendered);
            if (matches == self.not) try self.fail("Expected value to match snapshot", name orelse "default", rendered);
        }

        fn getNumericValue(self: *const Expect) !f64 {
            return switch (self.value) {
                .int => |value| @floatFromInt(value),
                .uint => |value| @floatFromInt(value),
                .float => |value| value,
                else => error.InvalidType,
            };
        }

        fn fail(self: *Expect, message: []const u8, expected: anytype, actual: anytype) !void {
            var failure = Failure{ .message = try self.allocator.dupe(u8, message) };
            errdefer failure.deinit(self.allocator);
            if (@TypeOf(expected) != @TypeOf(null)) failure.expected = try std.fmt.allocPrint(self.allocator, "{any}", .{expected});
            failure.actual = try std.fmt.allocPrint(self.allocator, "{any}", .{actual});
            try self.failures.append(self.allocator, failure);
        }
    };

    pub const Snapshots = struct {
        allocator: Allocator,
        snapshots: std.StringHashMapUnmanaged([]const u8) = .empty,
        snapshot_dir: []const u8,

        pub fn init(allocator: Allocator, dir: []const u8) Snapshots {
            return .{ .allocator = allocator, .snapshot_dir = dir };
        }

        pub fn deinit(self: *Snapshots) void {
            var iterator = self.snapshots.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.snapshots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn matchSnapshot(self: *Snapshots, name: []const u8, value: []const u8) !bool {
            if (self.snapshots.get(name)) |snapshot| return std.mem.eql(u8, snapshot, value);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(owned_value);
            try self.snapshots.put(self.allocator, owned_name, owned_value);
            return true;
        }

        pub fn updateSnapshot(self: *Snapshots, name: []const u8, value: []const u8) !void {
            const owned_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(owned_value);
            if (self.snapshots.getPtr(name)) |current| {
                const old = current.*;
                current.* = owned_value;
                self.allocator.free(old);
                return;
            }
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try self.snapshots.put(self.allocator, owned_name, owned_value);
        }
    };

    pub const Mock = struct {
        allocator: Allocator,
        io: Io,
        calls: std.ArrayListUnmanaged(Call) = .empty,
        return_values: std.ArrayListUnmanaged(?*anyopaque) = .empty,
        implementation: ?*const fn ([]const ?*anyopaque) anyerror!?*anyopaque = null,

        pub const Call = struct { args: []const ?*anyopaque, return_value: ?*anyopaque, timestamp: i64 };

        pub fn init(allocator: Allocator) Mock {
            return Mock.initWithIo(allocator, Io.Threaded.global_single_threaded.io());
        }

        pub fn initWithIo(allocator: Allocator, io: Io) Mock {
            return .{ .allocator = allocator, .io = io };
        }

        pub fn deinit(self: *Mock) void {
            for (self.calls.items) |recorded_call| self.allocator.free(recorded_call.args);
            self.calls.deinit(self.allocator);
            self.return_values.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn mockReturnValue(self: *Mock, value: ?*anyopaque) !void {
            try self.return_values.append(self.allocator, value);
        }

        pub fn mockImplementation(self: *Mock, implementation: *const fn ([]const ?*anyopaque) anyerror!?*anyopaque) void {
            self.implementation = implementation;
        }

        pub fn call(self: *Mock, args: []const ?*anyopaque) !?*anyopaque {
            const result = if (self.implementation) |implementation|
                try implementation(args)
            else if (self.return_values.items.len != 0)
                self.return_values.items[self.calls.items.len % self.return_values.items.len]
            else
                null;
            const owned_args = try self.allocator.dupe(?*anyopaque, args);
            errdefer self.allocator.free(owned_args);
            try self.calls.append(self.allocator, .{
                .args = owned_args,
                .return_value = result,
                .timestamp = @intCast(Io.Clock.real.now(self.io).toMilliseconds()),
            });
            return result;
        }

        pub fn toHaveBeenCalled(self: *const Mock) bool {
            return self.calls.items.len != 0;
        }

        pub fn toHaveBeenCalledTimes(self: *const Mock, times: usize) bool {
            return self.calls.items.len == times;
        }

        pub fn toHaveBeenCalledWith(self: *const Mock, args: []const ?*anyopaque) bool {
            for (self.calls.items) |recorded_call| if (std.mem.eql(?*anyopaque, recorded_call.args, args)) return true;
            return false;
        }
    };

    pub const Reporter = struct {
        config: Config.ReporterType,
        writer: ?*Io.Writer = null,
        use_color: bool = true,

        pub fn init(config: Config.ReporterType) Reporter {
            return .{ .config = config };
        }

        fn print(self: *Reporter, comptime format: []const u8, args: anytype) !void {
            if (self.writer) |writer| try writer.print(format, args) else std.debug.print(format, args);
        }

        pub fn suiteStart(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty => try self.print("\n{s}\n", .{name}),
                .verbose => try self.print("Suite: {s}\n", .{name}),
                else => {},
            }
        }

        pub fn testPass(self: *Reporter, name: []const u8, duration_ms: f64) !void {
            switch (self.config) {
                .pretty => try self.print("  ✓ {s} ({d:.2}ms)\n", .{ name, duration_ms }),
                .minimal => try self.print(".", .{}),
                .verbose => try self.print("PASS {s} ({d:.2}ms)\n", .{ name, duration_ms }),
                .tap => try self.print("ok - {s}\n", .{name}),
                .json => {},
            }
        }

        pub fn testFail(self: *Reporter, name: []const u8, failures: []const Expect.Failure) !void {
            switch (self.config) {
                .pretty, .verbose => {
                    try self.print("  ✗ {s}\n", .{name});
                    for (failures) |failure| try self.print("    {s}\n", .{failure.message});
                },
                .minimal => try self.print("F", .{}),
                .tap => try self.print("not ok - {s}\n", .{name}),
                .json => {},
            }
        }

        pub fn testSkip(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty, .verbose => try self.print("  ○ {s} (skipped)\n", .{name}),
                .minimal => try self.print("S", .{}),
                .tap => try self.print("ok - {s} # SKIP\n", .{name}),
                .json => {},
            }
        }

        pub fn testTodo(self: *Reporter, name: []const u8) !void {
            switch (self.config) {
                .pretty, .verbose => try self.print("  ○ {s} (TODO)\n", .{name}),
                .minimal => try self.print("T", .{}),
                .tap => try self.print("not ok - {s} # TODO\n", .{name}),
                .json => {},
            }
        }

        pub fn summary(self: *Reporter, results: Results, duration_ms: f64) !void {
            switch (self.config) {
                .pretty, .verbose => try self.print("\nTests: {d} passed, {d} failed, {d} skipped, {d} todo, {d} total\nTime: {d:.2}ms\n", .{ results.passed, results.failed, results.skipped, results.todo, results.total, duration_ms }),
                .minimal => try self.print("\n{d}/{d} passed\n", .{ results.passed, results.total }),
                .json => try self.print("{{\"total\":{d},\"passed\":{d},\"failed\":{d},\"skipped\":{d},\"todo\":{d},\"duration\":{d:.2}}}\n", .{ results.total, results.passed, results.failed, results.skipped, results.todo, duration_ms }),
                .tap => try self.print("1..{d}\n", .{results.total}),
            }
        }
    };

    pub fn init(allocator: Allocator, config: Config) ModernTest {
        return ModernTest.initWithIo(allocator, Io.Threaded.global_single_threaded.io(), config);
    }

    pub fn initWithIo(allocator: Allocator, io: Io, config: Config) ModernTest {
        return .{ .allocator = allocator, .io = io, .config = config, .reporter = Reporter.init(config.reporter), .snapshots = Snapshots.init(allocator, "__snapshots__"), .watch_mode = config.watch };
    }

    pub fn initWithWriter(allocator: Allocator, io: Io, config: Config, writer: *Io.Writer) ModernTest {
        var framework = initWithIo(allocator, io, config);
        framework.reporter.writer = writer;
        return framework;
    }

    pub fn deinit(self: *ModernTest) void {
        if (global_test_framework == self) global_test_framework = null;
        current_suite = null;
        for (self.suites.items) |*suite| suite.deinit(self.allocator);
        self.suites.deinit(self.allocator);
        self.snapshots.deinit();
        self.* = undefined;
    }

    pub fn run(self: *ModernTest) !Results {
        const start = Io.Clock.awake.now(self.io);
        var results = Results{};
        const only_mode = blk: {
            for (self.suites.items) |suite| if (suite.hasOnly()) break :blk true;
            break :blk false;
        };
        for (self.suites.items) |*suite| {
            try self.runSuite(suite, only_mode, false, &results);
            if (self.config.bail and results.failed != 0) break;
        }
        const duration_ms: f64 = @floatFromInt(start.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds());
        try self.reporter.summary(results, duration_ms);
        return results;
    }

    fn runSuite(self: *ModernTest, suite: *Suite, only_mode: bool, inherited_only: bool, results: *Results) !void {
        const selected = inherited_only or suite.only;
        if (suite.skip or (only_mode and !selected and !suite.hasOnly())) {
            try self.skipSuite(suite, results);
            return;
        }
        try self.reporter.suiteStart(suite.name);
        if (suite.before_all) |hook| try hook();
        for (suite.tests.items) |test_case| {
            if (self.config.bail and results.failed != 0) break;
            if (only_mode and !selected and !test_case.only) {
                try self.reporter.testSkip(test_case.name);
                results.total += 1;
                results.skipped += 1;
                continue;
            }
            if (self.config.filter) |filter| {
                if (std.mem.indexOf(u8, test_case.name, filter) == null and std.mem.indexOf(u8, suite.name, filter) == null) continue;
            }
            results.total += 1;
            if (test_case.skip) {
                results.skipped += 1;
                try self.reporter.testSkip(test_case.name);
                continue;
            }
            if (test_case.todo) {
                results.todo += 1;
                try self.reporter.testTodo(test_case.name);
                continue;
            }
            try self.runTest(suite, test_case, results);
        }
        for (suite.nested_suites.items) |*nested| {
            if (self.config.bail and results.failed != 0) break;
            try self.runSuite(nested, only_mode, selected, results);
        }
        if (suite.after_all) |hook| try hook();
    }

    fn runTest(self: *ModernTest, suite: *Suite, test_case: Test, results: *Results) !void {
        const attempts: usize = @as(usize, test_case.retry orelse self.config.retry) + 1;
        var failures: std.ArrayListUnmanaged(Expect.Failure) = .empty;
        defer failures.deinit(self.allocator);
        defer clearFailures(self.allocator, &failures);
        var duration_ms: f64 = 0;
        var attempt: usize = 0;
        while (attempt < attempts) : (attempt += 1) {
            clearFailures(self.allocator, &failures);
            if (suite.before_each) |hook| try hook();
            const start = Io.Clock.awake.now(self.io);
            var expectation = Expect{ .allocator = self.allocator, .value = .{ .null_value = {} }, .failures = &failures };
            test_case.func(&expectation) catch |err| {
                if (err == error.OutOfMemory) return err;
                try appendErrorFailure(self.allocator, &failures, err);
            };
            duration_ms = @floatFromInt(start.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds());
            const timeout = test_case.timeout_ms orelse self.config.timeout_ms;
            if (duration_ms > @as(f64, @floatFromInt(timeout))) try appendTimeoutFailure(self.allocator, &failures, duration_ms, timeout);
            if (suite.after_each) |hook| try hook();
            if (failures.items.len == 0) break;
        }
        if (failures.items.len == 0) {
            results.passed += 1;
            try self.reporter.testPass(test_case.name, duration_ms);
        } else {
            results.failed += 1;
            try self.reporter.testFail(test_case.name, failures.items);
        }
    }

    fn skipSuite(self: *ModernTest, suite: *const Suite, results: *Results) !void {
        for (suite.tests.items) |test_case| {
            results.total += 1;
            results.skipped += 1;
            try self.reporter.testSkip(test_case.name);
        }
        for (suite.nested_suites.items) |*nested| try self.skipSuite(nested, results);
    }
};

pub var global_test_framework: ?*ModernTest = null;
pub var current_suite: ?*ModernTest.Suite = null;

pub fn describe(name: []const u8, func: *const fn () anyerror!void) !void {
    const framework = global_test_framework orelse return error.NoTestFramework;
    var suite = try ModernTest.Suite.initOwned(framework.allocator, name);
    errdefer suite.deinit(framework.allocator);
    const previous = current_suite;
    current_suite = &suite;
    defer current_suite = previous;
    try func();
    if (previous) |parent| try parent.nested_suites.append(framework.allocator, suite) else try framework.suites.append(framework.allocator, suite);
}

pub fn it(name: []const u8, func: *const fn (*ModernTest.Expect) anyerror!void) !void {
    const framework = global_test_framework orelse return error.NoTestFramework;
    const suite = current_suite orelse return error.NoTestSuite;
    const owned_name = try framework.allocator.dupe(u8, name);
    errdefer framework.allocator.free(owned_name);
    try suite.tests.append(framework.allocator, .{ .name = owned_name, .func = func, .owns_name = true });
}

pub fn beforeAll(func: *const fn () anyerror!void) !void {
    const suite = current_suite orelse return error.NoTestSuite;
    suite.before_all = func;
}

pub fn afterAll(func: *const fn () anyerror!void) !void {
    const suite = current_suite orelse return error.NoTestSuite;
    suite.after_all = func;
}

pub fn beforeEach(func: *const fn () anyerror!void) !void {
    const suite = current_suite orelse return error.NoTestSuite;
    suite.before_each = func;
}

pub fn afterEach(func: *const fn () anyerror!void) !void {
    const suite = current_suite orelse return error.NoTestSuite;
    suite.after_each = func;
}

pub fn expect(allocator: Allocator, value: anytype, failures: *std.ArrayListUnmanaged(ModernTest.Expect.Failure)) ModernTest.Expect {
    return .{ .allocator = allocator, .value = valueFrom(value), .failures = failures };
}

pub const t = struct {
    pub const describe = @import("vitest.zig").describe;
    pub const it = @import("vitest.zig").it;
    pub const beforeAll = @import("vitest.zig").beforeAll;
    pub const afterAll = @import("vitest.zig").afterAll;
    pub const beforeEach = @import("vitest.zig").beforeEach;
    pub const afterEach = @import("vitest.zig").afterEach;
    pub const expect = @import("vitest.zig").expect;
};

fn valueFrom(value: anytype) ModernTest.Expect.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) return .{ .any = value };
    if (T == *ModernTest.Mock) return .{ .mock = value };
    if (T == ModernTest.Expect.ThrowingFn) return .{ .throwing = value };
    return switch (@typeInfo(T)) {
        .comptime_int => if (value < 0) .{ .int = value } else .{ .uint = value },
        .int => |info| if (info.signedness == .signed) .{ .int = @intCast(value) } else .{ .uint = @intCast(value) },
        .comptime_float, .float => .{ .float = @floatCast(value) },
        .bool => .{ .bool = value },
        .null => .{ .null_value = {} },
        .pointer => |pointer| blk: {
            if (pointer.size == .slice and pointer.child == u8) break :blk .{ .string = value };
            if (pointer.size == .one) switch (@typeInfo(pointer.child)) {
                .array => |array| if (array.child == u8) break :blk .{ .string = value[0..array.len] },
                .@"fn" => if (T == ModernTest.Expect.ThrowingFn) break :blk .{ .throwing = value },
                else => {},
            };
            break :blk .{ .pointer = @ptrCast(value) };
        },
        else => @compileError("unsupported value type for vitest.expect: " ++ @typeName(T)),
    };
}

fn valuesEqual(actual: ModernTest.Expect.Value, expected: ModernTest.Expect.Value) bool {
    return switch (actual) {
        .int => |left| switch (expected) {
            .int => |right| left == right,
            .uint => |right| left >= 0 and @as(u64, @intCast(left)) == right,
            else => false,
        },
        .uint => |left| switch (expected) {
            .uint => |right| left == right,
            .int => |right| right >= 0 and left == @as(u64, @intCast(right)),
            else => false,
        },
        .float => |left| switch (expected) {
            .float => |right| left == right,
            else => false,
        },
        .bool => |left| switch (expected) {
            .bool => |right| left == right,
            else => false,
        },
        .string => |left| switch (expected) {
            .string => |right| std.mem.eql(u8, left, right),
            else => false,
        },
        .pointer => |left| switch (expected) {
            .pointer => |right| left == right,
            else => false,
        },
        .null_value => expected == .null_value,
        .any => |left| switch (expected) {
            .any => |right| std.meta.eql(left, right),
            else => false,
        },
        .mock => |left| switch (expected) {
            .mock => |right| left == right,
            else => false,
        },
        .throwing => |left| switch (expected) {
            .throwing => |right| left == right,
            else => false,
        },
    };
}

fn numericValue(value: anytype) !f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .comptime_int, .int => @floatFromInt(value),
        .comptime_float, .float => @floatCast(value),
        else => error.InvalidType,
    };
}

fn clearFailures(allocator: Allocator, failures: *std.ArrayListUnmanaged(ModernTest.Expect.Failure)) void {
    for (failures.items) |*failure| failure.deinit(allocator);
    failures.clearRetainingCapacity();
}

fn appendErrorFailure(allocator: Allocator, failures: *std.ArrayListUnmanaged(ModernTest.Expect.Failure), err: anyerror) !void {
    const message = try std.fmt.allocPrint(allocator, "Test threw error: {s}", .{@errorName(err)});
    errdefer allocator.free(message);
    try failures.append(allocator, .{ .message = message });
}

fn appendTimeoutFailure(allocator: Allocator, failures: *std.ArrayListUnmanaged(ModernTest.Expect.Failure), elapsed: f64, timeout: u64) !void {
    const message = try std.fmt.allocPrint(allocator, "Test timed out after {d:.2}ms (limit: {d}ms)", .{ elapsed, timeout });
    errdefer allocator.free(message);
    try failures.append(allocator, .{ .message = message });
}

test {
    std.testing.refAllDecls(@This());
}
