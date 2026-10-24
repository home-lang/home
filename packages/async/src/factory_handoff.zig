//! A factory callback and its waiting consumer are independent owners. A wait
//! ending or cancellation must never retire an unfinished producer callback.
//! Caller serializes transitions and owns all payload/cleanup separately.
const std = @import("std");
const preparation = @import("preparation_gate.zig");
pub const Handoff = struct {
    gate: preparation.Gate = .{},
    callback_started: bool = false,
    callback_done: bool = false,
    waiter_done: bool = false,
    supplied: bool = false,
    code: i32 = 0,

    /// A cancelled, unclaimed notification still needs finishCallback to retire
    /// its notification lifetime, but must not invoke application work.
    pub fn beginCallback(self: *Handoff) !bool {
        if (self.callback_started or self.callback_done) return error.AlreadyClaimed;
        self.callback_started = true;
        return self.gate.claim();
    }
    pub fn supply(self: *Handoff) !void {
        if (!self.callback_started or self.callback_done or self.supplied) return error.InvalidState;
        if (self.waiter_done or self.gate.cancel_requested or self.gate.phase == .cancelled) return error.Cancelled;
        self.supplied = true;
        // Input-owner release can be asynchronous. Readiness is withheld until
        // that callback has joined, even though the consumer payload exists.
    }
    pub fn finishCallback(self: *Handoff, code: i32) !void {
        if (!self.callback_started or self.callback_done) return error.InvalidState;
        if (code == 0 and !self.supplied and self.gate.phase != .cancelled and !self.gate.cancel_requested) return error.InvalidState;
        self.callback_done = true;
        self.code = code;
        if (code != 0) {
            _ = self.gate.fail();
        } else if (self.gate.cancel_requested) {
            // The host has retired any unpublished payload to an owning cleanup
            // queue. Physical storage may remain charged there until retry.
            _ = self.gate.cleaned();
        } else if (self.gate.phase != .cancelled) {
            std.debug.assert(self.gate.ready());
        }
    }
    pub fn cancel(self: *Handoff) bool {
        return self.gate.cancel();
    }
    pub fn publish(self: *Handoff) bool {
        if (!self.callback_done or self.waiter_done or self.code != 0) return false;
        return self.gate.publish();
    }
    pub fn finishWaiter(self: *Handoff) !void {
        if (self.waiter_done) return error.InvalidState;
        if (self.gate.phase != .published) _ = self.gate.cancel();
        if (self.callback_done and self.gate.cancel_requested) _ = self.gate.cleaned();
        self.waiter_done = true;
    }
    pub fn releasable(self: *const Handoff) bool {
        return self.callback_done and self.waiter_done;
    }
};

test "supplied storage stays unpublished until the producer release joins" {
    var handoff: Handoff = .{};
    try std.testing.expect(try handoff.beginCallback());
    try handoff.supply();
    try std.testing.expect(!handoff.publish());
    try std.testing.expectError(error.AlreadyClaimed, handoff.beginCallback());
    try handoff.finishCallback(0);
    try std.testing.expect(handoff.publish());
    try std.testing.expect(!handoff.cancel());
    try std.testing.expect(!handoff.releasable());
    try handoff.finishWaiter();
    try std.testing.expect(handoff.releasable());
    try std.testing.expectError(error.InvalidState, handoff.finishWaiter());
}
test "waiter cancellation retains a late callback notification before or after claim" {
    for ([_]bool{ false, true }) |claimed| {
        var handoff: Handoff = .{};
        if (claimed) try std.testing.expect(try handoff.beginCallback());
        try handoff.finishWaiter();
        try std.testing.expect(!handoff.releasable());
        if (!claimed) try std.testing.expect(!try handoff.beginCallback());
        try std.testing.expectError(error.Cancelled, handoff.supply());
        try handoff.finishCallback(0);
        try std.testing.expect(handoff.releasable());
        try std.testing.expect(!handoff.publish());
    }
}
test "cancellation of supplied work and producer errors cannot publish late results" {
    for ([_]i32{ 0, -6 }) |code| {
        var handoff: Handoff = .{};
        try std.testing.expect(try handoff.beginCallback());
        try handoff.supply();
        try std.testing.expect(handoff.cancel());
        try std.testing.expect(!handoff.publish());
        try handoff.finishCallback(code);
        try std.testing.expect(!handoff.publish());
        try handoff.finishWaiter();
        try std.testing.expect(handoff.releasable());
        try std.testing.expectEqual(code, handoff.code);
    }
}
test "an unfinished or failed factory cannot fabricate a successful payload" {
    var handoff: Handoff = .{};
    try std.testing.expectError(error.InvalidState, handoff.supply());
    try std.testing.expectError(error.InvalidState, handoff.finishCallback(0));
    try std.testing.expect(try handoff.beginCallback());
    try std.testing.expectError(error.InvalidState, handoff.finishCallback(0));
    try handoff.finishCallback(-6);
    try std.testing.expect(!handoff.publish());
    try handoff.finishWaiter();
    try std.testing.expect(handoff.releasable());
}
