//! Soft rotation thresholds: caller stages a keyframe-aligned split when due.
const std = @import("std");
pub const Policy = struct {
    duration_ns: u64 = 0,
    max_bytes: u64 = 0,
    pub fn due(s: Policy, frames: u64, elapsed_ns: u64, bytes: u64, pending: bool) bool {
        return frames > 0 and !pending and ((s.duration_ns != 0 and elapsed_ns >= s.duration_ns) or (s.max_bytes != 0 and bytes >= s.max_bytes));
    }
};
/// Irreversible media finalization. Caller serializes codec/container ownership.
/// A completed flush replays its result without entering an encoder again.
pub const Finalization = struct {
    pub const Phase = enum(u32) { open, running, finished, failed };
    phase: Phase = .open,
    code: i32 = 0,
    pub fn accepting(s: Finalization) bool {
        return s.phase == .open;
    }
    pub fn begin(s: *Finalization) !bool {
        switch (s.phase) {
            .open => {
                s.phase = .running;
                return true;
            },
            .running => return error.Busy,
            .finished, .failed => return false,
        }
    }
    pub fn complete(s: *Finalization, code: i32) !void {
        if (s.phase != .running) return error.InvalidState;
        if (code > 0) return error.InvalidResult;
        s.code = code;
        s.phase = if (code == 0) .finished else .failed;
    }
};
test "finalization enters once, rejects concurrent entry, and replays success or failure" {
    for ([_]i32{ 0, -6 }) |code| {
        var f: Finalization = .{};
        try std.testing.expect(f.accepting());
        try std.testing.expectError(error.InvalidState, f.complete(code));
        try std.testing.expect(try f.begin());
        try std.testing.expect(!f.accepting());
        try std.testing.expectError(error.Busy, f.begin());
        try std.testing.expectError(error.InvalidResult, f.complete(1));
        try std.testing.expectEqual(Finalization.Phase.running, f.phase);
        try f.complete(code);
        try std.testing.expect(!try f.begin());
        try std.testing.expectEqual(code, f.code);
        try std.testing.expectError(error.InvalidState, f.complete(0));
        try std.testing.expectEqual(code, f.code);
    }
}
test "thresholds include equality, ignore empty and pending segments, and can disable" {
    const p = Policy{ .duration_ns = 100, .max_bytes = 200 };
    try std.testing.expect(!p.due(0, 100, 200, false));
    try std.testing.expect(!p.due(1, 100, 200, true));
    try std.testing.expect(!p.due(1, 99, 199, false));
    try std.testing.expect(p.due(1, 100, 0, false));
    try std.testing.expect(p.due(1, 0, 200, false));
    try std.testing.expect(!(Policy{}).due(1, 100, 200, false));
}
