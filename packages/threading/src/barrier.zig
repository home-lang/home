// Home Programming Language - Thread Barriers
// Reusable generation barrier with futex-backed blocking

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Futex = @import("threading_futex");

pub const Barrier = struct {
    threshold: u32,
    count: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),

    pub fn init(count: u32) ThreadError!Barrier {
        if (count == 0) return ThreadError.InvalidArgument;
        return Barrier{
            .threshold = count,
            .count = std.atomic.Value(u32).init(0),
            .generation = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Barrier) void {
        _ = self;
    }

    pub fn wait(self: *Barrier) ThreadError!void {
        const gen = self.generation.load(.acquire);
        const old = self.count.fetchAdd(1, .acq_rel);

        if (old + 1 == self.threshold) {
            self.count.store(0, .release);
            _ = self.generation.fetchAdd(1, .release);
            Futex.wake(&self.generation, std.math.maxInt(u32));
        } else {
            while (self.generation.load(.acquire) == gen) {
                Futex.waitForever(&self.generation, gen);
            }
        }
    }
};

test "barrier init" {
    var barrier = try Barrier.init(2);
    defer barrier.deinit();
    try std.testing.expectError(ThreadError.InvalidArgument, Barrier.init(0));
}

test "barrier releases eight threads across repeated generations" {
    const thread_count = 8;
    const rounds = 100;
    var barrier = try Barrier.init(thread_count);
    defer barrier.deinit();

    const Context = struct {
        barrier: *Barrier,
        arrivals: [rounds]std.atomic.Value(u32) = @splat(.init(0)),
        failed: std.atomic.Value(bool) = .init(false),

        fn worker(context: *@This()) void {
            for (0..rounds) |round| {
                _ = context.arrivals[round].fetchAdd(1, .release);
                context.barrier.wait() catch {
                    context.failed.store(true, .release);
                    return;
                };
                if (context.arrivals[round].load(.acquire) != thread_count) {
                    context.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var context = Context{ .barrier = &barrier };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.worker, .{&context});
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
    for (&context.arrivals) |*arrivals| {
        try std.testing.expectEqual(@as(u32, thread_count), arrivals.load(.acquire));
    }
}
