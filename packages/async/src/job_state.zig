//! Shared atomic task transitions. Cancellation cannot be undone by an in-flight
//! poll. Terminal states are immutable. Storage must outlive the polling owner.
const std = @import("std");
pub const State = enum(u8) { Pending, Running, Completed, Failed, Cancelled };
pub fn terminal(state: State) bool {
    return switch (state) {
        .Completed, .Failed, .Cancelled => true,
        else => false,
    };
}
pub fn cancel(state: *std.atomic.Value(State)) bool {
    var current = state.load(.acquire);
    while (!terminal(current)) {
        current = state.cmpxchgStrong(current, .Cancelled, .acq_rel, .acquire) orelse return true;
    }
    return false;
}
/// Called only by the poll owner, after publishing any result payload.
pub fn finishPoll(state: *std.atomic.Value(State), ready: bool) bool {
    const next: State = if (ready) .Completed else .Pending;
    if (state.cmpxchgStrong(.Running, next, .release, .monotonic)) |actual| return terminal(actual);
    return ready;
}
test "cancel between poll reservation and completion cannot be overwritten" {
    for ([_]bool{ false, true }) |ready| {
        var state = std.atomic.Value(State).init(.Running);
        try std.testing.expect(cancel(&state));
        try std.testing.expect(finishPoll(&state, ready));
        try std.testing.expectEqual(State.Cancelled, state.load(.acquire));
    }
}
test "completion and failure are immutable and pending polls remain resumable" {
    for ([_]State{ .Completed, .Failed, .Cancelled }) |terminal_state| {
        var state = std.atomic.Value(State).init(terminal_state);
        try std.testing.expect(!cancel(&state));
        try std.testing.expectEqual(terminal_state, state.load(.acquire));
    }
    var state = std.atomic.Value(State).init(.Running);
    try std.testing.expect(!finishPoll(&state, false));
    try std.testing.expectEqual(State.Pending, state.load(.acquire));
    state.store(.Running, .release);
    try std.testing.expect(finishPoll(&state, true));
    try std.testing.expectEqual(State.Completed, state.load(.acquire));
}
