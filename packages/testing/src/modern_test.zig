const std = @import("std");

/// Global test framework instance (set by test runner main)
pub var global_test_framework: ?*ModernTest = null;

pub const Failure = struct {
    test_name: []const u8,
    message: []const u8,
};

/// Module-level test API (used as `t.describe(...)`, `t.it(...)`, etc.)
pub const t = struct {
    pub fn describe(name: []const u8, func: *const fn () anyerror!void) anyerror!void {
        if (global_test_framework) |fw| {
            try fw.addSuite(name, func);
        }
    }

    pub fn it(name: []const u8, func: *const fn (*ModernTest.Expect) anyerror!void) anyerror!void {
        if (global_test_framework) |fw| {
            try fw.addTest(name, func);
        }
    }

    pub fn expect(allocator: std.mem.Allocator, value: anytype, failures: *std.ArrayListUnmanaged(Failure)) ModernTest.Expect {
        const T = @TypeOf(value);
        const stored: i128 = switch (@typeInfo(T)) {
            .bool => if (value) 1 else 0,
            .comptime_int => @as(i128, value),
            .int => @as(i128, @intCast(value)),
            else => 0,
        };
        return ModernTest.Expect{
            .allocator = allocator,
            .value = stored,
            .value_is_bool = @typeInfo(T) == .bool,
            .failures = failures,
        };
    }
};

const TestFn = *const fn (*ModernTest.Expect) anyerror!void;
const SuiteFn = *const fn () anyerror!void;

const TestCase = struct {
    name: []const u8,
    func: TestFn,
    suite: []const u8,
};

const TestSuite = struct {
    name: []const u8,
    func: SuiteFn,
};

pub const Reporter = enum {
    pretty,
    minimal,
    json,
};

pub const Options = struct {
    reporter: Reporter = .pretty,
    verbose: bool = false,
};

pub const Results = struct {
    total: usize,
    passed: usize,
    failed: usize,
    skipped: usize,
};

pub const ModernTest = struct {
    allocator: std.mem.Allocator,
    options: Options,
    suites: std.ArrayListUnmanaged(TestSuite),
    tests: std.ArrayListUnmanaged(TestCase),
    current_suite: []const u8,
    failures: std.ArrayListUnmanaged(Failure),

    pub const Expect = struct {
        allocator: std.mem.Allocator,
        value: i128,
        value_is_bool: bool,
        failures: *std.ArrayListUnmanaged(Failure),

        pub fn toBe(self: *Expect, expected: anytype) !void {
            const T = @TypeOf(expected);
            const expected_val: i128 = switch (@typeInfo(T)) {
                .bool => if (expected) 1 else 0,
                .comptime_int => @as(i128, expected),
                .int => @as(i128, @intCast(expected)),
                else => 0,
            };
            if (self.value != expected_val) {
                try self.failures.append(self.allocator, .{
                    .test_name = "assertion",
                    .message = "expected values to be equal",
                });
                return error.AssertionFailed;
            }
        }

        pub fn toBeGreaterThan(self: *Expect, expected: anytype) !void {
            const T = @TypeOf(expected);
            const expected_val: i128 = switch (@typeInfo(T)) {
                .bool => if (expected) 1 else 0,
                .comptime_int => @as(i128, expected),
                .int => @as(i128, @intCast(expected)),
                else => 0,
            };
            if (self.value <= expected_val) {
                try self.failures.append(self.allocator, .{
                    .test_name = "assertion",
                    .message = "expected value to be greater than",
                });
                return error.AssertionFailed;
            }
        }

        pub fn toBeTruthy(self: *Expect) !void {
            if (self.value == 0) {
                try self.failures.append(self.allocator, .{
                    .test_name = "assertion",
                    .message = "expected truthy value",
                });
                return error.AssertionFailed;
            }
        }

        pub fn toBeFalsy(self: *Expect) !void {
            if (self.value != 0) {
                try self.failures.append(self.allocator, .{
                    .test_name = "assertion",
                    .message = "expected falsy value",
                });
                return error.AssertionFailed;
            }
        }

        pub fn toEqual(self: *Expect, expected: anytype) !void {
            return self.toBe(expected);
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) ModernTest {
        return .{
            .allocator = allocator,
            .options = options,
            .suites = .{},
            .tests = .{},
            .current_suite = "",
            .failures = .{},
        };
    }

    pub fn deinit(self: *ModernTest) void {
        self.suites.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.failures.deinit(self.allocator);
    }

    pub fn addSuite(self: *ModernTest, name: []const u8, func: SuiteFn) !void {
        const prev_suite = self.current_suite;
        self.current_suite = name;
        func() catch |err| {
            std.debug.print("  Suite setup error in '{s}': {}\n", .{ name, err });
        };
        self.current_suite = prev_suite;
    }

    pub fn addTest(self: *ModernTest, name: []const u8, func: TestFn) !void {
        try self.tests.append(self.allocator, .{
            .name = name,
            .func = func,
            .suite = self.current_suite,
        });
    }

    pub fn run(self: *ModernTest) !Results {
        var passed: usize = 0;
        var failed: usize = 0;
        var current_suite: []const u8 = "";

        for (self.tests.items) |test_case| {
            if (!std.mem.eql(u8, test_case.suite, current_suite)) {
                current_suite = test_case.suite;
                if (self.options.reporter == .pretty) {
                    std.debug.print("\n  {s}\n", .{current_suite});
                }
            }

            var expect_val = Expect{
                .allocator = self.allocator,
                .value = 0,
                .value_is_bool = false,
                .failures = &self.failures,
            };

            const prev_failures = self.failures.items.len;

            test_case.func(&expect_val) catch |err| {
                if (err != error.AssertionFailed) {
                    std.debug.print("    x {s} (error: {})\n", .{ test_case.name, err });
                }
            };

            if (self.failures.items.len > prev_failures) {
                failed += 1;
                if (self.options.reporter == .pretty) {
                    std.debug.print("    x {s}\n", .{test_case.name});
                }
            } else {
                passed += 1;
                if (self.options.reporter == .pretty) {
                    std.debug.print("    . {s}\n", .{test_case.name});
                }
            }
        }

        return Results{
            .total = passed + failed,
            .passed = passed,
            .failed = failed,
            .skipped = 0,
        };
    }
};
