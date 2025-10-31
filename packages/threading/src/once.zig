// Home Programming Language - Once Initialization
// Ensure function runs exactly once

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Once = struct {
    state: std.atomic.Value(u32),

    pub fn init() Once {
        return Once{
            .state = std.atomic.Value(u32).init(0),
        };
    }

    pub fn call(self: *Once, func: *const fn () void) ThreadError!void {
        if (self.state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            func();
            self.state.store(2, .release);
        } else {
            while (self.state.load(.acquire) != 2) {
                std.atomic.spinLoopHint();
            }
        }
    }
};

test "once init" {
    const once = Once.init();
    _ = once;
}
