//! Revision-aware two-phase job completion. Small allocation-free adaptation of
//! Home task states for event-driven jobs; caller owns synchronization.
//! A terminal outcome is immutable, including under cancellation/late events.
const std = @import("std");
pub const State = enum(u32) { pending = 1, active = 2, succeeded = 3, failed = 4, cancelled = 5, stopped = 6 };
pub const Gate = struct {
    revision: u64,
    state: State = .pending,
    observed_revision: ?u64 = null,
    pub fn terminal(self: Gate) bool {
        return switch (self.state) {
            .pending, .active => false,
            else => true,
        };
    }
    pub fn observe(self: *Gate, revision: u64, active: bool, outcome: ?bool) void {
        if (self.terminal() or revision < self.revision) return;
        // Request completions may arrive out of order. An older completion must
        // never finish a scan observed on a newer control revision.
        if (self.observed_revision) |latest| if (revision < latest) return;
        self.observed_revision = revision;
        if (active) self.state = .active;
        if (self.state == .active) {
            if (outcome) |success| {
                self.state = if (success) .succeeded else .failed;
            }
        }
    }
    pub fn cancel(self: *Gate) void {
        if (!self.terminal()) self.state = .cancelled;
    }
    pub fn stop(self: *Gate) void {
        if (!self.terminal()) self.state = .stopped;
    }
};
test "newer observations fence older completion events without rejecting equal revisions" {
    var g: Gate = .{ .revision = 9 };
    g.observe(11, false, true);
    g.observe(10, true, null);
    try std.testing.expectEqual(State.pending, g.state);
    g.observe(11, true, null);
    g.observe(10, false, false);
    try std.testing.expectEqual(State.active, g.state);
    g.observe(11, false, true);
    try std.testing.expectEqual(State.succeeded, g.state);
}
test "gate ignores stale and pre-active results; cancellation is terminal" {
    var g: Gate = .{ .revision = 9 };
    g.observe(8, true, null);
    g.observe(9, false, true);
    try std.testing.expectEqual(State.pending, g.state);
    g.observe(9, true, null);
    try std.testing.expectEqual(State.active, g.state);
    g.cancel();
    g.observe(10, false, true);
    try std.testing.expectEqual(State.cancelled, g.state);
}
test "success failure and stop never overwrite a terminal result" {
    var g: Gate = .{ .revision = 1 };
    g.observe(1, true, null);
    g.observe(2, false, true);
    g.cancel();
    g.stop();
    try std.testing.expectEqual(State.succeeded, g.state);
    g = .{ .revision = 1 };
    g.observe(1, true, null);
    g.observe(1, false, false);
    try std.testing.expectEqual(State.failed, g.state);
    g = .{ .revision = 1 };
    g.stop();
    g.observe(1, true, true);
    try std.testing.expectEqual(State.stopped, g.state);
}
