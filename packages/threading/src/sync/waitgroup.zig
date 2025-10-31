// Home Programming Language - WaitGroup
// Go-style waiting for multiple operations to complete

const std = @import("std");

/// WaitGroup - wait for collection of operations to finish
/// Similar to Go's sync.WaitGroup
pub const WaitGroup = struct {
    counter: std.atomic.Value(i32),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init() WaitGroup {
        return .{
            .counter = std.atomic.Value(i32).init(0),
            .mutex = .{},
            .cond = .{},
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

        if (new == 0) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    }

    /// Decrement counter by 1
    pub fn done(self: *WaitGroup) void {
        self.add(-1);
    }

    /// Wait until counter reaches zero
    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.counter.load(.acquire) > 0) {
            self.cond.wait(&self.mutex);
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
