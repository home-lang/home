// Home Programming Language - Thread Primitives
// Wrapper around Zig's std.Thread for Home language idioms

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Thread = struct {
    inner: std.Thread,

    pub fn spawn(
        allocator: std.mem.Allocator,
        comptime func: anytype,
        args: anytype,
    ) ThreadError!Thread {
        const inner = std.Thread.spawn(.{}, func, args) catch {
            return ThreadError.ThreadCreationFailed;
        };
        _ = allocator; // For API compatibility
        return Thread{ .inner = inner };
    }

    pub fn join(self: Thread) ThreadError!void {
        self.inner.join();
    }

    pub fn detach(self: Thread) ThreadError!void {
        self.inner.detach();
    }

    pub fn getCurrentId() std.Thread.Id {
        return std.Thread.getCurrentId();
    }

    pub fn yield() void {
        std.Thread.yield() catch {};
    }

    pub fn sleep(nanoseconds: u64) void {
        std.Thread.sleep(nanoseconds);
    }

    pub const Id = std.Thread.Id;
};

pub const ThreadAttr = struct {
    stack_size: ?usize = null,
    priority: i32 = 0,

    pub fn init() ThreadAttr {
        return .{};
    }

    pub fn setStackSize(self: *ThreadAttr, size: usize) void {
        self.stack_size = size;
    }

    pub fn setPriority(self: *ThreadAttr, priority: i32) void {
        self.priority = priority;
    }
};

test "thread spawn and join" {
    const testing = std.testing;

    const TestFn = struct {
        fn worker(value: *i32) void {
            value.* = 42;
        }
    };

    var value: i32 = 0;
    const thread = try Thread.spawn(testing.allocator, TestFn.worker, .{&value});
    try thread.join();

    try testing.expectEqual(@as(i32, 42), value);
}

test "thread yield" {
    Thread.yield();
}

test "thread sleep" {
    const start = std.time.nanoTimestamp();
    Thread.sleep(1_000_000); // 1ms
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    const testing = std.testing;
    try testing.expect(elapsed >= 500_000);
}
