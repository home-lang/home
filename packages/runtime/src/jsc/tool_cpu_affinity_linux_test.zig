//! Only imported by Linux CPU-availability test builds.
const std = @import("std");
const cpu = @import("tool_cpu.zig");

test "native availability follows changed Linux affinity and restores it" {
    const original = try std.posix.sched_getaffinity(0);
    const before = try cpu.availableParallelism();
    try std.testing.expect(std.posix.CPU_COUNT(original) > 0);
    var restricted: std.os.linux.cpu_set_t = @splat(0);
    var selected: usize = 0;
    defer std.os.linux.sched_setaffinity(0, &original) catch @panic("cannot restore CPU test affinity");
    for (original, 0..) |word, index| {
        for (0..@bitSizeOf(@TypeOf(word))) |bit| {
            const flag = @as(@TypeOf(word), 1) << @intCast(bit);
            if (word & flag == 0) continue;
            restricted[index] |= flag;
            selected += 1;
            try std.os.linux.sched_setaffinity(0, &restricted);
            try std.testing.expectEqual(selected, try std.Thread.getCpuCount());
            try std.testing.expectEqual(@min(before, selected), try cpu.availableParallelism());
            if (selected == 2) break;
        }
        if (selected == 2) break;
    }
    try std.os.linux.sched_setaffinity(0, &original);
    try std.testing.expectEqual(before, try cpu.availableParallelism());
}
