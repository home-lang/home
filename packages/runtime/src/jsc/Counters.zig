// Copied from bun/src/jsc/Counters.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge surface omitted:
//   - `toJS`                  (needs jsc.JSObject.create + JSGlobalObject)
//   - `createCountersObject`  (needs jsc.CallFrame + JSGlobalObject + bunVM())
// These re-land alongside the rest of the JSC binding surface in Phase 12.2.
//
// What survives is the pure-Zig counter struct plus the saturating-increment
// `mark` helper, which is the bit other Home subsystems use to record
// observability events.

const Counters = @This();

spawnSync_blocking: i32 = 0,
spawn_memfd: i32 = 0,

pub fn mark(this: *Counters, comptime tag: Field) void {
    @field(this, @tagName(tag)) +|= 1;
}

const Field = std.meta.FieldEnum(Counters);

const std = @import("std");

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
