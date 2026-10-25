//! Allocation-free control transactions. An observation is not proof that a
//! physical device has applied a cached value to a particular frame.
const std = @import("std");
pub fn Outcome(comptime T: type) type {
    return struct {
        previous: ?T = null,
        current: ?T = null,
        write_attempted: bool = false,
        write_succeeded: bool = false,
        failure: ?anyerror = null,
        pub fn changed(self: @This()) ?bool {
            if (self.previous) |previous| if (self.current) |current| return !std.meta.eql(previous, current);
            return null;
        }
    };
}
/// Validate and observe before mutation. A forced write is an explicit caller
/// request, not a retry. After any attempted write, observe once and preserve
/// the write error if observation also fails. Never silently retry a write.
pub fn apply(comptime T: type, io: anytype, requested: T, force: bool) Outcome(T) {
    var out = Outcome(T){};
    io.validate() catch |err| {
        out.failure = err;
        return out;
    };
    const previous = io.read() catch |err| {
        out.failure = err;
        return out;
    };
    out.previous = previous;
    out.current = previous;
    if (!force and std.meta.eql(previous, requested)) return out;
    out.write_attempted = true;
    out.current = null;
    io.write(requested) catch |err| {
        out.failure = err;
    };
    out.write_succeeded = out.failure == null;
    out.current = io.read() catch |err| {
        if (out.failure == null) out.failure = err;
        return out;
    };
    if (out.failure == null and !std.meta.eql(out.current.?, requested)) out.failure = error.ControlNotApplied;
    return out;
}
const Fake = struct {
    value: [4]u32 = .{ 1, 2, 3, 4 },
    validations: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    fail_validate: bool = false,
    fail_read: u32 = 0,
    fail_write: bool = false,
    partial: bool = false,
    ignore: bool = false,
    pub fn validate(self: *@This()) !void {
        self.validations += 1;
        if (self.fail_validate) return error.WrongDevice;
    }
    pub fn read(self: *@This()) ![4]u32 {
        self.reads += 1;
        if (self.reads == self.fail_read) return error.ReadFailure;
        return self.value;
    }
    pub fn write(self: *@This(), value: [4]u32) !void {
        self.writes += 1;
        if (!self.ignore and (!self.fail_write or self.partial)) self.value = value;
        if (self.fail_write) return error.WriteFailure;
    }
};
test "payload controls skip unchanged values and force exactly one explicitly requested write" {
    const t = std.testing;
    var io = Fake{};
    var result = apply([4]u32, &io, io.value, false);
    try t.expect(result.failure == null and !result.write_attempted and result.changed().? == false);
    try t.expectEqual(@as(u32, 0), io.writes);
    result = apply([4]u32, &io, io.value, true);
    try t.expect(result.failure == null and result.write_attempted and result.write_succeeded and result.changed().? == false);
    try t.expectEqual(@as(u32, 1), io.writes);
    result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
    try t.expect(result.changed().? and result.write_succeeded);
    try t.expectEqual(@as(u32, 2), io.writes);
}
test "payload control errors preserve observations first failures and never retry failed writes" {
    const t = std.testing;
    var io = Fake{ .fail_validate = true };
    var result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
    try t.expect(result.previous == null and result.current == null and io.reads == 0 and io.writes == 0);
    io = .{ .fail_read = 1 };
    result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
    try t.expect(result.previous == null and !result.write_attempted);
    for ([_]bool{ false, true }) |partial| {
        io = .{ .fail_write = true, .partial = partial };
        result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
        try t.expectEqual(@as(?anyerror, error.WriteFailure), result.failure);
        try t.expect(result.current != null and result.changed().? == partial and !result.write_succeeded and io.writes == 1);
    }
    io = .{ .fail_write = true, .fail_read = 2, .partial = true };
    result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
    try t.expectEqual(@as(?anyerror, error.WriteFailure), result.failure);
    try t.expect(result.previous != null and result.current == null and result.changed() == null and io.writes == 1);
    io = .{ .ignore = true };
    result = apply([4]u32, &io, .{ 5, 6, 7, 8 }, false);
    try t.expectEqual(@as(?anyerror, error.ControlNotApplied), result.failure);
    try t.expect(result.write_succeeded and result.changed().? == false);
}
