const std = @import("std");

const DoneCallback = @import("bun/DoneCallback.zig");
const scaffold = @import("bun/done_callback_scaffold.zig");

fn resetVmAllocator() void {
    scaffold.jsc.VirtualMachine.useAllocator(std.testing.allocator);
}

test "copied Bun DoneCallback creates an unbound live JS wrapper" {
    resetVmAllocator();
    var global = scaffold.jsc.JSGlobalObject.init(std.testing.allocator);

    const value = DoneCallback.createUnbound(&global);

    try std.testing.expectEqual(@as(usize, 1), global.ensure_alive_count);
    const callback = DoneCallback.fromJS(value).?;
    defer std.testing.allocator.destroy(callback);
    try std.testing.expect(callback.ref == null);
    try std.testing.expect(!callback.called);
}

test "copied Bun DoneCallback finalize derefs pending ref data" {
    resetVmAllocator();
    var deref_count: usize = 0;
    var ref_data = scaffold.BunTest.RefData{ .deref_count = &deref_count };
    const callback = try std.testing.allocator.create(DoneCallback);
    callback.* = .{ .ref = &ref_data };

    callback.finalize();

    try std.testing.expectEqual(@as(usize, 1), deref_count);
}

test "copied Bun DoneCallback finalize ignores already-cleared ref data" {
    resetVmAllocator();
    const callback = try std.testing.allocator.create(DoneCallback);
    callback.* = .{ .ref = null, .called = true };

    callback.finalize();
}

test "copied Bun DoneCallback bind returns a done-bound wrapper" {
    resetVmAllocator();
    var global = scaffold.jsc.JSGlobalObject.init(std.testing.allocator);
    const value = DoneCallback.createUnbound(&global);
    const callback = DoneCallback.fromJS(value).?;
    defer std.testing.allocator.destroy(callback);

    const bound = try DoneCallback.bind(value, &global);

    try std.testing.expect(DoneCallback.fromJS(bound).? == callback);
    try std.testing.expectEqualStrings("done", bound.bound_name.?);
    try std.testing.expectEqual(@as(usize, 1), bound.bound_arg_count);
}
