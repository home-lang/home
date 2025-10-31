// Home Programming Language - Thread Barriers
// Wrapper around Zig's std.Thread.ResetEvent

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Barrier = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    threshold: u32,
    count: u32,
    generation: u32,

    pub fn init(count: u32) ThreadError!Barrier {
        return Barrier{
            .mutex = .{},
            .cond = .{},
            .threshold = count,
            .count = 0,
            .generation = 0,
        };
    }

    pub fn deinit(self: *Barrier) void {
        _ = self;
    }

    pub fn wait(self: *Barrier) ThreadError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gen = self.generation;
        self.count += 1;

        if (self.count == self.threshold) {
            self.generation += 1;
            self.count = 0;
            self.cond.broadcast();
        } else {
            while (gen == self.generation) {
                self.cond.wait(&self.mutex);
            }
        }
    }
};

test "barrier init" {
    var barrier = try Barrier.init(2);
    defer barrier.deinit();
}
