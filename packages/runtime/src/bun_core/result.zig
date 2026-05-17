// Copied verbatim from bun/src/bun_core/result.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

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

test "Result asErr returns the error payload" {
    const std = @import("std");
    const R = Result(u32, []const u8);
    const ok_value: R = .{ .ok = 7 };
    const err_value: R = .{ .err = "boom" };
    try std.testing.expect(ok_value.asErr() == null);
    try std.testing.expectEqualStrings("boom", err_value.asErr().?);
}
