const std = @import("std");

const Collection = @import("bun/Collection.zig");
const scaffold = @import("bun/collection_scaffold.zig");

fn globalObject() *scaffold.jsc.JSGlobalObject {
    return @ptrFromInt(@as(usize, 1));
}

fn makeScope(gpa: std.mem.Allocator, name: ?[]const u8, parent: ?*scaffold.DescribeScope) *scaffold.DescribeScope {
    return scaffold.DescribeScope.create(gpa, .{
        .parent = parent,
        .name = name,
        .concurrent = false,
        .mode = .normal,
        .only = .no,
        .has_callback = false,
        .test_id_for_debugger = 0,
        .line_no = 0,
    });
}

test "copied Bun Collection initializes root scope under preload hook scope" {
    const allocator = std.testing.allocator;
    const hook_scope = makeScope(allocator, "hook", null);
    defer hook_scope.destroy(allocator);
    var root = scaffold.BunTestRoot{ .hook_scope = hook_scope };
    var buntest = scaffold.BunTest.init(allocator, &root);
    defer buntest.deinit();

    try std.testing.expect(buntest.collection.root_scope == buntest.collection.active_scope);
    try std.testing.expect(buntest.collection.root_scope.base.parent == hook_scope);
    try std.testing.expectEqual(scaffold.ScopeMode.normal, buntest.collection.root_scope.base.mode);
    try std.testing.expectEqual(@as(usize, 0), buntest.collection.describe_callback_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), buntest.collection.current_scope_callback_queue.items.len);
}

test "copied Bun Collection queues describe callbacks in active scope" {
    const allocator = std.testing.allocator;
    const hook_scope = makeScope(allocator, "hook", null);
    defer hook_scope.destroy(allocator);
    var root = scaffold.BunTestRoot{ .hook_scope = hook_scope };
    var buntest = scaffold.BunTest.init(allocator, &root);
    defer buntest.deinit();

    const child_scope = makeScope(allocator, "child", buntest.collection.active_scope);
    defer child_scope.destroy(allocator);

    try buntest.collection.enqueueDescribeCallback(child_scope, 42);

    try std.testing.expectEqual(@as(usize, 1), buntest.collection.current_scope_callback_queue.items.len);
    const queued = buntest.collection.current_scope_callback_queue.items[0];
    try std.testing.expect(queued.active_scope == buntest.collection.root_scope);
    try std.testing.expect(queued.new_scope == child_scope);
    try std.testing.expectEqual(@as(scaffold.jsc.JSValue, 42), queued.callback.get());
}

test "copied Bun Collection step runs queued describe callback and restores scope" {
    const allocator = std.testing.allocator;
    const hook_scope = makeScope(allocator, "hook", null);
    defer hook_scope.destroy(allocator);
    var root = scaffold.BunTestRoot{ .hook_scope = hook_scope };
    var buntest = scaffold.BunTest.init(allocator, &root);
    defer buntest.deinit();

    const previous_scope = buntest.collection.active_scope;
    const child_scope = makeScope(allocator, "child", previous_scope);
    defer child_scope.destroy(allocator);

    buntest.next_callback_result = .{ .collection = .{ .active_scope = previous_scope } };
    try buntest.collection.enqueueDescribeCallback(child_scope, 99);

    const first = try Collection.step(buntest.strong(), globalObject(), .start);
    try std.testing.expect(first == .waiting);
    try std.testing.expect(buntest.collection.active_scope == child_scope);
    try std.testing.expectEqual(@as(usize, 1), buntest.callback_runs);
    try std.testing.expectEqual(@as(?scaffold.jsc.JSValue, 99), buntest.last_callback);
    try std.testing.expectEqual(@as(usize, 1), buntest.added_results.items.len);

    const callback_data = buntest.last_callback_data.?;
    try std.testing.expect(callback_data == .collection);
    try std.testing.expect(callback_data.collection.active_scope == previous_scope);

    const second = try Collection.step(buntest.strong(), globalObject(), .{ .collection = .{ .active_scope = previous_scope } });
    try std.testing.expect(second == .complete);
    try std.testing.expect(buntest.collection.active_scope == previous_scope);
}

test "copied Bun Collection marks active describe failed after uncaught exception" {
    const allocator = std.testing.allocator;
    const hook_scope = makeScope(allocator, "hook", null);
    defer hook_scope.destroy(allocator);
    var root = scaffold.BunTestRoot{ .hook_scope = hook_scope };
    var buntest = scaffold.BunTest.init(allocator, &root);
    defer buntest.deinit();

    const status = buntest.collection.handleUncaughtException(.start);

    try std.testing.expectEqual(scaffold.HandleUncaughtExceptionResult.show_unhandled_error_in_describe, status);
    try std.testing.expect(buntest.collection.active_scope.failed);
}

test "copied Bun Collection skips callbacks from failed active scopes" {
    const allocator = std.testing.allocator;
    const hook_scope = makeScope(allocator, "hook", null);
    defer hook_scope.destroy(allocator);
    var root = scaffold.BunTestRoot{ .hook_scope = hook_scope };
    var buntest = scaffold.BunTest.init(allocator, &root);
    defer buntest.deinit();

    const child_scope = makeScope(allocator, "child", buntest.collection.active_scope);
    defer child_scope.destroy(allocator);
    try buntest.collection.enqueueDescribeCallback(child_scope, 77);
    buntest.collection.active_scope.failed = true;

    const result = try Collection.step(buntest.strong(), globalObject(), .start);

    try std.testing.expect(result == .complete);
    try std.testing.expectEqual(@as(usize, 0), buntest.callback_runs);
}
