//! Linux-only live affinity witness; invoked explicitly by ecosystem qualification.
const std = @import("std");
const cpu = @import("tool_cpu_info.zig");

test "processor information retains all online CPUs when Linux affinity changes" {
    const original = try std.posix.sched_getaffinity(0);
    defer std.os.linux.sched_setaffinity(0, &original) catch @panic("cannot restore CPU information test affinity");
    var before = try cpu.snapshot(std.testing.allocator);
    defer before.deinit();
    var restricted: std.os.linux.cpu_set_t = @splat(0);
    var selected = false;
    outer: for (original, 0..) |word, index| {
        for (0..@bitSizeOf(@TypeOf(word))) |bit| {
            const flag = @as(@TypeOf(word), 1) << @intCast(bit);
            if (word & flag == 0) continue;
            restricted[index] = flag;
            selected = true;
            break :outer;
        }
    }
    try std.testing.expect(selected);
    try std.os.linux.sched_setaffinity(0, &restricted);
    try std.testing.expectEqual(@as(usize, 1), try std.Thread.getCpuCount());
    var after = try cpu.snapshot(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqual(before.records.len, after.records.len);
    for (before.records, after.records) |one, two| try std.testing.expectEqualStrings(one.model, two.model);
}
