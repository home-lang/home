const std = @import("std");

const debug = @import("bun/debug.zig");
const scaffold = @import("bun/debug_scaffold.zig");

test "copied Bun debug group is disabled by compat logs flag" {
    try std.testing.expect(!debug.group.getLogEnabled());
    debug.group.begin(@src());
    debug.group.beginMsg("disabled {d}", .{1});
    debug.group.log("disabled {d}", .{2});
    debug.group.end();
}

test "copied Bun debug dump functions no-op with logging disabled" {
    var describe = scaffold.DescribeScope.init(std.testing.allocator, .{
        .name = "root",
        .concurrent = true,
        .has_callback = true,
    });
    defer describe.deinit();

    var before_all = scaffold.ExecutionEntry{ .base = .{ .name = "setup" } };
    var test_entry = scaffold.ExecutionEntry{ .base = .{ .name = "case", .concurrent = true } };
    var after_all = scaffold.ExecutionEntry{ .base = .{ .name = "cleanup" } };

    try describe.beforeAll.append(&before_all);
    try describe.entries.append(.{ .test_callback = &test_entry });
    try describe.afterAll.append(&after_all);

    try debug.dumpTest(&test_entry, "test");
    try debug.dumpSub(.{ .describe = &describe });
    try debug.dumpSub(.{ .test_callback = &test_entry });
    try debug.dumpDescribe(&describe);
}

test "copied Bun debug dumpOrder accepts runner scheduling shapes" {
    var first = scaffold.ExecutionEntry{ .base = .{ .name = "first" } };
    var second = scaffold.ExecutionEntry{ .base = .{ .name = "second" } };
    first.next = &second;

    var sequences = [_]scaffold.ExecutionSequence{
        .{ .first_entry = &first, .remaining_repeat_count = 2 },
    };
    var groups = [_]scaffold.ConcurrentGroup{
        .{ .sequence_start = 0, .sequence_end = sequences.len },
    };
    var execution = scaffold.Execution{
        .groups = &groups,
        .sequences = &sequences,
    };

    try debug.dumpOrder(&execution);
}
