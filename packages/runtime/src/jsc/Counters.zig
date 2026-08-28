// Copied from bun/src/jsc/Counters.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Native snapshots read the invoking VM's counters; the returned object does
// not share mutable state with the runtime or subsequent snapshots.

const Counters = @This();

spawnSync_blocking: i32 = 0,
spawn_memfd: i32 = 0,

pub fn mark(this: *Counters, comptime tag: Field) void {
    @field(this, @tagName(tag)) +|= 1;
}

pub fn toJS(this: *const Counters, globalObject: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
    return (try jsc.JSObject.create(this.*, globalObject)).toJS();
}

pub fn createCountersObject(globalObject: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    return globalObject.bunVM().counters.toJS(globalObject);
}

const Field = std.meta.FieldEnum(Counters);

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;

test "Counters.mark increments named fields saturating" {
    var c: Counters = .{};
    try std.testing.expectEqual(@as(i32, 0), c.spawnSync_blocking);
    c.mark(.spawnSync_blocking);
    c.mark(.spawnSync_blocking);
    c.mark(.spawn_memfd);
    try std.testing.expectEqual(@as(i32, 2), c.spawnSync_blocking);
    try std.testing.expectEqual(@as(i32, 1), c.spawn_memfd);
}

test "Counters.mark saturates at max i32" {
    var c: Counters = .{};
    c.spawnSync_blocking = std.math.maxInt(i32);
    c.mark(.spawnSync_blocking);
    try std.testing.expectEqual(std.math.maxInt(i32), c.spawnSync_blocking);
}
