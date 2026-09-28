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
        return spawnWithAttr(allocator, .{}, func, args);
    }

    pub fn spawnWithAttr(
        allocator: std.mem.Allocator,
        attr: ThreadAttr,
        comptime func: anytype,
        args: anytype,
    ) ThreadError!Thread {
        const config = try attr.spawnConfig(allocator);
        const inner = std.Thread.spawn(config, func, args) catch {
            return ThreadError.ThreadCreationFailed;
        };
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
        const builtin = @import("builtin");
        if (comptime builtin.os.tag == .windows) {
            // Windows: use NtDelayExecution with negative 100ns intervals
            const delay = -@as(i64, @intCast(nanoseconds / 100));
            _ = std.os.windows.ntdll.NtDelayExecution(@enumFromInt(0), &delay);
        } else if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const seconds: isize = @intCast(nanoseconds / 1_000_000_000);
            const nanos: isize = @intCast(nanoseconds % 1_000_000_000);
            _ = linux.nanosleep(&.{ .sec = seconds, .nsec = nanos }, null);
        } else {
            const seconds: isize = @intCast(nanoseconds / 1_000_000_000);
            const nanos: isize = @intCast(nanoseconds % 1_000_000_000);
            _ = std.c.nanosleep(&.{ .sec = seconds, .nsec = nanos }, null);
        }
    }

    pub const Id = std.Thread.Id;
};

pub const ThreadAttr = struct {
    pub const minimum_stack_size: usize = 16 * 1024;

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

    fn spawnConfig(self: ThreadAttr, allocator: std.mem.Allocator) ThreadError!std.Thread.SpawnConfig {
        var config = std.Thread.SpawnConfig{ .allocator = allocator };
        if (self.stack_size) |stack_size| {
            if (stack_size < minimum_stack_size) return ThreadError.StackTooSmall;
            config.stack_size = stack_size;
        }
        return config;
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

test "thread attributes configure stack and allocator" {
    const testing = std.testing;
    var attr = ThreadAttr.init();
    attr.setStackSize(512 * 1024);

    const config = try attr.spawnConfig(testing.allocator);
    try testing.expectEqual(@as(usize, 512 * 1024), config.stack_size);
    try testing.expect(config.allocator.?.ptr == testing.allocator.ptr);

    attr.setStackSize(ThreadAttr.minimum_stack_size - 1);
    try testing.expectError(ThreadError.StackTooSmall, attr.spawnConfig(testing.allocator));
}

test "thread sleep" {
    // Just verify sleep doesn't crash
    Thread.sleep(1_000_000); // 1ms
}
