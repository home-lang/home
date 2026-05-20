const std = @import("std");

const scaffold = @import("bun/execution_scaffold.zig");
const Execution = @import("bun/Execution.zig");

test "copied Bun Execution initializes empty scheduler state" {
    var execution = Execution.init(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), execution.groups.len);
    try std.testing.expectEqual(@as(usize, 0), execution.sequences.len);
    try std.testing.expectEqual(@as(usize, 0), execution.group_index);
    try std.testing.expect(execution.activeGroup() == null);
}

test "copied Bun Execution exposes grouped sequence windows" {
    var first = scaffold.ExecutionEntry{ .base = .{ .name = "first" } };
    var second = scaffold.ExecutionEntry{ .base = .{ .name = "second" } };
    var sequences = [_]Execution.ExecutionSequence{
        .init(.{ .first_entry = &first, .test_entry = &first }),
        .init(.{ .first_entry = &second, .test_entry = &second }),
    };
    var groups = [_]Execution.ConcurrentGroup{
        .init(0, 2, 1),
    };
    var execution = Execution{
        .groups = groups[0..],
        .sequences = sequences[0..],
        .group_index = 0,
    };

    const active = execution.activeGroup().?;
    const window = active.sequences(&execution);
    try std.testing.expectEqual(@as(usize, 2), window.len);
    try std.testing.expect(window[0].test_entry == &first);
    try std.testing.expect(window[1].test_entry == &second);
}

test "copied Bun Execution result classification mirrors runner statuses" {
    try std.testing.expect(Execution.Result.pass.isPass(.pending_is_fail));
    try std.testing.expect(Execution.Result.skip.isPass(.pending_is_fail));
    try std.testing.expect(Execution.Result.todo.isPass(.pending_is_fail));
    try std.testing.expect(Execution.Result.pending.isPass(.pending_is_pass));
    try std.testing.expect(Execution.Result.fail_because_timeout.isFail());
    try std.testing.expectEqual(Execution.Result.Basic.fail, Execution.Result.fail_because_expected_assertion_count.basicResult());
}

test "copied Bun Execution reset preserves retry history and removes execution-phase entries" {
    var test_entry = scaffold.ExecutionEntry{ .base = .{ .name = "case" } };
    var dynamic_hook = scaffold.ExecutionEntry{ .added_in_phase = .execution };
    test_entry.next = &dynamic_hook;

    var sequence = Execution.ExecutionSequence.init(.{
        .first_entry = &test_entry,
        .test_entry = &test_entry,
        .retry_count = 1,
        .repeat_count = 2,
    });
    sequence.flaky_attempt_count = 1;
    sequence.flaky_attempts_buf[0] = .{ .result = .fail, .elapsed_ns = 12 };

    var execution = Execution{
        .groups = &.{},
        .sequences = &.{},
        .group_index = 0,
    };
    execution.resetSequence(&sequence);

    try std.testing.expect(test_entry.next == null);
    try std.testing.expect(sequence.active_entry == &test_entry);
    try std.testing.expectEqual(@as(u32, 1), sequence.remaining_retry_count);
    try std.testing.expectEqual(@as(u32, 2), sequence.remaining_repeat_count);
    try std.testing.expectEqual(@as(usize, 1), sequence.flaky_attempt_count);
    try std.testing.expectEqual(Execution.Result.fail, sequence.flaky_attempts_buf[0].result);
}
