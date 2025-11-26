const std = @import("std");

/// Comprehensive assertion library for testing
pub const Assert = struct {
    /// Assert that two values are equal
    pub fn equal(comptime T: type, expected: T, actual: T) !void {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("Assertion failed: expected {any}, got {any}\n", .{ expected, actual });
            return error.AssertionFailed;
        }
    }

    /// Assert that two strings are equal
    pub fn equalStrings(expected: []const u8, actual: []const u8) !void {
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("Assertion failed:\n  Expected: \"{s}\"\n  Got:      \"{s}\"\n", .{ expected, actual });
            return error.AssertionFailed;
        }
    }

    /// Assert that a condition is true
    pub fn isTrue(condition: bool) !void {
        if (!condition) {
            std.debug.print("Assertion failed: expected true, got false\n", .{});
            return error.AssertionFailed;
        }
    }

    /// Assert that a condition is false
    pub fn isFalse(condition: bool) !void {
        if (condition) {
            std.debug.print("Assertion failed: expected false, got true\n", .{});
            return error.AssertionFailed;
        }
    }

    /// Assert that a value is null
    pub fn isNull(comptime T: type, value: ?T) !void {
        if (value != null) {
            std.debug.print("Assertion failed: expected null, got {any}\n", .{value});
            return error.AssertionFailed;
        }
    }

    /// Assert that a value is not null
    pub fn isNotNull(comptime T: type, value: ?T) !void {
        if (value == null) {
            std.debug.print("Assertion failed: expected non-null value\n", .{});
            return error.AssertionFailed;
        }
    }

    /// Assert that an expression returns an error
    pub fn expectError(comptime E: type, result: anytype) !void {
        if (result) |_| {
            std.debug.print("Assertion failed: expected error, got success\n", .{});
            return error.AssertionFailed;
        } else |err| {
            if (@TypeOf(err) != E) {
                std.debug.print("Assertion failed: expected error type {}, got {}\n", .{ E, @TypeOf(err) });
                return error.AssertionFailed;
            }
        }
    }

    /// Assert that a value is greater than another
    pub fn greaterThan(comptime T: type, actual: T, expected: T) !void {
        if (!(actual > expected)) {
            std.debug.print("Assertion failed: {any} is not greater than {any}\n", .{ actual, expected });
            return error.AssertionFailed;
        }
    }

    /// Assert that a value is less than another
    pub fn lessThan(comptime T: type, actual: T, expected: T) !void {
        if (!(actual < expected)) {
            std.debug.print("Assertion failed: {any} is not less than {any}\n", .{ actual, expected });
            return error.AssertionFailed;
        }
    }

    /// Assert that a slice contains a value
    pub fn contains(comptime T: type, haystack: []const T, needle: T) !void {
        for (haystack) |item| {
            if (std.meta.eql(item, needle)) {
                return;
            }
        }
        std.debug.print("Assertion failed: slice does not contain {any}\n", .{needle});
        return error.AssertionFailed;
    }

    /// Assert that a string contains a substring
    pub fn containsString(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            std.debug.print("Assertion failed: \"{s}\" does not contain \"{s}\"\n", .{ haystack, needle });
            return error.AssertionFailed;
        }
    }

    /// Assert that two slices are equal
    pub fn equalSlices(comptime T: type, expected: []const T, actual: []const T) !void {
        if (expected.len != actual.len) {
            std.debug.print("Assertion failed: slice lengths differ (expected {d}, got {d})\n", .{ expected.len, actual.len });
            return error.AssertionFailed;
        }

        for (expected, 0..) |item, i| {
            if (!std.meta.eql(item, actual[i])) {
                std.debug.print("Assertion failed: slices differ at index {d}\n", .{i});
                return error.AssertionFailed;
            }
        }
    }

    /// Assert that a value is within a range
    pub fn inRange(comptime T: type, value: T, min: T, max: T) !void {
        if (value < min or value > max) {
            std.debug.print("Assertion failed: {any} is not in range [{any}, {any}]\n", .{ value, min, max });
            return error.AssertionFailed;
        }
    }

    /// Assert that two floating-point numbers are approximately equal
    pub fn approxEqual(comptime T: type, expected: T, actual: T, tolerance: T) !void {
        const diff = if (expected > actual) expected - actual else actual - expected;
        if (diff > tolerance) {
            std.debug.print("Assertion failed: {d} is not approximately equal to {d} (tolerance: {d})\n", .{ actual, expected, tolerance });
            return error.AssertionFailed;
        }
    }
};

/// Test fixtures for setup and teardown
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    setup_fn: ?*const fn (*Fixture) anyerror!void = null,
    teardown_fn: ?*const fn (*Fixture) anyerror!void = null,
    data: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Fixture {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setup(self: *Fixture) !void {
        if (self.setup_fn) |func| {
            try func(self);
        }
    }

    pub fn teardown(self: *Fixture) !void {
        if (self.teardown_fn) |func| {
            try func(self);
        }
    }

    pub fn setData(self: *Fixture, data: anytype) !void {
        const T = @TypeOf(data);
        const ptr = try self.allocator.create(T);
        ptr.* = data;
        self.data = ptr;
    }

    pub fn getData(self: *Fixture, comptime T: type) ?*T {
        if (self.data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }
};

/// Mock/Stub framework
pub const Mock = struct {
    calls: std.ArrayList(Call),
    allocator: std.mem.Allocator,

    pub const Call = struct {
        function_name: []const u8,
        args: []const u8,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator) Mock {
        return .{
            .calls = std.ArrayList(Call).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mock) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.function_name);
            self.allocator.free(call.args);
        }
        self.calls.deinit();
    }

    pub fn recordCall(self: *Mock, function_name: []const u8, args: []const u8) !void {
        try self.calls.append(.{
            .function_name = try self.allocator.dupe(u8, function_name),
            .args = try self.allocator.dupe(u8, args),
            .timestamp = std.time.timestamp(),
        });
    }

    pub fn wasCalled(self: *const Mock, function_name: []const u8) bool {
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.function_name, function_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn callCount(self: *const Mock, function_name: []const u8) usize {
        var count: usize = 0;
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.function_name, function_name)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn reset(self: *Mock) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.function_name);
            self.allocator.free(call.args);
        }
        self.calls.clearAndFree();
    }
};

test "Assert equal" {
    try Assert.equal(i32, 42, 42);
    try Assert.equalStrings("hello", "hello");
}

test "Assert conditions" {
    try Assert.isTrue(true);
    try Assert.isFalse(false);
}

test "Mock framework" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.recordCall("testFunction", "arg1, arg2");

    try testing.expect(mock.wasCalled("testFunction"));
    try testing.expectEqual(@as(usize, 1), mock.callCount("testFunction"));
}
