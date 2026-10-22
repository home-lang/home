//! Owned POSIX/libc environment access. Callers serialize mutation; this cannot
//! make unrelated process environment writers cooperate. Raw bytes are retained.
const std = @import("std");
const builtin = @import("builtin");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
inline fn supported() !void {
    if (builtin.os.tag == .windows or !builtin.link_libc) return error.UnsupportedEnvironment;
}
fn duplicate(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
    const bytes = try allocator.allocSentinel(u8, input.len, 0);
    @memcpy(bytes, input);
    return bytes;
}
fn keyValid(key: []const u8) bool {
    return key.len != 0 and std.mem.indexOfAny(u8, key, "=\x00") == null;
}
pub fn get(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    try supported();
    if (!keyValid(key)) return error.InvalidEnvironmentKey;
    const name = try duplicate(allocator, key);
    defer allocator.free(name);
    // Reads expose a plain slice, matching env.get's public ownership contract.
    // Do not hide a sentinel allocation whose extra byte callers cannot free.
    return if (std.c.getenv(name)) |value| try allocator.dupe(u8, std.mem.span(value)) else null;
}
pub fn set(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try supported();
    if (!keyValid(key) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironmentValue;
    const name = try duplicate(allocator, key);
    defer allocator.free(name);
    const bytes = try duplicate(allocator, value);
    defer allocator.free(bytes);
    if (setenv(name, bytes, 1) != 0) return error.EnvironmentWriteFailed;
}
pub fn unset(allocator: std.mem.Allocator, key: []const u8) !void {
    try supported();
    if (!keyValid(key)) return error.InvalidEnvironmentKey;
    const name = try duplicate(allocator, key);
    defer allocator.free(name);
    if (unsetenv(name) != 0) return error.EnvironmentWriteFailed;
}
pub const Restoration = enum { restored, superseded };
pub const Override = struct {
    allocator: std.mem.Allocator,
    key: [:0]u8,
    value: [:0]u8,
    previous: ?[:0]u8,
    live: bool = true,
    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Override {
        try supported();
        if (!keyValid(key) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironmentValue;
        const name = try duplicate(allocator, key);
        errdefer allocator.free(name);
        const bytes = try duplicate(allocator, value);
        errdefer allocator.free(bytes);
        const previous = if (std.c.getenv(name)) |old| try duplicate(allocator, std.mem.span(old)) else null;
        errdefer if (previous) |old| allocator.free(old);
        // All fallible allocations precede mutation. Close reuses owned copies; libc setters can still fail.
        if (setenv(name, bytes, 1) != 0) return error.EnvironmentWriteFailed;
        return .{ .allocator = allocator, .key = name, .value = bytes, .previous = previous };
    }
    pub fn matchesCurrent(self: *const Override) bool {
        if (!self.live) return false;
        const value = std.c.getenv(self.key) orelse return false;
        return std.mem.eql(u8, self.value, std.mem.span(value));
    }
    /// Failed restoration retains every owner for retry. A different external
    /// value is preserved and reports superseded. Identity is byte-based, so an
    /// external same-value write is indistinguishable from our own override.
    pub fn close(self: *Override) !Restoration {
        if (!self.live) return .restored;
        const same = self.matchesCurrent();
        if (same) {
            if (fail_restore or (if (self.previous) |old| setenv(self.key, old, 1) else unsetenv(self.key)) != 0) return error.EnvironmentWriteFailed;
        }
        if (self.previous) |old| self.allocator.free(old);
        self.allocator.free(self.key);
        self.allocator.free(self.value);
        self.live = false;
        return if (same) .restored else .superseded;
    }
};
var fail_restore = false;
const test_key = "HOME_POSIX_ENV_OWNERSHIP_TEST";
test "owned reads preserve empty missing long and raw values without path limits" {
    const t = std.testing;
    const previous = try get(t.allocator, test_key);
    defer if (previous) |v| t.allocator.free(v);
    defer {
        if (previous) |v| {
            set(t.allocator, test_key, v) catch unreachable;
        } else unset(t.allocator, test_key) catch unreachable;
    }
    try unset(t.allocator, test_key);
    try t.expectEqual(null, try get(t.allocator, test_key));
    try set(t.allocator, test_key, "");
    const empty = (try get(t.allocator, test_key)).?;
    defer t.allocator.free(empty);
    try t.expectEqualStrings("", empty);
    var long: [8192]u8 = @splat('x');
    long[100] = 0xff;
    try set(t.allocator, test_key, &long);
    const owned = (try get(t.allocator, test_key)).?;
    defer t.allocator.free(owned);
    try unset(t.allocator, test_key);
    try t.expectEqualSlices(u8, &long, owned);
    try t.expectError(error.InvalidEnvironmentKey, get(t.allocator, "a=b"));
    try t.expectError(error.InvalidEnvironmentValue, set(t.allocator, test_key, "a\x00b"));
}
test "override restoration retries failure distinguishes missing empty and preserves external writes" {
    const t = std.testing;
    const previous = try get(t.allocator, test_key);
    defer if (previous) |v| t.allocator.free(v);
    defer {
        fail_restore = false;
        if (previous) |v| {
            set(t.allocator, test_key, v) catch unreachable;
        } else unset(t.allocator, test_key) catch unreachable;
    }
    for ([_]bool{ false, true }) |empty| {
        if (empty) try set(t.allocator, test_key, "") else try unset(t.allocator, test_key);
        var guard = try Override.init(t.allocator, test_key, "owned");
        fail_restore = true;
        try t.expectError(error.EnvironmentWriteFailed, guard.close());
        try t.expect(guard.matchesCurrent());
        fail_restore = false;
        try t.expectEqual(Restoration.restored, try guard.close());
        try t.expectEqual(Restoration.restored, try guard.close());
        const restored = try get(t.allocator, test_key);
        defer if (restored) |v| t.allocator.free(v);
        if (empty) try t.expectEqualStrings("", restored.?) else try t.expectEqual(null, restored);
    }
    var guard = try Override.init(t.allocator, test_key, "owned");
    try set(t.allocator, test_key, "external");
    try t.expectEqual(Restoration.superseded, try guard.close());
    const current = (try get(t.allocator, test_key)).?;
    defer t.allocator.free(current);
    try t.expectEqualStrings("external", current);
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    var guard = Override.init(allocator, test_key, "candidate") catch |err| {
        try std.testing.expectEqualStrings("previous", std.mem.span(std.c.getenv(test_key).?));
        return err;
    };
    _ = try guard.close();
}
test "allocation failures never publish a partial override" {
    const previous = try get(std.testing.allocator, test_key);
    defer if (previous) |v| std.testing.allocator.free(v);
    defer {
        if (previous) |v| {
            set(std.testing.allocator, test_key, v) catch unreachable;
        } else unset(std.testing.allocator, test_key) catch unreachable;
    }
    try set(std.testing.allocator, test_key, "previous");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
