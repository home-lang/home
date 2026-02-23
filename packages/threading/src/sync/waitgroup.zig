// Home Programming Language - WaitGroup
// Go-style waiting for multiple operations to complete (spin-based for Zig 0.16)

const std = @import("std");

/// WaitGroup - wait for collection of operations to finish
/// Similar to Go's sync.WaitGroup
pub const WaitGroup = struct {
    counter: std.atomic.Value(i32),

    pub fn init() WaitGroup {
        return .{
            .counter = std.atomic.Value(i32).init(0),
        };
    }

    pub fn deinit(self: *WaitGroup) void {
        _ = self;
    }

    /// Add delta to the WaitGroup counter
    pub fn add(self: *WaitGroup, delta: i32) void {
        const old = self.counter.fetchAdd(delta, .release);
        const new = old + delta;

        if (new < 0) {
            @panic("WaitGroup counter cannot be negative");
        }
    }

    /// Decrement counter by 1
    pub fn done(self: *WaitGroup) void {
        self.add(-1);
    }

    /// Wait until counter reaches zero
    pub fn wait(self: *WaitGroup) void {
        while (self.counter.load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }
    }
};

test "waitgroup" {
    const testing = std.testing;

    var wg = WaitGroup.init();
    defer wg.deinit();

    wg.add(2);
    wg.done();
    wg.done();
    wg.wait(); // Should return immediately since counter is 0

    try testing.expect(wg.counter.load(.monotonic) == 0);
}
