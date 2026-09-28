// Home Programming Language - Thread Primitives
// Wrapper around Zig's std.Thread for Home language idioms

const std = @import("std");
const builtin = @import("builtin");
const ThreadError = @import("errors.zig").ThreadError;

fn currentPthreadStackSize() ?usize {
    if (comptime !std.Thread.use_pthreads) return null;

    if (comptime builtin.os.tag == .macos) {
        const Pthread = struct {
            extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
        };
        return Pthread.pthread_get_stacksize_np(std.c.pthread_self());
    }

    if (comptime builtin.os.tag == .linux) {
        const Pthread = struct {
            extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
            extern "c" fn pthread_attr_getstacksize(attr: *const std.c.pthread_attr_t, stack_size: *usize) c_int;
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (Pthread.pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
        defer _ = std.c.pthread_attr_destroy(&attr);

        var stack_size: usize = 0;
        if (Pthread.pthread_attr_getstacksize(&attr, &stack_size) != 0) return null;
        return stack_size;
    }

    return null;
}

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

test "spawnWithAttr applies the requested pthread stack size" {
    if (comptime !std.Thread.use_pthreads or (builtin.os.tag != .macos and builtin.os.tag != .linux)) {
        return error.SkipZigTest;
    }

    const requested_stack_size = 512 * 1024;
    var observed_stack_size: ?usize = null;
    const Worker = struct {
        fn run(observed: *?usize) void {
            observed.* = currentPthreadStackSize();
        }
    };

    var attr = ThreadAttr.init();
    attr.setStackSize(requested_stack_size);
    const thread = try Thread.spawnWithAttr(std.testing.allocator, attr, Worker.run, .{&observed_stack_size});
    try thread.join();

    try std.testing.expect(observed_stack_size != null);
    const observed = observed_stack_size.?;
    try std.testing.expect(observed >= requested_stack_size);
    try std.testing.expect(observed < std.Thread.SpawnConfig.default_stack_size);
}

test "thread sleep" {
    // Just verify sleep doesn't crash
    Thread.sleep(1_000_000); // 1ms
}
