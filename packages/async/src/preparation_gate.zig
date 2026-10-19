//! Cooperative preparation followed by atomic publication. Caller serializes
//! access. Cancellation of claimed work is terminal only after owned cleanup.
const std = @import("std");
pub const Phase = enum(u32) { queued, preparing, ready, published, cancelled, failed };
pub const Gate = struct {
    phase: Phase = .queued,
    cancel_requested: bool = false,
    pub fn claim(self: *Gate) bool {
        if (self.phase != .queued) return false;
        self.phase = .preparing;
        return true;
    }
    pub fn ready(self: *Gate) bool {
        if (self.phase != .preparing or self.cancel_requested) return false;
        self.phase = .ready;
        return true;
    }
    pub fn publish(self: *Gate) bool {
        if (self.phase != .ready or self.cancel_requested) return false;
        self.phase = .published;
        return true;
    }
    pub fn cancel(self: *Gate) bool {
        if (self.cancel_requested) return false;
        switch (self.phase) {
            .queued => self.phase = .cancelled,
            .preparing, .ready => self.cancel_requested = true,
            else => return false,
        }
        return true;
    }
    pub fn cleaned(self: *Gate) bool {
        if (!self.cancel_requested or (self.phase != .preparing and self.phase != .ready)) return false;
        self.phase = .cancelled;
        return true;
    }
    pub fn fail(self: *Gate) bool {
        switch (self.phase) {
            .queued, .preparing, .ready => self.phase = .failed,
            else => return false,
        }
        return true;
    }
};
test "claimed cancellation waits for cleanup and prevents publication" {
    for ([_]bool{ false, true }) |prepared| {
        var g: Gate = .{};
        try std.testing.expect(g.claim());
        if (prepared) try std.testing.expect(g.ready());
        try std.testing.expect(g.cancel());
        try std.testing.expect(!g.cancel());
        try std.testing.expect(g.cancel_requested);
        try std.testing.expect(!g.publish());
        try std.testing.expect(g.phase != .cancelled);
        try std.testing.expect(g.cleaned());
        try std.testing.expectEqual(Phase.cancelled, g.phase);
        try std.testing.expect(!g.fail());
    }
}
test "queued cancellation and publication are immutable" {
    var g: Gate = .{};
    try std.testing.expect(!g.publish());
    try std.testing.expect(!g.ready());
    try std.testing.expect(g.cancel());
    try std.testing.expect(!g.claim());
    try std.testing.expect(!g.cleaned());
    g = .{};
    try std.testing.expect(g.claim());
    try std.testing.expect(!g.claim());
    try std.testing.expect(g.ready());
    try std.testing.expect(g.publish());
    try std.testing.expect(!g.cancel());
    try std.testing.expect(!g.fail());
    try std.testing.expectEqual(Phase.published, g.phase);
}
test "preparation errors remain errors even when cancellation was requested" {
    var g: Gate = .{};
    try std.testing.expect(g.claim());
    try std.testing.expect(g.cancel());
    try std.testing.expect(g.fail());
    try std.testing.expect(!g.cleaned());
    try std.testing.expect(!g.cancel());
    try std.testing.expectEqual(Phase.failed, g.phase);
}
