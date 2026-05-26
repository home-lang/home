pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        pub inline fn asErr(this: *const @This()) ?E {
            if (this.* == .err) return this.err;
            return null;
        }
    };
}

const std = @import("std");
const t = std.testing;

test "Result(i32, []const u8): ok branch carries the payload, asErr is null" {
    const R = Result(i32, []const u8);
    const value: R = .{ .ok = 42 };
    try t.expect(value == .ok);
    try t.expectEqual(@as(i32, 42), value.ok);
    try t.expect(value.asErr() == null);
}

test "Result(void, anyerror): err branch surfaces via asErr" {
    const R = Result(void, anyerror);
    const value: R = .{ .err = error.SomethingFailed };
    try t.expect(value == .err);
    const e = value.asErr() orelse return error.TestUnexpectedResult;
    try t.expectEqual(error.SomethingFailed, e);
}
