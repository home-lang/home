// Home Programming Language - Thread Barriers
// Spin-based barrier for Zig 0.16 (std.Thread.Condition removed)

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Barrier = struct {
    threshold: u32,
    count: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),

    pub fn init(count: u32) ThreadError!Barrier {
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
            // Last thread: reset count and advance generation
            self.count.store(0, .release);
            _ = self.generation.fetchAdd(1, .release);
        } else {
            // Spin until generation advances
            while (self.generation.load(.acquire) == gen) {
                std.atomic.spinLoopHint();
            }
        }
    }
};

test "barrier init" {
    var barrier = try Barrier.init(2);
    defer barrier.deinit();
}
