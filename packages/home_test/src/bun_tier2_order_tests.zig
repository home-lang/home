const std = @import("std");

const Order = @import("bun/Order.zig");
const scaffold = @import("bun/order_scaffold.zig");

fn makeOrder(arena: std.mem.Allocator) Order {
    return Order.init(std.testing.allocator, arena, .{
        .always_use_hooks = false,
        .randomize = null,
    });
}

fn callbackSentinel() *anyopaque {
    return @ptrFromInt(@as(usize, 1));
}

test "copied Bun Order merges adjacent concurrent groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var order = makeOrder(arena_state.allocator());
    defer order.deinit();

    try Order.appendOrExtendConcurrentGroup(&order, true, 0, 1);
    try Order.appendOrExtendConcurrentGroup(&order, true, 1, 2);
    try Order.appendOrExtendConcurrentGroup(&order, false, 2, 3);

    try std.testing.expectEqual(@as(usize, 2), order.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), order.groups.items[0].sequence_start);
    try std.testing.expectEqual(@as(usize, 2), order.groups.items[0].sequence_end);
    try std.testing.expectEqual(@as(usize, 2), order.groups.items[0].remaining_incomplete_entries);
    try std.testing.expectEqual(@as(usize, 2), order.groups.items[1].sequence_start);
    try std.testing.expectEqual(@as(usize, 3), order.groups.items[1].sequence_end);
}

test "copied Bun Order generateAllOrder creates one group per entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var order = makeOrder(arena_state.allocator());
    defer order.deinit();

    var first = scaffold.ExecutionEntry{
        .base = .{ .has_callback = true },
        .callback = callbackSentinel(),
        .next = undefined,
        .failure_skip_past = undefined,
    };
    var second = scaffold.ExecutionEntry{
        .base = .{ .has_callback = true },
        .callback = callbackSentinel(),
        .next = &first,
        .failure_skip_past = &first,
    };
    const entries = [_]*scaffold.ExecutionEntry{ &first, &second };

    const result = try order.generateAllOrder(&entries);

    try std.testing.expectEqual(@as(usize, 0), result.start);
    try std.testing.expectEqual(@as(usize, 2), result.end);
    try std.testing.expectEqual(@as(usize, 2), order.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), order.sequences.items.len);
    try std.testing.expect(first.next == null);
    try std.testing.expect(first.failure_skip_past == null);
    try std.testing.expect(second.next == null);
    try std.testing.expect(second.failure_skip_past == null);
    try std.testing.expectEqual(@as(usize, 0), order.groups.items[0].sequence_start);
    try std.testing.expectEqual(@as(usize, 1), order.groups.items[0].sequence_end);
    try std.testing.expectEqual(@as(usize, 1), order.groups.items[1].sequence_start);
    try std.testing.expectEqual(@as(usize, 2), order.groups.items[1].sequence_end);
}

test "copied Bun Order generateOrderTest wraps hooks and preserves retry repeat counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var order = makeOrder(arena_state.allocator());
    defer order.deinit();

    var root = scaffold.DescribeScope.init(std.testing.allocator, .{ .has_callback = true });
    defer root.deinit();

    var before_each = scaffold.ExecutionEntry{
        .base = .{ .parent = &root, .has_callback = true },
        .callback = callbackSentinel(),
    };
    var test_entry = scaffold.ExecutionEntry{
        .base = .{ .parent = &root, .has_callback = true },
        .callback = callbackSentinel(),
        .retry_count = 2,
        .repeat_count = 3,
    };
    var after_each = scaffold.ExecutionEntry{
        .base = .{ .parent = &root, .has_callback = true },
        .callback = callbackSentinel(),
    };

    try root.beforeEach.append(&before_each);
    try root.afterEach.append(&after_each);

    try order.generateOrderTest(&test_entry);

    try std.testing.expectEqual(@as(usize, 1), order.groups.items.len);
    try std.testing.expectEqual(@as(usize, 1), order.sequences.items.len);

    const sequence = order.sequences.items[0];
    try std.testing.expectEqual(@as(u32, 2), sequence.remaining_retry_count);
    try std.testing.expectEqual(@as(u32, 3), sequence.remaining_repeat_count);
    try std.testing.expect(sequence.first_entry != null);
    try std.testing.expect(sequence.test_entry == &test_entry);
    try std.testing.expect(sequence.first_entry != &test_entry);
    try std.testing.expect(sequence.first_entry.?.next == &test_entry);
    try std.testing.expect(test_entry.next != null);
    try std.testing.expect(test_entry.next != &after_each);
    try std.testing.expect(test_entry.next.?.next == null);
    try std.testing.expect(sequence.first_entry.?.failure_skip_past == &test_entry);
    try std.testing.expect(test_entry.failure_skip_past == &test_entry);
    try std.testing.expect(test_entry.next.?.failure_skip_past == null);
}
