//! Observe the outcome of a layout-changing boolean control, including writes
//! that report failure after changing hardware. Caller supplies exclusive device
//! ownership and IO methods validate(), read()!bool and write(bool)!void.
const std = @import("std");
pub const Outcome = struct {
    previous: ?bool = null,
    current: ?bool = null,
    write_attempted: bool = false,
    write_succeeded: bool = false,
    failure: ?anyerror = null,
    pub fn changed(self: Outcome) ?bool {
        if (self.previous) |previous| if (self.current) |current| return current != previous;
        return null;
    }
};
/// Never retries a write. Read back after every attempted write; preserve the
/// original write error if observation also fails. Unknown state stays unknown.
pub fn apply(io: anytype, requested: bool) Outcome {
    var out = Outcome{};
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
    if (previous == requested) return out;
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
    if (out.failure == null and out.current.? != requested) out.failure = error.ControlNotApplied;
    return out;
}
const Fake = struct {
    current: bool = false,
    validations: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    fail_validation: bool = false,
    fail_read: usize = 0,
    fail_write: bool = false,
    change_on_failed_write: bool = false,
    ignore_write: bool = false,
    fn validate(self: *Fake) !void {
        self.validations += 1;
        if (self.fail_validation) return error.WrongDevice;
    }
    fn read(self: *Fake) !bool {
        self.reads += 1;
        if (self.fail_read == self.reads) return error.ReadFailure;
        return self.current;
    }
    fn write(self: *Fake, value: bool) !void {
        self.writes += 1;
        if (!self.ignore_write and (!self.fail_write or self.change_on_failed_write)) self.current = value;
        if (self.fail_write) return error.WriteFailure;
    }
};
test "boolean control observes unchanged and changed values without duplicate writes" {
    const t = std.testing;
    for ([_]bool{ false, true }) |initial| for ([_]bool{ false, true }) |requested| {
        var io = Fake{ .current = initial };
        const out = apply(&io, requested);
        try t.expect(out.failure == null);
        try t.expectEqual(@as(?bool, initial), out.previous);
        try t.expectEqual(@as(?bool, requested), out.current);
        try t.expectEqual(@as(?bool, initial != requested), out.changed());
        try t.expectEqual(@as(usize, @intFromBool(initial != requested)), io.writes);
        try t.expectEqual(@as(usize, if (initial == requested) 1 else 2), io.reads);
        io.current = !requested;
        try t.expectEqual(@as(?bool, requested), out.current);
    };
}
test "boolean control validation and initial read errors do not attempt mutation" {
    const t = std.testing;
    var io = Fake{ .fail_validation = true };
    var out = apply(&io, true);
    try t.expectEqual(@as(?anyerror, error.WrongDevice), out.failure);
    try t.expect(out.previous == null and out.current == null and !out.write_attempted);
    try t.expectEqual(@as(usize, 0), io.reads);
    io = .{ .fail_read = 1 };
    out = apply(&io, true);
    try t.expectEqual(@as(?anyerror, error.ReadFailure), out.failure);
    try t.expect(out.changed() == null and !out.write_attempted and io.writes == 0);
}
test "boolean control retains observed partial changes and first errors without claiming unknown state" {
    const t = std.testing;
    for ([_]bool{ false, true }) |changed| {
        var io = Fake{ .fail_write = true, .change_on_failed_write = changed };
        const out = apply(&io, true);
        try t.expectEqual(@as(?anyerror, error.WriteFailure), out.failure);
        try t.expectEqual(@as(?bool, changed), out.current);
        try t.expectEqual(@as(?bool, changed), out.changed());
        try t.expect(out.write_attempted and !out.write_succeeded and io.writes == 1);
    }
    var io = Fake{ .fail_read = 2 };
    var out = apply(&io, true);
    try t.expect(out.write_attempted and out.write_succeeded and out.current == null and out.changed() == null);
    try t.expectEqual(@as(?anyerror, error.ReadFailure), out.failure);
    io = .{ .fail_write = true, .fail_read = 2, .change_on_failed_write = true };
    out = apply(&io, true);
    try t.expectEqual(@as(?anyerror, error.WriteFailure), out.failure);
    try t.expect(out.current == null and out.changed() == null);
    io = .{ .ignore_write = true };
    out = apply(&io, true);
    try t.expectEqual(@as(?anyerror, error.ControlNotApplied), out.failure);
    try t.expectEqual(@as(?bool, false), out.changed());
    try t.expect(out.write_succeeded and io.writes == 1);
}
