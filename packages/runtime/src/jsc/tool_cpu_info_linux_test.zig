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

test "native CPU proc files expose live data despite zero stat length" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "/proc/stat", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(u64, 0), stat.size);
    const empty = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/stat", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const streamed = try @import("tool_cpu_files.zig").read(std.testing.allocator, .cwd(), "/proc/stat", .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(streamed);
    try std.testing.expect(std.mem.startsWith(u8, streamed, "cpu "));
}
